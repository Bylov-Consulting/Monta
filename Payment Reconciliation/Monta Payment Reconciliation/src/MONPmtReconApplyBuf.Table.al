table 50200 "MON Pmt Recon Apply Buf"
{
    // Internal, temporary-only buffer that flattens an incoming multi-customer payment into one row
    // per (customer, invoice, amount-to-apply). It is the per-customer structure the unified balanced
    // poster ("MON Pmt Recon Post".PostCustomerPaymentsToBank) consumes: it is iterated grouped by
    // "Customer No." (key ByCustomer) so each customer becomes one Gen. Journal payment line with its
    // own Applies-to ID, and the running total across all rows is the single bank line amount.
    TableType = Temporary;
    Access = Internal;
    Caption = 'MON Pmt Recon Apply Buffer';
    DataClassification = CustomerContent;

    fields
    {
        field(1; "Entry No."; Integer)
        {
            Caption = 'Entry No.';
            // Insertion sequence; primary key only. Distinct from "Cust. Ledger Entry No." so two
            // customers (or future partial applies) never collide on the primary key.
        }
        field(2; "Customer No."; Code[20])
        {
            Caption = 'Customer No.';
            TableRelation = Customer;
        }
        field(3; "Cust. Ledger Entry No."; Integer)
        {
            Caption = 'Cust. Ledger Entry No.';
            TableRelation = "Cust. Ledger Entry";
        }
        field(4; "Amount to Apply"; Decimal)
        {
            Caption = 'Amount to Apply';
            // For a Customer Apply row: the amount applied to "Cust. Ledger Entry No.".
            // For a Write-Off row: the difference amount W posted to "G/L Account No." (debit).
        }
        field(5; "Line Type"; Option)
        {
            Caption = 'Line Type';
            // Discriminates the two kinds of rows the unified poster consumes. Customer Apply rows are
            // grouped per customer into one negative payment line each; Write-Off rows each become one
            // positive G/L line. Default 0 = Customer Apply keeps every pre-slice-6 row a customer apply.
            OptionMembers = "Customer Apply","Write-Off";
            OptionCaption = 'Customer Apply,Write-Off';
        }
        field(6; "G/L Account No."; Code[20])
        {
            Caption = 'G/L Account No.';
            // Only populated on a Write-Off row: the agent-nominated G/L account the payment difference
            // is debited to. Blank on Customer Apply rows.
            TableRelation = "G/L Account";
        }
    }

    keys
    {
        key(PK; "Entry No.")
        {
            Clustered = true;
        }
        key(ByCustomer; "Customer No.", "Cust. Ledger Entry No.")
        {
        }
    }
}
