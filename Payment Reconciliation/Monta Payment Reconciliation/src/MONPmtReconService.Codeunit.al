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
    ///   "payments": [                     - slice 3: EXACTLY one entry (slices 4-5 allow many).
    ///     {
    ///       "customerNo": Code[20]        - customer whose payment is being posted.
    ///       "appliesTo": [                - slice 3: EXACTLY one entry (slices 4-5 allow many).
    ///         {
    ///           "custLedgerEntryNo": Integer - open Cust. Ledger Entry (invoice) settled in full.
    ///           "amount":            Decimal - the received amount for this application (> 0).
    ///         }
    ///       ]
    ///       // "writeOff": [ ... ]        - reserved for slice 6; absent in slice 3.
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
    procedure PostAndReconcile(Request: JsonObject): JsonObject
    var
        PmtReconPost: Codeunit "MON Pmt Recon Post";
        PmtReconMatch: Codeunit "MON Pmt Recon Match";
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
        CustLedgerEntryNo: Integer;
        Amount: Decimal;
        BankAccountLedgerEntryNo: Integer;
    begin
        // --- Parse the header scalars (slice 3 assumes the settled happy-path shape) ---
        BankAccountNo := CopyStr(GetText(Request, 'bankAccountNo'), 1, MaxStrLen(BankAccountNo));
        StatementNo := CopyStr(GetText(Request, 'statementNo'), 1, MaxStrLen(StatementNo));
        StatementLineNo := GetInt(Request, 'statementLineNo');
        JournalTemplateName := CopyStr(GetText(Request, 'journalTemplateName'), 1, MaxStrLen(JournalTemplateName));
        JournalBatchName := CopyStr(GetText(Request, 'journalBatchName'), 1, MaxStrLen(JournalBatchName));
        ExternalDocumentNo := CopyStr(GetText(Request, 'externalDocumentNo'), 1, MaxStrLen(ExternalDocumentNo));

        // --- Parse payments[0] and its appliesTo[0] (slice 3: exactly one of each) ---
        Request.Get('payments', PaymentsTok);
        PaymentsTok.AsArray().Get(0, PaymentTok);
        PaymentObj := PaymentTok.AsObject();
        CustomerNo := CopyStr(GetText(PaymentObj, 'customerNo'), 1, MaxStrLen(CustomerNo));

        PaymentObj.Get('appliesTo', AppliesToTok);
        AppliesToTok.AsArray().Get(0, AppliesToEntryTok);
        AppliesToObj := AppliesToEntryTok.AsObject();
        CustLedgerEntryNo := GetInt(AppliesToObj, 'custLedgerEntryNo');
        Amount := GetDecimal(AppliesToObj, 'amount');

        // --- Compose post + match in ONE transaction (NO intermediate Commit -> atomic) ---
        BankAccountLedgerEntryNo :=
            PmtReconPost.PostCustomerPaymentToBank(
                CustomerNo, BankAccountNo, Amount, CustLedgerEntryNo,
                JournalTemplateName, JournalBatchName, ExternalDocumentNo);

        PmtReconMatch.MatchBankEntryToReconLine(
            BankAccountNo, StatementNo, StatementLineNo, BankAccountLedgerEntryNo);

        // --- Build the response per the stable contract ---
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
