report 90001 "Clear Add. Reporting Amounts"
{
    Caption = 'Clear Add. Reporting Amounts on G/L Entries';
    ApplicationArea = Suite;
    UsageCategory = Administration;
    ProcessingOnly = true;
    Permissions = tabledata "G/L Entry" = rm;

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
                if not GuiAllowed() then
                    Error(HeadlessNotSupportedErr);

                if not Confirm(ConfirmClearQst, false) then
                    CurrReport.Quit();

                ModifiedCount := ClearAddReportingMgmt.ClearAmounts(GLEntry);
                if ModifiedCount = 0 then
                    Message(NoEntriesClearedMsg)
                else
                    Message(ClearedCountMsg, ModifiedCount);
                CurrReport.Break();
            end;
        }
    }

    var
        ConfirmClearQst: Label 'This will blank "Additional-Currency Amount", "Add.-Currency Debit Amount" and "Add.-Currency Credit Amount" on every G/L Entry matching the filters. Do you want to continue?';
        ClearedCountMsg: Label 'Cleared additional reporting amounts on %1 G/L Entries.', Comment = '%1 = number of entries modified';
        NoEntriesClearedMsg: Label 'No G/L Entries matched the filter with additional reporting amounts to clear.';
        HeadlessNotSupportedErr: Label 'This report cannot be run in a non-interactive session. Open it from the client and confirm the cleanup interactively.';
}
