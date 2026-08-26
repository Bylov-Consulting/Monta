codeunit 50108 "MDC Dup. Reject Mgt."
{
    Access = Internal;
    Permissions = tabledata "CDC Document" = m,
                  tabledata "Vendor Ledger Entry" = r;

    /// <summary>
    /// Rejects a Document Capture document when Continia's own duplicate check has flagged it.
    /// Returns true when the document was auto-rejected by this call.
    /// </summary>
    internal procedure RejectIfDuplicate(var Document: Record "CDC Document"): Boolean
    var
        Setup: Record "CDC Document Capture Setup";
        DocumentComment: Record "CDC Document Comment";
        TelemetryDims: Dictionary of [Text, Text];
    begin
        // A document we have already auto-rejected once is left alone for good. A user who
        // reopens a false positive would otherwise have it re-rejected on the next validation
        // pass and could never win. Read off the passed record, which is the one Continia is
        // validating - not a re-read. Checked before the setup so that toggling the switch off
        // and back on does not re-reject every false positive a user has since reopened.
        if Document."MDC Auto-Rejected" then
            exit(false);

        // Only an Open document may be auto-rejected. A Registered one has already become a
        // purchase invoice in BC - rejecting it after the fact would leave the two records
        // contradicting each other, silently, because nobody watches a registered document.
        // Allow-list rather than deny-list: it also covers an already-Rejected document, whose
        // "Date-Time for Register/Reject" would otherwise be rewritten, and any status
        // Continia adds in a future release.
        if Document.Status <> Document.Status::Open then
            exit(false);

        // Both setup values come from one row read - this runs once per document during OCR
        // import, so a second Get would double the reads on the setup table for nothing.
        // A missing setup row means the feature was never configured: do nothing, same as the
        // switch being off.
        Setup.SetLoadFields("MDC Auto-Reject Duplicates", "MDC Duplicate Msg. Center ID");
        if not Setup.Get() then
            exit(false);

        // Opt-in per company. This rejects documents with no human in the loop, so nothing
        // happens until someone turns the switch on.
        if not Setup."MDC Auto-Reject Duplicates" then
            exit(false);

        // No Message Center ID configured means nothing identifies a duplicate, so nothing
        // can be auto-rejected. Do not fall back to "any comment" - Continia writes plenty
        // of unrelated comments during validation.
        if Setup."MDC Duplicate Msg. Center ID" = '' then
            exit(false);

        DocumentComment.SetRange("Document No.", Document."No.");
        DocumentComment.SetRange("Message Center ID", Setup."MDC Duplicate Msg. Center ID");
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

        // Auto-rejection is silent and destructive. When Monta asks "where did this invoice
        // go", this is what answers how often it fires and on which message.
        // The comment text is deliberately NOT a dimension: it carries vendor and invoice
        // numbers, which is customer content and does not belong in Application Insights.
        TelemetryDims.Add('DocumentNo', Document."No.");
        TelemetryDims.Add('MessageCenterID', Setup."MDC Duplicate Msg. Center ID");
        TelemetryDims.Add('DocumentCategoryCode', Document."Document Category Code");
        Session.LogMessage(
            'MON-DC-0002',
            AutoRejectedTelemetryLbl,
            Verbosity::Normal,
            DataClassification::SystemMetadata,
            TelemetryScope::ExtensionPublisher,
            TelemetryDims);
        exit(true);
    end;

    /// <summary>
    /// Decides whether a vendor document number already exists on a posted or unposted purchase
    /// document for the same pay-to vendor. Mirrors the checks Continia's
    /// "CDC Purch. - Validation" runs, because Continia records the hit as a comment with a
    /// blank Message Center ID, which nothing can filter on.
    /// Reason returns the text to store on the document when the answer is true.
    /// </summary>
    internal procedure HasDuplicate(VendDocNo: Code[50]; DocumentType: Integer; SourceVendorNo: Code[20]; var Reason: Text[250]): Boolean
    var
        CDCTemplateFieldRule: Record "CDC Template Field Rule";
        VendLedgEntry: Record "Vendor Ledger Entry";
    begin
        // Mirrors the posted-document half of the "CHECK EXTERNAL DOCUMENT NO." block in
        // Continia's codeunit 6085705 "CDC Purch. - Validation", read from the extracted
        // source of DC 28.3 (Monta's sandbox). The 26.2 copy has identical filters, so 27.3
        // is the same. Diff against that block when upgrading Continia.
        // We repeat the lookup instead of reading Continia's own verdict because Continia
        // records it as a "CDC Document Comment" with a BLANK "Message Center ID" - nothing
        // can filter on it - and the comment text is a Label, so it is translated.
        Reason := '';

        // DELIBERATE DIVERGENCE FROM CONTINIA. Continia's case statement has no else arm, so
        // for Order, Receipt and " " it leaves the lookup unfiltered on document type. We exit
        // instead. Two reasons: MON-113 is scoped to invoices and credit memos only, and an
        // unfiltered type lookup is a false-positive source we would be choosing to inherit.
        // So: safer than Continia here, and different from Continia - both on purpose.
        // Invoice and Prepayment share one arm because Continia maps both to a posted Invoice.
        case DocumentType of
            CDCTemplateFieldRule."Document Type"::Invoice,
            CDCTemplateFieldRule."Document Type"::Prepayment:
                VendLedgEntry.SetRange("Document Type", VendLedgEntry."Document Type"::Invoice);
            CDCTemplateFieldRule."Document Type"::"Credit Memo":
                VendLedgEntry.SetRange("Document Type", VendLedgEntry."Document Type"::"Credit Memo");
            else
                exit(false);
        end;

        VendLedgEntry.SetCurrentKey("External Document No.");
        VendLedgEntry.SetLoadFields("Entry No.");
        VendLedgEntry.SetRange("External Document No.", CopyStr(VendDocNo, 1, MaxStrLen(VendLedgEntry."External Document No.")));
        // Vendors number their own invoices, so the same document number turning up for two
        // different vendors is ordinary. Without this filter a legitimate invoice from one
        // vendor is auto-rejected because another vendor once used that number.
        VendLedgEntry.SetRange("Vendor No.", SourceVendorNo);
        if not VendLedgEntry.FindFirst() then
            exit(false);

        Reason := CopyStr(StrSubstNo(DuplicateOnPostedEntryMsg, VendDocNo, VendLedgEntry."Entry No."), 1, MaxStrLen(Reason));
        exit(true);
    end;

    var
        DuplicateOnPostedEntryMsg: Label 'Document no. %1 already exists on posted vendor ledger entry %2.', Comment = '%1 = vendor document number, %2 = Vendor Ledger Entry No.';
        AutoRejectedTelemetryLbl: Label 'Monta Utility auto-rejected a Document Capture document flagged as a duplicate.', Locked = true;
}
