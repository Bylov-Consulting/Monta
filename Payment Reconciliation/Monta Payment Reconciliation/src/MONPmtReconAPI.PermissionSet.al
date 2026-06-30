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
        // --- This app's data ---
        tabledata "MON Pmt Recon Log" = RIM,
        tabledata "MON Pmt Recon Apply Buf" = RIMD,
        // --- Standard tabledata the operations read/write ---
        tabledata "Gen. Journal Line" = RIMD,
        tabledata "Cust. Ledger Entry" = RIMD,
        tabledata "Bank Account Ledger Entry" = RIMD,
        tabledata "Bank Acc. Reconciliation" = RIMD,
        tabledata "Bank Acc. Reconciliation Line" = RIMD,
        tabledata "G/L Entry" = RIM;
}
