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

    [Test]
    procedure MatchWrongBankEntry_IsRejected()
    var
        BankAccountA: Record "Bank Account";
        BankAccountB: Record "Bank Account";
        BankAccReconciliation: Record "Bank Acc. Reconciliation";
        BankAccReconLine: Record "Bank Acc. Reconciliation Line";
        PmtReconMatch: Codeunit "MON Pmt Recon Match";
        BankEntryOnA: Integer;
        StatementAmount: Decimal;
    begin
        // [SCENARIO] An OPEN bank ledger entry that belongs to bank account A must NOT be matchable to a
        // reconciliation line on a DIFFERENT bank account B. The match must be rejected by a guard that
        // names the offending entry and the bank account it was asked to reconcile against, so a caller
        // can never silently mis-stamp one bank's receipt onto another bank's statement.

        // [GIVEN] Bank account A carrying exactly one open receipt (slice 1) for a known amount.
        LibraryERM.CreateBankAccount(BankAccountA);
        BankEntryOnA := CreateOpenBankReceiptOn(BankAccountA, StatementAmount);

        // [GIVEN] A standard Bank Acc. Reconciliation + line on a DIFFERENT bank account B, sized to A's
        // receipt so only the bank-account mismatch — not the amount — can cause a rejection.
        LibraryERM.CreateBankAccount(BankAccountB);
        LibraryERM.CreateBankAccReconciliation(
            BankAccReconciliation, BankAccountB."No.",
            BankAccReconciliation."Statement Type"::"Bank Reconciliation");
        LibraryERM.CreateBankAccReconciliationLn(BankAccReconLine, BankAccReconciliation);
        BankAccReconLine.Validate("Statement Amount", StatementAmount);
        BankAccReconLine.Difference := StatementAmount; // unmatched: nothing applied yet
        BankAccReconLine.Modify(true);

        // [WHEN] Matching bank A's entry against bank B's reconciliation line.
        asserterror PmtReconMatch.MatchBankEntryToReconLine(
            BankAccountB."No.", BankAccReconLine."Statement No.", BankAccReconLine."Statement Line No.", BankEntryOnA);

        // [THEN] The match is rejected because the entry does not belong to the supplied bank account.
        // RED: no such guard exists yet — standard ApplyEntries either mis-stamps silently (no error ->
        // asserterror fails) or throws an unrelated error -> the specific substring is absent -> fails.
        Assert.ExpectedError('does not belong to bank account');
    end;

    [Test]
    procedure MatchClosedBankEntry_IsRejected()
    var
        BankAccount: Record "Bank Account";
        BankAccReconciliation: Record "Bank Acc. Reconciliation";
        BankAccReconLine: Record "Bank Acc. Reconciliation Line";
        SecondBankAccReconciliation: Record "Bank Acc. Reconciliation";
        SecondBankAccReconLine: Record "Bank Acc. Reconciliation Line";
        BankAccLedgerEntry: Record "Bank Account Ledger Entry";
        BankAccReconPost: Codeunit "Bank Acc. Reconciliation Post";
        PmtReconMatch: Codeunit "MON Pmt Recon Match";
        BankEntryNo: Integer;
        StatementAmount: Decimal;
    begin
        // [SCENARIO] Once a bank ledger entry has been reconciled and the statement POSTED, the entry is
        // closed (Open = false, Statement Status = Closed). A closed entry must NOT be matchable again —
        // re-matching would corrupt an already-settled entry. The match must be rejected by a guard that
        // reports the entry is not open.

        // [GIVEN] A bank account carrying exactly one open receipt (slice 1) for a known amount.
        LibraryERM.CreateBankAccount(BankAccount);
        BankEntryNo := CreateOpenBankReceiptOn(BankAccount, StatementAmount);

        // [GIVEN] A balanced Bank Acc. Reconciliation whose single line is matched to that receipt...
        LibraryERM.CreateBankAccReconciliation(
            BankAccReconciliation, BankAccount."No.",
            BankAccReconciliation."Statement Type"::"Bank Reconciliation");
        LibraryERM.CreateBankAccReconciliationLn(BankAccReconLine, BankAccReconciliation);
        BankAccReconLine.Validate("Statement Amount", StatementAmount);
        BankAccReconLine.Difference := StatementAmount; // unmatched: nothing applied yet
        BankAccReconLine.Modify(true);
        // ...matched via slice 2 (known-green) so the line is fully applied (Difference returns to 0)...
        PmtReconMatch.MatchBankEntryToReconLine(
            BankAccount."No.", BankAccReconLine."Statement No.", BankAccReconLine."Statement Line No.", BankEntryNo);
        // ...and POSTED via standard codeunit 370. A fresh bank account has Balance Last Statement = 0, so
        // Statement Ending Balance must equal the single line's Statement Amount for the statement to
        // balance (CheckLinesMatchEndingBalance). Posting then closes the matched bank ledger entry.
        BankAccReconciliation.Get(
            BankAccReconciliation."Statement Type"::"Bank Reconciliation", BankAccount."No.",
            BankAccReconciliation."Statement No.");
        BankAccReconciliation.Validate("Statement Date", WorkDate());
        BankAccReconciliation.Validate("Statement Ending Balance", StatementAmount);
        BankAccReconciliation.Modify(true);
        BankAccReconPost.Run(BankAccReconciliation);

        // [GIVEN] Confirm the receipt is now genuinely closed — the precondition for the guard under test.
        BankAccLedgerEntry.Get(BankEntryNo);
        Assert.IsFalse(
            BankAccLedgerEntry.Open,
            'Precondition: posting the statement must have closed the bank ledger entry.');

        // [GIVEN] A fresh Bank Acc. Reconciliation + line on the SAME bank account to re-match against
        // (the first reconciliation is deleted by posting), sized to the entry amount.
        LibraryERM.CreateBankAccReconciliation(
            SecondBankAccReconciliation, BankAccount."No.",
            SecondBankAccReconciliation."Statement Type"::"Bank Reconciliation");
        LibraryERM.CreateBankAccReconciliationLn(SecondBankAccReconLine, SecondBankAccReconciliation);
        SecondBankAccReconLine.Validate("Statement Amount", StatementAmount);
        SecondBankAccReconLine.Difference := StatementAmount; // unmatched: nothing applied yet
        SecondBankAccReconLine.Modify(true);

        // [WHEN] Attempting to match the now-CLOSED bank ledger entry again.
        asserterror PmtReconMatch.MatchBankEntryToReconLine(
            BankAccount."No.", SecondBankAccReconLine."Statement No.", SecondBankAccReconLine."Statement Line No.", BankEntryNo);

        // [THEN] The match is rejected because the entry is not open.
        // RED: no open-guard exists yet — standard apply either silently re-stamps the closed entry (no
        // error -> asserterror fails) or throws an unrelated error -> the specific substring is absent.
        Assert.ExpectedError('is not open and cannot be matched');
    end;

    /// <summary>
    /// Arranges exactly one OPEN Bank Account Ledger Entry on <paramref name="BankAccount"/> by posting a
    /// customer payment (slice 1) that fully settles a fresh posted sales invoice. Mirrors the slice-2
    /// happy-path arrange. Returns the new bank ledger Entry No. and outputs the signed receipt amount
    /// (the value to use as the reconciliation line's Statement Amount).
    /// </summary>
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
        LibraryERM.CreateGenJournalBatch(GenJournalBatch, GenJournalTemplate.Name);
        BankEntryNo := PmtReconPost.PostCustomerPaymentToBank(
            Customer."No.", BankAccount."No.", CustLedgerEntry."Remaining Amount", CustLedgerEntry."Entry No.",
            GenJournalTemplate.Name, GenJournalBatch.Name,
            CopyStr('MON-' + Format(LibraryRandom.RandIntInRange(100000, 999999)), 1, 35));
        BankAccLedgerEntry.Get(BankEntryNo);
        StatementAmount := BankAccLedgerEntry.Amount; // signed receipt amount carried by the bank entry
        exit(BankEntryNo);
    end;
}
