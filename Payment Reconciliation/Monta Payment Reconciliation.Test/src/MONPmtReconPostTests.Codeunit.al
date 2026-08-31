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
        CreateGenJnlBatchWithSeries(GenJournalBatch, GenJournalTemplate.Name);

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

    [Test]
    procedure PostToClosedInvoice_IsRejected()
    var
        Customer: Record Customer;
        BankAccount: Record "Bank Account";
        GenJournalTemplate: Record "Gen. Journal Template";
        GenJournalBatch: Record "Gen. Journal Batch";
        PmtReconPost: Codeunit "MON Pmt Recon Post";
        CustLedgerEntryNo: Integer;
        InvoiceAmount: Decimal;
    begin
        // [SCENARIO] A payment applied to a customer ledger entry that is already closed (fully
        // settled by an earlier payment) must be rejected — the posting must not settle the same
        // invoice twice.

        // [GIVEN] A customer with a posted invoice, settled in full by a first payment (this closes
        // the invoice's customer ledger entry).
        CreateCustomerWithPostedInvoice(Customer, CustLedgerEntryNo, InvoiceAmount);
        CreatePaymentInfrastructure(BankAccount, GenJournalTemplate, GenJournalBatch);
        PmtReconPost.PostCustomerPaymentToBank(
            Customer."No.", BankAccount."No.", InvoiceAmount, CustLedgerEntryNo,
            GenJournalTemplate.Name, GenJournalBatch.Name, NewExternalDocNo());

        // [WHEN] A second payment is posted against that now-closed entry
        asserterror PmtReconPost.PostCustomerPaymentToBank(
            Customer."No.", BankAccount."No.", InvoiceAmount, CustLedgerEntryNo,
            GenJournalTemplate.Name, GenJournalBatch.Name, NewExternalDocNo());

        // [THEN] It is rejected with the closed-entry guard message
        Assert.ExpectedError('is closed and cannot be settled by this payment');
    end;

    [Test]
    procedure PostCrossCustomerEntry_IsRejected()
    var
        CustomerA: Record Customer;
        CustomerB: Record Customer;
        BankAccount: Record "Bank Account";
        GenJournalTemplate: Record "Gen. Journal Template";
        GenJournalBatch: Record "Gen. Journal Batch";
        PmtReconPost: Codeunit "MON Pmt Recon Post";
        CustomerBEntryNo: Integer;
        InvoiceAmountB: Decimal;
    begin
        // [SCENARIO] A payment for customer A that is applied to customer B's open ledger entry must
        // be rejected — an entry may only be settled by a payment from its own customer.

        // [GIVEN] Customer A (the payer) and Customer B with an open posted invoice
        LibrarySales.CreateCustomer(CustomerA);
        CreateCustomerWithPostedInvoice(CustomerB, CustomerBEntryNo, InvoiceAmountB);
        CreatePaymentInfrastructure(BankAccount, GenJournalTemplate, GenJournalBatch);

        // [WHEN] Customer A pays, but the payment is applied to Customer B's open entry
        asserterror PmtReconPost.PostCustomerPaymentToBank(
            CustomerA."No.", BankAccount."No.", InvoiceAmountB, CustomerBEntryNo,
            GenJournalTemplate.Name, GenJournalBatch.Name, NewExternalDocNo());

        // [THEN] It is rejected with the cross-customer guard message
        Assert.ExpectedError('does not belong to customer');
    end;

    [Test]
    procedure PostToReservedEntry_IsRejected()
    var
        Customer: Record Customer;
        BankAccount: Record "Bank Account";
        GenJournalTemplate: Record "Gen. Journal Template";
        GenJournalBatch: Record "Gen. Journal Batch";
        CustLedgerEntry: Record "Cust. Ledger Entry";
        BankAccLedgerEntry: Record "Bank Account Ledger Entry";
        CustEntryEdit: Codeunit "Cust. Entry-Edit";
        PmtReconPost: Codeunit "MON Pmt Recon Post";
        CustLedgerEntryNo: Integer;
        InvoiceAmount: Decimal;
    begin
        // [SCENARIO] An open invoice ALREADY reserved by another application — in production, an applied but
        // unposted cash-receipt journal line holding the entry's "Applies-to ID" — must be rejected with
        // NOTHING posted. Regression guard for the production defect where "Cust. Entry-SetAppl.ID" toggled
        // the foreign ID OFF instead of stamping ours, so the payment posted ON ACCOUNT (bank entry created,
        // invoice left open for its full amount) while the API still reported success.

        // [GIVEN] A customer with one open posted invoice, and the payment infrastructure
        CreateCustomerWithPostedInvoice(Customer, CustLedgerEntryNo, InvoiceAmount);
        CreatePaymentInfrastructure(BankAccount, GenJournalTemplate, GenJournalBatch);

        // [GIVEN] Another, unposted application already reserves that invoice entry. Committed on purpose:
        // the asserterror below rolls the database back to the last commit, so an uncommitted reservation
        // would be undone by the rollback itself and the "reservation survived" assertion could never
        // distinguish that from the poster having cleared it. (The invoice is already committed — the
        // sales-posting library commits — which is why it survives the same rollback.)
        CustLedgerEntry.Get(CustLedgerEntryNo);
        CustLedgerEntry."Applies-to ID" := 'STAGED-JNL-LINE';
        CustEntryEdit.Run(CustLedgerEntry);
        Commit();

        // [WHEN] The agent posts a payment against that reserved entry
        asserterror PmtReconPost.PostCustomerPaymentToBank(
            Customer."No.", BankAccount."No.", InvoiceAmount, CustLedgerEntryNo,
            GenJournalTemplate.Name, GenJournalBatch.Name, NewExternalDocNo());

        // [THEN] It is rejected, naming the reservation rather than posting on account
        Assert.ExpectedError('is already reserved for application');

        // [THEN] Nothing was posted: the payment bank account has no ledger entry at all
        BankAccLedgerEntry.SetRange("Bank Account No.", BankAccount."No.");
        Assert.RecordIsEmpty(BankAccLedgerEntry);

        // [THEN] The other application's reservation is left intact and the invoice is still open
        CustLedgerEntry.Get(CustLedgerEntryNo);
        Assert.AreEqual(
            'STAGED-JNL-LINE', CustLedgerEntry."Applies-to ID",
            'The pre-existing application must not be cleared by the rejected payment.');
        Assert.IsTrue(CustLedgerEntry.Open, 'The invoice must remain open.');
    end;

    [Test]
    procedure PostsForeignCurrencyPaymentToForeignCurrencyBank()
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
        CurrencyCode: Code[10];
        PostedInvoiceNo: Code[20];
        AppliedCustLedgerEntryNo: Integer;
        InvoiceAmount: Decimal;
        ResultEntryNo: Integer;
    begin
        // [SCENARIO] A payment received into a FOREIGN-currency bank account (currency <> LCY), settling a
        // foreign-currency invoice, must post cleanly. Regression guard: the poster used to leave the
        // customer/write-off legs in LCY while the bank leg took the bank account's currency, so for a
        // foreign-currency bank the legs converted to different LCY amounts and the whole document failed
        // the G/L Entry consistency check ("...will cause inconsistencies in the G/L Entry table"). Every
        // leg must now carry the receipt currency so the balanced document's LCY conversion nets to zero.

        // [GIVEN] A currency with a non-unity exchange rate (so the transaction currency <> LCY).
        CurrencyCode := LibraryERM.CreateCurrencyWithRandomExchRates();

        // [GIVEN] A customer in that currency with a posted invoice denominated in it.
        LibrarySales.CreateCustomer(Customer);
        Customer.Validate("Currency Code", CurrencyCode);
        Customer.Modify(true);
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
        AppliedCustLedgerEntryNo := CustLedgerEntry."Entry No.";
        InvoiceAmount := CustLedgerEntry."Remaining Amount";

        // [GIVEN] A bank account in the SAME foreign currency the receipt lands in.
        LibraryERM.CreateBankAccount(BankAccount);
        BankAccount.Validate("Currency Code", CurrencyCode);
        BankAccount.Modify(true);
        LibraryERM.CreateGenJournalTemplate(GenJournalTemplate);
        CreateGenJnlBatchWithSeries(GenJournalBatch, GenJournalTemplate.Name);

        // [WHEN] The agent posts the foreign-currency payment to the foreign-currency bank account.
        ResultEntryNo := PmtReconPost.PostCustomerPaymentToBank(
            Customer."No.", BankAccount."No.", InvoiceAmount, AppliedCustLedgerEntryNo,
            GenJournalTemplate.Name, GenJournalBatch.Name, NewExternalDocNo());

        // [THEN] Posting succeeds (no consistency error): a bank entry exists, in the bank's currency,
        // for the payment amount, left open.
        Assert.AreNotEqual(0, ResultEntryNo, 'Posting must return a non-zero Bank Account Ledger Entry No.');
        BankAccLedgerEntry.Get(ResultEntryNo);
        Assert.AreEqual(
            CurrencyCode, BankAccLedgerEntry."Currency Code",
            'The Bank Account Ledger Entry must carry the foreign receipt currency.');
        Assert.AreEqual(
            InvoiceAmount, Abs(BankAccLedgerEntry.Amount),
            'The Bank Account Ledger Entry amount must equal the posted payment amount (in currency).');
        Assert.IsTrue(BankAccLedgerEntry.Open, 'The Bank Account Ledger Entry must remain open.');

        // [THEN] The applied invoice is fully closed.
        CustLedgerEntry.Get(AppliedCustLedgerEntryNo);
        CustLedgerEntry.CalcFields("Remaining Amount");
        Assert.AreEqual(0, CustLedgerEntry."Remaining Amount", 'The applied invoice must be fully paid.');
        Assert.IsFalse(CustLedgerEntry.Open, 'The applied invoice must be closed after the payment is applied.');
    end;

    local procedure CreateCustomerWithPostedInvoice(var Customer: Record Customer; var CustLedgerEntryNo: Integer; var InvoiceAmount: Decimal)
    var
        Item: Record Item;
        SalesHeader: Record "Sales Header";
        SalesLine: Record "Sales Line";
        CustLedgerEntry: Record "Cust. Ledger Entry";
        PostedInvoiceNo: Code[20];
    begin
        // Mirrors the happy-path arrange: a customer with one open posted sales invoice.
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
        CustLedgerEntryNo := CustLedgerEntry."Entry No.";
        InvoiceAmount := CustLedgerEntry."Remaining Amount";
    end;

    local procedure CreatePaymentInfrastructure(var BankAccount: Record "Bank Account"; var GenJournalTemplate: Record "Gen. Journal Template"; var GenJournalBatch: Record "Gen. Journal Batch")
    begin
        LibraryERM.CreateBankAccount(BankAccount);
        LibraryERM.CreateGenJournalTemplate(GenJournalTemplate);
        CreateGenJnlBatchWithSeries(GenJournalBatch, GenJournalTemplate.Name);
    end;

    local procedure CreateGenJnlBatchWithSeries(var GenJournalBatch: Record "Gen. Journal Batch"; TemplateName: Code[10])
    begin
        // Production requires the batch to draw document numbers from a No. Series; the poster now
        // rejects a seriesless batch, so every posting test must configure one.
        LibraryERM.CreateGenJournalBatch(GenJournalBatch, TemplateName);
        GenJournalBatch.Validate("No. Series", LibraryERM.CreateNoSeriesCode());
        GenJournalBatch.Modify(true);
    end;

    local procedure NewExternalDocNo(): Code[35]
    begin
        exit(CopyStr('MON-' + Format(LibraryRandom.RandIntInRange(100000, 999999)), 1, 35));
    end;
}
