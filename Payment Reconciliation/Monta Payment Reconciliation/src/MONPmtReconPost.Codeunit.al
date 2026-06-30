codeunit 50200 "MON Pmt Recon Post"
{
    Access = Public;

    var
        PaymentAmountErr: Label 'The payment amount must be greater than zero.';
        NoAppliesEntriesErr: Label 'At least one customer ledger entry must be supplied for the payment.';
        BankEntryNotFoundErr: Label 'The payment posting did not create the expected Bank Account Ledger Entry.';
        BankEntryNotFoundDetailTxt: Label 'No Bank Account Ledger Entry was created on bank account %1 for document %2 after posting the customer payment.', Comment = '%1 = Bank Account No., %2 = Document No.';
        ClosedEntryErr: Label 'Customer ledger entry %1 is closed and cannot be settled by this payment.', Comment = '%1 = Cust. Ledger Entry No.';
        CustomerMismatchErr: Label 'Customer ledger entry %1 does not belong to customer %2.', Comment = '%1 = Cust. Ledger Entry No., %2 = Customer No.';

    /// <summary>
    /// Posts an incoming customer payment that balances to a Bank Account — creating a Bank
    /// Account Ledger Entry, which the standard customerPayments API cannot do — applied to
    /// the given open customer ledger entry, and returns the resulting Bank Account Ledger
    /// Entry No. The entry is left open so it can subsequently be reconciled.
    ///
    /// Single-invoice convenience overload: delegates to <see cref="PostCustomerPaymentToBankMulti"/>
    /// with exactly one (entry, amount) pair, so there is ONE posting implementation.
    /// </summary>
    /// <param name="CustomerNo">The customer whose payment is being posted.</param>
    /// <param name="BankAccountNo">The bank account the payment is received into; the balancing entry is posted here.</param>
    /// <param name="PaymentAmount">The received amount; must be greater than zero.</param>
    /// <param name="AppliesToCustLedgerEntryNo">Entry No. of the open customer ledger entry (invoice) the payment settles in full.</param>
    /// <param name="GenJnlTemplateName">General journal template used to post the payment.</param>
    /// <param name="GenJnlBatchName">General journal batch (within the template) used to post the payment.</param>
    /// <param name="ExternalDocumentNo">Optional external document reference stamped on the payment line.</param>
    /// <returns>The Entry No. of the Bank Account Ledger Entry created by the posting (left open for reconciliation).</returns>
    procedure PostCustomerPaymentToBank(CustomerNo: Code[20]; BankAccountNo: Code[20]; PaymentAmount: Decimal; AppliesToCustLedgerEntryNo: Integer; GenJnlTemplateName: Code[10]; GenJnlBatchName: Code[10]; ExternalDocumentNo: Code[35]): Integer
    var
        AppliesToEntries: Dictionary of [Integer, Decimal];
    begin
        // One posting path: wrap the single application as a one-element set and delegate.
        AppliesToEntries.Add(AppliesToCustLedgerEntryNo, PaymentAmount);
        exit(
            this.PostCustomerPaymentToBankMulti(
                CustomerNo, BankAccountNo, AppliesToEntries,
                GenJnlTemplateName, GenJnlBatchName, ExternalDocumentNo));
    end;

    /// <summary>
    /// Posts ONE incoming customer payment that settles MULTIPLE open customer ledger entries
    /// (invoices) of the SAME customer in a single balanced posting. Every target entry is stamped
    /// with the SAME Applies-to ID and its own "Amount to Apply", and exactly ONE Gen. Journal line
    /// for the TOTAL is posted (Account Type = Customer, Amount = -Total; Bal. Account Type = Bank
    /// Account), yielding exactly ONE Bank Account Ledger Entry for the whole receipt. The entry is
    /// left open so it can subsequently be reconciled (1:1 with the statement line for the total).
    /// </summary>
    /// <param name="CustomerNo">The customer whose payment is being posted.</param>
    /// <param name="BankAccountNo">The bank account the payment is received into; the balancing entry is posted here.</param>
    /// <param name="AppliesToEntries">Map of open Cust. Ledger Entry No. -> the amount (> 0) to apply to it. Each entry must belong to CustomerNo and be open.</param>
    /// <param name="GenJnlTemplateName">General journal template used to post the payment.</param>
    /// <param name="GenJnlBatchName">General journal batch (within the template) used to post the payment.</param>
    /// <param name="ExternalDocumentNo">Optional external document reference stamped on the payment line.</param>
    /// <returns>The Entry No. of the single Bank Account Ledger Entry created by the posting (left open for reconciliation).</returns>
    [CommitBehavior(CommitBehavior::Ignore)]
    procedure PostCustomerPaymentToBankMulti(CustomerNo: Code[20]; BankAccountNo: Code[20]; AppliesToEntries: Dictionary of [Integer, Decimal]; GenJnlTemplateName: Code[10]; GenJnlBatchName: Code[10]; ExternalDocumentNo: Code[35]): Integer
    var
        GenJournalTemplate: Record "Gen. Journal Template";
        GenJournalBatch: Record "Gen. Journal Batch";
        GenJournalLine: Record "Gen. Journal Line";
        BankAccountLedgerEntry: Record "Bank Account Ledger Entry";
        GenJnlPostLine: Codeunit "Gen. Jnl.-Post Line";
        ErrInfo: ErrorInfo;
        EntryNos: List of [Integer];
        EntryNo: Integer;
        TotalAmount: Decimal;
        DocumentNo: Code[20];
        AppliesToID: Code[50];
        LastBankEntryNo: Integer;
    begin
        this.ValidateRequest(CustomerNo, BankAccountNo, AppliesToEntries, GenJnlTemplateName, GenJnlBatchName);

        EntryNos := AppliesToEntries.Keys;
        TotalAmount := this.SumAmounts(AppliesToEntries);

        GenJournalTemplate.SetLoadFields("Source Code");
        GenJournalTemplate.Get(GenJnlTemplateName);
        GenJournalBatch.SetLoadFields("No. Series");
        GenJournalBatch.Get(GenJnlTemplateName, GenJnlBatchName);

        // One shared Applies-to ID groups every target invoice under this single receipt.
        DocumentNo := this.DetermineDocumentNo(GenJournalBatch, EntryNos.Get(1));
        AppliesToID := DocumentNo;

        // Mark EVERY target open invoice for application under the SAME Applies-to ID, each with its
        // own supplied "Amount to Apply" — so the one payment line settles them all together.
        foreach EntryNo in EntryNos do
            this.MarkInvoiceForApplication(EntryNo, AppliesToEntries.Get(EntryNo), AppliesToID);

        // Build one balanced payment line: the Customer leg carries the negative total (a credit that
        // settles the positive invoices), balancing to the Bank Account, which yields exactly ONE
        // Bank Account Ledger Entry for the whole receipt — left open for later reconciliation.
        GenJournalLine.Init();
        GenJournalLine.Validate("Journal Template Name", GenJournalTemplate.Name);
        GenJournalLine.Validate("Journal Batch Name", GenJournalBatch.Name);
        GenJournalLine."Line No." := 10000;
        GenJournalLine.Validate("Posting Date", WorkDate());
        GenJournalLine.Validate("Document Type", GenJournalLine."Document Type"::Payment);
        GenJournalLine.Validate("Document No.", DocumentNo);
        GenJournalLine.Validate("Account Type", GenJournalLine."Account Type"::Customer);
        GenJournalLine.Validate("Account No.", CustomerNo);
        GenJournalLine.Validate(Amount, -TotalAmount);
        GenJournalLine.Validate("Bal. Account Type", GenJournalLine."Bal. Account Type"::"Bank Account");
        GenJournalLine.Validate("Bal. Account No.", BankAccountNo);
        if ExternalDocumentNo <> '' then
            GenJournalLine.Validate("External Document No.", ExternalDocumentNo);
        GenJournalLine."Source Code" := GenJournalTemplate."Source Code";
        GenJournalLine."Applies-to ID" := AppliesToID;

        // Snapshot the latest existing bank ledger entry so the entry created by this posting
        // can be identified by Entry No. — robust against any Document No. reuse across earlier
        // committed entries (a Document No. filter is not collision-proof).
        BankAccountLedgerEntry.SetRange("Bank Account No.", BankAccountNo);
        BankAccountLedgerEntry.SetLoadFields("Entry No.");
        if BankAccountLedgerEntry.FindLast() then
            LastBankEntryNo := BankAccountLedgerEntry."Entry No.";

        // Single transaction — no intermediate Commit. The orchestrator's real-container test
        // verifies the actual posting behaviour.
        GenJnlPostLine.Run(GenJournalLine);

        // The receipt is the new entry on this bank account beyond the pre-post snapshot.
        BankAccountLedgerEntry.Reset();
        BankAccountLedgerEntry.SetRange("Bank Account No.", BankAccountNo);
        BankAccountLedgerEntry.SetFilter("Entry No.", '>%1', LastBankEntryNo);
        BankAccountLedgerEntry.SetLoadFields("Entry No.");
        if not BankAccountLedgerEntry.FindFirst() then begin
            // Impossible-invariant: posting succeeded but produced no bank entry. Not user-
            // recoverable — classify Internal so the platform shows a generic dialog and the
            // detail goes to telemetry.
            ErrInfo := ErrorInfo.Create(BankEntryNotFoundErr);
            ErrInfo.ErrorType := ErrorType::Internal;
            ErrInfo.DetailedMessage := StrSubstNo(BankEntryNotFoundDetailTxt, BankAccountNo, DocumentNo);
            Error(ErrInfo);
        end;
        exit(BankAccountLedgerEntry."Entry No.");
    end;

    local procedure MarkInvoiceForApplication(CustLedgerEntryNo: Integer; AmountToApply: Decimal; AppliesToID: Code[50])
    var
        CustLedgerEntry: Record "Cust. Ledger Entry";
        ApplyingCustLedgerEntry: Record "Cust. Ledger Entry";
        CustEntrySetApplID: Codeunit "Cust. Entry-SetAppl.ID";
        CustEntryEdit: Codeunit "Cust. Entry-Edit";
    begin
        // Stamp the shared Applies-to ID on this entry via the standard mechanism. ApplyingCustLedgerEntry
        // is left blank (Entry No. = 0): no partial-apply origin, so SetApplId also defaults "Amount to
        // Apply" to the full remaining amount.
        CustLedgerEntry.Get(CustLedgerEntryNo);
        CustLedgerEntry.SetRecFilter();
        CustEntrySetApplID.SetApplId(CustLedgerEntry, ApplyingCustLedgerEntry, AppliesToID);

        // Persist the EXACT supplied "Amount to Apply" for this entry the standard way (codeunit 103),
        // so multi/partial applies settle the precise amount, not just the full remaining. Re-Get to
        // carry the Applies-to ID SetApplId just stamped (Cust. Entry-Edit re-writes "Applies-to ID"
        // from Rec); only "Amount to Apply" actually changes.
        CustLedgerEntry.Get(CustLedgerEntryNo);
        CustLedgerEntry.Validate("Amount to Apply", AmountToApply);
        CustEntryEdit.Run(CustLedgerEntry);
    end;

    local procedure DetermineDocumentNo(GenJournalBatch: Record "Gen. Journal Batch"; SeedCustLedgerEntryNo: Integer) DocumentNo: Code[20]
    var
        NoSeries: Codeunit "No. Series";
    begin
        // Respect the batch's No. Series when one is configured; otherwise assign a deterministic
        // document number derived from a representative applied ledger entry.
        if GenJournalBatch."No. Series" <> '' then
            exit(NoSeries.GetNextNo(GenJournalBatch."No. Series", WorkDate()));
        exit(CopyStr('MONPMT' + Format(SeedCustLedgerEntryNo), 1, MaxStrLen(DocumentNo)));
    end;

    local procedure SumAmounts(AppliesToEntries: Dictionary of [Integer, Decimal]) Total: Decimal
    var
        AmountValue: Decimal;
    begin
        foreach AmountValue in AppliesToEntries.Values do
            Total += AmountValue;
    end;

    local procedure ValidateRequest(CustomerNo: Code[20]; BankAccountNo: Code[20]; AppliesToEntries: Dictionary of [Integer, Decimal]; GenJnlTemplateName: Code[10]; GenJnlBatchName: Code[10])
    var
        Customer: Record Customer;
        BankAccount: Record "Bank Account";
        CustLedgerEntry: Record "Cust. Ledger Entry";
        GenJournalBatch: Record "Gen. Journal Batch";
        EntryNo: Integer;
    begin
        // Cheap guards first — short-circuit before any database round-trip.
        if AppliesToEntries.Count = 0 then
            Error(NoAppliesEntriesErr);
        foreach EntryNo in AppliesToEntries.Keys do
            if AppliesToEntries.Get(EntryNo) <= 0 then
                Error(PaymentAmountErr);

        Customer.SetLoadFields("No.");
        Customer.Get(CustomerNo);
        BankAccount.SetLoadFields("No.");
        BankAccount.Get(BankAccountNo);
        GenJournalBatch.SetLoadFields("Name");
        GenJournalBatch.Get(GenJnlTemplateName, GenJnlBatchName);

        // The customer-owns-entry and entry-open guards apply to EVERY target entry.
        foreach EntryNo in AppliesToEntries.Keys do begin
            CustLedgerEntry.SetLoadFields("Customer No.", Open);
            CustLedgerEntry.Get(EntryNo);
            if CustLedgerEntry."Customer No." <> CustomerNo then
                Error(CustomerMismatchErr, EntryNo, CustomerNo);
            if not CustLedgerEntry.Open then
                Error(ClosedEntryErr, EntryNo);
        end;
    end;
}
