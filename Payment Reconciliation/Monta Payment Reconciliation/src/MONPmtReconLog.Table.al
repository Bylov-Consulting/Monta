table 50203 "MON Pmt Recon Log"
{
    // Persistent idempotency ledger for the agent-facing composite PostAndReconcile call. The reconciliation
    // line identity — (Bank Account No., Statement No., Statement Line No.) — IS the idempotency key: a
    // statement line can be reconciled exactly once. A row is written only after a successful post+match, so
    // a later call for the SAME line either replays the cached result (identical "Request Hash") or is
    // rejected as a conflict (different "Request Hash"). NOT temporary: the row must survive the call so a
    // replay/conflict on a subsequent call sees it.
    Access = Internal;
    Caption = 'MON Payment Reconciliation Log';
    DataClassification = CustomerContent;

    fields
    {
        field(1; "Bank Account No."; Code[20])
        {
            Caption = 'Bank Account No.';
            DataClassification = CustomerContent;
        }
        field(2; "Statement No."; Code[20])
        {
            Caption = 'Statement No.';
            DataClassification = CustomerContent;
        }
        field(3; "Statement Line No."; Integer)
        {
            Caption = 'Statement Line No.';
            DataClassification = CustomerContent;
        }
        field(10; "Status"; Option)
        {
            Caption = 'Status';
            DataClassification = SystemMetadata;
            // Posted = the line was reconciled by a completed post+match. Failed is reserved for slice 8
            // (failure audit) and carries no behaviour in slice 7.
            OptionMembers = "Posted","Failed";
            OptionCaption = 'Posted,Failed';
        }
        field(11; "Request Hash"; Code[64])
        {
            Caption = 'Request Hash';
            DataClassification = SystemMetadata;
            // SHA256 hex digest (64 chars) of the request that reconciled this line. Equal hash on a later
            // call -> idempotent replay; different hash for the same line -> conflict.
        }
        field(20; "Bank Acc. Ledger Entry No."; Integer)
        {
            Caption = 'Bank Acc. Ledger Entry No.';
            DataClassification = CustomerContent;
            // The open Bank Account Ledger Entry the original call created; returned verbatim on replay.
        }
        field(21; "Payment Document No."; Code[20])
        {
            Caption = 'Payment Document No.';
            DataClassification = CustomerContent;
            // Document No. of the posted bank receipt (for traceability); not used by the replay path.
        }
    }

    keys
    {
        key(PK; "Bank Account No.", "Statement No.", "Statement Line No.")
        {
            Clustered = true;
        }
    }
}
