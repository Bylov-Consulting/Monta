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
            field("MDC Auto-Reject Duplicates"; Rec."MDC Auto-Reject Duplicates")
            {
                ApplicationArea = All;
                ToolTip = 'Specifies whether Monta Document Capture Utility automatically rejects a document that Continia Document Capture has flagged as a duplicate. When enabled, an open document carrying the message selected in Duplicate Message Center ID, at severity Warning or Error, is set to Rejected with no user involved, and the message text is stored on the document as the reason. Disabled by default, because this rejects documents without a human in the loop. Added by Monta Document Capture Utility.';
            }
            field("MDC Duplicate Msg. Center ID"; Rec."MDC Duplicate Msg. Center ID")
            {
                ApplicationArea = All;
                ToolTip = 'Specifies which Continia Document Capture message identifies a duplicate document. Choose from the lookup the message center ID of Continia''s message "External Document No. %1 already exists (in %2, %3 = %4)." Severity is set per message in Continia''s own Message Center Setup: lowering the message to Information turns the automatic rejection off without changing this page. Leaving this field blank also turns it off. Added by Monta Document Capture Utility.';
            }
        }
    }
}
