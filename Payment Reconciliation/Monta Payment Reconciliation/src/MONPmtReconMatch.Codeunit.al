codeunit 50201 "MON Pmt Recon Match"
{
    Access = Public;

    /// <summary>
    /// Matches an OPEN Bank Account Ledger Entry (e.g. the receipt produced by
    /// <see cref="MON Pmt Recon Post.PostCustomerPaymentToBank"/>) to a standard Bank Acc.
    /// Reconciliation Line, recording the link the way standard BC does via the
    /// "Bank Acc. Entry Set Recon.-No." mechanism. After a successful match the reconciliation
    /// line shows the payment as applied (Applied Entries incremented, Applied Amount raised,
    /// Difference reduced toward zero) and the bank ledger entry carries the statement link with
    /// Statement Status = "Bank Acc. Entry Applied", while remaining Open until the statement is
    /// posted. Standard tables only (273/274/271) — no Continia.
    /// </summary>
    /// <param name="BankAccountNo">Bank account both the reconciliation and the ledger entry belong to.</param>
    /// <param name="StatementNo">Statement No. of the Bank Acc. Reconciliation (Statement Type = Bank Reconciliation).</param>
    /// <param name="StatementLineNo">Statement Line No. of the reconciliation line to apply the entry to.</param>
    /// <param name="BankAccountLedgerEntryNo">Entry No. of the open Bank Account Ledger Entry to match.</param>
    procedure MatchBankEntryToReconLine(BankAccountNo: Code[20]; StatementNo: Code[20]; StatementLineNo: Integer; BankAccountLedgerEntryNo: Integer)
    begin
        // RED stub: intentionally records NO match — leaves the reconciliation line and the bank
        // ledger entry unchanged so the slice-2 test fails. The GREEN phase wires this to
        // Codeunit "Bank Acc. Entry Set Recon.-No.".ApplyEntries(BankAccReconLine, BankAccLedgEntry, Relation::OneToOne).
    end;
}
