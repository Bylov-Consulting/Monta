codeunit 50400 "MDC Dup. Reject Tests"
{
    Subtype = Test;
    TestPermissions = Disabled;
    Permissions = tabledata "CDC Document" = imd,
                  tabledata "CDC Document Comment" = imd,
                  tabledata "CDC Document Capture Setup" = imd,
                  tabledata "CDC Document Category" = imd,
                  tabledata Vendor = imd,
                  tabledata "Vendor Ledger Entry" = imd,
                  tabledata "Purchase Header" = imd;

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
        DuplicateAcrossDocTypesErr: Label 'HasDuplicate reported a duplicate although the posted entry is a credit memo and the incoming document is an invoice. They are not the same kind of document.';
        NoCreditMemoDuplicateErr: Label 'HasDuplicate did not report a duplicate although a posted credit memo for the same vendor already carries that External Document No.';
        PrepaymentNotAnInvoiceErr: Label 'HasDuplicate did not treat Prepayment as an invoice. Continia maps Prepayment and Invoice onto the same posted document type.';
        TypeLeakedErr: Label 'HasDuplicate reported a duplicate for document type %1, which is outside the invoice and credit-memo scope MON-113 covers.', Comment = '%1 = document type name';
        ReasonLeftForTypeErr: Label 'HasDuplicate returned false for document type %1 but left text in Reason.', Comment = '%1 = document type name';
        OrderTypeTok: Label 'Order', Locked = true;
        ReceiptTypeTok: Label 'Receipt', Locked = true;
        BlankTypeTok: Label 'blank', Locked = true;
        NoUnpostedDuplicateErr: Label 'HasDuplicate did not report a duplicate although an unposted purchase invoice for the same vendor already carries that Vendor Invoice No. Nothing is in Vendor Ledger Entry yet, so only the unposted lookup can find it.';
        UnpostedReasonBlankErr: Label 'HasDuplicate reported an unposted duplicate but left Reason blank. The reason is what tells a user where the collision is.';
        UnpostedReasonSameAsPostedErr: Label 'HasDuplicate gave the unposted duplicate the same wording as a posted one. Telling a user the document sits on a posted vendor ledger entry is wrong when it is an open purchase invoice.';
        NoUnpostedCrMemoDuplicateErr: Label 'HasDuplicate did not report a duplicate although an unposted purchase credit memo for the same vendor already carries that Vendor Cr. Memo No.';
        UnpostedCrMemoReasonBlankErr: Label 'HasDuplicate reported an unposted credit-memo duplicate but left Reason blank.';
        CrMemoMatchedUnpostedInvoiceErr: Label 'HasDuplicate reported a duplicate although the only match is an unposted INVOICE and the incoming document is a CREDIT MEMO. They are not the same kind of document.';
        PayToVendorNotResolvedErr: Label 'HasDuplicate did not resolve the pay-to vendor. The sending vendor pays through another vendor, and that paying vendor already carries this document number.';
        PlainVendorLookupBrokenErr: Label 'HasDuplicate missed a duplicate for a vendor whose Pay-to Vendor No. is blank. Resolving pay-to must not break the ordinary case where the vendor pays for itself.';
        BlankDocNoMatchedErr: Label 'HasDuplicate reported a duplicate for a document whose number was never captured. A blank number matches every posted entry that also has none, so this rejects the documents most likely to be incomplete.';
        UnknownVendorMatchedErr: Label 'HasDuplicate reported a duplicate for a vendor number that does not exist. A missing vendor must exit, not fall through and look up the raw number.';
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

    [Test]
    procedure IgnoresPostedCreditMemoWhenDocumentIsInvoice()
    var
        TemplateFieldRule: Record "CDC Template Field Rule";
        DupRejectMgt: Codeunit "MDC Dup. Reject Mgt.";
        VendorNo: Code[20];
        ExternalDocNo: Code[35];
        Reason: Text[250];
        DuplicateFound: Boolean;
    begin
        // [SCENARIO] MON-113 v2: an invoice and a credit memo are not the same kind of
        // document, so the same number appearing on both is not a duplicate. Continia splits
        // on document type in both branches of its check and so must we.
        // Without the type filter an incoming invoice matches a posted credit memo carrying
        // that number for the same vendor - a false positive on an unrelated document.
        Initialize();

        // [GIVEN] A vendor with a posted CREDIT MEMO carrying an External Document No.
        VendorNo := CreateVendor();
        ExternalDocNo := AnyExternalDocNo();
        CreatePostedCreditMemoEntry(VendorNo, ExternalDocNo);

        // [WHEN] An INVOICE arrives from that vendor carrying the same document number
        DuplicateFound := DupRejectMgt.HasDuplicate(ExternalDocNo, TemplateFieldRule."Document Type"::Invoice, VendorNo, Reason);

        // [THEN] It is not a duplicate, and no reason is left behind
        Assert.IsFalse(DuplicateFound, DuplicateAcrossDocTypesErr);
        Assert.AreEqual('', Reason, ReasonNotBlankErr);
    end;

    [Test]
    procedure RejectsWhenPostedCreditMemoHasSameExtDocNo()
    var
        TemplateFieldRule: Record "CDC Template Field Rule";
        DupRejectMgt: Codeunit "MDC Dup. Reject Mgt.";
        VendorNo: Code[20];
        ExternalDocNo: Code[35];
        Reason: Text[250];
    begin
        // [SCENARIO] MON-113 v2: the credit-memo half of the same check. A credit memo whose
        // number already sits on a posted credit memo for that vendor IS a duplicate.
        // This is the guard against the type filter being written so tightly that credit memos
        // stop being checked at all.
        Initialize();

        // [GIVEN] A vendor with a posted credit memo carrying an External Document No.
        VendorNo := CreateVendor();
        ExternalDocNo := AnyExternalDocNo();
        CreatePostedCreditMemoEntry(VendorNo, ExternalDocNo);

        // [WHEN] A CREDIT MEMO arrives from that vendor carrying the same document number
        // [THEN] It is reported as a duplicate
        Assert.IsTrue(
            DupRejectMgt.HasDuplicate(ExternalDocNo, TemplateFieldRule."Document Type"::"Credit Memo", VendorNo, Reason),
            NoCreditMemoDuplicateErr);
    end;

    [Test]
    procedure TreatsPrepaymentAsAnInvoice()
    var
        CDCTemplateFieldRule: Record "CDC Template Field Rule";
        DupRejectMgt: Codeunit "MDC Dup. Reject Mgt.";
        VendorNo: Code[20];
        ExternalDocNo: Code[35];
        Reason: Text[250];
    begin
        // [SCENARIO] MON-113 v2: Continia puts Prepayment and Invoice in one case arm, so a
        // prepayment document is checked against posted INVOICE entries.
        // This pins that mapping. Nothing else in the suite would notice if Prepayment were
        // quietly dropped out of the arm and started being ignored.
        Initialize();

        // [GIVEN] A vendor with a posted invoice carrying an External Document No.
        VendorNo := CreateVendor();
        ExternalDocNo := AnyExternalDocNo();
        CreatePostedInvoiceEntry(VendorNo, ExternalDocNo);

        // [WHEN] A PREPAYMENT document arrives carrying that same document number
        // [THEN] It is reported as a duplicate, exactly as an invoice would be
        Assert.IsTrue(
            DupRejectMgt.HasDuplicate(ExternalDocNo, CDCTemplateFieldRule."Document Type"::Prepayment, VendorNo, Reason),
            PrepaymentNotAnInvoiceErr);
    end;

    [Test]
    procedure IgnoresDocumentTypesOutsideInvoiceAndCreditMemo()
    var
        CDCTemplateFieldRule: Record "CDC Template Field Rule";
        VendorNo: Code[20];
        ExternalDocNo: Code[35];
    begin
        // [SCENARIO] MON-113 v2: this pins our DELIBERATE DIVERGENCE from Continia. Continia's
        // case has no else arm, so Order, Receipt and " " leave its lookup unfiltered on type.
        // We exit instead - MON-113 covers invoices and credit memos only, and an unfiltered
        // type lookup is a false-positive source.
        // If someone later "corrects" our else arm to match Continia's fall-through, the
        // unfiltered lookup starts matching and this is the only test that would notice.
        Initialize();

        // [GIVEN] A vendor with a posted invoice carrying an External Document No.
        VendorNo := CreateVendor();
        ExternalDocNo := AnyExternalDocNo();
        CreatePostedInvoiceEntry(VendorNo, ExternalDocNo);

        // [WHEN] That same document number arrives under a type outside our scope
        // [THEN] It is never a duplicate, and no reason is left behind
        AssertNotDuplicateForType(ExternalDocNo, CDCTemplateFieldRule."Document Type"::"Order", VendorNo, OrderTypeTok);
        AssertNotDuplicateForType(ExternalDocNo, CDCTemplateFieldRule."Document Type"::Receipt, VendorNo, ReceiptTypeTok);
        AssertNotDuplicateForType(ExternalDocNo, CDCTemplateFieldRule."Document Type"::" ", VendorNo, BlankTypeTok);
    end;

    [Test]
    procedure RejectsWhenUnpostedInvoiceHasSameExtDocNo()
    var
        CDCTemplateFieldRule: Record "CDC Template Field Rule";
        DupRejectMgt: Codeunit "MDC Dup. Reject Mgt.";
        UnpostedVendorNo: Code[20];
        PostedVendorNo: Code[20];
        UnpostedDocNo: Code[35];
        PostedDocNo: Code[35];
        UnpostedReason: Text[250];
        PostedReason: Text[250];
    begin
        // [SCENARIO] MON-113 v2: Continia's SECOND check, and the half the ticket explicitly
        // asks for - the collision is with an OPEN purchase invoice nobody has posted yet, so
        // there is no Vendor Ledger Entry to find. Continia only reaches this check when the
        // posted lookup misses, and so must we.
        Initialize();

        // [GIVEN] A vendor with an unposted purchase invoice carrying a Vendor Invoice No.,
        // and deliberately NO posted entry - the posted lookup cannot be what answers this.
        UnpostedVendorNo := CreateVendor();
        UnpostedDocNo := AnyExternalDocNo();
        CreateUnpostedInvoice(UnpostedVendorNo, UnpostedDocNo);

        // [GIVEN] A separate vendor with a posted entry, to capture the posted wording
        PostedVendorNo := CreateVendor();
        PostedDocNo := AnyExternalDocNo();
        CreatePostedInvoiceEntry(PostedVendorNo, PostedDocNo);
        DupRejectMgt.HasDuplicate(PostedDocNo, CDCTemplateFieldRule."Document Type"::Invoice, PostedVendorNo, PostedReason);

        // [WHEN] That same vendor document number arrives again as an invoice
        // [THEN] It is a duplicate, and the reason says where it really is
        Assert.IsTrue(
            DupRejectMgt.HasDuplicate(UnpostedDocNo, CDCTemplateFieldRule."Document Type"::Invoice, UnpostedVendorNo, UnpostedReason),
            NoUnpostedDuplicateErr);
        Assert.AreNotEqual('', UnpostedReason, UnpostedReasonBlankErr);
        // Compared against the posted wording rather than against a hardcoded string, so the
        // test does not pin the Label text - only that the two paths cannot say the same thing.
        Assert.AreNotEqual(PostedReason, UnpostedReason, UnpostedReasonSameAsPostedErr);
    end;

    [Test]
    procedure RejectsWhenUnpostedCreditMemoHasSameExtDocNo()
    var
        CDCTemplateFieldRule: Record "CDC Template Field Rule";
        DupRejectMgt: Codeunit "MDC Dup. Reject Mgt.";
        VendorNo: Code[20];
        VendorDocNo: Code[35];
        Reason: Text[250];
        DuplicateFound: Boolean;
    begin
        // [SCENARIO] MON-113 v2: the credit-memo half of the unposted check. Continia filters
        // "Purchase Header" on "Vendor Cr. Memo No." for credit memos, a different field from
        // the invoice branch, so an invoice-only lookup never sees them.
        Initialize();

        // [GIVEN] A vendor with an unposted CREDIT MEMO carrying a Vendor Cr. Memo No.,
        // and no posted entry
        VendorNo := CreateVendor();
        VendorDocNo := AnyExternalDocNo();
        CreateUnpostedCreditMemo(VendorNo, VendorDocNo);

        // [WHEN] A CREDIT MEMO arrives from that vendor carrying the same document number
        DuplicateFound := DupRejectMgt.HasDuplicate(VendorDocNo, CDCTemplateFieldRule."Document Type"::"Credit Memo", VendorNo, Reason);

        // [THEN] It is a duplicate, and a reason is recorded
        Assert.IsTrue(DuplicateFound, NoUnpostedCrMemoDuplicateErr);
        Assert.AreNotEqual('', Reason, UnpostedCrMemoReasonBlankErr);
    end;

    [Test]
    procedure IgnoresUnpostedInvoiceWhenDocumentIsCreditMemo()
    var
        CDCTemplateFieldRule: Record "CDC Template Field Rule";
        DupRejectMgt: Codeunit "MDC Dup. Reject Mgt.";
        VendorNo: Code[20];
        VendorDocNo: Code[35];
        Reason: Text[250];
        DuplicateFound: Boolean;
    begin
        // [SCENARIO] MON-113 v2: closes the transient defect left open by cycle 5. A credit
        // memo passes the document-type gate, misses the ledger because that lookup correctly
        // filters on posted credit memos, then falls into an unposted lookup that searches
        // INVOICES - and matches. A legitimate credit memo auto-rejected because an unrelated
        // invoice happens to share the number.
        // This is the test that forces the credit-memo arm to be EXCLUSIVE rather than
        // additive. RejectsWhenUnpostedCreditMemoHasSameExtDocNo alone could be satisfied by
        // searching both document types indiscriminately.
        Initialize();

        // [GIVEN] A vendor with an unposted INVOICE carrying a Vendor Invoice No.,
        // and no posted entry
        VendorNo := CreateVendor();
        VendorDocNo := AnyExternalDocNo();
        CreateUnpostedInvoice(VendorNo, VendorDocNo);

        // [WHEN] A CREDIT MEMO arrives from that vendor carrying the same document number
        DuplicateFound := DupRejectMgt.HasDuplicate(VendorDocNo, CDCTemplateFieldRule."Document Type"::"Credit Memo", VendorNo, Reason);

        // [THEN] It is not a duplicate, and no reason is left behind
        Assert.IsFalse(DuplicateFound, CrMemoMatchedUnpostedInvoiceErr);
        Assert.AreEqual('', Reason, ReasonNotBlankErr);
    end;

    [Test]
    procedure ResolvesPayToVendorWhenLookingUpDuplicates()
    var
        CDCTemplateFieldRule: Record "CDC Template Field Rule";
        DupRejectMgt: Codeunit "MDC Dup. Reject Mgt.";
        SendingVendorNo: Code[20];
        PayingVendorNo: Code[20];
        ExternalDocNo: Code[35];
        Reason: Text[250];
    begin
        // [SCENARIO] MON-113 v2: a vendor paying through another vendor is a normal setup - a
        // subsidiary billing through its parent, or a factored receivable. Continia scopes the
        // duplicate check to the PAYING vendor, not to whoever sent the document.
        // Scoping it to the sender instead misses real duplicates: the same invoice arriving
        // from two subsidiaries of one parent settles against the same payable and the accounts
        // payable team considers it the same vendor.
        Initialize();

        // [GIVEN] Vendor A sends the documents but pays through vendor B
        PayingVendorNo := CreateVendor();
        SendingVendorNo := CreateVendorPayingThrough(PayingVendorNo);

        // [GIVEN] A posted invoice already carrying that document number, on the PAYING vendor
        ExternalDocNo := AnyExternalDocNo();
        CreatePostedInvoiceEntry(PayingVendorNo, ExternalDocNo);

        // [WHEN] The document arrives from the SENDING vendor with that same number
        // [THEN] It is a duplicate, because A pays through B and B already has it
        Assert.IsTrue(
            DupRejectMgt.HasDuplicate(ExternalDocNo, CDCTemplateFieldRule."Document Type"::Invoice, SendingVendorNo, Reason),
            PayToVendorNotResolvedErr);
    end;

    [Test]
    procedure UsesTheVendorItselfWhenNoPayToVendorIsSet()
    var
        CDCTemplateFieldRule: Record "CDC Template Field Rule";
        DupRejectMgt: Codeunit "MDC Dup. Reject Mgt.";
        VendorNo: Code[20];
        ExternalDocNo: Code[35];
        Reason: Text[250];
    begin
        // [SCENARIO] MON-113 v2: the other branch of Continia's resolution - a blank
        // "Pay-to Vendor No." means the vendor pays for itself, so the lookup uses its own
        // "No.". This is the ordinary case and covers almost every vendor.
        // It guards the obvious way to get pay-to resolution wrong: reading a blank pay-to and
        // filtering the lookup on '' , which would silently stop finding anything at all.
        Initialize();

        // [GIVEN] A vendor with no Pay-to Vendor No., carrying a posted invoice
        VendorNo := CreateVendor();
        ExternalDocNo := AnyExternalDocNo();
        CreatePostedInvoiceEntry(VendorNo, ExternalDocNo);

        // [WHEN] That same document number arrives again from that vendor
        // [THEN] It is a duplicate, found under the vendor's own number
        Assert.IsTrue(
            DupRejectMgt.HasDuplicate(ExternalDocNo, CDCTemplateFieldRule."Document Type"::Invoice, VendorNo, Reason),
            PlainVendorLookupBrokenErr);
    end;

    [Test]
    procedure IgnoresABlankDocumentNumber()
    var
        CDCTemplateFieldRule: Record "CDC Template Field Rule";
        DupRejectMgt: Codeunit "MDC Dup. Reject Mgt.";
        VendorNo: Code[20];
        Reason: Text[250];
        DuplicateFound: Boolean;
    begin
        // [SCENARIO] MON-113 v2: Continia gates its whole check on VendDocNo <> ''. Without
        // that guard a document whose number was never captured runs
        // SetRange("External Document No.", ''), which MATCHES every posted entry that also has
        // no external document number - and there are usually many. A mass false positive on
        // exactly the documents most likely to be incomplete.
        Initialize();

        // [GIVEN] A vendor with a posted invoice that itself carries NO external document no.
        // That blank entry is what makes this bite: without it the filter matches nothing and
        // the test would pass for the wrong reason.
        VendorNo := CreateVendor();
        CreatePostedInvoiceEntry(VendorNo, '');

        // [WHEN] A document arrives whose number was never captured
        DuplicateFound := DupRejectMgt.HasDuplicate('', CDCTemplateFieldRule."Document Type"::Invoice, VendorNo, Reason);

        // [THEN] It is not a duplicate, and no reason is left behind
        Assert.IsFalse(DuplicateFound, BlankDocNoMatchedErr);
        Assert.AreEqual('', Reason, ReasonNotBlankErr);
    end;

    [Test]
    procedure IgnoresAVendorThatDoesNotExist()
    var
        CDCTemplateFieldRule: Record "CDC Template Field Rule";
        DupRejectMgt: Codeunit "MDC Dup. Reject Mgt.";
        UnknownVendorNo: Code[20];
        ExternalDocNo: Code[35];
        Reason: Text[250];
        DuplicateFound: Boolean;
    begin
        // [SCENARIO] MON-113 v2: HasDuplicate resolves the pay-to vendor, so it must survive a
        // vendor number that no longer resolves. Two failure modes this pins:
        // 1. An unguarded Vendor.Get THROWS. Once wired, that error escapes our subscriber and
        //    kills Continia's whole validation - it would break OCR import, not just this doc.
        // 2. Treating a missing vendor as "pays for itself" and looking up the raw number,
        //    which is why the ledger entry below deliberately carries that very number.
        Initialize();

        // [GIVEN] A posted invoice filed under a vendor number that has no Vendor record
        UnknownVendorNo := AnyUnknownVendorNo();
        ExternalDocNo := AnyExternalDocNo();
        CreatePostedInvoiceEntry(UnknownVendorNo, ExternalDocNo);

        // [WHEN] A document arrives from that non-existent vendor with that same number
        DuplicateFound := DupRejectMgt.HasDuplicate(ExternalDocNo, CDCTemplateFieldRule."Document Type"::Invoice, UnknownVendorNo, Reason);

        // [THEN] It is not a duplicate, no reason is left behind, and nothing threw
        Assert.IsFalse(DuplicateFound, UnknownVendorMatchedErr);
        Assert.AreEqual('', Reason, ReasonNotBlankErr);
    end;

    local procedure Initialize()
    begin
        AnyLib.SetDefaultSeed();
        ClearTestDocuments();
        ClearTestVendors();
        ClearTestPurchaseHeaders();
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

    // Filters the ledger directly rather than looping vendors: IgnoresAVendorThatDoesNotExist
    // leaves an entry whose "Vendor No." has no Vendor record, and a vendor-driven loop would
    // never reach it.
    local procedure ClearTestVendors()
    var
        Vendor: Record Vendor;
        VendorLedgerEntry: Record "Vendor Ledger Entry";
    begin
        VendorLedgerEntry.SetFilter("Vendor No.", TestDocNoPrefixTok + '*');
        VendorLedgerEntry.DeleteAll(false);
        Vendor.SetFilter("No.", TestDocNoPrefixTok + '*');
        Vendor.DeleteAll(false);
    end;

    local procedure CreateVendor(): Code[20]
    begin
        exit(CreateVendorWithPayTo(''));
    end;

    // A vendor that sends the documents but is paid through another vendor - a subsidiary
    // billing through its parent, or a factored receivable.
    local procedure CreateVendorPayingThrough(PayToVendorNo: Code[20]): Code[20]
    begin
        exit(CreateVendorWithPayTo(PayToVendorNo));
    end;

    local procedure CreateVendorWithPayTo(PayToVendorNo: Code[20]): Code[20]
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
        Vendor."Pay-to Vendor No." := PayToVendorNo;
        Vendor.Insert(false);
        exit(Candidate);
    end;

    // A posted invoice, as Continia's first check sees it: a Vendor Ledger Entry of type
    // Invoice carrying the External Document No. for that vendor.
    local procedure CreatePostedInvoiceEntry(VendorNo: Code[20]; ExternalDocNo: Code[35])
    begin
        CreatePostedEntry(VendorNo, ExternalDocNo, "Gen. Journal Document Type"::Invoice);
    end;

    local procedure CreatePostedCreditMemoEntry(VendorNo: Code[20]; ExternalDocNo: Code[35])
    begin
        CreatePostedEntry(VendorNo, ExternalDocNo, "Gen. Journal Document Type"::"Credit Memo");
    end;

    // "Vendor Ledger Entry"."Document Type" is an Enum, not an Option, so the type can be a
    // real parameter here - no restating of member names, unlike AddComment's Option field.
    local procedure CreatePostedEntry(VendorNo: Code[20]; ExternalDocNo: Code[35]; DocumentType: Enum "Gen. Journal Document Type")
    var
        VendorLedgerEntry: Record "Vendor Ledger Entry";
    begin
        VendorLedgerEntry.Init();
        VendorLedgerEntry."Entry No." := NextVendorLedgerEntryNo();
        VendorLedgerEntry."Vendor No." := VendorNo;
        VendorLedgerEntry."Document Type" := DocumentType;
        VendorLedgerEntry."Document No." := CopyStr(TestDocNoPrefixTok + '-PPI', 1, MaxStrLen(VendorLedgerEntry."Document No."));
        VendorLedgerEntry."External Document No." := ExternalDocNo;
        VendorLedgerEntry."Posting Date" := WorkDate();
        VendorLedgerEntry."Document Date" := WorkDate();
        VendorLedgerEntry.Insert(false);
    end;

    // One call plus both assertions, so a failure names which document type leaked instead of
    // just saying "false expected".
    local procedure AssertNotDuplicateForType(ExternalDocNo: Code[35]; DocumentType: Integer; VendorNo: Code[20]; TypeName: Text)
    var
        DupRejectMgt: Codeunit "MDC Dup. Reject Mgt.";
        Reason: Text[250];
        DuplicateFound: Boolean;
    begin
        DuplicateFound := DupRejectMgt.HasDuplicate(ExternalDocNo, DocumentType, VendorNo, Reason);
        Assert.IsFalse(DuplicateFound, StrSubstNo(TypeLeakedErr, TypeName));
        Assert.AreEqual('', Reason, StrSubstNo(ReasonLeftForTypeErr, TypeName));
    end;

    local procedure ClearTestPurchaseHeaders()
    var
        PurchaseHeader: Record "Purchase Header";
    begin
        PurchaseHeader.SetFilter("No.", TestDocNoPrefixTok + '*');
        PurchaseHeader.DeleteAll(false);
    end;

    // An open purchase invoice that has NOT been posted, so nothing exists in Vendor Ledger
    // Entry. "Purchase Header" has an OnInsert trigger that pulls a number from No. Series, so
    // "No." is set here and Insert(false) skips the trigger.
    local procedure CreateUnpostedInvoice(PayToVendorNo: Code[20]; VendorInvoiceNo: Code[35])
    begin
        CreateUnpostedPurchaseDoc(PayToVendorNo, VendorInvoiceNo, "Purchase Document Type"::Invoice);
    end;

    local procedure CreateUnpostedCreditMemo(PayToVendorNo: Code[20]; VendorCrMemoNo: Code[35])
    begin
        CreateUnpostedPurchaseDoc(PayToVendorNo, VendorCrMemoNo, "Purchase Document Type"::"Credit Memo");
    end;

    // "Purchase Header"."Document Type" is an Enum, so the type is a real parameter here - same
    // reasoning as CreatePostedEntry, no restating of member names.
    // The vendor's own document number lives in a DIFFERENT FIELD per type, which is exactly
    // the split Continia filters on: invoices use "Vendor Invoice No.", credit memos use
    // "Vendor Cr. Memo No.".
    local procedure CreateUnpostedPurchaseDoc(PayToVendorNo: Code[20]; VendorDocNo: Code[35]; DocumentType: Enum "Purchase Document Type")
    var
        PurchaseHeader: Record "Purchase Header";
    begin
        PurchaseHeader.Init();
        PurchaseHeader."Document Type" := DocumentType;
        PurchaseHeader."No." := AnyPurchaseHeaderNo(DocumentType);
        PurchaseHeader."Buy-from Vendor No." := PayToVendorNo;
        PurchaseHeader."Pay-to Vendor No." := PayToVendorNo;
        if DocumentType = DocumentType::"Credit Memo" then
            PurchaseHeader."Vendor Cr. Memo No." := VendorDocNo
        else
            PurchaseHeader."Vendor Invoice No." := VendorDocNo;
        PurchaseHeader.Insert(false);
    end;

    local procedure AnyPurchaseHeaderNo(DocumentType: Enum "Purchase Document Type"): Code[20]
    var
        PurchaseHeader: Record "Purchase Header";
        Candidate: Code[20];
    begin
        repeat
            Candidate := CopyStr(TestDocNoPrefixTok + AnyLib.AlphanumericText(10), 1, MaxStrLen(Candidate));
        until not PurchaseHeader.Get(DocumentType, Candidate);
        exit(Candidate);
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

    // A vendor number that deliberately has NO Vendor record, for the missing-vendor path.
    local procedure AnyUnknownVendorNo(): Code[20]
    var
        Vendor: Record Vendor;
        Candidate: Code[20];
    begin
        repeat
            Candidate := CopyStr(TestDocNoPrefixTok + AnyLib.AlphanumericText(10), 1, MaxStrLen(Candidate));
        until not Vendor.Get(Candidate);
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
