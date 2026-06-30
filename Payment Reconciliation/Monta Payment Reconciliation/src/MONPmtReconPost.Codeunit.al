codeunit 50200 "MON Pmt Recon Post"
{
    Access = Public;

    var
        PaymentAmountErr: Label 'The payment amount must be greater than zero.';
        NoAppliesEntriesErr: Label 'At least one customer ledger entry must be supplied for the payment.';
        BankEntryNotFoundErr: Label 'The payment posting did not create the expected Bank Account Ledger Entry.';
        BankEntryNotFoundDetailTxt: Label 'No Bank Account Ledger Entry was created on bank account %1 for document %2 after posting the customer payment.', Comment = '%1 = Bank Account No., %2 = Document No.';
        ClosedEntryErr: Label 'Customer ledger entry %1 is closed and cannot be settled by this payment.', Comment = '%1 = Cust. Ledger Entry No.';
        CustomerMismatchErr: Label 'Customer ledger entry %1 does not belong to customer %2.', Comment = '%1 = Cust. Ledger Entry No., %2 = Customer No.';

    /// <summary>
    /// Posts an incoming customer payment that balances to a Bank Account — creating a Bank
    /// Account Ledger Entry, which the standard customerPayments API cannot do — applied to
    /// the given open customer ledger entry, and returns the resulting Bank Account Ledger
    /// Entry No. The entry is left open so it can subsequently be reconciled.
    ///
    /// Single-invoice convenience overload: delegates to <see cref="PostCustomerPaymentToBankMulti"/>
    /// with exactly one (entry, amount) pair, so there is ONE posting implementation.
    /// </summary>
    /// <param name="CustomerNo">The customer whose payment is being posted.</param>
    /// <param name="BankAccountNo">The bank account the payment is received into; the balancing entry is posted here.</param>
    /// <param name="PaymentAmount">The received amount; must be greater than zero.</param>
    /// <param name="AppliesToCustLedgerEntryNo">Entry No. of the open customer ledger entry (invoice) the payment settles in full.</param>
    /// <param name="GenJnlTemplateName">General journal template used to post the payment.</param>
    /// <param name="GenJnlBatchName">General journal batch (within the template) used to post the payment.</param>
    /// <param name="ExternalDocumentNo">Optional external document reference stamped on the payment line.</param>
    /// <returns>The Entry No. of the Bank Account Ledger Entry created by the posting (left open for reconciliation).</returns>
    [CommitBehavior(CommitBehavior::Ignore)]
    procedure PostCustomerPaymentToBank(CustomerNo: Code[20]; BankAccountNo: Code[20]; PaymentAmount: Decimal; AppliesToCustLedgerEntryNo: Integer; GenJnlTemplateName: Code[10]; GenJnlBatchName: Code[10]; ExternalDocumentNo: Code[35]): Integer
    var
        AppliesToEntries: Dictionary of [Integer, Decimal];
    begin
        // One posting path: wrap the single application as a one-element set and delegate.
        AppliesToEntries.Add(AppliesToCustLedgerEntryNo, PaymentAmount);
        exit(
            this.PostCustomerPaymentToBankMulti(
                CustomerNo, BankAccountNo, AppliesToEntries,
                GenJnlTemplateName, GenJnlBatchName, ExternalDocumentNo));
    end;

    /// <summary>
    /// Posts ONE incoming customer payment that settles MULTIPLE open customer ledger entries
    /// (invoices) of the SAME customer in a single balanced posting, yielding exactly ONE Bank
    /// Account Ledger Entry for the whole receipt (left open for reconciliation).
    ///
    /// Single-customer convenience overload: flattens the (entry -> amount) map into the per-customer
    /// buffer with one Customer No. and delegates to <see cref="PostCustomerPaymentsToBank"/>, so the
    /// single-customer and multi-customer paths share ONE posting implementation.
    /// </summary>
    /// <param name="CustomerNo">The customer whose payment is being posted.</param>
    /// <param name="BankAccountNo">The bank account the payment is received into; the balancing entry is posted here.</param>
    /// <param name="AppliesToEntries">Map of open Cust. Ledger Entry No. -> the amount (> 0) to apply to it. Each entry must belong to CustomerNo and be open.</param>
    /// <param name="GenJnlTemplateName">General journal template used to post the payment.</param>
    /// <param name="GenJnlBatchName">General journal batch (within the template) used to post the payment.</param>
    /// <param name="ExternalDocumentNo">Optional external document reference stamped on the payment line.</param>
    /// <returns>The Entry No. of the single Bank Account Ledger Entry created by the posting (left open for reconciliation).</returns>
    [CommitBehavior(CommitBehavior::Ignore)]
    procedure PostCustomerPaymentToBankMulti(CustomerNo: Code[20]; BankAccountNo: Code[20]; AppliesToEntries: Dictionary of [Integer, Decimal]; GenJnlTemplateName: Code[10]; GenJnlBatchName: Code[10]; ExternalDocumentNo: Code[35]): Integer
    var
        TempApplyBuffer: Record "MON Pmt Recon Apply Buf" temporary;
        EntryNo: Integer;
        BufLineNo: Integer;
    begin
        // One-customer wrapper over the unified multi-customer poster: every (entry -> amount) pair maps
        // to a buffer row under the SAME Customer No., so the unified builder produces exactly one
        // customer payment line for them all.
        foreach EntryNo in AppliesToEntries.Keys do begin
            BufLineNo += 1;
            TempApplyBuffer.Init();
            TempApplyBuffer."Entry No." := BufLineNo;
            TempApplyBuffer."Customer No." := CustomerNo;
            TempApplyBuffer."Cust. Ledger Entry No." := EntryNo;
            TempApplyBuffer."Amount to Apply" := AppliesToEntries.Get(EntryNo);
            TempApplyBuffer.Insert();
        end;

        exit(
            this.PostCustomerPaymentsToBank(
                TempApplyBuffer, BankAccountNo, GenJnlTemplateName, GenJnlBatchName, ExternalDocumentNo));
    end;

    /// <summary>
    /// Unified balanced poster: settles open invoices belonging to ONE OR MORE customers from a single
    /// incoming bank receipt, in ONE balanced Gen. Journal document, yielding exactly ONE Bank Account
    /// Ledger Entry for the grand total (left open for reconciliation).
    ///
    /// The document is built as: for EACH customer one Gen. Journal payment line carrying the NEGATIVE
    /// of that customer's total, stamped with that customer's OWN distinct Applies-to ID (so only that
    /// customer's invoices are settled by that leg) and with NO balancing account; plus ONE final Bank
    /// Account line carrying the POSITIVE grand total with no applies and no balancing account. The N
    /// customer credits (-totals) and the one bank debit (+grandTotal) net to zero, so the document
    /// balances. All lines share one Document No. / Posting Date and are posted through a SINGLE
    /// "Gen. Jnl.-Post Line" instance in ascending Line No. order: the instance accumulates the running
    /// balance across the lines exactly as base-app codeunit 13 "Gen. Jnl.-Post Batch" does, and the
    /// single Bank Account line produces exactly ONE Bank Account Ledger Entry for the grand total.
    /// No intermediate Commit — the whole document (and the caller's subsequent match) is one atomic
    /// transaction; the standard consistency check fires only at the outer commit, by which point the
    /// document is balanced.
    /// </summary>
    /// <param name="TempApplyBuffer">Temporary buffer with one row per (Customer No., Cust. Ledger Entry No., Amount to Apply). Each amount must be > 0 and each entry must be open and belong to its row's customer.</param>
    /// <param name="BankAccountNo">The bank account the payment is received into; the single bank line is posted here.</param>
    /// <param name="GenJnlTemplateName">General journal template used to post the payment.</param>
    /// <param name="GenJnlBatchName">General journal batch (within the template) used to post the payment.</param>
    /// <param name="ExternalDocumentNo">Optional external document reference stamped on the payment lines.</param>
    /// <returns>The Entry No. of the single Bank Account Ledger Entry created by the posting (left open for reconciliation).</returns>
    [CommitBehavior(CommitBehavior::Ignore)]
    internal procedure PostCustomerPaymentsToBank(var TempApplyBuffer: Record "MON Pmt Recon Apply Buf" temporary; BankAccountNo: Code[20]; GenJnlTemplateName: Code[10]; GenJnlBatchName: Code[10]; ExternalDocumentNo: Code[35]): Integer
    var
        GenJournalTemplate: Record "Gen. Journal Template";
        GenJournalBatch: Record "Gen. Journal Batch";
        GenJournalLine: Record "Gen. Journal Line";
        BankAccountLedgerEntry: Record "Bank Account Ledger Entry";
        GenJnlPostLine: Codeunit "Gen. Jnl.-Post Line";
        ErrInfo: ErrorInfo;
        GrandTotal: Decimal;
        CustomerTotal: Decimal;
        DocumentNo: Code[20];
        AppliesToID: Code[50];
        LineNo: Integer;
        CustomerSeq: Integer;
        LastBankEntryNo: Integer;
    begin
        this.ValidateRequest(TempApplyBuffer, BankAccountNo, GenJnlTemplateName, GenJnlBatchName);

        GenJournalTemplate.SetLoadFields("Source Code");
        GenJournalTemplate.Get(GenJnlTemplateName);
        GenJournalBatch.SetLoadFields("No. Series");
        GenJournalBatch.Get(GenJnlTemplateName, GenJnlBatchName);

        // One Document No. for the whole balanced payment document; the grand total drives the bank line.
        DocumentNo := this.DetermineDocumentNo(GenJournalBatch, this.FirstCustLedgerEntryNo(TempApplyBuffer));
        GrandTotal := this.SumBuffer(TempApplyBuffer);

        // Snapshot the latest existing bank ledger entry so the entry created by this posting can be
        // identified by Entry No. — robust against any Document No. reuse across earlier committed
        // entries (a Document No. filter is not collision-proof).
        BankAccountLedgerEntry.SetRange("Bank Account No.", BankAccountNo);
        BankAccountLedgerEntry.SetLoadFields("Entry No.");
        if BankAccountLedgerEntry.FindLast() then
            LastBankEntryNo := BankAccountLedgerEntry."Entry No.";

        // --- One customer payment line per customer, grouped by Customer No. ---
        LineNo := 0;
        CustomerSeq := 0;
        TempApplyBuffer.Reset();
        TempApplyBuffer.SetCurrentKey("Customer No.", "Cust. Ledger Entry No.");
        TempApplyBuffer.FindSet();
        repeat
            // Narrow to the current customer's rows and process them as one group.
            TempApplyBuffer.SetRange("Customer No.", TempApplyBuffer."Customer No.");
            CustomerSeq += 1;
            CustomerTotal := 0;

            // A DISTINCT Applies-to ID per customer (<= Code[50]); only this customer's invoices are
            // stamped with it, so this customer's payment leg settles exactly its own entries.
            AppliesToID := this.MakeAppliesToID(DocumentNo, CustomerSeq);
            repeat
                this.MarkInvoiceForApplication(
                    TempApplyBuffer."Cust. Ledger Entry No.", TempApplyBuffer."Amount to Apply", AppliesToID);
                CustomerTotal += TempApplyBuffer."Amount to Apply";
            until TempApplyBuffer.Next() = 0;

            // The customer leg: negative total (a credit settling the positive invoices), NO bal account
            // (it balances against the single bank line at the end of the document).
            LineNo += 10000;
            GenJournalLine.Init();
            GenJournalLine.Validate("Journal Template Name", GenJournalTemplate.Name);
            GenJournalLine.Validate("Journal Batch Name", GenJournalBatch.Name);
            GenJournalLine."Line No." := LineNo;
            GenJournalLine.Validate("Posting Date", WorkDate());
            GenJournalLine.Validate("Document Type", GenJournalLine."Document Type"::Payment);
            GenJournalLine.Validate("Document No.", DocumentNo);
            GenJournalLine.Validate("Account Type", GenJournalLine."Account Type"::Customer);
            GenJournalLine.Validate("Account No.", TempApplyBuffer."Customer No.");
            GenJournalLine.Validate(Amount, -CustomerTotal);
            if ExternalDocumentNo <> '' then
                GenJournalLine.Validate("External Document No.", ExternalDocumentNo);
            GenJournalLine."Source Code" := GenJournalTemplate."Source Code";
            GenJournalLine."Applies-to ID" := AppliesToID;
            GenJnlPostLine.Run(GenJournalLine);

            // Re-widen the filter and advance to the first row of the next customer (or end the loop).
            TempApplyBuffer.SetRange("Customer No.");
        until TempApplyBuffer.Next() = 0;

        // --- The single bank line: positive grand total, NO applies, NO bal account -> ONE bank entry ---
        LineNo += 10000;
        GenJournalLine.Init();
        GenJournalLine.Validate("Journal Template Name", GenJournalTemplate.Name);
        GenJournalLine.Validate("Journal Batch Name", GenJournalBatch.Name);
        GenJournalLine."Line No." := LineNo;
        GenJournalLine.Validate("Posting Date", WorkDate());
        GenJournalLine.Validate("Document Type", GenJournalLine."Document Type"::Payment);
        GenJournalLine.Validate("Document No.", DocumentNo);
        GenJournalLine.Validate("Account Type", GenJournalLine."Account Type"::"Bank Account");
        GenJournalLine.Validate("Account No.", BankAccountNo);
        GenJournalLine.Validate(Amount, GrandTotal);
        if ExternalDocumentNo <> '' then
            GenJournalLine.Validate("External Document No.", ExternalDocumentNo);
        GenJournalLine."Source Code" := GenJournalTemplate."Source Code";

        // Single transaction — no intermediate Commit. The orchestrator's real-container test verifies
        // the actual posting behaviour.
        GenJnlPostLine.Run(GenJournalLine);

        // The receipt is the new entry on this bank account beyond the pre-post snapshot. Exactly one
        // bank line was posted, so exactly one bank ledger entry sits above the snapshot.
        BankAccountLedgerEntry.Reset();
        BankAccountLedgerEntry.SetRange("Bank Account No.", BankAccountNo);
        BankAccountLedgerEntry.SetFilter("Entry No.", '>%1', LastBankEntryNo);
        BankAccountLedgerEntry.SetLoadFields("Entry No.");
        if not BankAccountLedgerEntry.FindFirst() then begin
            // Impossible-invariant: posting succeeded but produced no bank entry. Not user-recoverable —
            // classify Internal so the platform shows a generic dialog and the detail goes to telemetry.
            ErrInfo := ErrorInfo.Create(BankEntryNotFoundErr);
            ErrInfo.ErrorType := ErrorType::Internal;
            ErrInfo.DetailedMessage := StrSubstNo(BankEntryNotFoundDetailTxt, BankAccountNo, DocumentNo);
            Error(ErrInfo);
        end;
        exit(BankAccountLedgerEntry."Entry No.");
    end;

    local procedure MarkInvoiceForApplication(CustLedgerEntryNo: Integer; AmountToApply: Decimal; AppliesToID: Code[50])
    var
        CustLedgerEntry: Record "Cust. Ledger Entry";
        ApplyingCustLedgerEntry: Record "Cust. Ledger Entry";
        CustEntrySetApplID: Codeunit "Cust. Entry-SetAppl.ID";
        CustEntryEdit: Codeunit "Cust. Entry-Edit";
    begin
        // Stamp the customer's Applies-to ID on this entry via the standard mechanism. ApplyingCustLedgerEntry
        // is left blank (Entry No. = 0): no partial-apply origin, so SetApplId also defaults "Amount to
        // Apply" to the full remaining amount.
        CustLedgerEntry.Get(CustLedgerEntryNo);
        CustLedgerEntry.SetRecFilter();
        CustEntrySetApplID.SetApplId(CustLedgerEntry, ApplyingCustLedgerEntry, AppliesToID);

        // Persist the EXACT supplied "Amount to Apply" for this entry the standard way (codeunit 103),
        // so multi/partial applies settle the precise amount, not just the full remaining. Re-Get to
        // carry the Applies-to ID SetApplId just stamped (Cust. Entry-Edit re-writes "Applies-to ID"
        // from Rec); only "Amount to Apply" actually changes.
        CustLedgerEntry.Get(CustLedgerEntryNo);
        CustLedgerEntry.Validate("Amount to Apply", AmountToApply);
        CustEntryEdit.Run(CustLedgerEntry);
    end;

    local procedure DetermineDocumentNo(GenJournalBatch: Record "Gen. Journal Batch"; SeedCustLedgerEntryNo: Integer) DocumentNo: Code[20]
    var
        NoSeries: Codeunit "No. Series";
    begin
        // Respect the batch's No. Series when one is configured; otherwise assign a deterministic
        // document number derived from a representative applied ledger entry.
        if GenJournalBatch."No. Series" <> '' then
            exit(NoSeries.GetNextNo(GenJournalBatch."No. Series", WorkDate()));
        exit(CopyStr('MONPMT' + Format(SeedCustLedgerEntryNo), 1, MaxStrLen(DocumentNo)));
    end;

    local procedure MakeAppliesToID(DocumentNo: Code[20]; CustomerSeq: Integer): Code[50]
    begin
        // Distinct per-customer Applies-to ID derived from the shared Document No. plus the customer's
        // 1-based sequence in the document. Bounded to Code[50] (DocumentNo is Code[20] + '-' + digits).
        exit(CopyStr(DocumentNo + '-' + Format(CustomerSeq), 1, 50));
    end;

    local procedure FirstCustLedgerEntryNo(var TempApplyBuffer: Record "MON Pmt Recon Apply Buf" temporary): Integer
    begin
        TempApplyBuffer.Reset();
        TempApplyBuffer.FindFirst();
        exit(TempApplyBuffer."Cust. Ledger Entry No.");
    end;

    local procedure SumBuffer(var TempApplyBuffer: Record "MON Pmt Recon Apply Buf" temporary) Total: Decimal
    begin
        TempApplyBuffer.Reset();
        if TempApplyBuffer.FindSet() then
            repeat
                Total += TempApplyBuffer."Amount to Apply";
            until TempApplyBuffer.Next() = 0;
    end;

    local procedure ValidateRequest(var TempApplyBuffer: Record "MON Pmt Recon Apply Buf" temporary; BankAccountNo: Code[20]; GenJnlTemplateName: Code[10]; GenJnlBatchName: Code[10])
    var
        Customer: Record Customer;
        BankAccount: Record "Bank Account";
        CustLedgerEntry: Record "Cust. Ledger Entry";
        GenJournalBatch: Record "Gen. Journal Batch";
    begin
        // Cheap guard first — nothing to post.
        TempApplyBuffer.Reset();
        if TempApplyBuffer.IsEmpty() then
            Error(NoAppliesEntriesErr);

        BankAccount.SetLoadFields("No.");
        BankAccount.Get(BankAccountNo);
        GenJournalBatch.SetLoadFields("Name");
        GenJournalBatch.Get(GenJnlTemplateName, GenJnlBatchName);

        // The amount-positive, customer-exists, customer-owns-entry and entry-open guards apply to EVERY
        // target row regardless of which customer it belongs to.
        TempApplyBuffer.FindSet();
        repeat
            if TempApplyBuffer."Amount to Apply" <= 0 then
                Error(PaymentAmountErr);

            Customer.SetLoadFields("No.");
            Customer.Get(TempApplyBuffer."Customer No.");

            CustLedgerEntry.SetLoadFields("Customer No.", Open);
            CustLedgerEntry.Get(TempApplyBuffer."Cust. Ledger Entry No.");
            if CustLedgerEntry."Customer No." <> TempApplyBuffer."Customer No." then
                Error(CustomerMismatchErr, TempApplyBuffer."Cust. Ledger Entry No.", TempApplyBuffer."Customer No.");
            if not CustLedgerEntry.Open then
                Error(ClosedEntryErr, TempApplyBuffer."Cust. Ledger Entry No.");
        until TempApplyBuffer.Next() = 0;
    end;
}
