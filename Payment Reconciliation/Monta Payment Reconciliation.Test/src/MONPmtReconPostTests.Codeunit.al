codeunit 50300 "MON Pmt Recon Post Tests"
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
    procedure PostsPaymentToBankAndClosesInvoice()
    var
        Customer: Record Customer;
        Item: Record Item;
        BankAccount: Record "Bank Account";
        GenJournalTemplate: Record "Gen. Journal Template";
        GenJournalBatch: Record "Gen. Journal Batch";
        SalesHeader: Record "Sales Header";
        SalesLine: Record "Sales Line";
        CustLedgerEntry: Record "Cust. Ledger Entry";
        BankAccLedgerEntry: Record "Bank Account Ledger Entry";
        PmtReconPost: Codeunit "MON Pmt Recon Post";
        PostedInvoiceNo: Code[20];
        AppliedCustLedgerEntryNo: Integer;
        InvoiceAmount: Decimal;
        ExternalDocNo: Code[35];
        ResultEntryNo: Integer;
    begin
        // [SCENARIO] An incoming customer payment that balances to a Bank Account, applied to an
        // open posted sales invoice, must create a Bank Account Ledger Entry (left open so it can
        // later be reconciled) and fully close the applied invoice.

        // [GIVEN] A customer with a posted sales invoice for a known amount
        LibrarySales.CreateCustomer(Customer);
        LibraryInventory.CreateItem(Item);
        LibrarySales.CreateSalesHeader(SalesHeader, SalesHeader."Document Type"::Invoice, Customer."No.");
        LibrarySales.CreateSalesLine(SalesLine, SalesHeader, SalesLine.Type::Item, Item."No.", 1);
        SalesLine.Validate("Unit Price", LibraryRandom.RandDecInRange(100, 1000, 2));
        SalesLine.Modify(true);
        PostedInvoiceNo := LibrarySales.PostSalesDocument(SalesHeader, true, true);

        // [GIVEN] The open customer ledger entry and its remaining amount
        CustLedgerEntry.SetRange("Document Type", CustLedgerEntry."Document Type"::Invoice);
        CustLedgerEntry.SetRange("Document No.", PostedInvoiceNo);
        CustLedgerEntry.FindFirst();
        CustLedgerEntry.CalcFields("Remaining Amount");
        AppliedCustLedgerEntryNo := CustLedgerEntry."Entry No.";
        InvoiceAmount := CustLedgerEntry."Remaining Amount";

        // [GIVEN] A bank account and a general journal template + batch for the payment
        LibraryERM.CreateBankAccount(BankAccount);
        LibraryERM.CreateGenJournalTemplate(GenJournalTemplate);
        LibraryERM.CreateGenJournalBatch(GenJournalBatch, GenJournalTemplate.Name);

        ExternalDocNo := CopyStr('MON-' + Format(LibraryRandom.RandIntInRange(100000, 999999)), 1, MaxStrLen(ExternalDocNo));

        // [WHEN] The agent posts the payment to the bank, applied to the open invoice
        ResultEntryNo := PmtReconPost.PostCustomerPaymentToBank(
            Customer."No.", BankAccount."No.", InvoiceAmount, AppliedCustLedgerEntryNo,
            GenJournalTemplate.Name, GenJournalBatch.Name, ExternalDocNo);

        // [THEN] A Bank Account Ledger Entry was created (standard customerPayments API cannot do this)
        Assert.AreNotEqual(0, ResultEntryNo, 'Posting must return a non-zero Bank Account Ledger Entry No.');
        Assert.IsTrue(
            BankAccLedgerEntry.Get(ResultEntryNo),
            'A Bank Account Ledger Entry with the returned No. must exist.');

        // [THEN] It belongs to the payment bank account, with |Amount| = the payment, and is left open
        Assert.AreEqual(
            BankAccount."No.", BankAccLedgerEntry."Bank Account No.",
            'The Bank Account Ledger Entry must belong to the payment bank account.');
        Assert.AreEqual(
            InvoiceAmount, Abs(BankAccLedgerEntry.Amount),
            'The Bank Account Ledger Entry amount must equal the posted payment amount.');
        Assert.IsTrue(
            BankAccLedgerEntry.Open,
            'The Bank Account Ledger Entry must remain open so it can later be reconciled.');

        // [THEN] The applied invoice is now fully closed (payment really was applied, not just posted)
        CustLedgerEntry.Get(AppliedCustLedgerEntryNo);
        CustLedgerEntry.CalcFields("Remaining Amount");
        Assert.AreEqual(
            0, CustLedgerEntry."Remaining Amount",
            'The applied invoice must be fully paid (Remaining Amount = 0).');
        Assert.IsFalse(
            CustLedgerEntry.Open,
            'The applied invoice must be closed (Open = false) after the payment is applied.');
    end;
}
