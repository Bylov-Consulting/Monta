codeunit 50108 "MDC Dup. Reject Mgt."
{
    Access = Internal;
    Permissions = tabledata "CDC Document" = m;

    /// <summary>
    /// Rejects a Document Capture document when Continia's own duplicate check has flagged it.
    /// Returns true when the document was auto-rejected by this call.
    /// </summary>
    internal procedure RejectIfDuplicate(var Document: Record "CDC Document"): Boolean
    var
        DocumentComment: Record "CDC Document Comment";
        DuplicateMsgCenterID: Code[50];
    begin
        // A document we have already auto-rejected once is left alone for good. A user who
        // reopens a false positive would otherwise have it re-rejected on the next validation
        // pass and could never win. Read off the passed record, which is the one Continia is
        // validating - not a re-read. Checked before the setup so that toggling the switch off
        // and back on does not re-reject every false positive a user has since reopened.
        if Document."MDC Auto-Rejected" then
            exit(false);

        // Opt-in per company. This rejects documents with no human in the loop, so nothing
        // happens until someone turns the switch on. Checked first: when the feature is off
        // we do no work at all.
        if not IsAutoRejectEnabled() then
            exit(false);

        // No Message Center ID configured means nothing identifies a duplicate, so nothing
        // can be auto-rejected. Do not fall back to "any comment" - Continia writes plenty
        // of unrelated comments during validation.
        DuplicateMsgCenterID := GetDuplicateMsgCenterID();
        if DuplicateMsgCenterID = '' then
            exit(false);

        DocumentComment.SetRange("Document No.", Document."No.");
        DocumentComment.SetRange("Message Center ID", DuplicateMsgCenterID);
        // Severity is customer configuration in Continia's Message Center Setup. Dialling the
        // duplicate message down to Information turns the auto-reject off from Continia's own
        // page. The members are read off the record so a change on Continia's side is a
        // compile error here rather than a silent ordinal mismatch.
        DocumentComment.SetFilter("Comment Type", '%1|%2', DocumentComment."Comment Type"::Warning, DocumentComment."Comment Type"::Error);
        // FindFirst rather than IsEmpty: the comment text itself is what gets recorded as the
        // rejection reason, so the row is needed, not just its existence.
        DocumentComment.SetLoadFields(Comment);
        if not DocumentComment.FindFirst() then
            exit(false);

        // Continia's own Document.Reject() raises a Confirm dialog ("Do you want to reject
        // the document?") and offers no reachable way to suppress it - "CDC Template".SkipConfirm()
        // is internal to Continia. This code runs during validation, under the OCR import /
        // job queue path with no user present, so the status is written directly instead.
        //
        // Verified at runtime against DC 27.3.0.330595 by diffing the whole CDC Document row
        // before and after a Reject(): it changes only Status and Date-Time for Register/Reject.
        // No activity log row, no comment, no Document Status Text refresh. Writing both fields
        // here is therefore equivalent to calling Reject().
        Document.Status := Document.Status::Rejected;
        Document."Date-Time for Register/Reject" := CurrentDateTime();
        // Acceptance criterion: the reason for an automatic rejection stays discoverable
        // afterwards. Without these an auto-rejection is indistinguishable from a human one.
        // Both fields are Text[250], the same width as "CDC Document Comment".Comment, so
        // Continia's text is stored verbatim.
        Document."MDC Auto-Rejected" := true;
        Document."MDC Auto-Reject Reason" := DocumentComment.Comment;
        Document.Modify(false);
        exit(true);
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
