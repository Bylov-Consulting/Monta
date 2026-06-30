codeunit 50200 "MON Pmt Recon Post"
{
    Access = Public;

    var
        PaymentAmountErr: Label 'The payment amount must be greater than zero.';
        BankEntryNotFoundErr: Label 'The payment posting did not create the expected Bank Account Ledger Entry.';
        BankEntryNotFoundDetailTxt: Label 'No Bank Account Ledger Entry was created on bank account %1 for document %2 after posting the customer payment.', Comment = '%1 = Bank Account No., %2 = Document No.';

    /// <summary>
    /// Posts an incoming customer payment that balances to a Bank Account — creating a Bank
    /// Account Ledger Entry, which the standard customerPayments API cannot do — applied to
    /// the given open customer ledger entry, and returns the resulting Bank Account Ledger
    /// Entry No. The entry is left open so it can subsequently be reconciled.
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
        GenJournalTemplate: Record "Gen. Journal Template";
        GenJournalBatch: Record "Gen. Journal Batch";
        GenJournalLine: Record "Gen. Journal Line";
        BankAccountLedgerEntry: Record "Bank Account Ledger Entry";
        GenJnlPostLine: Codeunit "Gen. Jnl.-Post Line";
        ErrInfo: ErrorInfo;
        DocumentNo: Code[20];
        AppliesToID: Code[50];
        LastBankEntryNo: Integer;
    begin
        this.ValidateRequest(CustomerNo, BankAccountNo, PaymentAmount, AppliesToCustLedgerEntryNo, GenJnlTemplateName, GenJnlBatchName);

        GenJournalTemplate.SetLoadFields("Source Code");
        GenJournalTemplate.Get(GenJnlTemplateName);
        GenJournalBatch.SetLoadFields("No. Series");
        GenJournalBatch.Get(GenJnlTemplateName, GenJnlBatchName);

        DocumentNo := this.DetermineDocumentNo(GenJournalBatch, AppliesToCustLedgerEntryNo);
        AppliesToID := DocumentNo;

        // Mark the target open invoice for application. SetApplId stamps the "Applies-to ID"
        // and, because "Amount to Apply" is 0 and no applying entry is supplied, sets
        // "Amount to Apply" to the entry's full remaining amount — so the invoice is settled
        // in full when the payment posts.
        this.MarkInvoiceForApplication(AppliesToCustLedgerEntryNo, AppliesToID);

        // Build one balanced payment line: the Customer leg carries a negative amount (a credit
        // that settles the positive invoice), balancing to the Bank Account, which yields exactly
        // ONE Bank Account Ledger Entry for the receipt — left open for later reconciliation.
        GenJournalLine.Init();
        GenJournalLine.Validate("Journal Template Name", GenJournalTemplate.Name);
        GenJournalLine.Validate("Journal Batch Name", GenJournalBatch.Name);
        GenJournalLine."Line No." := 10000;
        GenJournalLine.Validate("Posting Date", WorkDate());
        GenJournalLine.Validate("Document Type", GenJournalLine."Document Type"::Payment);
        GenJournalLine.Validate("Document No.", DocumentNo);
        GenJournalLine.Validate("Account Type", GenJournalLine."Account Type"::Customer);
        GenJournalLine.Validate("Account No.", CustomerNo);
        GenJournalLine.Validate(Amount, -PaymentAmount);
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

    local procedure MarkInvoiceForApplication(CustLedgerEntryNo: Integer; AppliesToID: Code[50])
    var
        CustLedgerEntry: Record "Cust. Ledger Entry";
        ApplyingCustLedgerEntry: Record "Cust. Ledger Entry";
        CustEntrySetApplID: Codeunit "Cust. Entry-SetAppl.ID";
    begin
        CustLedgerEntry.Get(CustLedgerEntryNo);
        CustLedgerEntry.SetRange("Entry No.", CustLedgerEntryNo);
        // ApplyingCustLedgerEntry left blank (Entry No. = 0): no partial-apply origin, so the
        // full remaining amount is marked for application.
        CustEntrySetApplID.SetApplId(CustLedgerEntry, ApplyingCustLedgerEntry, AppliesToID);
    end;

    local procedure DetermineDocumentNo(GenJournalBatch: Record "Gen. Journal Batch"; AppliesToCustLedgerEntryNo: Integer) DocumentNo: Code[20]
    var
        NoSeries: Codeunit "No. Series";
    begin
        // Respect the batch's No. Series when one is configured; otherwise assign a deterministic
        // document number derived from the (unique) applied ledger entry.
        if GenJournalBatch."No. Series" <> '' then
            exit(NoSeries.GetNextNo(GenJournalBatch."No. Series", WorkDate()));
        exit(CopyStr('MONPMT' + Format(AppliesToCustLedgerEntryNo), 1, MaxStrLen(DocumentNo)));
    end;

    local procedure ValidateRequest(CustomerNo: Code[20]; BankAccountNo: Code[20]; PaymentAmount: Decimal; AppliesToCustLedgerEntryNo: Integer; GenJnlTemplateName: Code[10]; GenJnlBatchName: Code[10])
    var
        Customer: Record Customer;
        BankAccount: Record "Bank Account";
        CustLedgerEntry: Record "Cust. Ledger Entry";
        GenJournalBatch: Record "Gen. Journal Batch";
    begin
        // Cheap guard first — short-circuit before any database round-trip.
        if PaymentAmount <= 0 then
            Error(PaymentAmountErr);
        Customer.SetLoadFields("No.");
        Customer.Get(CustomerNo);
        BankAccount.SetLoadFields("No.");
        BankAccount.Get(BankAccountNo);
        CustLedgerEntry.SetLoadFields("Entry No.");
        CustLedgerEntry.Get(AppliesToCustLedgerEntryNo);
        GenJournalBatch.Get(GenJnlTemplateName, GenJnlBatchName);
    end;
}
