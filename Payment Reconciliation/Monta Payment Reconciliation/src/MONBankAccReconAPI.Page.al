page 50206 "MON Bank Acc Recon API"
{
    PageType = API;
    Caption = 'Bank Account Reconciliations';
    APIPublisher = 'monta';
    APIGroup = 'paymentReconciliation';
    APIVersion = 'v1.0';
    EntityName = 'bankAccReconciliation';
    EntitySetName = 'bankAccReconciliations';
    EntityCaption = 'Bank Account Reconciliation';
    EntitySetCaption = 'Bank Account Reconciliations';
    SourceTable = "Bank Acc. Reconciliation";
    ODataKeyFields = SystemId;
    Editable = false;
    InsertAllowed = false;
    ModifyAllowed = false;
    DeleteAllowed = false;
    Extensible = false;
    DataAccessIntent = ReadOnly;

    // The agent reads the bank-reconciliation HEADERS to discover the open statements it can act on, then
    // drills into the line API (and posts the postAndReconcile bound action). Scope is the ONLY filter:
    // Statement Type = Bank Reconciliation excludes Payment Application reconciliations; no status filter.
    SourceTableView = where("Statement Type" = const("Bank Reconciliation"));

    layout
    {
        area(Content)
        {
            repeater(Group)
            {
                field(id; Rec.SystemId)
                {
                    Caption = 'id';
                    Editable = false;
                }
                field(lastModifiedDateTime; Rec.SystemModifiedAt)
                {
                    Caption = 'Last Modified Date Time';
                    Editable = false;
                }
                // --- Header identity ---
                field(statementType; Rec."Statement Type")
                {
                    Caption = 'Statement Type';
                }
                field(bankAccountNo; Rec."Bank Account No.")
                {
                    Caption = 'Bank Account No.';
                }
                field(statementNo; Rec."Statement No.")
                {
                    Caption = 'Statement No.';
                }
                // --- Statement figures (read-only) ---
                field(statementDate; Rec."Statement Date")
                {
                    Caption = 'Statement Date';
                }
                field(statementEndingBalance; Rec."Statement Ending Balance")
                {
                    Caption = 'Statement Ending Balance';
                }
                field(balanceLastStatement; Rec."Balance Last Statement")
                {
                    Caption = 'Balance Last Statement';
                }
                // FlowField — calculated read-only on each read; gives the agent the bank's running balance.
                field(totalBalanceOnBankAccount; Rec."Total Balance on Bank Account")
                {
                    Caption = 'Total Balance on Bank Account';
                }
            }
        }
    }

    trigger OnOpenPage()
    begin
        // Serve only committed data — the agent makes financial decisions on this read, so it must
        // never see rows from a concurrent bank-reconciliation transaction that could later roll back.
        Rec.ReadIsolation := IsolationLevel::ReadCommitted;
    end;
}
