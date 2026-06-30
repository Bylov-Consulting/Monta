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
    ///       // "writeOff": [ ... ]        - reserved for slice 6; absent in slice 5.
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
    [CommitBehavior(CommitBehavior::Ignore)]
    procedure PostAndReconcile(Request: JsonObject): JsonObject
    var
        PmtReconPost: Codeunit "MON Pmt Recon Post";
        PmtReconMatch: Codeunit "MON Pmt Recon Match";
        TempApplyBuffer: Record "MON Pmt Recon Apply Buf" temporary;
        Response: JsonObject;
        PaymentsTok: JsonToken;
        PaymentTok: JsonToken;
        AppliesToTok: JsonToken;
        AppliesToEntryTok: JsonToken;
        PaymentObj: JsonObject;
        AppliesToObj: JsonObject;
        BankAccountNo: Code[20];
        StatementNo: Code[20];
        JournalTemplateName: Code[10];
        JournalBatchName: Code[10];
        ExternalDocumentNo: Code[35];
        CustomerNo: Code[20];
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
                TempApplyBuffer."Customer No." := CustomerNo;
                TempApplyBuffer."Cust. Ledger Entry No." := this.GetInt(AppliesToObj, 'custLedgerEntryNo');
                TempApplyBuffer."Amount to Apply" := this.GetDecimal(AppliesToObj, 'amount');
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

        // --- Build the response per the stable contract ---
        // MatchBankEntryToReconLine either succeeds or raises, so reaching here proves the match
        // was applied -> reconciliationLineMatched is unconditionally true on this path.
        Response.Add('bankAccountLedgerEntryNo', BankAccountLedgerEntryNo);
        Response.Add('reconciliationLineMatched', true);
        exit(Response);
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
