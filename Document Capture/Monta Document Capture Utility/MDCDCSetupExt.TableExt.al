tableextension 50100 "MDC DC Setup Ext" extends "CDC Document Capture Setup"
{
    fields
    {
        field(50100; "Disable CDC Cross-Co. Tmpl."; Boolean)
        {
            Caption = 'Disable CDC Cross-Company Template Lookup';
            DataClassification = CustomerContent;
            InitValue = true;
        }
        field(50101; "MDC Auto-Reject Duplicates"; Boolean)
        {
            Caption = 'Auto-Reject Duplicate Documents';
            DataClassification = CustomerContent;
        }
        field(50102; "MDC Duplicate Msg. Center ID"; Code[50])
        {
            Caption = 'Duplicate Message Center ID';
            DataClassification = CustomerContent;
            TableRelation = "CDC Msg. Center Setup Template"."Message Center ID";
        }
    }
}
