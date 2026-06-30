codeunit 50200 "MON Pmt Recon Post"
{
    Access = Public;

    var
        PaymentAmountErr: Label 'The payment amount must be greater than zero.';

    /// <summary>
    /// Posts an incoming customer payment that balances to a Bank Account — creating a Bank
    /// Account Ledger Entry, which the standard customerPayments API cannot do — applied to
    /// the given open customer ledger entry, and returns the resulting Bank Account Ledger
    /// Entry No. The entry is left open so it can subsequently be reconciled.
    /// </summary>
    procedure PostCustomerPaymentToBank(CustomerNo: Code[20]; BankAccountNo: Code[20]; PaymentAmount: Decimal; AppliesToCustLedgerEntryNo: Integer; GenJnlTemplateName: Code[10]; GenJnlBatchName: Code[10]; ExternalDocumentNo: Code[35]): Integer
    var
        GenJournalTemplate: Record "Gen. Journal Template";
        GenJournalBatch: Record "Gen. Journal Batch";
        GenJournalLine: Record "Gen. Journal Line";
        BankAccountLedgerEntry: Record "Bank Account Ledger Entry";
        GenJnlPostLine: Codeunit "Gen. Jnl.-Post Line";
        DocumentNo: Code[20];
        AppliesToID: Code[50];
    begin
        ValidateRequest(CustomerNo, BankAccountNo, PaymentAmount, AppliesToCustLedgerEntryNo, GenJnlTemplateName, GenJnlBatchName);

        GenJournalTemplate.Get(GenJnlTemplateName);
        GenJournalBatch.Get(GenJnlTemplateName, GenJnlBatchName);

        DocumentNo := DetermineDocumentNo(GenJournalBatch, AppliesToCustLedgerEntryNo);
        AppliesToID := DocumentNo;

        // Mark the target open invoice for application. SetApplId stamps the "Applies-to ID"
        // and, because "Amount to Apply" is 0 and no applying entry is supplied, sets
        // "Amount to Apply" to the entry's full remaining amount — so the invoice is settled
        // in full when the payment posts.
        MarkInvoiceForApplication(AppliesToCustLedgerEntryNo, AppliesToID);

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

        // Single transaction — no intermediate Commit. The orchestrator's real-container test
        // verifies the actual posting behaviour.
        GenJnlPostLine.Run(GenJournalLine);

        // The receipt landed on the bank account under the document number we posted.
        BankAccountLedgerEntry.SetRange("Bank Account No.", BankAccountNo);
        BankAccountLedgerEntry.SetRange("Document No.", DocumentNo);
        BankAccountLedgerEntry.FindLast();
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
        Customer.Get(CustomerNo);
        BankAccount.Get(BankAccountNo);
        CustLedgerEntry.Get(AppliesToCustLedgerEntryNo);
        GenJournalBatch.Get(GenJnlTemplateName, GenJnlBatchName);
        if PaymentAmount <= 0 then
            Error(PaymentAmountErr);
    end;
}
