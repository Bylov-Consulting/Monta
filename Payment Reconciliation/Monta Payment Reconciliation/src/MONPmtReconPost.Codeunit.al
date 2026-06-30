codeunit 50200 "MON Pmt Recon Post"
{
    Access = Public;

    var
        NotImplementedErr: Label 'Posting the customer payment to the bank account is not yet implemented.';
        PaymentAmountErr: Label 'The payment amount must be greater than zero.';

    /// <summary>
    /// Posts an incoming customer payment that balances to a Bank Account — creating a Bank
    /// Account Ledger Entry, which the standard customerPayments API cannot do — applied to
    /// the given open customer ledger entry, and returns the resulting Bank Account Ledger
    /// Entry No. The entry is left open so it can subsequently be reconciled.
    /// </summary>
    procedure PostCustomerPaymentToBank(CustomerNo: Code[20]; BankAccountNo: Code[20]; PaymentAmount: Decimal; AppliesToCustLedgerEntryNo: Integer; GenJnlTemplateName: Code[10]; GenJnlBatchName: Code[10]; ExternalDocumentNo: Code[35]): Integer
    begin
        ValidateRequest(CustomerNo, BankAccountNo, PaymentAmount, AppliesToCustLedgerEntryNo, GenJnlTemplateName, GenJnlBatchName);

        // GREEN slice: build a balanced general journal — one customer payment line
        // (Account Type = Customer, applied to AppliesToCustLedgerEntryNo via Applies-to ID)
        // and one bank balancing line (Bal. Account Type = Bank Account) — post it through
        // Gen. Jnl.-Post Line in a single transaction (no intermediate Commit), then locate
        // and return the No. of the resulting Bank Account Ledger Entry.
        Error(NotImplementedErr);
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
