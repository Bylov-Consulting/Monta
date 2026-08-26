codeunit 50400 "MDC Dup. Reject Tests"
{
    Subtype = Test;
    TestPermissions = Disabled;
    Permissions = tabledata "CDC Document" = imd,
                  tabledata "CDC Document Comment" = imd,
                  tabledata "CDC Document Capture Setup" = imd,
                  tabledata "CDC Document Category" = imd,
                  tabledata Vendor = imd,
                  tabledata "Vendor Ledger Entry" = imd;

    var
        AnyLib: Codeunit Any;
        Assert: Codeunit "Library Assert";
        TestDocNoPrefixTok: Label 'MON113', Locked = true;
        TestCategoryCodeTok: Label 'MON113CAT', Locked = true;
        DuplicateCommentTxt: Label 'External Document No. MON113-DUP already exists (in Posted Purchase Invoice, No. = PPI-0001).', Locked = true;
        OtherWarningCommentTxt: Label 'Vendor Invoice No. is empty.', Locked = true;
        InformationCommentTxt: Label 'External Document No. MON113-INF already exists (in Posted Purchase Invoice, No. = PPI-0002).', Locked = true;
        NotRejectedErr: Label 'The document was not rejected after Continia flagged it as a duplicate.';
        RejectedOnOtherIDErr: Label 'The document was rejected on a comment whose Message Center ID is not the configured duplicate ID.';
        RejectedOnInformationErr: Label 'The document was rejected on an Information-severity comment. Only Warning and Error may auto-reject.';
        RejectedWhileDisabledErr: Label 'The document was rejected while MDC Auto-Reject Duplicates is off. The switch must be honoured.';
        NotFlaggedAutoRejectedErr: Label 'MDC Auto-Rejected was not set. An automatic rejection must be distinguishable from a human one.';
        ReasonNotRecordedErr: Label 'MDC Auto-Reject Reason does not hold the Continia comment text that caused the rejection.';
        RejectedAfterReopenErr: Label 'A document already marked MDC Auto-Rejected was rejected again after a user reopened it. The user can never win.';
        RejectedRegisteredDocErr: Label 'A Registered document was rejected. It has already become a purchase invoice, so the two records would contradict each other.';
        RejectedOnBlankIDErr: Label 'A document was rejected while Duplicate Message Center ID is blank. Nothing identifies a duplicate, so nothing may be rejected.';
        NoDuplicateFoundErr: Label 'HasDuplicate did not report a duplicate although a posted invoice for the same vendor already carries that External Document No.';
        DuplicateAcrossVendorsErr: Label 'HasDuplicate reported a duplicate although the posted invoice belongs to a different vendor. A legitimate invoice would be auto-rejected with no user involved.';
        ReasonNotBlankErr: Label 'HasDuplicate returned false but left text in Reason. A false verdict must not leave a reason behind for a later cycle to write onto a document.';
    [Test]
    procedure AutoRejectsWhenDuplicateCommentPresent()
    var
        Document: Record "CDC Document";
        RereadDocument: Record "CDC Document";
        DupRejectMgt: Codeunit "MDC Dup. Reject Mgt.";
        MsgCenterID: Code[50];
    begin
        // [SCENARIO] MON-113: auto-reject is on, and Continia has written a Warning
        // Message Center comment with the configured Message Center ID on an Open
        // document. The document must end up Rejected.
        Initialize();

        // [GIVEN] Auto-reject enabled for a specific Message Center ID
        MsgCenterID := AnyMsgCenterID();
        SetupAutoReject(true, MsgCenterID);

        // [GIVEN] An Open Document Capture document
        CreateOpenDocument(Document);

        // [GIVEN] A Validation Warning comment carrying that Message Center ID
        AddComment(Document."No.", MsgCenterID, DuplicateCommentTxt);

        // [WHEN] The duplicate check runs
        DupRejectMgt.RejectIfDuplicate(Document);

        // [THEN] The stored document is Rejected
        RereadDocument.Get(Document."No.");
        Assert.AreEqual(RereadDocument.Status::Rejected, RereadDocument.Status, NotRejectedErr);
    end;

    [Test]
    procedure LeavesDocumentUntouchedWhenOtherMsgCenterID()
    var
        Document: Record "CDC Document";
        RereadDocument: Record "CDC Document";
        DupRejectMgt: Codeunit "MDC Dup. Reject Mgt.";
        ConfiguredMsgCenterID: Code[50];
        OtherMsgCenterID: Code[50];
    begin
        // [SCENARIO] MON-113: only the Message Center ID configured as the duplicate ID may
        // trigger an auto-reject. Continia writes many other Warning comments during
        // validation; none of them are a duplicate and none may reject the document.
        Initialize();

        // [GIVEN] Auto-reject enabled for Message Center ID A
        ConfiguredMsgCenterID := AnyMsgCenterID();
        SetupAutoReject(true, ConfiguredMsgCenterID);

        // [GIVEN] An Open Document Capture document
        CreateOpenDocument(Document);

        // [GIVEN] A Validation Warning comment carrying a different Message Center ID B
        OtherMsgCenterID := AnyMsgCenterID();
        AddComment(Document."No.", OtherMsgCenterID, OtherWarningCommentTxt);

        // [WHEN] The duplicate check runs
        DupRejectMgt.RejectIfDuplicate(Document);

        // [THEN] The stored document is still Open
        RereadDocument.Get(Document."No.");
        Assert.AreEqual(RereadDocument.Status::Open, RereadDocument.Status, RejectedOnOtherIDErr);
    end;

    [Test]
    procedure IgnoresInformationSeverityComment()
    var
        Document: Record "CDC Document";
        RereadDocument: Record "CDC Document";
        DupRejectMgt: Codeunit "MDC Dup. Reject Mgt.";
        MsgCenterID: Code[50];
    begin
        // [SCENARIO] MON-113: severity is customer configuration in Continia's Message Center
        // Setup. Dialling the duplicate message down to Information is how a customer turns
        // the auto-reject off from Continia's own page, without touching our switch. Only
        // Warning and Error may auto-reject.
        // Everything here matches AutoRejectsWhenDuplicateCommentPresent except the severity -
        // the configured Message Center ID is set and the comment carries it, so a pass here
        // can only come from the severity check.
        Initialize();

        // [GIVEN] Auto-reject enabled for a specific Message Center ID
        MsgCenterID := AnyMsgCenterID();
        SetupAutoReject(true, MsgCenterID);

        // [GIVEN] An Open Document Capture document
        CreateOpenDocument(Document);

        // [GIVEN] A Validation comment carrying that same Message Center ID, but at Information
        AddInformationComment(Document."No.", MsgCenterID, InformationCommentTxt);

        // [WHEN] The duplicate check runs
        DupRejectMgt.RejectIfDuplicate(Document);

        // [THEN] The stored document is still Open
        RereadDocument.Get(Document."No.");
        Assert.AreEqual(RereadDocument.Status::Open, RereadDocument.Status, RejectedOnInformationErr);
    end;

    [Test]
    procedure DoesNothingWhenAutoRejectDisabled()
    var
        Document: Record "CDC Document";
        RereadDocument: Record "CDC Document";
        DupRejectMgt: Codeunit "MDC Dup. Reject Mgt.";
        MsgCenterID: Code[50];
    begin
        // [SCENARIO] MON-113: this feature rejects documents with no human in the loop, so it
        // is opt-in per company. Until someone turns MDC Auto-Reject Duplicates on, nothing
        // may be rejected however well the comment matches.
        // Everything here matches AutoRejectsWhenDuplicateCommentPresent except the switch -
        // the Message Center ID is configured and the Warning comment carries it, so a pass
        // here can only come from the switch being read.
        Initialize();

        // [GIVEN] Auto-reject turned off, but a Message Center ID configured
        MsgCenterID := AnyMsgCenterID();
        SetupAutoReject(false, MsgCenterID);

        // [GIVEN] An Open Document Capture document
        CreateOpenDocument(Document);

        // [GIVEN] A Validation Warning comment carrying that Message Center ID
        AddComment(Document."No.", MsgCenterID, DuplicateCommentTxt);

        // [WHEN] The duplicate check runs
        DupRejectMgt.RejectIfDuplicate(Document);

        // [THEN] The stored document is still Open
        RereadDocument.Get(Document."No.");
        Assert.AreEqual(RereadDocument.Status::Open, RereadDocument.Status, RejectedWhileDisabledErr);
    end;

    [Test]
    procedure RecordsReasonWhenAutoRejecting()
    var
        Document: Record "CDC Document";
        RereadDocument: Record "CDC Document";
        DupRejectMgt: Codeunit "MDC Dup. Reject Mgt.";
        MsgCenterID: Code[50];
    begin
        // [SCENARIO] MON-113 acceptance criterion: the reason for an automatic rejection is
        // discoverable by a user afterwards. Without this the document is indistinguishable
        // from one a human rejected.
        // Status is not asserted here - AutoRejectsWhenDuplicateCommentPresent already pins it.
        // This test is about the audit trail.
        Initialize();

        // [GIVEN] Auto-reject enabled for a specific Message Center ID
        MsgCenterID := AnyMsgCenterID();
        SetupAutoReject(true, MsgCenterID);

        // [GIVEN] An Open Document Capture document
        CreateOpenDocument(Document);

        // [GIVEN] A Validation Warning comment carrying that Message Center ID
        AddComment(Document."No.", MsgCenterID, DuplicateCommentTxt);

        // [WHEN] The duplicate check runs
        DupRejectMgt.RejectIfDuplicate(Document);

        // [THEN] The stored document is marked as auto-rejected and carries Continia's own
        // comment text verbatim. Both fields are Text[250], the same width as
        // "CDC Document Comment".Comment, so nothing may be truncated.
        RereadDocument.Get(Document."No.");
        Assert.IsTrue(RereadDocument."MDC Auto-Rejected", NotFlaggedAutoRejectedErr);
        Assert.AreEqual(DuplicateCommentTxt, RereadDocument."MDC Auto-Reject Reason", ReasonNotRecordedErr);
    end;

    [Test]
    procedure DoesNotRejectAgainAfterReopen()
    var
        Document: Record "CDC Document";
        RereadDocument: Record "CDC Document";
        DupRejectMgt: Codeunit "MDC Dup. Reject Mgt.";
        MsgCenterID: Code[50];
    begin
        // [SCENARIO] MON-113: the auto-reject fires on a false positive. A user checks the
        // document, sees it is not a duplicate, and reopens it from Continia's Reopen action.
        // Validation runs again, the duplicate comment is still there, and without this guard
        // we reject it a second time - the user can never win and every false positive turns
        // into a support ticket.
        // MDC Auto-Rejected is what makes the document remember, and it survives Continia
        // deleting and rewriting its comments on re-validation.
        Initialize();

        // [GIVEN] Auto-reject enabled for a specific Message Center ID
        MsgCenterID := AnyMsgCenterID();
        SetupAutoReject(true, MsgCenterID);

        // [GIVEN] A document we auto-rejected once, which a user has since reopened
        CreateReopenedAutoRejectedDocument(Document);

        // [GIVEN] Continia's duplicate comment still sitting on it
        AddComment(Document."No.", MsgCenterID, DuplicateCommentTxt);

        // [WHEN] Validation runs again and the duplicate check fires a second time
        DupRejectMgt.RejectIfDuplicate(Document);

        // [THEN] The document the user reopened is left Open
        RereadDocument.Get(Document."No.");
        Assert.AreEqual(RereadDocument.Status::Open, RereadDocument.Status, RejectedAfterReopenErr);
    end;

    [Test]
    procedure DoesNotRejectARegisteredDocument()
    var
        Document: Record "CDC Document";
        RereadDocument: Record "CDC Document";
        DupRejectMgt: Codeunit "MDC Dup. Reject Mgt.";
        MsgCenterID: Code[50];
    begin
        // [SCENARIO] MON-113: a Registered document has already become a purchase invoice in
        // BC. Rejecting it after the fact would leave the Document Capture document saying
        // Rejected while the invoice it created still exists - the two records would
        // contradict each other, and nobody is watching a document that already registered,
        // so the rejection would be silent.
        // Everything here matches AutoRejectsWhenDuplicateCommentPresent except the status.
        Initialize();

        // [GIVEN] Auto-reject enabled for a specific Message Center ID
        MsgCenterID := AnyMsgCenterID();
        SetupAutoReject(true, MsgCenterID);

        // [GIVEN] A document that has already registered, never auto-rejected
        CreateRegisteredDocument(Document);

        // [GIVEN] A Validation Warning comment carrying that Message Center ID
        AddComment(Document."No.", MsgCenterID, DuplicateCommentTxt);

        // [WHEN] The duplicate check runs
        DupRejectMgt.RejectIfDuplicate(Document);

        // [THEN] The stored document is still Registered
        RereadDocument.Get(Document."No.");
        Assert.AreEqual(RereadDocument.Status::Registered, RereadDocument.Status, RejectedRegisteredDocErr);
    end;

    [Test]
    procedure DoesNothingWhenMsgCenterIDBlank()
    var
        Document: Record "CDC Document";
        RereadDocument: Record "CDC Document";
        DupRejectMgt: Codeunit "MDC Dup. Reject Mgt.";
    begin
        // [SCENARIO] MON-113: a company turns the switch on but never picks a Message Center
        // ID. Nothing identifies a duplicate, so nothing may be rejected.
        // The comment below deliberately carries a blank Message Center ID too. Without the
        // blank-ID guard the code runs SetRange("Message Center ID", ''), which MATCHES that
        // comment - so every document carrying a Warning gets auto-rejected. That is the real
        // failure this test exists to prevent, not a theoretical one.
        Initialize();

        // [GIVEN] Auto-reject enabled but no Message Center ID chosen
        SetupAutoReject(true, '');

        // [GIVEN] An Open Document Capture document
        CreateOpenDocument(Document);

        // [GIVEN] A Validation Warning comment that also carries no Message Center ID
        AddComment(Document."No.", '', OtherWarningCommentTxt);

        // [WHEN] The duplicate check runs
        DupRejectMgt.RejectIfDuplicate(Document);

        // [THEN] The stored document is still Open
        RereadDocument.Get(Document."No.");
        Assert.AreEqual(RereadDocument.Status::Open, RereadDocument.Status, RejectedOnBlankIDErr);
    end;

    [Test]
    procedure RejectsWhenPostedInvoiceHasSameExtDocNo()
    var
        TemplateFieldRule: Record "CDC Template Field Rule";
        DupRejectMgt: Codeunit "MDC Dup. Reject Mgt.";
        VendorNo: Code[20];
        ExternalDocNo: Code[35];
        Reason: Text[250];
    begin
        // [SCENARIO] MON-113 v2: Continia records a duplicate as a comment with a BLANK
        // Message Center ID, so nothing can filter on it and the comment text is a Label and
        // therefore translated. We run the same lookup ourselves instead.
        // This is Continia's first check in "CDC Purch. - Validation": the vendor document
        // number already sits on a posted entry for the same pay-to vendor.
        Initialize();

        // [GIVEN] A vendor with a posted invoice carrying an External Document No.
        VendorNo := CreateVendor();
        ExternalDocNo := AnyExternalDocNo();
        CreatePostedInvoiceEntry(VendorNo, ExternalDocNo);

        // [WHEN] The same vendor document number arrives again as an invoice
        // [THEN] It is reported as a duplicate
        Assert.IsTrue(
            DupRejectMgt.HasDuplicate(ExternalDocNo, TemplateFieldRule."Document Type"::Invoice, VendorNo, Reason),
            NoDuplicateFoundErr);
    end;

    [Test]
    procedure IgnoresPostedInvoiceForADifferentVendor()
    var
        TemplateFieldRule: Record "CDC Template Field Rule";
        DupRejectMgt: Codeunit "MDC Dup. Reject Mgt.";
        VendorANo: Code[20];
        VendorBNo: Code[20];
        ExternalDocNo: Code[35];
        Reason: Text[250];
        DuplicateFound: Boolean;
    begin
        // [SCENARIO] MON-113 v2: vendors number their own invoices, so two vendors reusing the
        // same document number is ordinary, not a duplicate. Continia scopes its lookup to the
        // pay-to vendor and so must we.
        // Two vendors are the point of this test: with one vendor it would pass against an
        // unfiltered lookup and prove nothing. Without the vendor filter a legitimate invoice
        // from vendor A is auto-rejected because vendor B once used that number.
        Initialize();

        // [GIVEN] Two vendors, and a posted invoice belonging to vendor B
        VendorANo := CreateVendor();
        VendorBNo := CreateVendor();
        ExternalDocNo := AnyExternalDocNo();
        CreatePostedInvoiceEntry(VendorBNo, ExternalDocNo);

        // [WHEN] Vendor A sends an invoice carrying that same document number
        DuplicateFound := DupRejectMgt.HasDuplicate(ExternalDocNo, TemplateFieldRule."Document Type"::Invoice, VendorANo, Reason);

        // [THEN] It is not a duplicate, and no reason is left behind
        Assert.IsFalse(DuplicateFound, DuplicateAcrossVendorsErr);
        Assert.AreEqual('', Reason, ReasonNotBlankErr);
    end;

    local procedure Initialize()
    begin
        AnyLib.SetDefaultSeed();
        ClearTestDocuments();
        ClearTestVendors();
    end;

    local procedure ClearTestDocuments()
    var
        Document: Record "CDC Document";
        DocumentComment: Record "CDC Document Comment";
    begin
        Document.SetFilter("No.", TestDocNoPrefixTok + '*');
        if Document.FindSet() then
            repeat
                DocumentComment.SetRange("Document No.", Document."No.");
                DocumentComment.DeleteAll(false);
            until Document.Next() = 0;
        Document.DeleteAll(false);
    end;

    local procedure ClearTestVendors()
    var
        Vendor: Record Vendor;
        VendorLedgerEntry: Record "Vendor Ledger Entry";
    begin
        Vendor.SetFilter("No.", TestDocNoPrefixTok + '*');
        if Vendor.FindSet() then
            repeat
                VendorLedgerEntry.SetRange("Vendor No.", Vendor."No.");
                VendorLedgerEntry.DeleteAll(false);
            until Vendor.Next() = 0;
        Vendor.DeleteAll(false);
    end;

    local procedure CreateVendor(): Code[20]
    var
        Vendor: Record Vendor;
        Candidate: Code[20];
    begin
        repeat
            Candidate := CopyStr(TestDocNoPrefixTok + AnyLib.AlphanumericText(10), 1, MaxStrLen(Candidate));
        until not Vendor.Get(Candidate);
        Vendor.Init();
        Vendor."No." := Candidate;
        Vendor.Name := Candidate;
        Vendor.Insert(false);
        exit(Candidate);
    end;

    // A posted invoice, as Continia's first check sees it: a Vendor Ledger Entry of type
    // Invoice carrying the External Document No. for that vendor.
    local procedure CreatePostedInvoiceEntry(VendorNo: Code[20]; ExternalDocNo: Code[35])
    var
        VendorLedgerEntry: Record "Vendor Ledger Entry";
    begin
        VendorLedgerEntry.Init();
        VendorLedgerEntry."Entry No." := NextVendorLedgerEntryNo();
        VendorLedgerEntry."Vendor No." := VendorNo;
        VendorLedgerEntry."Document Type" := VendorLedgerEntry."Document Type"::Invoice;
        VendorLedgerEntry."Document No." := CopyStr(TestDocNoPrefixTok + '-PPI', 1, MaxStrLen(VendorLedgerEntry."Document No."));
        VendorLedgerEntry."External Document No." := ExternalDocNo;
        VendorLedgerEntry."Posting Date" := WorkDate();
        VendorLedgerEntry."Document Date" := WorkDate();
        VendorLedgerEntry.Insert(false);
    end;

    // "Entry No." is not AutoIncrement on Vendor Ledger Entry - the poster assigns it.
    local procedure NextVendorLedgerEntryNo(): Integer
    var
        VendorLedgerEntry: Record "Vendor Ledger Entry";
    begin
        if VendorLedgerEntry.FindLast() then
            exit(VendorLedgerEntry."Entry No." + 1);
        exit(1);
    end;

    local procedure SetupAutoReject(Enabled: Boolean; MsgCenterID: Code[50])
    var
        Setup: Record "CDC Document Capture Setup";
    begin
        if not Setup.Get() then begin
            Setup.Init();
            Setup."Primary Key" := '';
            Setup.Insert(false);
        end;
        Setup."MDC Auto-Reject Duplicates" := Enabled;
        Setup."MDC Duplicate Msg. Center ID" := MsgCenterID;
        Setup.Modify(false);
    end;

    local procedure CreateOpenDocument(var Document: Record "CDC Document")
    begin
        Document.Init();
        Document."No." := AnyDocumentNo();
        Document."Document Category Code" := EnsureDocumentCategory();
        Document.Status := Document.Status::Open;
        Document.Insert(false);
    end;

    // A document that has already registered - it has become a purchase invoice in BC.
    // MDC Auto-Rejected is left false so the reopen guard cannot be what protects it.
    // Status is set before Insert so the record the caller passes on carries it in memory,
    // which is what RejectIfDuplicate reads.
    local procedure CreateRegisteredDocument(var Document: Record "CDC Document")
    begin
        Document.Init();
        Document."No." := AnyDocumentNo();
        Document."Document Category Code" := EnsureDocumentCategory();
        Document.Status := Document.Status::Registered;
        Document.Insert(false);
    end;

    // An Open document that carries MDC Auto-Rejected - what a document looks like after we
    // auto-rejected it once and a user reopened it. A separate helper rather than a parameter
    // on CreateOpenDocument so the four earlier tests keep calling exactly what they called
    // before. The returned record carries the flag, not just the stored row, because
    // RejectIfDuplicate reads it off the record it is passed.
    local procedure CreateReopenedAutoRejectedDocument(var Document: Record "CDC Document")
    begin
        Document.Init();
        Document."No." := AnyDocumentNo();
        Document."Document Category Code" := EnsureDocumentCategory();
        Document.Status := Document.Status::Open;
        Document."MDC Auto-Rejected" := true;
        Document.Insert(false);
    end;

    local procedure AddComment(DocumentNo: Code[20]; MsgCenterID: Code[50]; CommentTxt: Text[250])
    var
        DocumentComment: Record "CDC Document Comment";
    begin
        DocumentComment.Init();
        // "Entry No." is AutoIncrement - the platform assigns it on Insert.
        DocumentComment."Document No." := DocumentNo;
        DocumentComment."Comment Type" := DocumentComment."Comment Type"::Warning;
        DocumentComment.Area := DocumentComment.Area::Validation;
        DocumentComment.Comment := CommentTxt;
        DocumentComment."Message Center ID" := MsgCenterID;
        DocumentComment.Insert(false);
    end;

    // Same as AddComment but at Information severity. A separate helper rather than a
    // Comment Type parameter: "Comment Type" is an Option owned by Continia, so a parameter
    // would have to restate its members here and would silently drift if Continia changes them.
    local procedure AddInformationComment(DocumentNo: Code[20]; MsgCenterID: Code[50]; CommentTxt: Text[250])
    var
        DocumentComment: Record "CDC Document Comment";
    begin
        DocumentComment.Init();
        // "Entry No." is AutoIncrement - the platform assigns it on Insert.
        DocumentComment."Document No." := DocumentNo;
        DocumentComment."Comment Type" := DocumentComment."Comment Type"::Information;
        DocumentComment.Area := DocumentComment.Area::Validation;
        DocumentComment.Comment := CommentTxt;
        DocumentComment."Message Center ID" := MsgCenterID;
        DocumentComment.Insert(false);
    end;

    local procedure EnsureDocumentCategory(): Code[10]
    var
        DocumentCategory: Record "CDC Document Category";
    begin
        if not DocumentCategory.Get(TestCategoryCodeTok) then begin
            DocumentCategory.Init();
            DocumentCategory.Code := TestCategoryCodeTok;
            DocumentCategory.Description := TestCategoryCodeTok;
            DocumentCategory.Insert(false);
        end;
        exit(DocumentCategory.Code);
    end;

    local procedure AnyDocumentNo(): Code[20]
    var
        Document: Record "CDC Document";
        Candidate: Code[20];
    begin
        repeat
            Candidate := CopyStr(TestDocNoPrefixTok + AnyLib.AlphanumericText(10), 1, MaxStrLen(Candidate));
        until not Document.Get(Candidate);
        exit(Candidate);
    end;

    local procedure AnyExternalDocNo(): Code[35]
    var
        Result: Code[35];
    begin
        Result := CopyStr(TestDocNoPrefixTok + '-EXT-' + AnyLib.AlphanumericText(10), 1, MaxStrLen(Result));
        exit(Result);
    end;

    local procedure AnyMsgCenterID(): Code[50]
    var
        Result: Code[50];
    begin
        Result := CopyStr(TestDocNoPrefixTok + '-MC-' + AnyLib.AlphanumericText(10), 1, MaxStrLen(Result));
        exit(Result);
    end;
}
