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

    // The agent reads ALL Bank Reconciliation lines and itself decides which to act on, so the
    // server must NOT pre-filter by applied/match status. The ONLY legitimate SourceTableView
    // filter is the TYPE filter that scopes the read to bank-reconciliation lines.
    //
    // RED (slice 9): the extra "Difference = filter(<> 0)" clause is DELIBERATELY WRONG — it hides
    // every fully-applied (reconciled) line (Difference = 0). The slice-9 test proves a matched line
    // is still returned, so it FAILS here. GREEN removes the Difference clause, leaving only the
    // Statement Type filter.
    SourceTableView = where("Statement Type" = const("Bank Reconciliation"),
                            "Difference" = filter(<> 0));

    layout
    {
        area(Content)
        {
            repeater(Group)
            {
                field(systemId; Rec.SystemId)
                {
                    Caption = 'SystemId';
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
}
