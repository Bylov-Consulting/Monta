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
    procedure PostAndReconcileJson_TextBoundary()
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
        RequestText: Text;
        ResponseText: Text;
        PostedInvoiceNo: Code[20];
        AppliedCustLedgerEntryNo: Integer;
        InvoiceAmount: Decimal;
        StatementNo: Code[20];
        StatementLineNo: Integer;
        StatementAmount: Decimal;
        ResultBankEntryNo: Integer;
        ResultMatched: Boolean;
    begin
        // [SCENARIO] Slice 10: the agent-facing OData bound action postAndReconcile carries the request and
        // response as JSON STRINGS (Edm.String action parameter/return). The bound action is a one-line
        // delegate to MON Pmt Recon Service.PostAndReconcileJson, so this drives that text-boundary method
        // directly: a SERIALISED request string must produce the SAME composite post+match as the JsonObject
        // path AND a response STRING that parses back to the stable {bankAccountLedgerEntryNo,
        // reconciliationLineMatched} contract. (The HTTP/OData transport + auth + entity binding around the
        // [ServiceEnabled] action cannot be invoked by a TestPage and is verified in the sandbox smoke test;
        // this proves everything from the text boundary inward, which is all the action itself contributes.)

        // [GIVEN] A customer with a posted sales invoice for a known amount.
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
        AppliedCustLedgerEntryNo := CustLedgerEntry."Entry No.";
        InvoiceAmount := CustLedgerEntry."Remaining Amount";

        // [GIVEN] A bank account, a journal template + batch, and ONE unmatched reconciliation line whose
        // Statement Amount equals the invoice amount.
        LibraryERM.CreateBankAccount(BankAccount);
        LibraryERM.CreateGenJournalTemplate(GenJournalTemplate);
        LibraryERM.CreateGenJournalBatch(GenJournalBatch, GenJournalTemplate.Name);

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

        Assert.AreEqual(
            0, BankAccReconLine."Applied Entries",
            'Precondition: the reconciliation line must start with no applied entries.');

        // [WHEN] The request is SERIALISED to a JSON string (exactly what an OData action parameter delivers)
        // and passed to the text-boundary delegate the bound action calls.
        Request := BuildRequest(
            BankAccount."No.", StatementNo, StatementLineNo,
            GenJournalTemplate.Name, GenJournalBatch.Name, NewExternalDocNo(),
            Customer."No.", AppliedCustLedgerEntryNo, InvoiceAmount);
        Request.WriteTo(RequestText);
        Assert.AreNotEqual('', RequestText, 'Arrange: the request must serialise to a non-empty JSON string.');

        ResponseText := PmtReconService.PostAndReconcileJson(RequestText);

        // [THEN] The response is a JSON STRING that parses back to the stable contract. (A raw entry-No.
        // string, an empty string, or a non-object would fail ReadFrom -> the boundary did not round-trip.)
        Assert.IsTrue(
            Response.ReadFrom(ResponseText),
            'PostAndReconcileJson must return a JSON object string parseable as the response contract.');
        ResultBankEntryNo := ReadInt(Response, 'bankAccountLedgerEntryNo');
        ResultMatched := ReadBool(Response, 'reconciliationLineMatched');

        // [THEN] The composite really happened through the text boundary: a real open bank entry for the
        // payment exists, the invoice closed, and the recon line is matched 1:1 — identical observable
        // outcome to the JsonObject service test, proving the bound action's delegate is wired end to end.
        Assert.AreNotEqual(
            0, ResultBankEntryNo,
            'The text boundary must return a non-zero Bank Account Ledger Entry No. for the posted receipt.');
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

        CustLedgerEntry.Get(AppliedCustLedgerEntryNo);
        CustLedgerEntry.CalcFields("Remaining Amount");
        Assert.AreEqual(
            0, CustLedgerEntry."Remaining Amount",
            'The applied invoice must be fully paid (Remaining Amount = 0) after the text-boundary call.');

        BankAccReconLine.Get(
            BankAccReconLine."Statement Type"::"Bank Reconciliation",
            BankAccount."No.", StatementNo, StatementLineNo);
        Assert.AreEqual(
            1, BankAccReconLine."Applied Entries",
            'The reconciliation line must have exactly one applied bank ledger entry after the text-boundary call.');
        Assert.AreEqual(
            0, BankAccReconLine.Difference,
            'The reconciliation line difference must be zero once the entry is matched.');
        Assert.IsTrue(
            ResultMatched,
            'The response must report reconciliationLineMatched = true once the line is matched.');
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

    [Test]
    procedure PostAndReconcile_WithWriteOff()
    var
        Customer: Record Customer;
        BankAccount: Record "Bank Account";
        GenJournalTemplate: Record "Gen. Journal Template";
        GenJournalBatch: Record "Gen. Journal Batch";
        WriteOffGLAccount: Record "G/L Account";
        CustLedgerEntry: Record "Cust. Ledger Entry";
        BankAccReconciliation: Record "Bank Acc. Reconciliation";
        BankAccReconLine: Record "Bank Acc. Reconciliation Line";
        BankAccLedgerEntry: Record "Bank Account Ledger Entry";
        PmtReconService: Codeunit "MON Pmt Recon Service";
        Request: JsonObject;
        Response: JsonObject;
        AppliedCustLedgerEntryNo: Integer;
        InvoiceAmount: Decimal;
        WriteOffAmount: Decimal;
        CashAmount: Decimal;
        StatementNo: Code[20];
        StatementLineNo: Integer;
        ResultBankEntryNo: Integer;
        ResultMatched: Boolean;
    begin
        // [SCENARIO] Slice 6: a customer settles an invoice IN FULL but pays LESS cash than the invoice;
        // the agent supplies a G/L account to absorb the difference (a payment-difference write-off). The
        // invoice must close fully (Applies-to amount = invoice remaining X), the write-off difference W
        // must post to the agent's G/L account, and — by design — write-offs NEVER hit the bank, so the
        // single Bank Account Ledger Entry equals the CASH (X - W) = the statement-line amount, keeping
        // the recon match 1:1. One customer / one invoice; no VAT / bad-debt logic.

        // [GIVEN] A customer with ONE posted sales invoice of amount X; capture its open Cust. Ledger
        // Entry No. and remaining amount X (the full invoice value, settled in full by the apply).
        LibrarySales.CreateCustomer(Customer);
        CreatePostedInvoiceForCustomer(
            Customer."No.", LibraryRandom.RandDecInRange(100, 1000, 2), AppliedCustLedgerEntryNo, InvoiceAmount);

        // [GIVEN] A bank account and a general journal template + batch for the payment.
        LibraryERM.CreateBankAccount(BankAccount);
        LibraryERM.CreateGenJournalTemplate(GenJournalTemplate);
        LibraryERM.CreateGenJournalBatch(GenJournalBatch, GenJournalTemplate.Name);

        // [GIVEN] A G/L account the agent nominates for the write-off, explicitly set to allow DIRECT
        // POSTING (a balancing G/L journal line cannot post to an account with Direct Posting = false).
        // No Gen./VAT posting groups are set, so the write-off posts with no VAT (slice-6 scope).
        CreateDirectPostingGLAccount(WriteOffGLAccount);

        // [GIVEN] A small write-off W with 0 < W < X (the 10..50 range is strictly below the 100.. invoice
        // floor, so the under-payment is well-formed) and the CASH actually received = X - W.
        WriteOffAmount := LibraryRandom.RandDecInRange(10, 50, 2);
        CashAmount := InvoiceAmount - WriteOffAmount;

        // [GIVEN] Sanity: the write-off is a genuine under-payment (0 < W < X) so cash (X - W) is strictly
        // less than the invoice — the whole point of the slice is that bank <> invoice.
        Assert.IsTrue(
            (WriteOffAmount > 0) and (WriteOffAmount < InvoiceAmount),
            'Precondition: the write-off W must satisfy 0 < W < X so the payment is a real under-payment.');

        // [GIVEN] A standard Bank Acc. Reconciliation with ONE UNMATCHED line whose Statement Amount is
        // the CASH received (X - W) — write-offs never reach the bank, so the statement shows only cash.
        // Difference = X - W, Applied Entries = 0.
        LibraryERM.CreateBankAccReconciliation(
            BankAccReconciliation, BankAccount."No.",
            BankAccReconciliation."Statement Type"::"Bank Reconciliation");
        LibraryERM.CreateBankAccReconciliationLn(BankAccReconLine, BankAccReconciliation);
        BankAccReconLine.Validate("Statement Amount", CashAmount);
        BankAccReconLine.Difference := CashAmount; // unmatched: nothing applied yet
        BankAccReconLine.Modify(true);
        StatementNo := BankAccReconLine."Statement No.";
        StatementLineNo := BankAccReconLine."Statement Line No.";

        // [GIVEN] Guard the starting state so the post-conditions can only be reached by PostAndReconcile.
        Assert.AreEqual(
            0, BankAccReconLine."Applied Entries",
            'Precondition: the reconciliation line must start with no applied entries.');
        Assert.AreEqual(
            CashAmount, BankAccReconLine.Difference,
            'Precondition: the full cash amount (X - W) must be outstanding before the composite call.');
        Assert.AreEqual(
            0, WriteOffGLEntryAmount(WriteOffGLAccount."No."),
            'Precondition: the fresh write-off G/L account must have no G/L entries before the call.');

        // [WHEN] The agent issues a single PostAndReconcile call: payments[0] applies the FULL invoice X
        // to its CLE AND carries writeOff[0] = { glAccountNo, amount: W }.
        Request := BuildWriteOffRequest(
            BankAccount."No.", StatementNo, StatementLineNo,
            GenJournalTemplate.Name, GenJournalBatch.Name, NewExternalDocNo(),
            Customer."No.", AppliedCustLedgerEntryNo, InvoiceAmount,
            WriteOffGLAccount."No.", WriteOffAmount);
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

        // [THEN] The bank entry equals the CASH (X - W), NOT the invoice X. Today writeOff is ignored, so
        // the bank line is posted for the full Sum-of-applies X -> |Amount| = X <> X - W: this is the
        // FIRST assertion that fails under the current no-write-off behaviour.
        Assert.AreEqual(
            CashAmount, Abs(BankAccLedgerEntry.Amount),
            'The Bank Account Ledger Entry amount must equal the CASH received (X - W), not the invoice X.');
        Assert.IsTrue(
            BankAccLedgerEntry.Open,
            'The Bank Account Ledger Entry must remain open (matched, not yet statement-posted).');

        // [THEN] The invoice is settled in FULL — re-Get + CalcFields. (The full X is applied, so this
        // closes even today; it pins that the write-off does NOT shrink the customer settlement.)
        CustLedgerEntry.Get(AppliedCustLedgerEntryNo);
        CustLedgerEntry.CalcFields("Remaining Amount");
        Assert.AreEqual(
            0, CustLedgerEntry."Remaining Amount",
            'The invoice must be fully paid (Remaining Amount = 0): the apply settles the full X.');
        Assert.IsFalse(
            CustLedgerEntry.Open,
            'The invoice must be closed (Open = false) — settled in full despite the under-payment.');

        // [THEN] The write-off posted to the agent's G/L account: net G/L Entry Amount on that (fresh)
        // account = +W. For an under-payment write-off the difference is a DEBIT to the G/L account, and
        // a positive Gen. Journal Line Amount on a G/L Account posts a positive (debit) G/L Entry Amount,
        // so the net is +W. Today no write-off line is posted -> the net is 0 <> W.
        Assert.AreEqual(
            WriteOffAmount, WriteOffGLEntryAmount(WriteOffGLAccount."No."),
            'The write-off G/L account must carry a net G/L Entry Amount of +W (the difference debited to it).');

        // [THEN] The reconciliation line is fully matched to the ONE bank entry for the CASH: Applied
        // Entries = 1, Applied Amount = X - W, Difference = 0. Today the bank entry is X, so Applied
        // Amount = X and Difference = (X - W) - X = -W <> 0.
        BankAccReconLine.Get(
            BankAccReconLine."Statement Type"::"Bank Reconciliation",
            BankAccount."No.", StatementNo, StatementLineNo);
        Assert.AreEqual(
            1, BankAccReconLine."Applied Entries",
            'The reconciliation line must have exactly one applied bank ledger entry (1:1 with the cash receipt).');
        Assert.AreEqual(
            CashAmount, BankAccReconLine."Applied Amount",
            'The applied amount must equal the CASH statement amount (X - W).');
        Assert.AreEqual(
            0, BankAccReconLine.Difference,
            'The reconciliation line difference must be zero once the cash receipt is matched.');

        // [THEN] The response explicitly reports the line as matched.
        Assert.IsTrue(
            ResultMatched,
            'PostAndReconcile must report reconciliationLineMatched = true once the line is matched.');
    end;

    [Test]
    procedure PostAndReconcile_IdempotentReplay()
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
        Response1: JsonObject;
        Response2: JsonObject;
        AppliedCustLedgerEntryNo: Integer;
        InvoiceAmount: Decimal;
        StatementNo: Code[20];
        StatementLineNo: Integer;
        StatementAmount: Decimal;
        BankEntryNo1: Integer;
        BankEntryNo2: Integer;
        ResultMatched2: Boolean;
    begin
        // [SCENARIO] Slice 7 (idempotent replay): the idempotency key is the reconciliation line
        // identity (Bank Account No., Statement No., Statement Line No.). Calling PostAndReconcile a
        // SECOND time with the SAME request (same recon line + same payload/hash) must NOT post again:
        // it returns the SAME bankAccountLedgerEntryNo as the first call, posts NO additional payment
        // (exactly ONE bank entry, ONE customer payment), and leaves the recon line matched exactly once.
        // One customer / one invoice; no write-offs.

        // [GIVEN] A customer with a posted sales invoice of amount X and its open Cust. Ledger Entry.
        LibrarySales.CreateCustomer(Customer);
        CreatePostedInvoiceForCustomer(
            Customer."No.", LibraryRandom.RandDecInRange(100, 1000, 2), AppliedCustLedgerEntryNo, InvoiceAmount);

        // [GIVEN] A FRESH bank account + journal — a fresh bank account means a simple SetRange+Count on
        // Bank Account Ledger Entry isolates exactly the entries this test posts (so "exactly one" is sound).
        LibraryERM.CreateBankAccount(BankAccount);
        LibraryERM.CreateGenJournalTemplate(GenJournalTemplate);
        LibraryERM.CreateGenJournalBatch(GenJournalBatch, GenJournalTemplate.Name);

        // [GIVEN] A standard Bank Acc. Reconciliation with ONE UNMATCHED line whose Statement Amount = X.
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

        // [WHEN] The SAME request object/content is issued TWICE (built ONCE so the payload/hash is
        // byte-for-byte identical between calls — that identity is what the replay path keys on).
        Request := BuildRequest(
            BankAccount."No.", StatementNo, StatementLineNo,
            GenJournalTemplate.Name, GenJournalBatch.Name, NewExternalDocNo(),
            Customer."No.", AppliedCustLedgerEntryNo, InvoiceAmount);
        Response1 := PmtReconService.PostAndReconcile(Request);
        Response2 := PmtReconService.PostAndReconcile(Request);

        BankEntryNo1 := ReadInt(Response1, 'bankAccountLedgerEntryNo');
        BankEntryNo2 := ReadInt(Response2, 'bankAccountLedgerEntryNo');
        ResultMatched2 := ReadBool(Response2, 'reconciliationLineMatched');

        // [THEN] The replay returns the SAME bank ledger entry as the first call — no new post. Today the
        // second call never reaches here (it throws in ValidateRequest: the invoice CLE is now closed),
        // so this whole [THEN] block is unreachable under the current no-idempotency behaviour -> RED.
        Assert.AreNotEqual(
            0, BankEntryNo1,
            'The first call must return a non-zero Bank Account Ledger Entry No. for the posted receipt.');
        Assert.AreEqual(
            BankEntryNo1, BankEntryNo2,
            'Replay must return the SAME Bank Account Ledger Entry No. as the first call (no second post).');

        // [THEN] EXACTLY ONE Bank Account Ledger Entry exists on the (fresh) bank account: no double-post.
        BankAccLedgerEntry.SetRange("Bank Account No.", BankAccount."No.");
        Assert.AreEqual(
            1, BankAccLedgerEntry.Count(),
            'Exactly one Bank Account Ledger Entry must exist on the bank account (the replay must not post a second).');

        // [THEN] No additional customer payment was posted: exactly ONE Payment Cust. Ledger Entry exists
        // for the customer (a second post would create a second payment entry and a second application).
        Assert.AreEqual(
            1, CustomerPaymentEntryCount(Customer."No."),
            'Exactly one customer Payment ledger entry must exist (the invoice is applied by a SINGLE payment, not two).');

        // [THEN] The applied invoice is closed — settled by that single payment application.
        CustLedgerEntry.Get(AppliedCustLedgerEntryNo);
        CustLedgerEntry.CalcFields("Remaining Amount");
        Assert.AreEqual(
            0, CustLedgerEntry."Remaining Amount",
            'The applied invoice must be fully paid (Remaining Amount = 0) after the replay.');
        Assert.IsFalse(
            CustLedgerEntry.Open,
            'The applied invoice must be closed (Open = false) — applied exactly once.');

        // [THEN] The reconciliation line is matched exactly once: Applied Entries = 1, Difference = 0
        // (the replay must not add a second applied entry).
        BankAccReconLine.Get(
            BankAccReconLine."Statement Type"::"Bank Reconciliation",
            BankAccount."No.", StatementNo, StatementLineNo);
        Assert.AreEqual(
            1, BankAccReconLine."Applied Entries",
            'The reconciliation line must carry exactly one applied bank ledger entry after the replay.');
        Assert.AreEqual(
            0, BankAccReconLine.Difference,
            'The reconciliation line difference must be zero and unchanged by the replay.');

        // [THEN] The replay response still reports the line as matched.
        Assert.IsTrue(
            ResultMatched2,
            'PostAndReconcile must report reconciliationLineMatched = true on the idempotent replay.');
    end;

    [Test]
    procedure PostAndReconcile_ConflictRejected()
    var
        Customer1: Record Customer;
        Customer2: Record Customer;
        BankAccount: Record "Bank Account";
        GenJournalTemplate: Record "Gen. Journal Template";
        GenJournalBatch: Record "Gen. Journal Batch";
        BankAccReconciliation: Record "Bank Acc. Reconciliation";
        BankAccReconLine: Record "Bank Acc. Reconciliation Line";
        PmtReconService: Codeunit "MON Pmt Recon Service";
        Request1: JsonObject;
        Request2: JsonObject;
        Response1: JsonObject;
        CustLedgerEntryNo1: Integer;
        CustLedgerEntryNo2: Integer;
        Amount1: Decimal;
        Amount2: Decimal;
        StatementNo: Code[20];
        StatementLineNo: Integer;
        BankEntryNo1: Integer;
    begin
        // [SCENARIO] Slice 7 (conflict): calling PostAndReconcile AGAIN for the SAME reconciliation line L
        // but with a DIFFERENT payload (different request hash) must be REJECTED with a clear error — it
        // must NOT double-post or double-match. Two customers, one invoice each.

        // [GIVEN] TWO customers, each with ONE posted invoice of a distinct amount (X1, X2). Distinct
        // unit-price ranges guarantee X1 <> X2 (so the two payloads genuinely differ -> different hash).
        LibrarySales.CreateCustomer(Customer1);
        LibrarySales.CreateCustomer(Customer2);
        CreatePostedInvoiceForCustomer(
            Customer1."No.", LibraryRandom.RandDecInRange(100, 500, 2), CustLedgerEntryNo1, Amount1);
        CreatePostedInvoiceForCustomer(
            Customer2."No.", LibraryRandom.RandDecInRange(600, 1000, 2), CustLedgerEntryNo2, Amount2);

        // [GIVEN] Sanity: the two requests will differ (distinct customers, entries and amounts).
        Assert.AreNotEqual(
            Amount1, Amount2,
            'Precondition: the two payloads must differ so the second request has a different hash.');

        // [GIVEN] A fresh bank account + journal (fresh bank -> a simple Count isolates this test).
        LibraryERM.CreateBankAccount(BankAccount);
        LibraryERM.CreateGenJournalTemplate(GenJournalTemplate);
        LibraryERM.CreateGenJournalBatch(GenJournalBatch, GenJournalTemplate.Name);

        // [GIVEN] ONE reconciliation line L; Statement Amount = X1 so the FIRST request reconciles cleanly.
        LibraryERM.CreateBankAccReconciliation(
            BankAccReconciliation, BankAccount."No.",
            BankAccReconciliation."Statement Type"::"Bank Reconciliation");
        LibraryERM.CreateBankAccReconciliationLn(BankAccReconLine, BankAccReconciliation);
        BankAccReconLine.Validate("Statement Amount", Amount1);
        BankAccReconLine.Difference := Amount1; // unmatched: nothing applied yet
        BankAccReconLine.Modify(true);
        StatementNo := BankAccReconLine."Statement No.";
        StatementLineNo := BankAccReconLine."Statement Line No.";

        // [GIVEN] Two DIFFERENT requests targeting the SAME recon line L = (bank, StatementNo, LineNo).
        // Request1: customer 1 / invoice 1 / X1. Request2: customer 2 / invoice 2 / X2 — same recon line,
        // different payload (and different hash).
        Request1 := BuildRequest(
            BankAccount."No.", StatementNo, StatementLineNo,
            GenJournalTemplate.Name, GenJournalBatch.Name, NewExternalDocNo(),
            Customer1."No.", CustLedgerEntryNo1, Amount1);
        Request2 := BuildRequest(
            BankAccount."No.", StatementNo, StatementLineNo,
            GenJournalTemplate.Name, GenJournalBatch.Name, NewExternalDocNo(),
            Customer2."No.", CustLedgerEntryNo2, Amount2);

        // [WHEN] The first call succeeds and reconciles L.
        Response1 := PmtReconService.PostAndReconcile(Request1);
        BankEntryNo1 := ReadInt(Response1, 'bankAccountLedgerEntryNo');
        Assert.AreNotEqual(
            0, BankEntryNo1,
            'Arrange: the first call must reconcile the line (non-zero Bank Account Ledger Entry No.).');

        // [WHEN] A conflicting second call for the SAME recon line with a DIFFERENT payload is issued.
        asserterror PmtReconService.PostAndReconcile(Request2);

        // [THEN] It is rejected with the recon-line-already-reconciled conflict. GREEN raises
        // 'Reconciliation line %1/%2 has already been reconciled by a different request.' — assert on the
        // distinctive substring. Today there is NO conflict check (the second call either posts+matches a
        // second entry or throws an unrelated error), so this substring is ABSENT -> RED.
        // The conflict is rejected BEFORE any posting (the idempotency gate runs first), so no second
        // receipt is created. A post-asserterror Bank Account Ledger Entry count cannot prove this: the
        // caught error rolls the whole un-committed test transaction back past Request1 too — ExpectedError
        // above is the load-bearing proof of the conflict behaviour.
        Assert.ExpectedError('already been reconciled');
    end;

    [Test]
    procedure PostAndReconcile_RejectsNoPayments()
    var
        BankAccount: Record "Bank Account";
        GenJournalTemplate: Record "Gen. Journal Template";
        GenJournalBatch: Record "Gen. Journal Batch";
        PmtReconService: Codeunit "MON Pmt Recon Service";
        Request: JsonObject;
        Payments: JsonArray;
        StatementNo: Code[20];
        StatementLineNo: Integer;
    begin
        // [SCENARIO] Slice 3v (request-schema validation): the agent caller must get a clear, actionable
        // error BEFORE any posting when the request carries no payments at all. An EMPTY payments array
        // (the "nothing to post" shape) must be rejected with the specific "at least one payment" message
        // — not the opaque downstream error today's code raises once it tries to post an empty document.

        // [GIVEN] A valid bank account, journal template + batch and ONE unmatched reconciliation line, so
        // every header reference resolves and the ONLY defect under test is the absence of payments.
        ArrangeBankJournalRecon(
            BankAccount, GenJournalTemplate, GenJournalBatch,
            LibraryRandom.RandDecInRange(100, 1000, 2), StatementNo, StatementLineNo);

        // [GIVEN] An otherwise valid request whose payments is an EMPTY array.
        AddRequestHeader(
            Request, BankAccount."No.", StatementNo, StatementLineNo,
            GenJournalTemplate.Name, GenJournalBatch.Name, NewExternalDocNo());
        Request.Add('payments', Payments); // empty: nothing to post

        // [WHEN/THEN] PostAndReconcile must reject this up front with the no-payments validation error. Today
        // the empty array flows into the poster, whose ValidateRequest raises NoAppliesEntriesErr ("At least
        // one customer ledger entry must be supplied for the payment.") — a DIFFERENT message that does NOT
        // contain "at least one payment", so the substring is absent today -> RED.
        asserterror PmtReconService.PostAndReconcile(Request);
        Assert.ExpectedError('at least one payment');
    end;

    [Test]
    procedure PostAndReconcile_RejectsPaymentNoApplies()
    var
        Customer: Record Customer;
        BankAccount: Record "Bank Account";
        GenJournalTemplate: Record "Gen. Journal Template";
        GenJournalBatch: Record "Gen. Journal Batch";
        WriteOffGLAccount: Record "G/L Account";
        PmtReconService: Codeunit "MON Pmt Recon Service";
        Request: JsonObject;
        Payment: JsonObject;
        WriteOffEntry: JsonObject;
        Payments: JsonArray;
        AppliesTo: JsonArray;
        WriteOff: JsonArray;
        CustLedgerEntryNo: Integer;
        InvoiceAmount: Decimal;
        StatementNo: Code[20];
        StatementLineNo: Integer;
    begin
        // [SCENARIO] Slice 3v: a payment that applies to NO customer ledger entry must be rejected, EVEN
        // when it carries write-offs. This closes the slice-6 gap where an all-write-off / no-apply payment
        // posts a negative/cryptic bank line instead of erroring. The caller must get the specific
        // "at least one customer ledger entry" message before any posting.

        // [GIVEN] A real customer with an open invoice (so customerNo is valid), a direct-posting write-off
        // G/L account (so the write-off row itself is well-formed), and a valid bank/journal/recon line — so
        // the ONLY defect is the empty appliesTo.
        LibrarySales.CreateCustomer(Customer);
        CreatePostedInvoiceForCustomer(
            Customer."No.", LibraryRandom.RandDecInRange(100, 1000, 2), CustLedgerEntryNo, InvoiceAmount);
        CreateDirectPostingGLAccount(WriteOffGLAccount);
        ArrangeBankJournalRecon(
            BankAccount, GenJournalTemplate, GenJournalBatch, InvoiceAmount, StatementNo, StatementLineNo);

        // [GIVEN] A payment with an EMPTY appliesTo but a non-empty writeOff (applies to nothing, only writes
        // off) — the exact "all write-off, no apply rows" shape that otherwise posts a negative bank line.
        WriteOffEntry.Add('glAccountNo', WriteOffGLAccount."No.");
        WriteOffEntry.Add('amount', LibraryRandom.RandDecInRange(10, 50, 2));
        WriteOff.Add(WriteOffEntry);
        Payment.Add('customerNo', Customer."No.");
        Payment.Add('appliesTo', AppliesTo); // empty: applies to nothing
        Payment.Add('writeOff', WriteOff);
        Payments.Add(Payment);

        AddRequestHeader(
            Request, BankAccount."No.", StatementNo, StatementLineNo,
            GenJournalTemplate.Name, GenJournalBatch.Name, NewExternalDocNo());
        Request.Add('payments', Payments);

        // [WHEN/THEN] PostAndReconcile must reject the no-apply payment up front. Today the write-off row
        // keeps the buffer non-empty, so ValidateRequest passes and the poster fails later on an unrelated
        // opaque error (no Customer-Apply row to seed/group the document) — the "at least one customer ledger
        // entry" substring is absent today -> RED.
        asserterror PmtReconService.PostAndReconcile(Request);
        Assert.ExpectedError('at least one customer ledger entry');
    end;

    [Test]
    procedure PostAndReconcile_RejectsMissingHeader()
    var
        Customer: Record Customer;
        BankAccount: Record "Bank Account";
        GenJournalTemplate: Record "Gen. Journal Template";
        GenJournalBatch: Record "Gen. Journal Batch";
        PmtReconService: Codeunit "MON Pmt Recon Service";
        Request: JsonObject;
        Payment: JsonObject;
        AppliesToEntry: JsonObject;
        Payments: JsonArray;
        AppliesTo: JsonArray;
        CustLedgerEntryNo: Integer;
        InvoiceAmount: Decimal;
        StatementNo: Code[20];
        StatementLineNo: Integer;
    begin
        // [SCENARIO] Slice 3v: a required header field that is absent (or blank) must be rejected with the
        // specific "missing required field" message naming the field, instead of an opaque downstream "does
        // not exist" error. Representative case: bankAccountNo omitted entirely.

        // [GIVEN] A real customer with an open invoice and a valid bank/journal/recon line — every value the
        // request needs EXISTS, so the ONLY defect is that bankAccountNo is omitted from the request body.
        LibrarySales.CreateCustomer(Customer);
        CreatePostedInvoiceForCustomer(
            Customer."No.", LibraryRandom.RandDecInRange(100, 1000, 2), CustLedgerEntryNo, InvoiceAmount);
        ArrangeBankJournalRecon(
            BankAccount, GenJournalTemplate, GenJournalBatch, InvoiceAmount, StatementNo, StatementLineNo);

        // [GIVEN] A valid single payment...
        AppliesToEntry.Add('custLedgerEntryNo', CustLedgerEntryNo);
        AppliesToEntry.Add('amount', InvoiceAmount);
        AppliesTo.Add(AppliesToEntry);
        Payment.Add('customerNo', Customer."No.");
        Payment.Add('appliesTo', AppliesTo);
        Payments.Add(Payment);

        // [GIVEN] ...but a request header that OMITS bankAccountNo entirely (all other header keys present).
        Request.Add('statementNo', StatementNo);
        Request.Add('statementLineNo', StatementLineNo);
        Request.Add('journalTemplateName', GenJournalTemplate.Name);
        Request.Add('journalBatchName', GenJournalBatch.Name);
        Request.Add('externalDocumentNo', NewExternalDocNo());
        Request.Add('payments', Payments);

        // [WHEN/THEN] PostAndReconcile must reject the missing field up front. Today bankAccountNo defaults to
        // '' and the failure surfaces only later as BankAccount.Get('') -> "The Bank Account does not exist..."
        // which does NOT contain "missing required field" -> RED.
        asserterror PmtReconService.PostAndReconcile(Request);
        Assert.ExpectedError('missing required field');
    end;

    [Test]
    procedure PostAndReconcile_RejectsMissingStmtLine()
    var
        Customer: Record Customer;
        BankAccount: Record "Bank Account";
        GenJournalTemplate: Record "Gen. Journal Template";
        GenJournalBatch: Record "Gen. Journal Batch";
        PmtReconService: Codeunit "MON Pmt Recon Service";
        Request: JsonObject;
        Payment: JsonObject;
        AppliesToEntry: JsonObject;
        Payments: JsonArray;
        AppliesTo: JsonArray;
        CustLedgerEntryNo: Integer;
        InvoiceAmount: Decimal;
        StatementNo: Code[20];
        StatementLineNo: Integer;
    begin
        // [SCENARIO] Slice 3v: statementLineNo is one third of the reconciliation-line / idempotency key and is
        // required. When omitted, GetInt defaults it to 0; today the call posts then fails matching the
        // non-existent recon line 0 with an opaque "...does not exist" error. It must instead be rejected up
        // front with the specific "missing required field" message.

        // [GIVEN] A real customer + open invoice + valid bank/journal/recon line — the ONLY defect is that
        // statementLineNo is omitted from the request body.
        LibrarySales.CreateCustomer(Customer);
        CreatePostedInvoiceForCustomer(
            Customer."No.", LibraryRandom.RandDecInRange(100, 1000, 2), CustLedgerEntryNo, InvoiceAmount);
        ArrangeBankJournalRecon(
            BankAccount, GenJournalTemplate, GenJournalBatch, InvoiceAmount, StatementNo, StatementLineNo);

        // [GIVEN] A valid single payment...
        AppliesToEntry.Add('custLedgerEntryNo', CustLedgerEntryNo);
        AppliesToEntry.Add('amount', InvoiceAmount);
        AppliesTo.Add(AppliesToEntry);
        Payment.Add('customerNo', Customer."No.");
        Payment.Add('appliesTo', AppliesTo);
        Payments.Add(Payment);

        // [GIVEN] ...but a request header that OMITS statementLineNo (all other header keys present).
        Request.Add('bankAccountNo', BankAccount."No.");
        Request.Add('statementNo', StatementNo);
        Request.Add('journalTemplateName', GenJournalTemplate.Name);
        Request.Add('journalBatchName', GenJournalBatch.Name);
        Request.Add('externalDocumentNo', NewExternalDocNo());
        Request.Add('payments', Payments);

        // [WHEN/THEN] Rejected up front. Today statementLineNo defaults to 0 and the failure surfaces only as
        // matching the non-existent recon line 0 ("...does not exist"), lacking "missing required field" -> RED.
        asserterror PmtReconService.PostAndReconcile(Request);
        Assert.ExpectedError('missing required field');
    end;

    [Test]
    procedure PostAndReconcile_RejectsDuplicateApply()
    var
        Customer: Record Customer;
        BankAccount: Record "Bank Account";
        GenJournalTemplate: Record "Gen. Journal Template";
        GenJournalBatch: Record "Gen. Journal Batch";
        PmtReconService: Codeunit "MON Pmt Recon Service";
        Request: JsonObject;
        Payment: JsonObject;
        AppliesToEntry1: JsonObject;
        AppliesToEntry2: JsonObject;
        Payments: JsonArray;
        AppliesTo: JsonArray;
        CustLedgerEntryNo: Integer;
        InvoiceAmount: Decimal;
        StatementNo: Code[20];
        StatementLineNo: Integer;
    begin
        // [SCENARIO] Slice 3v: the SAME customer ledger entry appearing more than once in one payment's
        // appliesTo is a malformed request (it would double-apply / over-apply that entry) and must be
        // rejected with the specific "appears more than once" message BEFORE any posting.

        // [GIVEN] A real customer with ONE open invoice and a valid bank/journal/recon line — so the ONLY
        // defect is the duplicated custLedgerEntryNo (a real, open entry, so the duplicate is the sole issue).
        LibrarySales.CreateCustomer(Customer);
        CreatePostedInvoiceForCustomer(
            Customer."No.", LibraryRandom.RandDecInRange(100, 1000, 2), CustLedgerEntryNo, InvoiceAmount);
        ArrangeBankJournalRecon(
            BankAccount, GenJournalTemplate, GenJournalBatch, InvoiceAmount, StatementNo, StatementLineNo);

        // [GIVEN] A single payment whose appliesTo lists the SAME custLedgerEntryNo TWICE.
        AppliesToEntry1.Add('custLedgerEntryNo', CustLedgerEntryNo);
        AppliesToEntry1.Add('amount', InvoiceAmount);
        AppliesTo.Add(AppliesToEntry1);
        AppliesToEntry2.Add('custLedgerEntryNo', CustLedgerEntryNo); // duplicate of the same entry
        AppliesToEntry2.Add('amount', InvoiceAmount);
        AppliesTo.Add(AppliesToEntry2);
        Payment.Add('customerNo', Customer."No.");
        Payment.Add('appliesTo', AppliesTo);
        Payments.Add(Payment);

        AddRequestHeader(
            Request, BankAccount."No.", StatementNo, StatementLineNo,
            GenJournalTemplate.Name, GenJournalBatch.Name, NewExternalDocNo());
        Request.Add('payments', Payments);

        // [WHEN/THEN] PostAndReconcile must reject the duplicate up front. Today there is no duplicate guard:
        // both rows pass ValidateRequest (the entry is open and owned by the customer) and the entry is
        // applied twice — over-applying / mis-posting, or failing with an unrelated posting error, but NEVER
        // the "appears more than once" message; if no error is raised at all, asserterror itself fails. Either
        // way the substring is absent today -> RED.
        asserterror PmtReconService.PostAndReconcile(Request);
        Assert.ExpectedError('appears more than once');
    end;

    /// <summary>
    /// Arranges the non-payment scaffolding shared by the slice-3v validation tests: a fresh bank account, a
    /// gen. journal template + batch, and ONE unmatched Bank Acc. Reconciliation line (Statement Type = Bank
    /// Reconciliation) whose Statement Amount = StatementAmount. Returns the recon line identity so the header
    /// references all resolve and only the request defect under test can cause the failure.
    /// </summary>
    local procedure ArrangeBankJournalRecon(var BankAccount: Record "Bank Account"; var GenJournalTemplate: Record "Gen. Journal Template"; var GenJournalBatch: Record "Gen. Journal Batch"; StatementAmount: Decimal; var StatementNo: Code[20]; var StatementLineNo: Integer)
    var
        BankAccReconciliation: Record "Bank Acc. Reconciliation";
        BankAccReconLine: Record "Bank Acc. Reconciliation Line";
    begin
        LibraryERM.CreateBankAccount(BankAccount);
        LibraryERM.CreateGenJournalTemplate(GenJournalTemplate);
        LibraryERM.CreateGenJournalBatch(GenJournalBatch, GenJournalTemplate.Name);
        LibraryERM.CreateBankAccReconciliation(
            BankAccReconciliation, BankAccount."No.",
            BankAccReconciliation."Statement Type"::"Bank Reconciliation");
        LibraryERM.CreateBankAccReconciliationLn(BankAccReconLine, BankAccReconciliation);
        BankAccReconLine.Validate("Statement Amount", StatementAmount);
        BankAccReconLine.Difference := StatementAmount;
        BankAccReconLine.Modify(true);
        StatementNo := BankAccReconLine."Statement No.";
        StatementLineNo := BankAccReconLine."Statement Line No.";
    end;

    /// <summary>
    /// Adds the six stable header scalars (bankAccountNo, statementNo, statementLineNo, journalTemplateName,
    /// journalBatchName, externalDocumentNo) to Request. The caller adds the 'payments' array separately, so
    /// each validation test can attach whatever (well-formed or malformed) payments shape it needs.
    /// </summary>
    local procedure AddRequestHeader(var Request: JsonObject; BankAccountNo: Code[20]; StatementNo: Code[20]; StatementLineNo: Integer; JournalTemplateName: Code[10]; JournalBatchName: Code[10]; ExternalDocumentNo: Code[35])
    begin
        Request.Add('bankAccountNo', BankAccountNo);
        Request.Add('statementNo', StatementNo);
        Request.Add('statementLineNo', StatementLineNo);
        Request.Add('journalTemplateName', JournalTemplateName);
        Request.Add('journalBatchName', JournalBatchName);
        Request.Add('externalDocumentNo', ExternalDocumentNo);
    end;

    /// <summary>
    /// Number of POSTED customer Payment ledger entries for the given customer. The customer is created
    /// fresh per test, so counting all its Payment-type Cust. Ledger Entries isolates the payment(s) this
    /// test posts: a single PostAndReconcile posts exactly one customer payment line, so a value > 1 proves
    /// a second (non-idempotent) post occurred.
    /// </summary>
    local procedure CustomerPaymentEntryCount(CustomerNo: Code[20]): Integer
    var
        CustLedgerEntry: Record "Cust. Ledger Entry";
    begin
        CustLedgerEntry.SetRange("Customer No.", CustomerNo);
        CustLedgerEntry.SetRange("Document Type", CustLedgerEntry."Document Type"::Payment);
        exit(CustLedgerEntry.Count());
    end;

    /// <summary>
    /// Creates a G/L Account that ALLOWS direct posting (required so a balancing G/L journal line can
    /// post the write-off to it) and verifies the flag actually stuck. No Gen./VAT posting groups are
    /// assigned, so a direct posting to it carries no VAT — matching the slice-6 "no VAT logic" scope.
    /// </summary>
    local procedure CreateDirectPostingGLAccount(var GLAccount: Record "G/L Account")
    begin
        LibraryERM.CreateGLAccount(GLAccount);
        GLAccount.Validate("Direct Posting", true);
        GLAccount.Modify(true);
        Assert.IsTrue(
            GLAccount."Direct Posting",
            'Arrange: the write-off G/L account must allow direct posting.');
    end;

    /// <summary>
    /// Net G/L Entry Amount booked on the given G/L account. The account is created fresh per test, so
    /// summing ALL its entries isolates the write-off posting (no Document No. filter needed). Sign
    /// convention: a positive (debit) G/L Entry Amount returns positive.
    /// </summary>
    local procedure WriteOffGLEntryAmount(GLAccountNo: Code[20]): Decimal
    var
        GLEntry: Record "G/L Entry";
    begin
        GLEntry.SetRange("G/L Account No.", GLAccountNo);
        GLEntry.CalcSums(Amount);
        exit(GLEntry.Amount);
    end;

    /// <summary>
    /// Builds a slice-6 PostAndReconcile request: ONE payments entry with ONE appliesTo entry (the full
    /// invoice X) AND ONE writeOff entry { glAccountNo, amount: W }. Mirrors the stable JSON contract
    /// documented on codeunit "MON Pmt Recon Service".
    /// </summary>
    local procedure BuildWriteOffRequest(BankAccountNo: Code[20]; StatementNo: Code[20]; StatementLineNo: Integer; JournalTemplateName: Code[10]; JournalBatchName: Code[10]; ExternalDocumentNo: Code[35]; CustomerNo: Code[20]; CustLedgerEntryNo: Integer; AppliesAmount: Decimal; WriteOffGLAccountNo: Code[20]; WriteOffAmount: Decimal): JsonObject
    var
        Request: JsonObject;
        Payment: JsonObject;
        AppliesToEntry: JsonObject;
        WriteOffEntry: JsonObject;
        Payments: JsonArray;
        AppliesTo: JsonArray;
        WriteOff: JsonArray;
    begin
        AppliesToEntry.Add('custLedgerEntryNo', CustLedgerEntryNo);
        AppliesToEntry.Add('amount', AppliesAmount);
        AppliesTo.Add(AppliesToEntry);

        WriteOffEntry.Add('glAccountNo', WriteOffGLAccountNo);
        WriteOffEntry.Add('amount', WriteOffAmount);
        WriteOff.Add(WriteOffEntry);

        Payment.Add('customerNo', CustomerNo);
        Payment.Add('appliesTo', AppliesTo);
        Payment.Add('writeOff', WriteOff);
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
