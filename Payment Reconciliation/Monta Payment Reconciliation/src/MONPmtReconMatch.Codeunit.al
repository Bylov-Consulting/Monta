codeunit 50201 "MON Pmt Recon Match"
{
    Access = Public;

    var
        WrongBankErr: Label 'Bank account ledger entry %1 does not belong to bank account %2.', Comment = '%1 = Bank Account Ledger Entry No., %2 = Bank Account No.';
        NotOpenErr: Label 'Bank account ledger entry %1 is not open and cannot be matched.', Comment = '%1 = Bank Account Ledger Entry No.';
        AlreadyAppliedErr: Label 'Reconciliation line %1/%2 already has applied entries and cannot be matched again.', Comment = '%1 = Statement No., %2 = Statement Line No.';

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
    var
        BankAccReconLine: Record "Bank Acc. Reconciliation Line";
        BankAccLedgEntry: Record "Bank Account Ledger Entry";
        BankAccEntrySetReconNo: Codeunit "Bank Acc. Entry Set Recon.-No.";
        Relation: Option "One-to-One","One-to-Many","Many-to-One";
    begin
        // Load the standard reconciliation line (table 274, PK = Statement Type, Bank Account No.,
        // Statement No., Statement Line No.) and the open bank ledger entry (table 271) by their IDs.
        BankAccReconLine.Get(
            BankAccReconLine."Statement Type"::"Bank Reconciliation",
            BankAccountNo, StatementNo, StatementLineNo);
        BankAccLedgEntry.Get(BankAccountLedgerEntryNo);

        // Guard: the ledger entry must belong to the supplied bank account (codeunit 375 does not
        // cross-check, so a wrong entry would silently stamp a cross-account statement link) and
        // must still be open (matching a closed entry would overwrite a prior statement's link).
        if BankAccLedgEntry."Bank Account No." <> BankAccountNo then
            Error(WrongBankErr, BankAccountLedgerEntryNo, BankAccountNo);
        if not BankAccLedgEntry.Open then
            Error(NotOpenErr, BankAccountLedgerEntryNo);
        // Guard against double-application: the idempotency log only tracks API-originated calls, so a line
        // already matched by ANOTHER source (a manual UI match, or a repaired/missing log row) would otherwise
        // have ApplyEntries run a second time, doubling Applied Entries/Amount. Refuse a line already matched.
        if BankAccReconLine."Applied Entries" > 0 then
            Error(AlreadyAppliedErr, StatementNo, StatementLineNo);

        // Standard one-entry <-> one-line match. Public codeunit 375 "Bank Acc. Entry Set Recon.-No."
        // does exactly what the standard Apply action does: SetReconNo stamps the ledger entry's
        // Statement No./Line No. and sets Statement Status = "Bank Acc. Entry Applied" (the entry
        // stays Open), then the line's Applied Amount/Applied Entries are raised and Statement Amount
        // is re-validated so Difference returns to zero. The Relation Option mirrors the base-app
        // caller codeunit 1252 "Match Bank Rec. Lines", which declares the same local Option and
        // passes "One-to-One" for a single entry matched to a single line.
        BankAccEntrySetReconNo.ApplyEntries(BankAccReconLine, BankAccLedgEntry, Relation::"One-to-One");

        // Continia Statement Intelligence guard — PROD-ONLY, intentionally NOT covered by the
        // standard-BC container test (no Continia in the container). Codeunit 375 persists the line
        // via Modify(false), which does NOT fire table 274's OnModify trigger. In production this app
        // runs alongside Continia, whose table-extension OnModify subscriber repaints a derived
        // "CPM Status" field, so we must make the line's OnModify fire. We re-Get the line exactly as
        // the standard apply committed it and Modify(true): because Get sets xRec = Rec, the
        // "Statement Amount" is unchanged between xRec and Rec, so table 274's OnModify
        // ("if xRec.\"Statement Amount\" <> \"Statement Amount\" then RemoveApplication") does NOT undo
        // the match — every standard field the test asserts is preserved while the trigger still runs.
        BankAccReconLine.Get(
            BankAccReconLine."Statement Type"::"Bank Reconciliation",
            BankAccountNo, StatementNo, StatementLineNo);
        BankAccReconLine.Modify(true);
    end;
}
