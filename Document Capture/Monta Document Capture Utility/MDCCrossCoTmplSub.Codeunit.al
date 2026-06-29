codeunit 50102 "MDC Cross-Co. Tmpl. Sub."
{
    Access = Internal;

    [EventSubscriber(ObjectType::Table, Database::"CDC Document", 'OnBeforeFindTemplateInCompanies', '', false, false)]
    local procedure SuppressCrossCompanyLookup(var FromCompany: Text[30]; var FromTemplate: Record "CDC Template"; SourceName: Text[250]; var Result: Boolean; var IsHandle: Boolean)
    var
        Settings: Codeunit "MDC DC Setup Mgmt.";
        TelemetryDims: Dictionary of [Text, Text];
    begin
        if not Settings.IsCrossCompanyTemplateCopyDisabled() then
            exit;

        IsHandle := true;
        Result := false;

        TelemetryDims.Add('Company', CompanyName());
        TelemetryDims.Add('SourceNameLength', Format(StrLen(SourceName)));
        Session.LogMessage(
            'MON-DC-0001',
            SuppressedTelemetryLbl,
            Verbosity::Verbose,
            DataClassification::SystemMetadata,
            TelemetryScope::ExtensionPublisher,
            TelemetryDims);
    end;

    var
        SuppressedTelemetryLbl: Label 'Monta Utility suppressed CDC cross-company template lookup.', Locked = true;
}
