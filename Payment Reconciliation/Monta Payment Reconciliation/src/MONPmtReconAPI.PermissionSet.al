permissionset 50207 "MON Pmt Recon API"
{
    // S2S OAuth surface for the Monta agent. Monta owns the Entra app registration; this app only ships
    // the permission set, which the customer's admin assigns to the service-to-service application.
    // It grants execute on this app's objects + the standard tabledata the post/match/read operations
    // touch DIRECTLY. NOTE: a full payment posting also writes many standard ledger/register tables
    // through the base posting engine (Gen. Jnl.-Post Line and its callees). Enumerating every one of
    // those in a PTE permission set is fragile, so the Monta service account is expected to ALSO hold a
    // standard posting permission set (e.g. D365 BUS FULL ACCESS); completeness is a smoke-test item.
    Assignable = true;
    Caption = 'MON Payment Reconciliation API';

    Permissions =
        // --- This app's execution surface ---
        codeunit "MON Pmt Recon Post" = X,
        codeunit "MON Pmt Recon Match" = X,
        codeunit "MON Pmt Recon Service" = X,
        page "MON Bank Recon Line API" = X,
        page "MON Bank Acc Recon API" = X,
        // --- This app's data --- (the apply buffer is TableType=Temporary -> no tabledata grant needed)
        tabledata "MON Pmt Recon Log" = RIM,
        // --- Standard tabledata the operations touch. NOTE: permission completeness is only verifiable in
        // the real-sandbox smoke test; the S2S account is also expected to hold a standard posting set. ---
        // The app builds/validates an IN-MEMORY Gen. Journal Line and posts it via Gen. Jnl.-Post Line; it
        // does not insert or delete journal rows itself, so no Delete is needed.
        tabledata "Gen. Journal Line" = RIM,
        // Cust. Ledger Entry / Bank Account Ledger Entry are only READ directly here (Get/SetRange); their
        // modifications run through the standard code-mediated codeunits (Cust. Entry-Edit, codeunit 375),
        // so insert/modify are INDIRECT (lowercase) — least privilege on the S2S surface.
        tabledata "Cust. Ledger Entry" = Rim,
        tabledata "Bank Account Ledger Entry" = Rim,
        // Bank Acc. Reconciliation Line is modified DIRECTLY (Modify(true) to fire OnModify), so direct M.
        tabledata "Bank Acc. Reconciliation" = RIM,
        tabledata "Bank Acc. Reconciliation Line" = RIM,
        // G/L Entry is reached only THROUGH the base posting engine (which holds InherentPermissions on it),
        // never directly by this app -> indirect (lowercase) keeps the S2S surface minimal.
        tabledata "G/L Entry" = rim;
}
