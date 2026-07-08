codeunit 50303 "MON Bank Recon API Tests"
{
    Subtype = Test;
    TestPermissions = Disabled;

    var
        LibrarySales: Codeunit "Library - Sales";
        LibraryERM: Codeunit "Library - ERM";
        LibraryInventory: Codeunit "Library - Inventory";
        LibraryRandom: Codeunit "Library - Random";
        Assert: Codeunit "Library Assert";

    [Test]
    procedure ApiReturnsLinesRegardlessOfMatchStatus()
    var
        BankAccount: Record "Bank Account";
        BankAccReconciliation: Record "Bank Acc. Reconciliation";
        UnmatchedLine: Record "Bank Acc. Reconciliation Line";
        MatchedLine: Record "Bank Acc. Reconciliation Line";
        PmtReconMatch: Codeunit "MON Pmt Recon Match";
        BankReconLineAPI: TestPage "MON Bank Recon Line API";
        BankEntryNo: Integer;
        UnmatchedLineNo: Integer;
        MatchedLineNo: Integer;
        UnmatchedAmount: Decimal;
        MatchedAmount: Decimal;
        FoundUnmatched: Boolean;
        FoundMatched: Boolean;
        SeenStatementAmount: Decimal;
        SeenAppliedAmount: Decimal;
        SeenDifference: Decimal;
        SeenAppliedEntries: Integer;
    begin
        // [SCENARIO] The read API over standard Bank Acc. Reconciliation Lines (table 274,
        // Statement Type = Bank Reconciliation) must return EVERY line, regardless of whether it is
        // still unmatched or already fully applied/reconciled. The external agent decides which line
        // to act on, so the server must NOT pre-filter by applied/match status. This pins that an
        // already-matched (Difference = 0) line is STILL returned by the API.

        // [GIVEN] One bank account and one Bank Acc. Reconciliation (Statement Type = Bank Reconciliation).
        LibraryERM.CreateBankAccount(BankAccount);
        LibraryERM.CreateBankAccReconciliation(
            BankAccReconciliation, BankAccount."No.",
            BankAccReconciliation."Statement Type"::"Bank Reconciliation");

        // [GIVEN] Line A — UNMATCHED: a known Statement Amount fully outstanding (Applied Entries = 0,
        // Difference = Statement Amount). Nothing has been applied to it.
        UnmatchedAmount := LibraryRandom.RandDecInRange(100, 1000, 2);
        LibraryERM.CreateBankAccReconciliationLn(UnmatchedLine, BankAccReconciliation);
        UnmatchedLine.Validate("Statement Amount", UnmatchedAmount);
        UnmatchedLine.Difference := UnmatchedAmount; // unmatched: full amount outstanding
        UnmatchedLine.Modify(true);
        UnmatchedLineNo := UnmatchedLine."Statement Line No.";

        // [GIVEN] Line B — MATCHED: a second line on the SAME reconciliation, applied to a real open
        // bank receipt via slice 2 (known-green) so the line is fully reconciled (Applied Entries = 1,
        // Applied Amount = Statement Amount, Difference = 0).
        BankEntryNo := CreateOpenBankReceiptOn(BankAccount, MatchedAmount);
        LibraryERM.CreateBankAccReconciliationLn(MatchedLine, BankAccReconciliation);
        MatchedLine.Validate("Statement Amount", MatchedAmount);
        MatchedLine.Difference := MatchedAmount; // starts unmatched...
        MatchedLine.Modify(true);
        MatchedLineNo := MatchedLine."Statement Line No.";
        PmtReconMatch.MatchBankEntryToReconLine(
            BankAccount."No.", MatchedLine."Statement No.", MatchedLineNo, BankEntryNo);

        // [GIVEN] Confirm the arrange: A is genuinely unmatched (Difference <> 0), B is genuinely
        // matched (Difference = 0). These are exactly the states the server must NOT use to filter.
        UnmatchedLine.Get(
            UnmatchedLine."Statement Type"::"Bank Reconciliation",
            BankAccount."No.", BankAccReconciliation."Statement No.", UnmatchedLineNo);
        MatchedLine.Get(
            MatchedLine."Statement Type"::"Bank Reconciliation",
            BankAccount."No.", BankAccReconciliation."Statement No.", MatchedLineNo);
        Assert.AreNotEqual(
            0, UnmatchedLine.Difference,
            'Precondition: line A must be unmatched (non-zero Difference) before the API read.');
        Assert.AreEqual(
            0, MatchedLine.Difference,
            'Precondition: line B must be fully matched (zero Difference) before the API read.');
        Assert.AreEqual(
            1, MatchedLine."Applied Entries",
            'Precondition: line B must have exactly one applied entry before the API read.');

        // [WHEN] The agent reads the bank reconciliation lines through the API page. The page itself
        // must add NO status filter; the test scopes to THIS bank account + statement by comparing the
        // exposed identity values per row (so unrelated rows in the company are ignored).
        BankReconLineAPI.OpenView();

        FoundUnmatched := false;
        FoundMatched := false;
        if BankReconLineAPI.First() then
            repeat
                if (BankReconLineAPI.bankAccountNo.Value = BankAccount."No.") and
                   (BankReconLineAPI.statementNo.Value = BankAccReconciliation."Statement No.")
                then
                    case BankReconLineAPI.statementLineNo.AsInteger() of
                        UnmatchedLineNo:
                            FoundUnmatched := true;
                        MatchedLineNo:
                            begin
                                FoundMatched := true;
                                SeenStatementAmount := BankReconLineAPI.statementAmount.AsDecimal();
                                SeenAppliedAmount := BankReconLineAPI.appliedAmount.AsDecimal();
                                SeenDifference := BankReconLineAPI.difference.AsDecimal();
                                SeenAppliedEntries := BankReconLineAPI.appliedEntries.AsInteger();
                            end;
                    end;
            until not BankReconLineAPI.Next();
        BankReconLineAPI.Close();

        // [THEN] The UNMATCHED line is returned (sanity: the read is not empty / not over-filtered).
        Assert.IsTrue(
            FoundUnmatched,
            'The API must return the unmatched bank reconciliation line.');

        // [THEN] The MATCHED line is ALSO returned — the read is unfiltered by applied/match status.
        // RED: the page's "Difference = filter(<> 0)" SourceTableView clause hides this reconciled
        // line (Difference = 0), so it is absent from the result and this assertion FAILS. The API
        // must not hide reconciled lines.
        Assert.IsTrue(
            FoundMatched,
            'The API must also return the fully-matched (reconciled) line; the read must not be filtered by status.');

        // [THEN] For the matched line, the API exposes the record's true amounts (so the agent sees a
        // line is already reconciled instead of re-acting on it).
        Assert.AreEqual(
            MatchedLine."Statement Amount", SeenStatementAmount,
            'The API must expose the matched line''s Statement Amount.');
        Assert.AreEqual(
            MatchedLine."Applied Amount", SeenAppliedAmount,
            'The API must expose the matched line''s Applied Amount.');
        Assert.AreEqual(
            MatchedLine.Difference, SeenDifference,
            'The API must expose the matched line''s Difference (zero once reconciled).');
        Assert.AreEqual(
            MatchedLine."Applied Entries", SeenAppliedEntries,
            'The API must expose the matched line''s Applied Entries count.');
    end;

    /// <summary>
    /// Arranges exactly one OPEN Bank Account Ledger Entry on <paramref name="BankAccount"/> by posting a
    /// customer payment (slice 1) that fully settles a fresh posted sales invoice. Returns the new bank
    /// ledger Entry No. and outputs the signed receipt amount (the value to use as the matched
    /// reconciliation line's Statement Amount).
    /// </summary>
    local procedure CreateGenJnlBatchWithSeries(var GenJournalBatch: Record "Gen. Journal Batch"; TemplateName: Code[10])
    begin
        // The poster now rejects a batch with no No. Series, so posting tests must configure one.
        LibraryERM.CreateGenJournalBatch(GenJournalBatch, TemplateName);
        GenJournalBatch.Validate("No. Series", LibraryERM.CreateNoSeriesCode());
        GenJournalBatch.Modify(true);
    end;

    local procedure CreateOpenBankReceiptOn(var BankAccount: Record "Bank Account"; var StatementAmount: Decimal): Integer
    var
        Customer: Record Customer;
        Item: Record Item;
        GenJournalTemplate: Record "Gen. Journal Template";
        GenJournalBatch: Record "Gen. Journal Batch";
        SalesHeader: Record "Sales Header";
        SalesLine: Record "Sales Line";
        CustLedgerEntry: Record "Cust. Ledger Entry";
        BankAccLedgerEntry: Record "Bank Account Ledger Entry";
        PmtReconPost: Codeunit "MON Pmt Recon Post";
        PostedInvoiceNo: Code[20];
        BankEntryNo: Integer;
    begin
        LibrarySales.CreateCustomer(Customer);
        LibraryInventory.CreateItem(Item);
        LibrarySales.CreateSalesHeader(SalesHeader, SalesHeader."Document Type"::Invoice, Customer."No.");
        LibrarySales.CreateSalesLine(SalesLine, SalesHeader, SalesLine.Type::Item, Item."No.", 1);
        SalesLine.Validate("Unit Price", LibraryRandom.RandDecInRange(100, 1000, 2));
        SalesLine.Modify(true);
        PostedInvoiceNo := LibrarySales.PostSalesDocument(SalesHeader, true, true);

        CustLedgerEntry.SetRange("Document Type", CustLedgerEntry."Document Type"::Invoice);
        CustLedgerEntry.SetRange("Document No.", PostedInvoiceNo);
        CustLedgerEntry.FindFirst();
        CustLedgerEntry.CalcFields("Remaining Amount");

        LibraryERM.CreateGenJournalTemplate(GenJournalTemplate);
        CreateGenJnlBatchWithSeries(GenJournalBatch, GenJournalTemplate.Name);
        BankEntryNo := PmtReconPost.PostCustomerPaymentToBank(
            Customer."No.", BankAccount."No.", CustLedgerEntry."Remaining Amount", CustLedgerEntry."Entry No.",
            GenJournalTemplate.Name, GenJournalBatch.Name,
            CopyStr('MON-' + Format(LibraryRandom.RandIntInRange(100000, 999999)), 1, 35));
        BankAccLedgerEntry.Get(BankEntryNo);
        StatementAmount := BankAccLedgerEntry.Amount; // signed receipt amount carried by the bank entry
        exit(BankEntryNo);
    end;
}
