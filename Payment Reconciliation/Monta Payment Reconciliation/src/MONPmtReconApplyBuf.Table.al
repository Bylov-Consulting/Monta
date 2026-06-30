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
