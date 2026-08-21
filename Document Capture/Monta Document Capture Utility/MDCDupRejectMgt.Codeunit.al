codeunit 50108 "MDC Dup. Reject Mgt."
{
    Access = Internal;
    Permissions = tabledata "CDC Document" = m;

    /// <summary>
    /// Rejects a Document Capture document when Continia's own duplicate check has flagged it.
    /// Returns true when the document was auto-rejected by this call.
    /// </summary>
    internal procedure RejectIfDuplicate(var Document: Record "CDC Document"): Boolean
    begin
        exit(false);
    end;

    internal procedure IsAutoRejectEnabled(): Boolean
    var
        Setup: Record "CDC Document Capture Setup";
    begin
        Setup.SetLoadFields("MDC Auto-Reject Duplicates");
        if not Setup.Get() then
            exit(false);
        exit(Setup."MDC Auto-Reject Duplicates");
    end;

    internal procedure GetDuplicateMsgCenterID(): Code[50]
    var
        Setup: Record "CDC Document Capture Setup";
    begin
        Setup.SetLoadFields("MDC Duplicate Msg. Center ID");
        if not Setup.Get() then
            exit('');
        exit(Setup."MDC Duplicate Msg. Center ID");
    end;
}
