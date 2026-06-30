codeunit 50301 "MON Pmt Recon Match Tests"
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
    procedure MatchesBankEntryToReconLine()
    var
        Customer: Record Customer;
        Item: Record Item;
        BankAccount: Record "Bank Account";
        GenJournalTemplate: Record "Gen. Journal Template";
        GenJournalBatch: Record "Gen. Journal Batch";
        SalesHeader: Record "Sales Header";
        SalesLine: Record "Sales Line";
        CustLedgerEntry: Record "Cust. Ledger Entry";
        BankAccReconciliation: Record "Bank Acc. Reconciliation";
        BankAccReconLine: Record "Bank Acc. Reconciliation Line";
        BankAccLedgerEntry: Record "Bank Account Ledger Entry";
        PmtReconPost: Codeunit "MON Pmt Recon Post";
        PmtReconMatch: Codeunit "MON Pmt Recon Match";
        PostedInvoiceNo: Code[20];
        AppliedCustLedgerEntryNo: Integer;
        InvoiceAmount: Decimal;
        BankEntryNo: Integer;
        StatementNo: Code[20];
        StatementLineNo: Integer;
        StatementAmount: Decimal;
    begin
        // [SCENARIO] After a customer payment has posted to the bank (slice 1) — producing an OPEN
        // Bank Account Ledger Entry — the agent must MATCH that bank entry to a standard Bank Acc.
        // Reconciliation Line (standard BC "Set Recon.-No." mechanism, no Continia). The line must
        // then show the payment as applied (Applied Entries = 1, Applied Amount = Statement Amount,
        // Difference = 0) and the bank entry must carry the reconciliation link (Statement No. /
        // Statement Line No. set, Statement Status = "Bank Acc. Entry Applied") while staying Open
        // because the statement is not yet posted.

        // [GIVEN] A customer with a posted sales invoice for a known amount.
        LibrarySales.CreateCustomer(Customer);
        LibraryInventory.CreateItem(Item);
        LibrarySales.CreateSalesHeader(SalesHeader, SalesHeader."Document Type"::Invoice, Customer."No.");
        LibrarySales.CreateSalesLine(SalesLine, SalesHeader, SalesLine.Type::Item, Item."No.", 1);
        SalesLine.Validate("Unit Price", LibraryRandom.RandDecInRange(100, 1000, 2));
        SalesLine.Modify(true);
        PostedInvoiceNo := LibrarySales.PostSalesDocument(SalesHeader, true, true);

        // [GIVEN] Its open customer ledger entry and remaining amount.
        CustLedgerEntry.SetRange("Document Type", CustLedgerEntry."Document Type"::Invoice);
        CustLedgerEntry.SetRange("Document No.", PostedInvoiceNo);
        CustLedgerEntry.FindFirst();
        CustLedgerEntry.CalcFields("Remaining Amount");
        AppliedCustLedgerEntryNo := CustLedgerEntry."Entry No.";
        InvoiceAmount := CustLedgerEntry."Remaining Amount";

        // [GIVEN] A bank account + journal, and the payment posted to the bank (slice 1), yielding
        // exactly ONE open Bank Account Ledger Entry for the invoice amount.
        LibraryERM.CreateBankAccount(BankAccount);
        LibraryERM.CreateGenJournalTemplate(GenJournalTemplate);
        LibraryERM.CreateGenJournalBatch(GenJournalBatch, GenJournalTemplate.Name);
        BankEntryNo := PmtReconPost.PostCustomerPaymentToBank(
            Customer."No.", BankAccount."No.", InvoiceAmount, AppliedCustLedgerEntryNo,
            GenJournalTemplate.Name, GenJournalBatch.Name,
            CopyStr('MON-' + Format(LibraryRandom.RandIntInRange(100000, 999999)), 1, 35));
        BankAccLedgerEntry.Get(BankEntryNo);
        StatementAmount := BankAccLedgerEntry.Amount; // signed receipt amount carried by the bank entry

        // [GIVEN] A standard Bank Acc. Reconciliation (Statement Type = Bank Reconciliation) for that
        // bank account with ONE line whose Statement Amount equals the bank entry — currently
        // UNMATCHED: no applied entries and the full statement amount outstanding as Difference.
        LibraryERM.CreateBankAccReconciliation(
            BankAccReconciliation, BankAccount."No.",
            BankAccReconciliation."Statement Type"::"Bank Reconciliation");
        LibraryERM.CreateBankAccReconciliationLn(BankAccReconLine, BankAccReconciliation);
        BankAccReconLine.Validate("Statement Amount", StatementAmount);
        BankAccReconLine.Difference := StatementAmount; // unmatched: nothing applied yet
        BankAccReconLine.Modify(true);
        StatementNo := BankAccReconLine."Statement No.";
        StatementLineNo := BankAccReconLine."Statement Line No.";

        // [GIVEN] Guard the starting state so the post-conditions can only be reached by the match.
        Assert.AreEqual(
            0, BankAccReconLine."Applied Entries",
            'Precondition: the reconciliation line must start with no applied entries.');
        Assert.AreEqual(
            StatementAmount, BankAccReconLine.Difference,
            'Precondition: the full statement amount must be outstanding before matching.');

        // [WHEN] The agent matches the open bank ledger entry to the reconciliation line by IDs.
        PmtReconMatch.MatchBankEntryToReconLine(BankAccount."No.", StatementNo, StatementLineNo, BankEntryNo);

        // [THEN] The reconciliation line now shows exactly that one entry applied for the full
        // amount, with zero remaining difference. (Stub records nothing -> all three fail in RED.)
        BankAccReconLine.Get(
            BankAccReconLine."Statement Type"::"Bank Reconciliation",
            BankAccount."No.", StatementNo, StatementLineNo);
        Assert.AreEqual(
            1, BankAccReconLine."Applied Entries",
            'The reconciliation line must have exactly one applied bank ledger entry after matching.');
        Assert.AreEqual(
            StatementAmount, BankAccReconLine."Applied Amount",
            'The applied amount must equal the statement amount of the matched entry.');
        Assert.AreEqual(
            0, BankAccReconLine.Difference,
            'The reconciliation line difference must be zero once the entry is matched.');

        // [THEN] The bank ledger entry carries the reconciliation link and is flagged applied, but
        // stays open because the statement is not yet posted. (Stub leaves it Open/blank -> fails.)
        BankAccLedgerEntry.Get(BankEntryNo);
        Assert.AreEqual(
            StatementNo, BankAccLedgerEntry."Statement No.",
            'The bank ledger entry must reference the reconciliation statement it was matched to.');
        Assert.AreEqual(
            StatementLineNo, BankAccLedgerEntry."Statement Line No.",
            'The bank ledger entry must reference the matched statement line.');
        Assert.AreEqual(
            BankAccLedgerEntry."Statement Status"::"Bank Acc. Entry Applied", BankAccLedgerEntry."Statement Status",
            'The bank ledger entry status must be Bank Acc. Entry Applied after matching.');
        Assert.IsTrue(
            BankAccLedgerEntry.Open,
            'The matched bank ledger entry must remain open until the statement is posted.');
    end;
}
