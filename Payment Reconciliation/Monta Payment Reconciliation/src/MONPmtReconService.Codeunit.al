codeunit 50202 "MON Pmt Recon Service"
{
    Access = Public;

    var
        AlreadyReconciledErr: Label 'Reconciliation line %1/%2 has already been reconciled by a different request.', Comment = '%1 = Statement No., %2 = Statement Line No.';
        InvalidRequestErr: Label 'The request body is not a valid JSON object.';
        RequiredFieldErr: Label 'The request is missing required field ''%1''.', Comment = '%1 = the missing JSON field name';
        NoPaymentsErr: Label 'The request must contain at least one payment.';
        PaymentNoAppliesErr: Label 'Each payment must apply to at least one customer ledger entry.';
        DuplicateApplyErr: Label 'Customer ledger entry %1 appears more than once in the request.', Comment = '%1 = Cust. Ledger Entry No.';
        SuccessTelemetryTxt: Label 'PostAndReconcile posted and matched the reconciliation line.', Locked = true;

    /// <summary>
    /// Text-boundary wrapper over <see cref="PostAndReconcile"/> for the OData [ServiceEnabled] bound
    /// action: the agent sends the request as a JSON string and receives the response as a JSON string.
    /// Parses the text into the JsonObject contract, runs the composite, and serialises the response
    /// back to text. ALL business logic lives in PostAndReconcile (fully unit-tested across slices 3-7);
    /// this only crosses the Text&lt;-&gt;JSON boundary that an OData action parameter (Edm.String) needs,
    /// keeping the bound action on the API page a one-line delegation.
    /// </summary>
    /// <param name="Request">The composite request (see PostAndReconcile) serialised as a JSON string.</param>
    /// <returns>The PostAndReconcile response serialised as a JSON string.</returns>
    [CommitBehavior(CommitBehavior::Ignore)]
    procedure PostAndReconcileJson(Request: Text): Text
    var
        RequestObj: JsonObject;
        ResponseObj: JsonObject;
        ResponseText: Text;
    begin
        if not RequestObj.ReadFrom(Request) then
            Error(InvalidRequestErr);
        ResponseObj := this.PostAndReconcile(RequestObj);
        ResponseObj.WriteTo(ResponseText);
        exit(ResponseText);
    end;

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
    /// the request is hashed CANONICALLY (order-independent — JSON key order and collection order do not
    /// matter), so a retry with the same content replays; a different payload for the same line is a conflict.</remarks>
    [CommitBehavior(CommitBehavior::Ignore)]
    procedure PostAndReconcile(Request: JsonObject): JsonObject
    var
        PmtReconLog: Record "MON Pmt Recon Log";
        BankAccountLedgerEntry: Record "Bank Account Ledger Entry";
        TempApplyBuffer: Record "MON Pmt Recon Apply Buf" temporary;
        PmtReconPost: Codeunit "MON Pmt Recon Post";
        PmtReconMatch: Codeunit "MON Pmt Recon Match";
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
        PostingDate: Date;
    begin
        // --- Validate the request schema up front (BEFORE the idempotency gate and any posting) so the
        // agent caller gets a clear, actionable error instead of an opaque downstream failure. ---
        this.ValidateRequest(Request);

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
        // Insert below. NOTE: the hash is CANONICAL (over the request's semantic content in a fixed,
        // sorted order — see ComputeRequestHash), so a retry replays as long as it carries the same logical
        // content, even if its JSON keys/elements are serialized in a different order. ---
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

        // --- Resolve the posting date from the reconciliation line so the payment posts on the date the
        // cash moved at the bank (never today's WorkDate); the bank ledger entry then lands in the same
        // period as the statement it reconciles. See ResolvePostingDate for the transaction-date ->
        // statement-date -> WorkDate fallback chain. ---
        PostingDate := this.ResolvePostingDate(BankAccountNo, StatementNo, StatementLineNo);

        // --- Compose post + match in ONE transaction (NO intermediate Commit -> atomic) ---
        // ONE balanced posting for the grand TOTAL -> ONE open Bank Account Ledger Entry, matched 1:1.
        BankAccountLedgerEntryNo :=
            PmtReconPost.PostCustomerPaymentsToBank(
                TempApplyBuffer, BankAccountNo, PostingDate,
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
        this.LogSuccess(BankAccountNo, StatementNo, StatementLineNo, ExternalDocumentNo, BankAccountLedgerEntryNo);

        // --- Build the response per the stable contract ---
        // MatchBankEntryToReconLine either succeeds or raises, so reaching here proves the match
        // was applied -> reconciliationLineMatched is unconditionally true on this path.
        exit(this.BuildResponse(BankAccountLedgerEntryNo));
    end;

    /// <summary>
    /// Validates the request schema BEFORE the idempotency gate / any posting, so a malformed request is
    /// rejected with a clear, actionable error rather than an opaque downstream failure:
    /// (1) each required header field (bankAccountNo, statementNo, journalTemplateName, journalBatchName)
    ///     must be present and non-blank; (2) payments must be a non-empty array; (3) each payment must
    ///     carry a non-empty appliesTo array; (4) no custLedgerEntryNo may repeat within one payment.
    /// </summary>
    local procedure ValidateRequest(Request: JsonObject)
    var
        PaymentsTok: JsonToken;
        PaymentTok: JsonToken;
        AppliesToTok: JsonToken;
        AppliesToEntryTok: JsonToken;
        PaymentObj: JsonObject;
        SeenEntryNos: List of [Integer];
        CustLedgerEntryNo: Integer;
    begin
        // (1) Required header fields: absent OR blank text value is rejected.
        this.ValidateRequiredField(Request, 'bankAccountNo');
        this.ValidateRequiredField(Request, 'statementNo');
        this.ValidateRequiredField(Request, 'journalTemplateName');
        this.ValidateRequiredField(Request, 'journalBatchName');
        // statementLineNo is required (and one third of the recon-line / idempotency key). GetInt defaults a
        // missing/blank value to 0, which is never a real statement line no., so 0 means "missing".
        if this.GetInt(Request, 'statementLineNo') = 0 then
            Error(RequiredFieldErr, 'statementLineNo');

        // (2) payments must be present, an array, and non-empty.
        if not Request.Get('payments', PaymentsTok) then
            Error(NoPaymentsErr);
        if not PaymentsTok.IsArray() then
            Error(NoPaymentsErr);
        if PaymentsTok.AsArray().Count() = 0 then
            Error(NoPaymentsErr);

        // (3) + (4) per-payment appliesTo presence and duplicate detection.
        foreach PaymentTok in PaymentsTok.AsArray() do begin
            PaymentObj := PaymentTok.AsObject();

            if not PaymentObj.Get('appliesTo', AppliesToTok) then
                Error(PaymentNoAppliesErr);
            if not AppliesToTok.IsArray() then
                Error(PaymentNoAppliesErr);
            if AppliesToTok.AsArray().Count() = 0 then
                Error(PaymentNoAppliesErr);

            Clear(SeenEntryNos);
            foreach AppliesToEntryTok in AppliesToTok.AsArray() do begin
                CustLedgerEntryNo := this.GetInt(AppliesToEntryTok.AsObject(), 'custLedgerEntryNo');
                if SeenEntryNos.Contains(CustLedgerEntryNo) then
                    Error(DuplicateApplyErr, CustLedgerEntryNo);
                SeenEntryNos.Add(CustLedgerEntryNo);
            end;
        end;
    end;

    /// <summary>
    /// Resolves the date the payment must post on, from the reconciliation line being matched:
    /// the line's Transaction Date (the date the cash actually moved at the bank), falling back to the
    /// statement header's Statement Date when the line carries none, and to WorkDate only as an absolute
    /// last resort (both dates blank — pathological on a real reconciliation). This keeps the posted bank
    /// ledger entry in the same period as the statement it reconciles, rather than on today's WorkDate.
    /// </summary>
    local procedure ResolvePostingDate(BankAccountNo: Code[20]; StatementNo: Code[20]; StatementLineNo: Integer): Date
    var
        BankAccReconLine: Record "Bank Acc. Reconciliation Line";
        BankAccRecon: Record "Bank Acc. Reconciliation";
    begin
        if BankAccReconLine.Get(
             BankAccReconLine."Statement Type"::"Bank Reconciliation", BankAccountNo, StatementNo, StatementLineNo)
        then
            if BankAccReconLine."Transaction Date" <> 0D then
                exit(BankAccReconLine."Transaction Date");
        if BankAccRecon.Get(
             BankAccRecon."Statement Type"::"Bank Reconciliation", BankAccountNo, StatementNo)
        then
            if BankAccRecon."Statement Date" <> 0D then
                exit(BankAccRecon."Statement Date");
        exit(WorkDate());
    end;

    /// <summary>Rejects an absent or blank required header field with the field-naming RequiredFieldErr.</summary>
    local procedure ValidateRequiredField(Request: JsonObject; FieldName: Text)
    begin
        if this.GetText(Request, FieldName) = '' then
            Error(RequiredFieldErr, FieldName);
    end;

    /// <summary>Emits operational success telemetry with the recon-line identity and the bank entry created.</summary>
    local procedure LogSuccess(BankAccountNo: Code[20]; StatementNo: Code[20]; StatementLineNo: Integer; ExternalDocumentNo: Code[35]; BankAccountLedgerEntryNo: Integer)
    var
        TelemetryDims: Dictionary of [Text, Text];
    begin
        TelemetryDims.Add('operation', 'PostAndReconcile');
        TelemetryDims.Add('result', 'Success');
        TelemetryDims.Add('bankAccountNo', BankAccountNo);
        TelemetryDims.Add('statementNo', StatementNo);
        TelemetryDims.Add('statementLineNo', Format(StatementLineNo));
        TelemetryDims.Add('externalDocumentNo', ExternalDocumentNo);
        TelemetryDims.Add('bankAccountLedgerEntryNo', Format(BankAccountLedgerEntryNo));
        // OrganizationIdentifiableInformation: bankAccountNo/statementNo/externalDocumentNo are
        // user-managed organisational codes, not system-internal metadata.
        Session.LogMessage('MON-PR-0001', SuccessTelemetryTxt, Verbosity::Normal, DataClassification::OrganizationIdentifiableInformation, TelemetryScope::ExtensionPublisher, TelemetryDims);
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
    /// Stable SHA256 hex digest of the request's SEMANTIC content, used as the idempotency fingerprint.
    /// Unlike a raw WriteTo serialisation (which is sensitive to JSON key/element insertion order), this
    /// hashes a CANONICAL STRING built from the parsed/typed values in a FIXED, deterministic order with
    /// the payment / appliesTo / writeOff collections SORTED — so two requests with identical logical
    /// content hash EQUAL regardless of key or element order (replay), while any change to a value
    /// (customer / invoice / amount / etc.) changes the canonical string and therefore the hash (conflict).
    /// Standard System Application hashing — no external dependency.
    /// </summary>
    local procedure ComputeRequestHash(Request: JsonObject): Code[64]
    var
        CryptographyManagement: Codeunit "Cryptography Management";
        HashAlgorithmType: Option MD5,SHA1,SHA256,SHA384,SHA512;
        CanonicalText: Text;
    begin
        CanonicalText := this.BuildCanonicalRequest(Request);
        exit(CopyStr(CryptographyManagement.GenerateHash(CanonicalText, HashAlgorithmType::SHA256), 1, 64));
    end;

    /// <summary>
    /// Builds the order-independent canonical string the idempotency hash is taken over. Header scalars are
    /// emitted in a FIXED field order (typed, so '1'/'01'/whitespace and decimal rendering normalise); the
    /// payments are each canonicalised then SORTED so payment order is irrelevant. The delimiters ('|' between
    /// fields, '~' between records, ':' within an entry) are ASSUMED not to occur in BC-standard code values —
    /// a practical convention, NOT a type guarantee (a Code field can technically hold any character). For the
    /// controlled Monta agent with alphanumeric codes this holds; length-prefixing would remove even that
    /// assumption (tracked as optional hardening).
    /// </summary>
    local procedure BuildCanonicalRequest(Request: JsonObject): Text
    var
        PaymentsTok: JsonToken;
        PaymentTok: JsonToken;
        PaymentCanonicals: List of [Text];
        PaymentCanonical: Text;
        HeaderSegment: Text;
        PaymentsSegment: TextBuilder;
    begin
        HeaderSegment :=
            this.GetText(Request, 'bankAccountNo') + '|' +
            this.GetText(Request, 'statementNo') + '|' +
            Format(this.GetInt(Request, 'statementLineNo')) + '|' +
            this.GetText(Request, 'journalTemplateName') + '|' +
            this.GetText(Request, 'journalBatchName') + '|' +
            this.GetText(Request, 'externalDocumentNo');

        if Request.Get('payments', PaymentsTok) then
            foreach PaymentTok in PaymentsTok.AsArray() do
                PaymentCanonicals.Add(this.BuildCanonicalPayment(PaymentTok.AsObject()));
        this.SortTextList(PaymentCanonicals);
        foreach PaymentCanonical in PaymentCanonicals do
            PaymentsSegment.Append(PaymentCanonical + '~');

        exit(HeaderSegment + '~~' + PaymentsSegment.ToText());
    end;

    /// <summary>
    /// Canonical sub-string for ONE payment: customerNo, then its appliesTo entries (custLedgerEntryNo:amount)
    /// SORTED, then its writeOff entries (glAccountNo:amount) SORTED. Sorting both collections makes element
    /// order within a payment irrelevant; amounts use the invariant Format(.., 0, 9) so decimal rendering is
    /// stable. The 'A'/'W' section markers keep an appliesTo entry from ever aliasing a writeOff entry.
    /// </summary>
    local procedure BuildCanonicalPayment(PaymentObj: JsonObject): Text
    var
        AppliesToTok: JsonToken;
        WriteOffTok: JsonToken;
        EntryTok: JsonToken;
        EntryObj: JsonObject;
        AppliesEntries: List of [Text];
        WriteOffEntries: List of [Text];
        EntryText: Text;
        Result: TextBuilder;
    begin
        Result.Append(this.GetText(PaymentObj, 'customerNo'));

        if PaymentObj.Get('appliesTo', AppliesToTok) then
            foreach EntryTok in AppliesToTok.AsArray() do begin
                EntryObj := EntryTok.AsObject();
                AppliesEntries.Add(
                    Format(this.GetInt(EntryObj, 'custLedgerEntryNo')) + ':' +
                    Format(this.GetDecimal(EntryObj, 'amount'), 0, 9));
            end;
        this.SortTextList(AppliesEntries);
        Result.Append('|A');
        foreach EntryText in AppliesEntries do
            Result.Append('|' + EntryText);

        if PaymentObj.Get('writeOff', WriteOffTok) then
            foreach EntryTok in WriteOffTok.AsArray() do begin
                EntryObj := EntryTok.AsObject();
                WriteOffEntries.Add(
                    this.GetText(EntryObj, 'glAccountNo') + ':' +
                    Format(this.GetDecimal(EntryObj, 'amount'), 0, 9));
            end;
        this.SortTextList(WriteOffEntries);
        Result.Append('|W');
        foreach EntryText in WriteOffEntries do
            Result.Append('|' + EntryText);

        exit(Result.ToText());
    end;

    /// <summary>
    /// Deterministic in-place ascending sort of a List of [Text] (AL's List has no built-in Sort). Simple
    /// insertion sort: stable and fully deterministic, so an identical multiset of entries always yields the
    /// identical ordered sequence — which is what makes the canonical string order-independent.
    /// </summary>
    local procedure SortTextList(var Items: List of [Text])
    var
        Sorted: List of [Text];
        Item: Text;
        Inserted: Boolean;
        Index: Integer;
    begin
        foreach Item in Items do begin
            Inserted := false;
            for Index := 1 to Sorted.Count() do
                if Item < Sorted.Get(Index) then begin
                    Sorted.Insert(Index, Item);
                    Inserted := true;
                    break;
                end;
            if not Inserted then
                Sorted.Add(Item);
        end;
        Items := Sorted;
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
