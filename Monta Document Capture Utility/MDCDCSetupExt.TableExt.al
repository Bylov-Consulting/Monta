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
    }
}
