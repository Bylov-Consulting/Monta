codeunit 50103 "MDC DC Setup Mgmt."
{
    Access = Internal;

    internal procedure IsCrossCompanyTemplateCopyDisabled(): Boolean
    var
        Setup: Record "CDC Document Capture Setup";
    begin
        Setup.SetLoadFields("Disable CDC Cross-Co. Tmpl.");
        if not Setup.Get() then
            exit(false);
        exit(Setup."Disable CDC Cross-Co. Tmpl.");
    end;

    internal procedure EnsureSetupRecordOnInstall()
    var
        Setup: Record "CDC Document Capture Setup";
    begin
        Setup.SetLoadFields("Disable CDC Cross-Co. Tmpl.");
        if Setup.Get() then begin
            Setup."Disable CDC Cross-Co. Tmpl." := true;
            Setup.Modify(false);
            exit;
        end;
        Setup.Init();
        Setup."Primary Key" := '';
        Setup.Insert(true);
    end;
}
