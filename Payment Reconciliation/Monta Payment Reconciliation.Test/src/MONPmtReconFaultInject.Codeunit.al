codeunit 50304 "MON Pmt Recon Fault Inject"
{
    // Test-only fault injector. Stands in for a concurrent application or a third-party
    // subscriber that interferes with the base-app "Applies-to ID" stamping mechanism used by
    // "MON Pmt Recon Post". Not a SingleInstance codeunit: each test declares its own local
    // instance, sets the flag(s) it needs, and binds/unbinds it around exactly the one post it
    // is probing, so tests never leak fault state into each other.
    EventSubscriberInstance = Manual;

    var
        SuppressStamp: Boolean;

    /// <summary>
    /// Controls whether <see cref="OnBeforeSetApplId"/> suppresses the base-app "Applies-to ID"
    /// stamp for the next call. Must be set before binding this instance with BindSubscription.
    /// </summary>
    /// <param name="Suppress">true to suppress the stamp; false to leave the base-app behavior untouched.</param>
    procedure SetSuppressStamp(Suppress: Boolean)
    begin
        SuppressStamp := Suppress;
    end;

    [EventSubscriber(ObjectType::Codeunit, Codeunit::"Cust. Entry-SetAppl.ID", 'OnBeforeSetApplId', '', false, false)]
    local procedure OnBeforeSetApplId(var CustLedgEntry: Record "Cust. Ledger Entry"; ApplyingCustLedgEntry: Record "Cust. Ledger Entry"; var AppliesToID: Code[50]; var CustEntryApplID: Code[50]; var IsHandled: Boolean)
    begin
        if not SuppressStamp then
            exit;
        // GREEN wires IsHandled := true
    end;
}
