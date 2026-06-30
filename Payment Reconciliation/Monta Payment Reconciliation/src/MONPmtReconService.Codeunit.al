codeunit 50202 "MON Pmt Recon Service"
{
    Access = Public;

    /// <summary>
    /// Agent-facing composite: in ONE transaction (no intermediate Commit) posts an incoming
    /// customer payment to the bank — creating the open Bank Account Ledger Entry — AND matches that
    /// entry to the named standard Bank Acc. Reconciliation line, achieving the combined effect of
    /// <see cref="MON Pmt Recon Post.PostCustomerPaymentToBank"/> (slice 1) and
    /// <see cref="MON Pmt Recon Match.MatchBankEntryToReconLine"/> (slice 2) in a single call.
    /// Standard BC only (tables 271/273/274) — no Continia.
    ///
    /// STABLE JSON CONTRACT (later slices extend it WITHOUT breaking these keys).
    ///
    /// Request:
    /// {
    ///   "bankAccountNo":       Code[20]  - bank account the payment is received into and that the
    ///                                      reconciliation belongs to.
    ///   "statementNo":         Code[20]  - Statement No. of the Bank Acc. Reconciliation
    ///                                      (Statement Type = Bank Reconciliation).
    ///   "statementLineNo":     Integer   - Statement Line No. of the reconciliation line to match.
    ///   "journalTemplateName": Code[10]  - Gen. journal template used to post the payment.
    ///   "journalBatchName":    Code[10]  - Gen. journal batch (within the template).
    ///   "externalDocumentNo":  Code[35]  - optional external document reference stamped on the line.
    ///   "payments": [                     - slice 5: ONE OR MORE entries (one per customer).
    ///     {
    ///       "customerNo": Code[20]        - customer whose payment is being posted.
    ///       "appliesTo": [                - ONE OR MORE entries (this customer's N invoices).
    ///         {
    ///           "custLedgerEntryNo": Integer - open Cust. Ledger Entry (invoice) settled by this apply.
    ///           "amount":            Decimal - the received amount for this application (> 0).
    ///         }
    ///       ]
    ///       "writeOff": [                 - slice 6: OPTIONAL; ZERO OR MORE payment-difference write-offs.
    ///         {
    ///           "glAccountNo": Code[20]   - direct-posting G/L account the difference is debited to.
    ///           "amount":      Decimal    - the write-off amount W (> 0); never reaches the bank.
    ///         }
    ///       ]
    ///     }
    ///   ]
    /// }
    ///
    /// Response (at least):
    /// {
    ///   "bankAccountLedgerEntryNo": Integer - Entry No. of the open Bank Account Ledger Entry the
    ///                                         posting created (the receipt that was reconciled).
    ///   "reconciliationLineMatched": Boolean - true once the reconciliation line carries the match.
    /// }
    /// </summary>
    /// <param name="Request">The composite request described above.</param>
    /// <returns>The response described above.</returns>
    /// <remarks>Idempotent on the reconciliation line (Bank Account No. + Statement No. + Statement Line No.):
    /// a retry MUST resend a byte-identical request body to be recognised as a replay; a different payload for
    /// the same line is rejected as a conflict.</remarks>
    var
        AlreadyReconciledErr: Label 'Reconciliation line %1/%2 has already been reconciled by a different request.', Comment = '%1 = Statement No., %2 = Statement Line No.';
        SuccessTelemetryTxt: Label 'PostAndReconcile posted and matched the reconciliation line.', Locked = true;

    [CommitBehavior(CommitBehavior::Ignore)]
    procedure PostAndReconcile(Request: JsonObject): JsonObject
    var
        PmtReconPost: Codeunit "MON Pmt Recon Post";
        PmtReconMatch: Codeunit "MON Pmt Recon Match";
        PmtReconLog: Record "MON Pmt Recon Log";
        BankAccountLedgerEntry: Record "Bank Account Ledger Entry";
        TempApplyBuffer: Record "MON Pmt Recon Apply Buf" temporary;
        PaymentsTok: JsonToken;
        PaymentTok: JsonToken;
        AppliesToTok: JsonToken;
        AppliesToEntryTok: JsonToken;
        WriteOffTok: JsonToken;
        WriteOffEntryTok: JsonToken;
        PaymentObj: JsonObject;
        AppliesToObj: JsonObject;
        WriteOffObj: JsonObject;
        BankAccountNo: Code[20];
        StatementNo: Code[20];
        JournalTemplateName: Code[10];
        JournalBatchName: Code[10];
        ExternalDocumentNo: Code[35];
        CustomerNo: Code[20];
        RequestHash: Code[64];
        StatementLineNo: Integer;
        BufLineNo: Integer;
        BankAccountLedgerEntryNo: Integer;
    begin
        // --- Parse the header scalars (settled happy-path shape) ---
        BankAccountNo := CopyStr(this.GetText(Request, 'bankAccountNo'), 1, MaxStrLen(BankAccountNo));
        StatementNo := CopyStr(this.GetText(Request, 'statementNo'), 1, MaxStrLen(StatementNo));
        StatementLineNo := this.GetInt(Request, 'statementLineNo');
        JournalTemplateName := CopyStr(this.GetText(Request, 'journalTemplateName'), 1, MaxStrLen(JournalTemplateName));
        JournalBatchName := CopyStr(this.GetText(Request, 'journalBatchName'), 1, MaxStrLen(JournalBatchName));
        ExternalDocumentNo := CopyStr(this.GetText(Request, 'externalDocumentNo'), 1, MaxStrLen(ExternalDocumentNo));

        // --- Idempotency: the reconciliation line identity is the key. A completed call left a Posted log
        // row for that line; a later call for the SAME line replays its cached result (identical request)
        // or is rejected as a conflict (a different payload / hash). Checked BEFORE any posting so a replay
        // posts nothing and a conflict creates no second receipt. The PRIMARY scenario is a cross-transaction
        // agent retry that reads the prior call's COMMITTED row; an in-transaction repeat reading the prior
        // uncommitted row is a secondary benefit. LockTable serializes concurrent first-time calls for the
        // same line so the loser surfaces the designed conflict error, not a raw duplicate-key error from the
        // Insert below. NOTE: the hash is over the serialized request, so a retry must resend a byte-identical
        // JSON body to replay (see <remarks>); an order-independent canonical hash would relax this. ---
        RequestHash := this.ComputeRequestHash(Request);
        PmtReconLog.LockTable();
        if PmtReconLog.Get(BankAccountNo, StatementNo, StatementLineNo) then
            // A Failed row (reserved for slice 8) is retryable -> fall through to re-post; only Posted gates.
            if PmtReconLog.Status = PmtReconLog.Status::Posted then begin
                if PmtReconLog."Request Hash" = RequestHash then
                    exit(this.BuildResponse(PmtReconLog."Bank Acc. Ledger Entry No.")); // idempotent replay
                Error(AlreadyReconciledErr, StatementNo, StatementLineNo); // conflicting replay
            end;

        // --- Flatten EVERY payment (slice 5: one or more customers) and its FULL appliesTo set into the
        // per-customer buffer: one row per (customer, invoice, amount) so the unified poster builds one
        // balanced document = one payment line per customer + one bank line for the grand total. ---
        Request.Get('payments', PaymentsTok);
        foreach PaymentTok in PaymentsTok.AsArray() do begin
            PaymentObj := PaymentTok.AsObject();
            CustomerNo := CopyStr(this.GetText(PaymentObj, 'customerNo'), 1, MaxStrLen(CustomerNo));

            PaymentObj.Get('appliesTo', AppliesToTok);
            foreach AppliesToEntryTok in AppliesToTok.AsArray() do begin
                AppliesToObj := AppliesToEntryTok.AsObject();
                BufLineNo += 1;
                TempApplyBuffer.Init();
                TempApplyBuffer."Entry No." := BufLineNo;
                TempApplyBuffer."Line Type" := TempApplyBuffer."Line Type"::"Customer Apply";
                TempApplyBuffer."Customer No." := CustomerNo;
                TempApplyBuffer."Cust. Ledger Entry No." := this.GetInt(AppliesToObj, 'custLedgerEntryNo');
                TempApplyBuffer."Amount to Apply" := this.GetDecimal(AppliesToObj, 'amount');
                TempApplyBuffer.Insert();
            end;

            // Slice 6 (OPTIONAL): each writeOff entry absorbs the payment difference for this customer onto
            // an agent-supplied G/L account. Absent on slices 3-5 requests -> no write-off rows, so the
            // poster behaves exactly as before (bank = Σ applies).
            if PaymentObj.Get('writeOff', WriteOffTok) then
                foreach WriteOffEntryTok in WriteOffTok.AsArray() do begin
                    WriteOffObj := WriteOffEntryTok.AsObject();
                    BufLineNo += 1;
                    TempApplyBuffer.Init();
                    TempApplyBuffer."Entry No." := BufLineNo;
                    TempApplyBuffer."Line Type" := TempApplyBuffer."Line Type"::"Write-Off";
                    TempApplyBuffer."Customer No." := CustomerNo;
                    TempApplyBuffer."G/L Account No." := CopyStr(this.GetText(WriteOffObj, 'glAccountNo'), 1, MaxStrLen(TempApplyBuffer."G/L Account No."));
                    TempApplyBuffer."Amount to Apply" := this.GetDecimal(WriteOffObj, 'amount');
                    TempApplyBuffer.Insert();
                end;
        end;

        // --- Compose post + match in ONE transaction (NO intermediate Commit -> atomic) ---
        // ONE balanced posting for the grand TOTAL -> ONE open Bank Account Ledger Entry, matched 1:1.
        BankAccountLedgerEntryNo :=
            PmtReconPost.PostCustomerPaymentsToBank(
                TempApplyBuffer, BankAccountNo,
                JournalTemplateName, JournalBatchName, ExternalDocumentNo);

        PmtReconMatch.MatchBankEntryToReconLine(
            BankAccountNo, StatementNo, StatementLineNo, BankAccountLedgerEntryNo);

        // --- Record the idempotency log row so any later call for this reconciliation line replays (same
        // request) or is rejected as a conflict (different request). No intermediate Commit: the row is
        // part of this single transaction and is committed at the outer boundary together with the posting
        // and match. ---
        PmtReconLog.Init();
        PmtReconLog."Bank Account No." := BankAccountNo;
        PmtReconLog."Statement No." := StatementNo;
        PmtReconLog."Statement Line No." := StatementLineNo;
        PmtReconLog.Status := PmtReconLog.Status::Posted;
        PmtReconLog."Request Hash" := RequestHash;
        PmtReconLog."Bank Acc. Ledger Entry No." := BankAccountLedgerEntryNo;
        BankAccountLedgerEntry.SetLoadFields("Document No.");
        if BankAccountLedgerEntry.Get(BankAccountLedgerEntryNo) then
            PmtReconLog."Payment Document No." := BankAccountLedgerEntry."Document No.";
        PmtReconLog.Insert(false);

        // Operational success telemetry (custom dimensions). Failures are not caught here — they propagate
        // and are captured by BC's built-in platform error telemetry; a catch wrapper (Codeunit.Run) was
        // rejected because it breaks the test framework's transaction isolation. Verified in the smoke test.
        this.LogSuccess(BankAccountNo, StatementNo, StatementLineNo, BankAccountLedgerEntryNo);

        // --- Build the response per the stable contract ---
        // MatchBankEntryToReconLine either succeeds or raises, so reaching here proves the match
        // was applied -> reconciliationLineMatched is unconditionally true on this path.
        exit(this.BuildResponse(BankAccountLedgerEntryNo));
    end;

    /// <summary>Emits operational success telemetry with the recon-line identity and the bank entry created.</summary>
    local procedure LogSuccess(BankAccountNo: Code[20]; StatementNo: Code[20]; StatementLineNo: Integer; BankAccountLedgerEntryNo: Integer)
    var
        TelemetryDims: Dictionary of [Text, Text];
    begin
        TelemetryDims.Add('operation', 'PostAndReconcile');
        TelemetryDims.Add('result', 'Success');
        TelemetryDims.Add('bankAccountNo', BankAccountNo);
        TelemetryDims.Add('statementNo', StatementNo);
        TelemetryDims.Add('statementLineNo', Format(StatementLineNo));
        TelemetryDims.Add('bankAccountLedgerEntryNo', Format(BankAccountLedgerEntryNo));
        Session.LogMessage('MON-PR-0001', SuccessTelemetryTxt, Verbosity::Normal, DataClassification::SystemMetadata, TelemetryScope::ExtensionPublisher, TelemetryDims);
    end;

    /// <summary>
    /// Builds the stable response: the open Bank Account Ledger Entry No. of the reconciled receipt plus
    /// reconciliationLineMatched = true. Used both on the fresh post+match path and the idempotent replay
    /// path, so both return the IDENTICAL shape and the cached entry replays verbatim.
    /// </summary>
    local procedure BuildResponse(BankAccountLedgerEntryNo: Integer): JsonObject
    var
        Response: JsonObject;
    begin
        Response.Add('bankAccountLedgerEntryNo', BankAccountLedgerEntryNo);
        Response.Add('reconciliationLineMatched', true);
        exit(Response);
    end;

    /// <summary>
    /// Stable SHA256 hex digest of the WHOLE request (header scalars + payments), used as the idempotency
    /// fingerprint. The same JsonObject serialises to the same text, so an identical request hashes equal
    /// (replay), while any change to customer / invoice / amount / etc. changes the text and therefore the
    /// hash (conflict). Standard System Application hashing — no external dependency.
    /// </summary>
    local procedure ComputeRequestHash(Request: JsonObject): Code[64]
    var
        CryptographyManagement: Codeunit "Cryptography Management";
        HashAlgorithmType: Option MD5,SHA1,SHA256,SHA384,SHA512;
        RequestText: Text;
    begin
        Request.WriteTo(RequestText);
        exit(CopyStr(CryptographyManagement.GenerateHash(RequestText, HashAlgorithmType::SHA256), 1, 64));
    end;

    local procedure GetText(Obj: JsonObject; KeyName: Text): Text
    var
        Token: JsonToken;
    begin
        if Obj.Get(KeyName, Token) then
            exit(Token.AsValue().AsText());
        exit('');
    end;

    local procedure GetInt(Obj: JsonObject; KeyName: Text): Integer
    var
        Token: JsonToken;
    begin
        if Obj.Get(KeyName, Token) then
            exit(Token.AsValue().AsInteger());
        exit(0);
    end;

    local procedure GetDecimal(Obj: JsonObject; KeyName: Text): Decimal
    var
        Token: JsonToken;
    begin
        if Obj.Get(KeyName, Token) then
            exit(Token.AsValue().AsDecimal());
        exit(0);
    end;
}
