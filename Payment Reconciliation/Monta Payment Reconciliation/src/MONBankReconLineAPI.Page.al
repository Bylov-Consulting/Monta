page 50205 "MON Bank Recon Line API"
{
    PageType = API;
    Caption = 'Bank Reconciliation Lines';
    APIPublisher = 'monta';
    APIGroup = 'paymentReconciliation';
    APIVersion = 'v1.0';
    EntityName = 'bankReconciliationLine';
    EntitySetName = 'bankReconciliationLines';
    EntityCaption = 'Bank Reconciliation Line';
    EntitySetCaption = 'Bank Reconciliation Lines';
    SourceTable = "Bank Acc. Reconciliation Line";
    ODataKeyFields = SystemId;
    Editable = false;
    InsertAllowed = false;
    ModifyAllowed = false;
    DeleteAllowed = false;
    Extensible = false;
    DataAccessIntent = ReadOnly;

    // The agent reads ALL Bank Reconciliation lines and itself decides which to act on, so the
    // server must NOT pre-filter by applied/match status. The ONLY filter is the TYPE filter that
    // scopes the read to bank-reconciliation lines (not check reconciliations) — matched and
    // unmatched lines alike are returned; status interpretation is the agent's job.
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
                // --- Line identity (table 274 primary key) ---
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
                field(statementLineNo; Rec."Statement Line No.")
                {
                    Caption = 'Statement Line No.';
                }
                // --- Amounts / applied state (read, never filtered on) ---
                field(statementAmount; Rec."Statement Amount")
                {
                    Caption = 'Statement Amount';
                }
                field(appliedAmount; Rec."Applied Amount")
                {
                    Caption = 'Applied Amount';
                }
                field(difference; Rec.Difference)
                {
                    Caption = 'Difference';
                }
                field(appliedEntries; Rec."Applied Entries")
                {
                    Caption = 'Applied Entries';
                }
                // --- Descriptive / external-payment-reference fields ---
                field(transactionDate; Rec."Transaction Date")
                {
                    Caption = 'Transaction Date';
                }
                field(valueDate; Rec."Value Date")
                {
                    Caption = 'Value Date';
                }
                field(description; Rec.Description)
                {
                    Caption = 'Description';
                }
                field(relatedPartyName; Rec."Related-Party Name")
                {
                    Caption = 'Related-Party Name';
                }
                field(relatedPartyBankAccNo; Rec."Related-Party Bank Acc. No.")
                {
                    Caption = 'Related-Party Bank Acc. No.';
                }
                field(paymentReference; Rec."Payment Reference No.")
                {
                    Caption = 'Payment Reference';
                }
                field(transactionText; Rec."Transaction Text")
                {
                    Caption = 'Transaction Text';
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

    /// <summary>
    /// PRIMARY agent write path. OData V4 bound action exposed on this API entity:
    /// POST .../api/monta/paymentReconciliation/v1.0/companies(&lt;id&gt;)/bankReconciliationLines(&lt;id&gt;)/Microsoft.NAV.postAndReconcile
    /// with body { "request": "&lt;PostAndReconcile request JSON, as a string&gt;" }. Returns the
    /// PostAndReconcile response JSON (bankAccountLedgerEntryNo + reconciliationLineMatched) as a string
    /// in the OData action result's "value". The action is bound to the bank-reconciliation LINE entity
    /// because its full identity (bankAccountNo/statementNo/statementLineNo) IS this table's key, so the
    /// agent reads a line here and posts the action on that exact line. THIN delegation only — all logic
    /// lives in the fully-unit-tested service codeunit. JSON is carried as Edm.String because JsonObject
    /// is not an OData-serialisable AL action parameter type.
    /// </summary>
    [ServiceEnabled]
    procedure postAndReconcile(request: Text): Text
    var
        PmtReconService: Codeunit "MON Pmt Recon Service";
    begin
        exit(PmtReconService.PostAndReconcileJson(request));
    end;
}
