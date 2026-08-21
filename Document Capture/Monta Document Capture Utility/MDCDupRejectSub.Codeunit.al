codeunit 50107 "MDC Dup. Reject Sub."
{
    Access = Internal;

    // Continia publishes no event for "a duplicate was detected" - the duplicate is written as
    // a Message Center comment on the document. So we let validation finish and then read the
    // comments it wrote. Every guard lives in "MDC Dup. Reject Mgt." where the tests reach it;
    // this subscriber stays a single call on purpose.
    [EventSubscriber(ObjectType::Codeunit, Codeunit::"CDC Purch. - Validation", 'OnAfterValidateDocument', '', false, false)]
    local procedure AutoRejectOnDuplicate(var Document: Record "CDC Document"; var IsInvalid: Boolean)
    var
        DupRejectMgt: Codeunit "MDC Dup. Reject Mgt.";
    begin
        // IsInvalid is deliberately not set. We reject the document; we are not telling
        // Continia that its validation failed.
        DupRejectMgt.RejectIfDuplicate(Document);
    end;
}
