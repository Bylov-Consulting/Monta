codeunit 50200 "MDC Dup. Reject Tests"
{
    Subtype = Test;
    TestPermissions = Disabled;
    Permissions = tabledata "CDC Document" = imd,
                  tabledata "CDC Document Comment" = imd,
                  tabledata "CDC Document Capture Setup" = imd,
                  tabledata "CDC Document Category" = imd;

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

    local procedure Initialize()
    begin
        AnyLib.SetDefaultSeed();
        ClearTestDocuments();
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

    local procedure AnyMsgCenterID(): Code[50]
    var
        Result: Code[50];
    begin
        Result := CopyStr(TestDocNoPrefixTok + '-MC-' + AnyLib.AlphanumericText(10), 1, MaxStrLen(Result));
        exit(Result);
    end;
}
