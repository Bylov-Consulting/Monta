codeunit 50104 "MDC DC Setup Install"
{
    Access = Internal;
    Subtype = Install;
    Permissions = tabledata "CDC Document Capture Setup" = m;

    trigger OnInstallAppPerCompany()
    var
        Settings: Codeunit "MDC DC Setup Mgmt.";
    begin
        Settings.EnsureSetupRecordOnInstall();
    end;
}
