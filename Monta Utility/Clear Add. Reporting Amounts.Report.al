report 90001 "Clear Add. Reporting Amounts"
{
    Caption = 'Clear Add. Reporting Amounts on G/L Entries';
    ApplicationArea = All;
    UsageCategory = Administration;
    ProcessingOnly = true;

    dataset
    {
        dataitem(GLEntry; "G/L Entry")
        {
            RequestFilterFields = "Posting Date", "G/L Account No.", "Document No.";

            trigger OnPreDataItem()
            var
                ClearAddReportingMgmt: Codeunit "Clear Add. Reporting Mgmt.";
                ModifiedCount: Integer;
            begin
                if GuiAllowed() then
                    if not Confirm(ConfirmClearQst, false) then
                        CurrReport.Quit();

                ModifiedCount := ClearAddReportingMgmt.ClearAmounts(GLEntry);
                Message(ClearedCountMsg, ModifiedCount);
                CurrReport.Break();
            end;
        }
    }

    var
        ConfirmClearQst: Label 'This will blank "Additional-Currency Amount", "Add.-Currency Debit Amount" and "Add.-Currency Credit Amount" on every G/L Entry matching the filters. Do you want to continue?';
        ClearedCountMsg: Label 'Cleared additional reporting amounts on %1 G/L Entries.', Comment = '%1 = number of entries modified';
}
