pageextension 50101 "MDC DC Setup Card Ext" extends "CDC Setup - Purch. Approval"
{
    layout
    {
        addafter("Use Acc. and Dim. App. Pms.")
        {
            field("Disable CDC Cross-Co. Tmpl."; Rec."Disable CDC Cross-Co. Tmpl.")
            {
                ApplicationArea = All;
                ToolTip = 'Specifies whether Monta Document Capture Utility suppresses Continia Document Capture''s cross-company template-copy prompt. When enabled (default), processing a document whose source name matches a template in another company will skip the "Copy template from..." prompt and fall through to the standard create-new-template path. Added by Monta Document Capture Utility.';
            }
        }
    }
}
