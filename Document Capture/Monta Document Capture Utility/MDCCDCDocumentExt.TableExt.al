tableextension 50105 "MDC CDC Document Ext" extends "CDC Document"
{
    fields
    {
        field(50110; "MDC Auto-Rejected"; Boolean)
        {
            Caption = 'Auto-Rejected as Duplicate';
            DataClassification = CustomerContent;
            Editable = false;
        }
        field(50111; "MDC Auto-Reject Reason"; Text[250])
        {
            Caption = 'Auto-Rejection Reason';
            DataClassification = CustomerContent;
            Editable = false;
        }
    }
}
