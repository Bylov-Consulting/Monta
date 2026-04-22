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
        if GLEntryToClear.FindSet(true) then
            repeat
                if HasAdditionalReportingAmount(GLEntryToClear) then begin
                    GLEntryToClear."Additional-Currency Amount" := 0;
                    GLEntryToClear."Add.-Currency Debit Amount" := 0;
                    GLEntryToClear."Add.-Currency Credit Amount" := 0;
                    GLEntryToClear.Modify(false);
                    ModifiedCount += 1;
                end;
            until GLEntryToClear.Next() = 0;

        LogCleanupTelemetry(GLEntry, ModifiedCount);
    end;

    local procedure HasAdditionalReportingAmount(GLEntry: Record "G/L Entry"): Boolean
    begin
        exit(
            (GLEntry."Additional-Currency Amount" <> 0) or
            (GLEntry."Add.-Currency Debit Amount" <> 0) or
            (GLEntry."Add.-Currency Credit Amount" <> 0));
    end;

    local procedure LogCleanupTelemetry(GLEntry: Record "G/L Entry"; ModifiedCount: Integer)
    var
        Dimensions: Dictionary of [Text, Text];
    begin
        Dimensions.Add('UserId', UserId());
        Dimensions.Add('Filters', GLEntry.GetFilters());
        Dimensions.Add('ModifiedCount', Format(ModifiedCount));
        Session.LogMessage(
            'MON-94-0001',
            StrSubstNo(CleanupTelemetryTxt, ModifiedCount),
            Verbosity::Normal,
            DataClassification::SystemMetadata,
            TelemetryScope::ExtensionPublisher,
            Dimensions);
    end;

    var
        CleanupTelemetryTxt: Label 'Clear Add. Reporting Amounts ran and modified %1 G/L Entries.', Locked = true;
}
