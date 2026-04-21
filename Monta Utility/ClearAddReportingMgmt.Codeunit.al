codeunit 90000 "Clear Add. Reporting Mgmt."
{
    procedure ClearAmounts(var GLEntry: Record "G/L Entry") ModifiedCount: Integer
    var
        GLEntryToClear: Record "G/L Entry";
    begin
        GLEntryToClear.CopyFilters(GLEntry);
        GLEntryToClear.SetLoadFields(
            "Entry No.",
            "Additional-Currency Amount",
            "Add.-Currency Debit Amount",
            "Add.-Currency Credit Amount");
        if not GLEntryToClear.FindSet(true) then
            exit(0);

        repeat
            if HasAdditionalReportingAmount(GLEntryToClear) then begin
                GLEntryToClear."Additional-Currency Amount" := 0;
                GLEntryToClear."Add.-Currency Debit Amount" := 0;
                GLEntryToClear."Add.-Currency Credit Amount" := 0;
                GLEntryToClear.Modify(false);
                ModifiedCount += 1;
            end;
        until GLEntryToClear.Next() = 0;
    end;

    local procedure HasAdditionalReportingAmount(GLEntry: Record "G/L Entry"): Boolean
    begin
        exit(
            (GLEntry."Additional-Currency Amount" <> 0) or
            (GLEntry."Add.-Currency Debit Amount" <> 0) or
            (GLEntry."Add.-Currency Credit Amount" <> 0));
    end;
}
