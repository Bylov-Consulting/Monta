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
        EntryReservedErr: Label 'Customer ledger entry %1 is already reserved for application (an applied but unposted journal line, or another open application). Remove that application before posting this payment.', Comment = '%1 = Cust. Ledger Entry No.';
        EntryReservedDetailTxt: Label 'Reserved by Applies-to ID ''%1''.', Comment = '%1 = the Applies-to ID already on the entry';
        ApplyIdNotStampedErr: Label 'Customer ledger entry %1 could not be reserved for this payment. Nothing was posted.', Comment = '%1 = Cust. Ledger Entry No.';
        ApplyIdNotStampedDetailTxt: Label 'Expected Applies-to ID ''%1'' but the entry carries ''%2''.', Comment = '%1 = the Applies-to ID this payment stamps, %2 = the Applies-to ID actually on the entry';
        AmountToApplyNotSetErr: Label 'Customer ledger entry %1 could not be set to apply %2. Nothing was posted.', Comment = '%1 = Cust. Ledger Entry No., %2 = the requested Amount to Apply';
        AmountToApplyNotSetDetailTxt: Label 'The entry carries Amount to Apply %1 instead of the requested %2.', Comment = '%1 = the Amount to Apply actually on the entry, %2 = the requested Amount to Apply';
        InvalidBankAmountErr: Label 'The total write-off amount (%1) must be less than the total applied amount (%2).', Comment = '%1 = write-off total, %2 = applied total';
        MissingNoSeriesErr: Label 'General journal batch %1/%2 has no No. Series. Configure a No. Series on the batch so payment documents draw controlled, auditable numbers.', Comment = '%1 = Journal Template Name, %2 = Journal Batch Name';

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

        // No statement context on this low-level overload -> post on WorkDate. The statement-aware
        // date (transaction/statement date) is resolved and supplied by the service layer, which owns
        // the reconciliation-line knowledge.
        exit(
            this.PostCustomerPaymentsToBank(
                TempApplyBuffer, BankAccountNo, WorkDate(), GenJnlTemplateName, GenJnlBatchName, ExternalDocumentNo));
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
    /// <param name="PostingDate">The date all document lines post on (and the No. Series draws against). Callers with statement context supply the reconciliation line's transaction/statement date so the bank entry lands in the statement's period.</param>
    /// <param name="GenJnlTemplateName">General journal template used to post the payment.</param>
    /// <param name="GenJnlBatchName">General journal batch (within the template) used to post the payment.</param>
    /// <param name="ExternalDocumentNo">Optional external document reference stamped on the payment lines.</param>
    /// <returns>The Entry No. of the single Bank Account Ledger Entry created by the posting (left open for reconciliation).</returns>
    [CommitBehavior(CommitBehavior::Ignore)]
    internal procedure PostCustomerPaymentsToBank(var TempApplyBuffer: Record "MON Pmt Recon Apply Buf" temporary; BankAccountNo: Code[20]; PostingDate: Date; GenJnlTemplateName: Code[10]; GenJnlBatchName: Code[10]; ExternalDocumentNo: Code[35]): Integer
    var
        GenJournalTemplate: Record "Gen. Journal Template";
        GenJournalBatch: Record "Gen. Journal Batch";
        GenJournalLine: Record "Gen. Journal Line";
        BankAccount: Record "Bank Account";
        BankAccountLedgerEntry: Record "Bank Account Ledger Entry";
        GenJnlPostLine: Codeunit "Gen. Jnl.-Post Line";
        ErrInfo: ErrorInfo;
        BankAmount: Decimal;
        AppliesTotal: Decimal;
        WriteOffTotal: Decimal;
        CustomerTotal: Decimal;
        DocumentNo: Code[20];
        AppliesToID: Code[50];
        PaymentCurrencyCode: Code[10];
        LineNo: Integer;
        CustomerSeq: Integer;
        LastBankEntryNo: Integer;
    begin
        this.ValidateRequest(TempApplyBuffer, BankAccountNo, GenJnlTemplateName, GenJnlBatchName);

        GenJournalTemplate.SetLoadFields("Source Code");
        GenJournalTemplate.Get(GenJnlTemplateName);
        GenJournalBatch.SetLoadFields("No. Series");
        GenJournalBatch.Get(GenJnlTemplateName, GenJnlBatchName);

        // The receipt is denominated in the bank account's currency. EVERY line of the document must carry
        // that SAME currency, so the whole balanced document posts in one currency and its LCY conversion
        // nets to zero. Otherwise the customer/write-off legs default to LCY while the bank line (whose
        // Account No. validation copies the bank's currency) posts in the bank's currency: for a foreign-
        // currency bank account the legs then convert to DIFFERENT LCY amounts and the transaction fails the
        // G/L Entry consistency check ("...will cause inconsistencies in the G/L Entry table"). For an LCY
        // bank account this is blank and every line stays in LCY exactly as before.
        BankAccount.SetLoadFields("Currency Code");
        BankAccount.Get(BankAccountNo);
        PaymentCurrencyCode := BankAccount."Currency Code";

        // One Document No. for the whole balanced payment document. The bank (cash) line is the customer
        // applies LESS the write-offs: write-offs settle invoice value against a G/L account, never the
        // bank, so the bank receipt equals the cash actually received.
        DocumentNo := this.DetermineDocumentNo(GenJournalBatch, PostingDate);
        AppliesTotal := this.SumBuffer(TempApplyBuffer, TempApplyBuffer."Line Type"::"Customer Apply");
        WriteOffTotal := this.SumBuffer(TempApplyBuffer, TempApplyBuffer."Line Type"::"Write-Off");
        BankAmount := AppliesTotal - WriteOffTotal;
        // The bank must receive a POSITIVE amount: write-offs absorb the payment difference, never the whole
        // (or more than the) applied amount. A zero/negative bank line would post no cash (or a debit), silently
        // corrupting the reconciliation balance.
        if BankAmount <= 0 then
            Error(InvalidBankAmountErr, WriteOffTotal, AppliesTotal);

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
        // Only Customer Apply rows become customer payment lines; the Line Type filter persists across the
        // inner SetRange("Customer No.") narrow/widen, so write-off rows are never grouped as customers.
        TempApplyBuffer.SetRange("Line Type", TempApplyBuffer."Line Type"::"Customer Apply");
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
            GenJournalLine.Validate("Posting Date", PostingDate);
            GenJournalLine.Validate("Document Type", GenJournalLine."Document Type"::Payment);
            GenJournalLine.Validate("Document No.", DocumentNo);
            GenJournalLine.Validate("Account Type", GenJournalLine."Account Type"::Customer);
            GenJournalLine.Validate("Account No.", TempApplyBuffer."Customer No.");
            // After Account No. so the customer-account validation cannot reset it; before Amount so the
            // amount is interpreted in — and its LCY value computed from — the receipt currency.
            GenJournalLine.Validate("Currency Code", PaymentCurrencyCode);
            GenJournalLine.Validate(Amount, -CustomerTotal);
            if ExternalDocumentNo <> '' then
                GenJournalLine.Validate("External Document No.", ExternalDocumentNo);
            GenJournalLine."Source Code" := GenJournalTemplate."Source Code";
            GenJournalLine."Applies-to ID" := AppliesToID;
            GenJnlPostLine.Run(GenJournalLine);

            // Re-widen the filter and advance to the first row of the next customer (or end the loop).
            TempApplyBuffer.SetRange("Customer No.");
        until TempApplyBuffer.Next() = 0;

        // --- One G/L write-off line per Write-Off row: positive (debit) amount, NO applies, NO bal account.
        // The customer leg already credited the FULL invoice (so it closes); this debits the difference to
        // the agent's G/L account. Σ(write-offs) offsets the gap between Σ(applies) and the smaller bank
        // (cash) line, so the document still nets to zero. ---
        TempApplyBuffer.Reset();
        TempApplyBuffer.SetRange("Line Type", TempApplyBuffer."Line Type"::"Write-Off");
        if TempApplyBuffer.FindSet() then
            repeat
                LineNo += 10000;
                GenJournalLine.Init();
                GenJournalLine.Validate("Journal Template Name", GenJournalTemplate.Name);
                GenJournalLine.Validate("Journal Batch Name", GenJournalBatch.Name);
                GenJournalLine."Line No." := LineNo;
                GenJournalLine.Validate("Posting Date", PostingDate);
                GenJournalLine.Validate("Document Type", GenJournalLine."Document Type"::Payment);
                GenJournalLine.Validate("Document No.", DocumentNo);
                GenJournalLine.Validate("Account Type", GenJournalLine."Account Type"::"G/L Account");
                GenJournalLine.Validate("Account No.", TempApplyBuffer."G/L Account No.");
                // Same receipt currency as every other leg (see the customer line) so the balanced document
                // posts in one currency and its LCY conversion nets to zero.
                GenJournalLine.Validate("Currency Code", PaymentCurrencyCode);
                GenJournalLine.Validate(Amount, TempApplyBuffer."Amount to Apply");
                if ExternalDocumentNo <> '' then
                    GenJournalLine.Validate("External Document No.", ExternalDocumentNo);
                GenJournalLine."Source Code" := GenJournalTemplate."Source Code";
                GenJnlPostLine.Run(GenJournalLine);
            until TempApplyBuffer.Next() = 0;
        TempApplyBuffer.Reset();

        // --- The single bank line: positive CASH (applies - write-offs), NO applies, NO bal account ->
        // ONE bank entry for the cash actually received (= the statement-line amount). ---
        LineNo += 10000;
        GenJournalLine.Init();
        GenJournalLine.Validate("Journal Template Name", GenJournalTemplate.Name);
        GenJournalLine.Validate("Journal Batch Name", GenJournalBatch.Name);
        GenJournalLine."Line No." := LineNo;
        GenJournalLine.Validate("Posting Date", PostingDate);
        GenJournalLine.Validate("Document Type", GenJournalLine."Document Type"::Payment);
        GenJournalLine.Validate("Document No.", DocumentNo);
        GenJournalLine.Validate("Account Type", GenJournalLine."Account Type"::"Bank Account");
        GenJournalLine.Validate("Account No.", BankAccountNo);
        // Validating the bank Account No. already copied the bank's currency; re-validating to the same
        // PaymentCurrencyCode is a harmless no-op that keeps every leg's currency explicit and identical.
        GenJournalLine.Validate("Currency Code", PaymentCurrencyCode);
        GenJournalLine.Validate(Amount, BankAmount);
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
        ErrInfo: ErrorInfo;
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

        // Defence in depth behind the pre-flight reserved-entry guard: re-read what actually landed on the
        // entry and refuse to continue unless it carries THIS payment's Applies-to ID for THIS amount.
        // Without this, any failure to stamp (SetApplId's toggle, a concurrent application taking the entry
        // between the pre-flight and here, an event subscriber clearing it) posts the payment on account and
        // still returns success. Erroring rolls back the whole PostAndReconcile transaction — nothing posts.
        // Both checks keep the raw Applies-to ID / amount out of the client-facing Message and in
        // DetailedMessage instead. ErrorType is deliberately left at the default (Client), not Internal:
        // Internal replaces the message with a generic "contact your system administrator" text for the
        // API caller and for tests alike (verified against a real container) — the caller needs to see
        // which entry failed to stamp.
        CustLedgerEntry.SetLoadFields("Applies-to ID", "Amount to Apply");
        CustLedgerEntry.Get(CustLedgerEntryNo);
        if CustLedgerEntry."Applies-to ID" <> AppliesToID then begin
            ErrInfo := ErrorInfo.Create(StrSubstNo(ApplyIdNotStampedErr, CustLedgerEntryNo));
            ErrInfo.DetailedMessage := StrSubstNo(ApplyIdNotStampedDetailTxt, AppliesToID, CustLedgerEntry."Applies-to ID");
            Error(ErrInfo);
        end;
        if CustLedgerEntry."Amount to Apply" <> AmountToApply then begin
            ErrInfo := ErrorInfo.Create(StrSubstNo(AmountToApplyNotSetErr, CustLedgerEntryNo, AmountToApply));
            ErrInfo.DetailedMessage := StrSubstNo(AmountToApplyNotSetDetailTxt, CustLedgerEntry."Amount to Apply", AmountToApply);
            Error(ErrInfo);
        end;
    end;

    local procedure DetermineDocumentNo(GenJournalBatch: Record "Gen. Journal Batch"; PostingDate: Date): Code[20]
    var
        NoSeries: Codeunit "No. Series";
    begin
        // Production payment documents must draw controlled, auditable numbers from the batch's No.
        // Series. A batch with no series is a configuration error — reject it rather than silently
        // minting a synthetic number. The number is drawn against the payment's posting date so the
        // document number and the posting land in the same period.
        if GenJournalBatch."No. Series" = '' then
            Error(MissingNoSeriesErr, GenJournalBatch."Journal Template Name", GenJournalBatch.Name);
        exit(NoSeries.GetNextNo(GenJournalBatch."No. Series", PostingDate));
    end;

    local procedure MakeAppliesToID(DocumentNo: Code[20]; CustomerSeq: Integer): Code[50]
    begin
        // Distinct per-customer Applies-to ID derived from the shared Document No. plus the customer's
        // 1-based sequence in the document. Bounded to Code[50] (DocumentNo is Code[20] + '-' + digits).
        exit(CopyStr(DocumentNo + '-' + Format(CustomerSeq), 1, 50));
    end;

    local procedure SumBuffer(var TempApplyBuffer: Record "MON Pmt Recon Apply Buf" temporary; LineType: Option "Customer Apply","Write-Off") Total: Decimal
    begin
        TempApplyBuffer.Reset();
        TempApplyBuffer.SetRange("Line Type", LineType);
        if TempApplyBuffer.FindSet() then
            repeat
                Total += TempApplyBuffer."Amount to Apply";
            until TempApplyBuffer.Next() = 0;
        TempApplyBuffer.SetRange("Line Type");
    end;

    local procedure ValidateRequest(var TempApplyBuffer: Record "MON Pmt Recon Apply Buf" temporary; BankAccountNo: Code[20]; GenJnlTemplateName: Code[10]; GenJnlBatchName: Code[10])
    var
        Customer: Record Customer;
        BankAccount: Record "Bank Account";
        CustLedgerEntry: Record "Cust. Ledger Entry";
        GLAccount: Record "G/L Account";
        GenJournalBatch: Record "Gen. Journal Batch";
        ErrInfo: ErrorInfo;
    begin
        // Cheap guard first — nothing to post.
        TempApplyBuffer.Reset();
        if TempApplyBuffer.IsEmpty() then
            Error(NoAppliesEntriesErr);

        BankAccount.SetLoadFields("No.");
        BankAccount.Get(BankAccountNo);
        GenJournalBatch.SetLoadFields("Name");
        GenJournalBatch.Get(GenJnlTemplateName, GenJnlBatchName);

        // Every row must carry a positive amount; the remaining guards are per row type: Customer Apply
        // rows must name an existing customer that owns an open ledger entry, while Write-Off rows must
        // name an existing G/L account (direct-posting is left for the posting engine to enforce).
        TempApplyBuffer.FindSet();
        repeat
            if TempApplyBuffer."Amount to Apply" <= 0 then
                Error(PaymentAmountErr);

            case TempApplyBuffer."Line Type" of
                TempApplyBuffer."Line Type"::"Customer Apply":
                    begin
                        Customer.SetLoadFields("No.");
                        Customer.Get(TempApplyBuffer."Customer No.");

                        CustLedgerEntry.SetLoadFields("Customer No.", Open, "Applies-to ID");
                        CustLedgerEntry.Get(TempApplyBuffer."Cust. Ledger Entry No.");
                        if CustLedgerEntry."Customer No." <> TempApplyBuffer."Customer No." then
                            Error(CustomerMismatchErr, TempApplyBuffer."Cust. Ledger Entry No.", TempApplyBuffer."Customer No.");
                        if not CustLedgerEntry.Open then
                            Error(ClosedEntryErr, TempApplyBuffer."Cust. Ledger Entry No.");
                        // An entry another application already reserved CANNOT be settled by this payment:
                        // "Cust. Entry-SetAppl.ID" TOGGLES, so handed an entry that already carries an
                        // "Applies-to ID" it CLEARS that ID instead of stamping ours. The payment then posts
                        // ON ACCOUNT — bank entry created, invoice left open for its full amount — and the
                        // caller still sees a success. The usual source is an applied-but-unposted general
                        // journal line (a staged cash-receipt line) holding the entry. Reject here, in the
                        // pre-flight, so NOTHING is posted and the caller gets the entry no. and the reason.
                        // The reserving Applies-to ID is frequently a BC user name (base-app codeunit 101
                        // stamps UserId from the Apply Entries page), so it goes to DetailedMessage, never
                        // to the client-facing message.
                        if CustLedgerEntry."Applies-to ID" <> '' then begin
                            ErrInfo := ErrorInfo.Create(StrSubstNo(EntryReservedErr, TempApplyBuffer."Cust. Ledger Entry No."));
                            ErrInfo.DetailedMessage := StrSubstNo(EntryReservedDetailTxt, CustLedgerEntry."Applies-to ID");
                            ErrInfo.DataClassification := DataClassification::EndUserIdentifiableInformation;
                            Error(ErrInfo);
                        end;
                    end;
                TempApplyBuffer."Line Type"::"Write-Off":
                    begin
                        GLAccount.SetLoadFields("No.");
                        GLAccount.Get(TempApplyBuffer."G/L Account No.");
                    end;
            end;
        until TempApplyBuffer.Next() = 0;
    end;
}
