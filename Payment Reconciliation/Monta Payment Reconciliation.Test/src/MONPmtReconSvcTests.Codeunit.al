codeunit 50302 "MON Pmt Recon Svc Tests"
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
    procedure PostAndReconcile_PostsAndMatches()
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
        PmtReconService: Codeunit "MON Pmt Recon Service";
        Request: JsonObject;
        Response: JsonObject;
        PostedInvoiceNo: Code[20];
        AppliedCustLedgerEntryNo: Integer;
        InvoiceAmount: Decimal;
        StatementNo: Code[20];
        StatementLineNo: Integer;
        StatementAmount: Decimal;
        ResultBankEntryNo: Integer;
        ResultMatched: Boolean;
    begin
        // [SCENARIO] A single agent-facing call PostAndReconcile must, in ONE transaction, post an
        // incoming customer payment to the bank (creating the open Bank Account Ledger Entry) AND match
        // that entry to the named standard Bank Acc. Reconciliation line — i.e. one call achieves the
        // combined effect of slice 1 (post) + slice 2 (match). Minimal happy path: one payment, one
        // customer, one applied invoice; no write-offs, no idempotency/audit.

        // [GIVEN] A customer with a posted sales invoice for a known amount.
        LibrarySales.CreateCustomer(Customer);
        LibraryInventory.CreateItem(Item);
        LibrarySales.CreateSalesHeader(SalesHeader, SalesHeader."Document Type"::Invoice, Customer."No.");
        LibrarySales.CreateSalesLine(SalesLine, SalesHeader, SalesLine.Type::Item, Item."No.", 1);
        SalesLine.Validate("Unit Price", LibraryRandom.RandDecInRange(100, 1000, 2));
        SalesLine.Modify(true);
        PostedInvoiceNo := LibrarySales.PostSalesDocument(SalesHeader, true, true);

        // [GIVEN] Its open customer ledger entry and remaining amount (the payment amount).
        CustLedgerEntry.SetRange("Document Type", CustLedgerEntry."Document Type"::Invoice);
        CustLedgerEntry.SetRange("Document No.", PostedInvoiceNo);
        CustLedgerEntry.FindFirst();
        CustLedgerEntry.CalcFields("Remaining Amount");
        AppliedCustLedgerEntryNo := CustLedgerEntry."Entry No.";
        InvoiceAmount := CustLedgerEntry."Remaining Amount";

        // [GIVEN] A bank account and a general journal template + batch for the payment.
        LibraryERM.CreateBankAccount(BankAccount);
        LibraryERM.CreateGenJournalTemplate(GenJournalTemplate);
        LibraryERM.CreateGenJournalBatch(GenJournalBatch, GenJournalTemplate.Name);

        // [GIVEN] A standard Bank Acc. Reconciliation (Statement Type = Bank Reconciliation) for that
        // bank account with ONE UNMATCHED line whose Statement Amount equals the invoice amount. A
        // receipt posts to the bank as a POSITIVE Bank Account Ledger Entry amount, so the matching
        // statement amount is +InvoiceAmount. Difference = Statement Amount, Applied Entries = 0.
        StatementAmount := InvoiceAmount;
        LibraryERM.CreateBankAccReconciliation(
            BankAccReconciliation, BankAccount."No.",
            BankAccReconciliation."Statement Type"::"Bank Reconciliation");
        LibraryERM.CreateBankAccReconciliationLn(BankAccReconLine, BankAccReconciliation);
        BankAccReconLine.Validate("Statement Amount", StatementAmount);
        BankAccReconLine.Difference := StatementAmount; // unmatched: nothing applied yet
        BankAccReconLine.Modify(true);
        StatementNo := BankAccReconLine."Statement No.";
        StatementLineNo := BankAccReconLine."Statement Line No.";

        // [GIVEN] Guard the starting state so the post-conditions can only be reached by PostAndReconcile.
        Assert.AreEqual(
            0, BankAccReconLine."Applied Entries",
            'Precondition: the reconciliation line must start with no applied entries.');
        Assert.AreEqual(
            StatementAmount, BankAccReconLine.Difference,
            'Precondition: the full statement amount must be outstanding before the composite call.');

        // [WHEN] The agent issues a single PostAndReconcile call with the composite request.
        Request := BuildRequest(
            BankAccount."No.", StatementNo, StatementLineNo,
            GenJournalTemplate.Name, GenJournalBatch.Name, NewExternalDocNo(),
            Customer."No.", AppliedCustLedgerEntryNo, InvoiceAmount);
        Response := PmtReconService.PostAndReconcile(Request);

        ResultBankEntryNo := ReadInt(Response, 'bankAccountLedgerEntryNo');
        ResultMatched := ReadBool(Response, 'reconciliationLineMatched');

        // [THEN] The response names a real, open Bank Account Ledger Entry on the bank for the payment.
        // (Stub returns 0 -> AreNotEqual fails first; the composite posted nothing.)
        Assert.AreNotEqual(
            0, ResultBankEntryNo,
            'PostAndReconcile must return a non-zero Bank Account Ledger Entry No. for the posted receipt.');
        Assert.IsTrue(
            BankAccLedgerEntry.Get(ResultBankEntryNo),
            'A Bank Account Ledger Entry with the returned No. must exist (the payment must have posted).');
        Assert.AreEqual(
            BankAccount."No.", BankAccLedgerEntry."Bank Account No.",
            'The created Bank Account Ledger Entry must belong to the payment bank account.');
        Assert.AreEqual(
            InvoiceAmount, Abs(BankAccLedgerEntry.Amount),
            'The Bank Account Ledger Entry amount must equal the posted payment amount.');
        Assert.IsTrue(
            BankAccLedgerEntry.Open,
            'The Bank Account Ledger Entry must remain open (matched, not yet statement-posted).');

        // [THEN] The applied invoice is fully closed — the payment really was applied, not just posted.
        CustLedgerEntry.Get(AppliedCustLedgerEntryNo);
        CustLedgerEntry.CalcFields("Remaining Amount");
        Assert.AreEqual(
            0, CustLedgerEntry."Remaining Amount",
            'The applied invoice must be fully paid (Remaining Amount = 0) after the composite call.');
        Assert.IsFalse(
            CustLedgerEntry.Open,
            'The applied invoice must be closed (Open = false) after the payment is applied.');

        // [THEN] The reconciliation line is matched: exactly one applied entry for the full amount, zero
        // difference — proving the SAME call also performed the slice-2 match. (Stub matches nothing.)
        BankAccReconLine.Get(
            BankAccReconLine."Statement Type"::"Bank Reconciliation",
            BankAccount."No.", StatementNo, StatementLineNo);
        Assert.AreEqual(
            1, BankAccReconLine."Applied Entries",
            'The reconciliation line must have exactly one applied bank ledger entry after the composite call.');
        Assert.AreEqual(
            StatementAmount, BankAccReconLine."Applied Amount",
            'The applied amount must equal the statement amount of the matched entry.');
        Assert.AreEqual(
            0, BankAccReconLine.Difference,
            'The reconciliation line difference must be zero once the entry is matched.');

        // [THEN] The response explicitly reports the line as matched. (Stub returns false.)
        Assert.IsTrue(
            ResultMatched,
            'PostAndReconcile must report reconciliationLineMatched = true once the line is matched.');
    end;

    [Test]
    procedure PostAndReconcile_MultiInvoice()
    var
        Customer: Record Customer;
        BankAccount: Record "Bank Account";
        GenJournalTemplate: Record "Gen. Journal Template";
        GenJournalBatch: Record "Gen. Journal Batch";
        CustLedgerEntry: Record "Cust. Ledger Entry";
        BankAccReconciliation: Record "Bank Acc. Reconciliation";
        BankAccReconLine: Record "Bank Acc. Reconciliation Line";
        BankAccLedgerEntry: Record "Bank Account Ledger Entry";
        PmtReconService: Codeunit "MON Pmt Recon Service";
        Request: JsonObject;
        Response: JsonObject;
        CustLedgerEntryNoA: Integer;
        CustLedgerEntryNoB: Integer;
        AmountA: Decimal;
        AmountB: Decimal;
        TotalAmount: Decimal;
        StatementNo: Code[20];
        StatementLineNo: Integer;
        ResultBankEntryNo: Integer;
        ResultMatched: Boolean;
    begin
        // [SCENARIO] Slice 4: ONE incoming payment from ONE customer settles MULTIPLE open invoices at
        // once. Each target Cust. Ledger Entry is stamped with the same Applies-to ID + its Amount to
        // Apply, and exactly ONE Bank Account Ledger Entry is created for the TOTAL (A + B), so the
        // reconciliation line stays a 1:1 match to that single bank entry. One customer, two invoices,
        // no write-offs, no multi-customer.

        // [GIVEN] One customer with TWO posted sales invoices of distinct known amounts A and B
        // (distinct unit-price ranges guarantee A <> B). Capture both open Cust. Ledger Entry Nos.
        // and remaining amounts.
        LibrarySales.CreateCustomer(Customer);
        CreatePostedInvoiceForCustomer(
            Customer."No.", LibraryRandom.RandDecInRange(100, 500, 2), CustLedgerEntryNoA, AmountA);
        CreatePostedInvoiceForCustomer(
            Customer."No.", LibraryRandom.RandDecInRange(600, 1000, 2), CustLedgerEntryNoB, AmountB);
        TotalAmount := AmountA + AmountB;

        // [GIVEN] Sanity: the two invoices are distinct, both open, with distinct positive amounts so
        // a single-appliesTo regression (settling only A) is observable.
        Assert.AreNotEqual(
            CustLedgerEntryNoA, CustLedgerEntryNoB,
            'Precondition: the two invoices must be distinct customer ledger entries.');
        Assert.AreNotEqual(
            AmountA, AmountB,
            'Precondition: the two invoice amounts must differ so a partial (A-only) settlement is detectable.');

        // [GIVEN] A bank account and a general journal template + batch for the payment.
        LibraryERM.CreateBankAccount(BankAccount);
        LibraryERM.CreateGenJournalTemplate(GenJournalTemplate);
        LibraryERM.CreateGenJournalBatch(GenJournalBatch, GenJournalTemplate.Name);

        // [GIVEN] A standard Bank Acc. Reconciliation with ONE UNMATCHED line whose Statement Amount is
        // the TOTAL of both invoices (A + B): a single receipt for the whole payment. Difference = A+B,
        // Applied Entries = 0.
        LibraryERM.CreateBankAccReconciliation(
            BankAccReconciliation, BankAccount."No.",
            BankAccReconciliation."Statement Type"::"Bank Reconciliation");
        LibraryERM.CreateBankAccReconciliationLn(BankAccReconLine, BankAccReconciliation);
        BankAccReconLine.Validate("Statement Amount", TotalAmount);
        BankAccReconLine.Difference := TotalAmount; // unmatched: nothing applied yet
        BankAccReconLine.Modify(true);
        StatementNo := BankAccReconLine."Statement No.";
        StatementLineNo := BankAccReconLine."Statement Line No.";

        // [GIVEN] Guard the starting state so the post-conditions can only be reached by PostAndReconcile.
        Assert.AreEqual(
            0, BankAccReconLine."Applied Entries",
            'Precondition: the reconciliation line must start with no applied entries.');
        Assert.AreEqual(
            TotalAmount, BankAccReconLine.Difference,
            'Precondition: the full total (A + B) must be outstanding before the composite call.');

        // [WHEN] The agent issues a single PostAndReconcile call whose payments[0].appliesTo carries TWO
        // entries: {A's CLE, A} and {B's CLE, B}.
        Request := BuildMultiInvoiceRequest(
            BankAccount."No.", StatementNo, StatementLineNo,
            GenJournalTemplate.Name, GenJournalBatch.Name, NewExternalDocNo(),
            Customer."No.", CustLedgerEntryNoA, AmountA, CustLedgerEntryNoB, AmountB);
        Response := PmtReconService.PostAndReconcile(Request);

        ResultBankEntryNo := ReadInt(Response, 'bankAccountLedgerEntryNo');
        ResultMatched := ReadBool(Response, 'reconciliationLineMatched');

        // [THEN] The response names a real, open Bank Account Ledger Entry on the bank.
        Assert.AreNotEqual(
            0, ResultBankEntryNo,
            'PostAndReconcile must return a non-zero Bank Account Ledger Entry No. for the posted receipt.');
        Assert.IsTrue(
            BankAccLedgerEntry.Get(ResultBankEntryNo),
            'A Bank Account Ledger Entry with the returned No. must exist (the payment must have posted).');
        Assert.AreEqual(
            BankAccount."No.", BankAccLedgerEntry."Bank Account No.",
            'The created Bank Account Ledger Entry must belong to the payment bank account.');

        // [THEN] EXACTLY ONE bank entry for the WHOLE payment: |Amount| = A + B. Today the service reads
        // only appliesTo[0] and posts A, so |Amount| = A <> A+B -> this is the FIRST assertion to fail.
        Assert.AreEqual(
            TotalAmount, Abs(BankAccLedgerEntry.Amount),
            'The single Bank Account Ledger Entry amount must equal the TOTAL of both invoices (A + B).');
        Assert.IsTrue(
            BankAccLedgerEntry.Open,
            'The Bank Account Ledger Entry must remain open (matched, not yet statement-posted).');

        // [THEN] BOTH invoices are fully closed — re-Get + CalcFields each. Today invoice B is never
        // applied (only appliesTo[0] is read), so it stays open -> this fails for B.
        CustLedgerEntry.Get(CustLedgerEntryNoA);
        CustLedgerEntry.CalcFields("Remaining Amount");
        Assert.AreEqual(
            0, CustLedgerEntry."Remaining Amount",
            'Invoice A must be fully paid (Remaining Amount = 0) after the multi-invoice call.');
        Assert.IsFalse(
            CustLedgerEntry.Open,
            'Invoice A must be closed (Open = false) after the multi-invoice call.');

        CustLedgerEntry.Get(CustLedgerEntryNoB);
        CustLedgerEntry.CalcFields("Remaining Amount");
        Assert.AreEqual(
            0, CustLedgerEntry."Remaining Amount",
            'Invoice B must be fully paid (Remaining Amount = 0) after the multi-invoice call.');
        Assert.IsFalse(
            CustLedgerEntry.Open,
            'Invoice B must be closed (Open = false) after the multi-invoice call.');

        // [THEN] The reconciliation line is fully matched to the ONE bank entry: Applied Entries = 1,
        // Applied Amount = A+B, Difference = 0. Today Applied Amount = A and Difference = B <> 0.
        BankAccReconLine.Get(
            BankAccReconLine."Statement Type"::"Bank Reconciliation",
            BankAccount."No.", StatementNo, StatementLineNo);
        Assert.AreEqual(
            1, BankAccReconLine."Applied Entries",
            'The reconciliation line must have exactly one applied bank ledger entry (1:1 with the total receipt).');
        Assert.AreEqual(
            TotalAmount, BankAccReconLine."Applied Amount",
            'The applied amount must equal the TOTAL statement amount (A + B).');
        Assert.AreEqual(
            0, BankAccReconLine.Difference,
            'The reconciliation line difference must be zero once the total receipt is matched.');

        // [THEN] The response explicitly reports the line as matched.
        Assert.IsTrue(
            ResultMatched,
            'PostAndReconcile must report reconciliationLineMatched = true once the line is matched.');
    end;

    [Test]
    procedure PostAndReconcile_MultiCustomer()
    var
        Customer1: Record Customer;
        Customer2: Record Customer;
        BankAccount: Record "Bank Account";
        GenJournalTemplate: Record "Gen. Journal Template";
        GenJournalBatch: Record "Gen. Journal Batch";
        CustLedgerEntry: Record "Cust. Ledger Entry";
        BankAccReconciliation: Record "Bank Acc. Reconciliation";
        BankAccReconLine: Record "Bank Acc. Reconciliation Line";
        BankAccLedgerEntry: Record "Bank Account Ledger Entry";
        PmtReconService: Codeunit "MON Pmt Recon Service";
        Request: JsonObject;
        Response: JsonObject;
        CustLedgerEntryNoA: Integer;
        CustLedgerEntryNoB: Integer;
        AmountA: Decimal;
        AmountB: Decimal;
        TotalAmount: Decimal;
        StatementNo: Code[20];
        StatementLineNo: Integer;
        ResultBankEntryNo: Integer;
        ResultMatched: Boolean;
    begin
        // [SCENARIO] Slice 5: ONE incoming bank payment settles invoices belonging to MORE THAN ONE
        // customer at once. The design posts ONE balanced Gen. Journal document = N customer payment
        // lines (one per customer, each with its OWN Applies-to ID stamping that customer's invoices)
        // + ONE Bank Account line for the TOTAL -> exactly ONE Bank Account Ledger Entry, so the recon
        // line stays a 1:1 match for the whole statement-line amount. Atomic. Two customers, one
        // invoice each, no write-offs.

        // [GIVEN] TWO distinct customers, each with ONE posted sales invoice of a distinct known amount
        // (distinct unit-price ranges guarantee A <> B). Capture both open Cust. Ledger Entry Nos.
        LibrarySales.CreateCustomer(Customer1);
        LibrarySales.CreateCustomer(Customer2);
        CreatePostedInvoiceForCustomer(
            Customer1."No.", LibraryRandom.RandDecInRange(100, 500, 2), CustLedgerEntryNoA, AmountA);
        CreatePostedInvoiceForCustomer(
            Customer2."No.", LibraryRandom.RandDecInRange(600, 1000, 2), CustLedgerEntryNoB, AmountB);
        TotalAmount := AmountA + AmountB;

        // [GIVEN] Sanity: the two customers and their invoices are distinct, both open, with distinct
        // positive amounts so a single-customer regression (settling only customer 1) is observable.
        Assert.AreNotEqual(
            Customer1."No.", Customer2."No.",
            'Precondition: the two payments must belong to distinct customers.');
        Assert.AreNotEqual(
            CustLedgerEntryNoA, CustLedgerEntryNoB,
            'Precondition: the two invoices must be distinct customer ledger entries.');
        Assert.AreNotEqual(
            AmountA, AmountB,
            'Precondition: the two invoice amounts must differ so a partial (customer-1-only) settlement is detectable.');

        // [GIVEN] A bank account and a general journal template + batch for the payment.
        LibraryERM.CreateBankAccount(BankAccount);
        LibraryERM.CreateGenJournalTemplate(GenJournalTemplate);
        LibraryERM.CreateGenJournalBatch(GenJournalBatch, GenJournalTemplate.Name);

        // [GIVEN] A standard Bank Acc. Reconciliation with ONE UNMATCHED line whose Statement Amount is
        // the TOTAL across both customers (A + B): a single receipt for the whole payment. Difference =
        // A+B, Applied Entries = 0.
        LibraryERM.CreateBankAccReconciliation(
            BankAccReconciliation, BankAccount."No.",
            BankAccReconciliation."Statement Type"::"Bank Reconciliation");
        LibraryERM.CreateBankAccReconciliationLn(BankAccReconLine, BankAccReconciliation);
        BankAccReconLine.Validate("Statement Amount", TotalAmount);
        BankAccReconLine.Difference := TotalAmount; // unmatched: nothing applied yet
        BankAccReconLine.Modify(true);
        StatementNo := BankAccReconLine."Statement No.";
        StatementLineNo := BankAccReconLine."Statement Line No.";

        // [GIVEN] Guard the starting state so the post-conditions can only be reached by PostAndReconcile.
        Assert.AreEqual(
            0, BankAccReconLine."Applied Entries",
            'Precondition: the reconciliation line must start with no applied entries.');
        Assert.AreEqual(
            TotalAmount, BankAccReconLine.Difference,
            'Precondition: the full total (A + B) must be outstanding before the composite call.');

        // [WHEN] The agent issues a single PostAndReconcile call whose payments carries TWO entries:
        // {customer 1, [{A's CLE, A}]} and {customer 2, [{B's CLE, B}]}.
        Request := BuildMultiCustomerRequest(
            BankAccount."No.", StatementNo, StatementLineNo,
            GenJournalTemplate.Name, GenJournalBatch.Name, NewExternalDocNo(),
            Customer1."No.", CustLedgerEntryNoA, AmountA,
            Customer2."No.", CustLedgerEntryNoB, AmountB);
        Response := PmtReconService.PostAndReconcile(Request);

        ResultBankEntryNo := ReadInt(Response, 'bankAccountLedgerEntryNo');
        ResultMatched := ReadBool(Response, 'reconciliationLineMatched');

        // [THEN] The response names a real, open Bank Account Ledger Entry on the bank.
        Assert.AreNotEqual(
            0, ResultBankEntryNo,
            'PostAndReconcile must return a non-zero Bank Account Ledger Entry No. for the posted receipt.');
        Assert.IsTrue(
            BankAccLedgerEntry.Get(ResultBankEntryNo),
            'A Bank Account Ledger Entry with the returned No. must exist (the payment must have posted).');
        Assert.AreEqual(
            BankAccount."No.", BankAccLedgerEntry."Bank Account No.",
            'The created Bank Account Ledger Entry must belong to the payment bank account.');

        // [THEN] EXACTLY ONE bank entry for the WHOLE payment: |Amount| = A + B. Today the service reads
        // only payments[0] (customer 1) and posts A, so |Amount| = A <> A+B -> this is the FIRST
        // assertion to fail. (One bank line for the grand total, not one bank entry per customer.)
        Assert.AreEqual(
            TotalAmount, Abs(BankAccLedgerEntry.Amount),
            'The single Bank Account Ledger Entry amount must equal the TOTAL across both customers (A + B).');
        Assert.IsTrue(
            BankAccLedgerEntry.Open,
            'The Bank Account Ledger Entry must remain open (matched, not yet statement-posted).');

        // [THEN] BOTH invoices (one per customer) are fully closed — re-Get + CalcFields each. Today
        // customer 2's invoice is never applied (only payments[0] is read), so it stays open -> this
        // fails for B.
        CustLedgerEntry.Get(CustLedgerEntryNoA);
        CustLedgerEntry.CalcFields("Remaining Amount");
        Assert.AreEqual(
            0, CustLedgerEntry."Remaining Amount",
            'Customer 1''s invoice must be fully paid (Remaining Amount = 0) after the multi-customer call.');
        Assert.IsFalse(
            CustLedgerEntry.Open,
            'Customer 1''s invoice must be closed (Open = false) after the multi-customer call.');

        CustLedgerEntry.Get(CustLedgerEntryNoB);
        CustLedgerEntry.CalcFields("Remaining Amount");
        Assert.AreEqual(
            0, CustLedgerEntry."Remaining Amount",
            'Customer 2''s invoice must be fully paid (Remaining Amount = 0) after the multi-customer call.');
        Assert.IsFalse(
            CustLedgerEntry.Open,
            'Customer 2''s invoice must be closed (Open = false) after the multi-customer call.');

        // [THEN] The reconciliation line is fully matched to the ONE bank entry: Applied Entries = 1,
        // Applied Amount = A+B, Difference = 0. Today Applied Amount = A and Difference = B <> 0.
        BankAccReconLine.Get(
            BankAccReconLine."Statement Type"::"Bank Reconciliation",
            BankAccount."No.", StatementNo, StatementLineNo);
        Assert.AreEqual(
            1, BankAccReconLine."Applied Entries",
            'The reconciliation line must have exactly one applied bank ledger entry (1:1 with the total receipt).');
        Assert.AreEqual(
            TotalAmount, BankAccReconLine."Applied Amount",
            'The applied amount must equal the TOTAL statement amount (A + B).');
        Assert.AreEqual(
            0, BankAccReconLine.Difference,
            'The reconciliation line difference must be zero once the total receipt is matched.');

        // [THEN] The response explicitly reports the line as matched.
        Assert.IsTrue(
            ResultMatched,
            'PostAndReconcile must report reconciliationLineMatched = true once the line is matched.');
    end;

    /// <summary>
    /// Builds a slice-5 PostAndReconcile request: TWO payments entries (two customers), each carrying
    /// ONE appliesTo entry (one invoice per customer). Mirrors the stable JSON contract documented on
    /// codeunit "MON Pmt Recon Service".
    /// </summary>
    local procedure BuildMultiCustomerRequest(BankAccountNo: Code[20]; StatementNo: Code[20]; StatementLineNo: Integer; JournalTemplateName: Code[10]; JournalBatchName: Code[10]; ExternalDocumentNo: Code[35]; CustomerNo1: Code[20]; CustLedgerEntryNoA: Integer; AmountA: Decimal; CustomerNo2: Code[20]; CustLedgerEntryNoB: Integer; AmountB: Decimal): JsonObject
    var
        Request: JsonObject;
        Payment1: JsonObject;
        Payment2: JsonObject;
        AppliesToEntryA: JsonObject;
        AppliesToEntryB: JsonObject;
        Payments: JsonArray;
        AppliesTo1: JsonArray;
        AppliesTo2: JsonArray;
    begin
        // Payment 1: customer 1 settling invoice A.
        AppliesToEntryA.Add('custLedgerEntryNo', CustLedgerEntryNoA);
        AppliesToEntryA.Add('amount', AmountA);
        AppliesTo1.Add(AppliesToEntryA);
        Payment1.Add('customerNo', CustomerNo1);
        Payment1.Add('appliesTo', AppliesTo1);
        Payments.Add(Payment1);

        // Payment 2: customer 2 settling invoice B.
        AppliesToEntryB.Add('custLedgerEntryNo', CustLedgerEntryNoB);
        AppliesToEntryB.Add('amount', AmountB);
        AppliesTo2.Add(AppliesToEntryB);
        Payment2.Add('customerNo', CustomerNo2);
        Payment2.Add('appliesTo', AppliesTo2);
        Payments.Add(Payment2);

        Request.Add('bankAccountNo', BankAccountNo);
        Request.Add('statementNo', StatementNo);
        Request.Add('statementLineNo', StatementLineNo);
        Request.Add('journalTemplateName', JournalTemplateName);
        Request.Add('journalBatchName', JournalBatchName);
        Request.Add('externalDocumentNo', ExternalDocumentNo);
        Request.Add('payments', Payments);
        exit(Request);
    end;

    /// <summary>
    /// Posts a sales invoice of ONE item line at the given unit price for an existing customer and
    /// returns the resulting open Cust. Ledger Entry No. and its remaining amount (the settle amount,
    /// VAT included). Used to arrange the multiple distinct invoices of the slice-4 scenario.
    /// </summary>
    local procedure CreatePostedInvoiceForCustomer(CustomerNo: Code[20]; UnitPrice: Decimal; var CustLedgerEntryNo: Integer; var RemainingAmount: Decimal)
    var
        Item: Record Item;
        SalesHeader: Record "Sales Header";
        SalesLine: Record "Sales Line";
        CustLedgerEntry: Record "Cust. Ledger Entry";
        PostedInvoiceNo: Code[20];
    begin
        LibraryInventory.CreateItem(Item);
        LibrarySales.CreateSalesHeader(SalesHeader, SalesHeader."Document Type"::Invoice, CustomerNo);
        LibrarySales.CreateSalesLine(SalesLine, SalesHeader, SalesLine.Type::Item, Item."No.", 1);
        SalesLine.Validate("Unit Price", UnitPrice);
        SalesLine.Modify(true);
        PostedInvoiceNo := LibrarySales.PostSalesDocument(SalesHeader, true, true);

        CustLedgerEntry.SetRange("Document Type", CustLedgerEntry."Document Type"::Invoice);
        CustLedgerEntry.SetRange("Document No.", PostedInvoiceNo);
        CustLedgerEntry.FindFirst();
        CustLedgerEntry.CalcFields("Remaining Amount");
        CustLedgerEntryNo := CustLedgerEntry."Entry No.";
        RemainingAmount := CustLedgerEntry."Remaining Amount";
    end;

    /// <summary>
    /// Builds a slice-4 PostAndReconcile request: ONE payments entry whose appliesTo carries TWO
    /// entries (one customer, two invoices). Mirrors the stable JSON contract documented on codeunit
    /// "MON Pmt Recon Service".
    /// </summary>
    local procedure BuildMultiInvoiceRequest(BankAccountNo: Code[20]; StatementNo: Code[20]; StatementLineNo: Integer; JournalTemplateName: Code[10]; JournalBatchName: Code[10]; ExternalDocumentNo: Code[35]; CustomerNo: Code[20]; CustLedgerEntryNoA: Integer; AmountA: Decimal; CustLedgerEntryNoB: Integer; AmountB: Decimal): JsonObject
    var
        Request: JsonObject;
        Payment: JsonObject;
        AppliesToEntryA: JsonObject;
        AppliesToEntryB: JsonObject;
        Payments: JsonArray;
        AppliesTo: JsonArray;
    begin
        AppliesToEntryA.Add('custLedgerEntryNo', CustLedgerEntryNoA);
        AppliesToEntryA.Add('amount', AmountA);
        AppliesTo.Add(AppliesToEntryA);

        AppliesToEntryB.Add('custLedgerEntryNo', CustLedgerEntryNoB);
        AppliesToEntryB.Add('amount', AmountB);
        AppliesTo.Add(AppliesToEntryB);

        Payment.Add('customerNo', CustomerNo);
        Payment.Add('appliesTo', AppliesTo);
        Payments.Add(Payment);

        Request.Add('bankAccountNo', BankAccountNo);
        Request.Add('statementNo', StatementNo);
        Request.Add('statementLineNo', StatementLineNo);
        Request.Add('journalTemplateName', JournalTemplateName);
        Request.Add('journalBatchName', JournalBatchName);
        Request.Add('externalDocumentNo', ExternalDocumentNo);
        Request.Add('payments', Payments);
        exit(Request);
    end;

    /// <summary>
    /// Builds the slice-3 PostAndReconcile request: exactly one payments entry with exactly one
    /// appliesTo entry. Mirrors the stable JSON contract documented on codeunit "MON Pmt Recon Service".
    /// </summary>
    local procedure BuildRequest(BankAccountNo: Code[20]; StatementNo: Code[20]; StatementLineNo: Integer; JournalTemplateName: Code[10]; JournalBatchName: Code[10]; ExternalDocumentNo: Code[35]; CustomerNo: Code[20]; CustLedgerEntryNo: Integer; Amount: Decimal): JsonObject
    var
        Request: JsonObject;
        Payment: JsonObject;
        AppliesToEntry: JsonObject;
        Payments: JsonArray;
        AppliesTo: JsonArray;
    begin
        AppliesToEntry.Add('custLedgerEntryNo', CustLedgerEntryNo);
        AppliesToEntry.Add('amount', Amount);
        AppliesTo.Add(AppliesToEntry);

        Payment.Add('customerNo', CustomerNo);
        Payment.Add('appliesTo', AppliesTo);
        Payments.Add(Payment);

        Request.Add('bankAccountNo', BankAccountNo);
        Request.Add('statementNo', StatementNo);
        Request.Add('statementLineNo', StatementLineNo);
        Request.Add('journalTemplateName', JournalTemplateName);
        Request.Add('journalBatchName', JournalBatchName);
        Request.Add('externalDocumentNo', ExternalDocumentNo);
        Request.Add('payments', Payments);
        exit(Request);
    end;

    local procedure ReadInt(Obj: JsonObject; KeyName: Text): Integer
    var
        Token: JsonToken;
    begin
        if not Obj.Get(KeyName, Token) then
            exit(0);
        exit(Token.AsValue().AsInteger());
    end;

    local procedure ReadBool(Obj: JsonObject; KeyName: Text): Boolean
    var
        Token: JsonToken;
    begin
        if not Obj.Get(KeyName, Token) then
            exit(false);
        exit(Token.AsValue().AsBoolean());
    end;

    local procedure NewExternalDocNo(): Code[35]
    begin
        exit(CopyStr('MON-' + Format(LibraryRandom.RandIntInRange(100000, 999999)), 1, 35));
    end;
}
