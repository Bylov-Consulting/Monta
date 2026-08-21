pageextension 50106 "MDC DC Document Card Ext" extends "CDC Document Card"
{
    layout
    {
        addafter(Status)
        {
            field("MDC Auto-Rejected"; Rec."MDC Auto-Rejected")
            {
                ApplicationArea = All;
                Editable = false;
                ToolTip = 'Specifies whether this document was rejected automatically because Continia Document Capture flagged it as a duplicate, rather than by a user. A document that carries this mark is never auto-rejected again, so you can reopen a false positive and it stays open. Added by Monta Document Capture Utility.';
            }
            field("MDC Auto-Reject Reason"; Rec."MDC Auto-Reject Reason")
            {
                ApplicationArea = All;
                Editable = false;
                MultiLine = true;
                ToolTip = 'Specifies the Continia Document Capture message that caused the automatic rejection, stored word for word as Continia wrote it. Added by Monta Document Capture Utility.';
            }
        }
    }
}
