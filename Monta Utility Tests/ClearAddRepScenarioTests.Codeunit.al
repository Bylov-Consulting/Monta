codeunit 90103 "Clear Add. Rep. Scenario Tests"
{
    // End-to-end scenario tests for Report 90001 "Clear Add. Reporting Amounts".
    //
    // Business context: an admin tenant accidentally enabled Additional Reporting Currency,
    // posted GL entries (populating the three ACY fields on G/L Entry), then disabled ACY.
    // The residual values must be blanked for financial reporting integrity.
    // These tests simulate the complete admin workflow: open report, set filters, confirm,
    // verify results — or abort and verify nothing was touched.

    Subtype = Test;
    TestPermissions = Disabled;

    var
        Assert: Codeunit "Library Assert";
        LastMessage: Text[1024];

    // -------------------------------------------------------------------------
    // Scenario 1
    // -------------------------------------------------------------------------
    // The admin notices that five G/L entries on account "ACC-001" posted during
    // January 2026 carry non-zero ACY amounts left over from the accidental ACY
    // period. She opens the "Clear Add. Reporting Amounts" report, filters it to
    // that account and that month, confirms the dialog, and expects a message
    // confirming exactly 5 entries were cleared. LCY amounts must not change.
    // -------------------------------------------------------------------------

    [Test]
    [TransactionModel(TransactionModel::AutoRollback)]
    [HandlerFunctions('ConfirmHandlerTrue,MessageHandlerCapture')]
    procedure AdminCleansUpAccidentalACYOnSingleAccount()
    var
        GLEntry: Record "G/L Entry";
        AccountNo: Code[20];
        EntryNos: array[5] of Integer;
        i: Integer;
    begin
        LastMessage := '';
        // Arrange ---------------------------------------------------------------
        // Five transactions on a single G/L account, all in January 2026.
        // Each carries ACY amounts and a meaningful LCY amount.
        AccountNo := 'ACC-SCENARIO-001';

        EntryNos[1] := InsertGLEntry(AccountNo, 120.00, 120.00, 0, 1200.00, 20260105D);
        EntryNos[2] := InsertGLEntry(AccountNo, 85.50, 0, 85.50, 855.00, 20260110D);
        EntryNos[3] := InsertGLEntry(AccountNo, 200.00, 200.00, 0, 2000.00, 20260115D);
        EntryNos[4] := InsertGLEntry(AccountNo, 45.75, 0, 45.75, 457.50, 20260120D);
        EntryNos[5] := InsertGLEntry(AccountNo, 310.00, 310.00, 0, 3100.00, 20260128D);

        // Seed the report's dataitem filter via the record passed to RunModal.
        GLEntry.SetRange("G/L Account No.", AccountNo);
        GLEntry.SetRange("Posting Date", 20260101D, 20260131D);

        // Act -------------------------------------------------------------------
        // The admin opens the report. The ConfirmHandler answers true (continue).
        // The MessageHandler captures the completion message for later assertion.
        Report.RunModal(Report::"Clear Add. Reporting Amounts", true, false, GLEntry);

        // Assert ----------------------------------------------------------------
        // Verify every entry has its three ACY fields zeroed out.
        for i := 1 to 5 do begin
            GLEntry.Get(EntryNos[i]);
            Assert.AreEqual(0, GLEntry."Additional-Currency Amount",
                StrSubstNo('Entry %1: "Additional-Currency Amount" must be zero after cleanup', EntryNos[i]));
            Assert.AreEqual(0, GLEntry."Add.-Currency Debit Amount",
                StrSubstNo('Entry %1: "Add.-Currency Debit Amount" must be zero after cleanup', EntryNos[i]));
            Assert.AreEqual(0, GLEntry."Add.-Currency Credit Amount",
                StrSubstNo('Entry %1: "Add.-Currency Credit Amount" must be zero after cleanup', EntryNos[i]));
        end;

        // Verify LCY amounts are untouched — financial integrity of the ledger.
        GLEntry.Get(EntryNos[1]);
        Assert.AreEqual(1200.00, GLEntry.Amount, 'Entry 1: LCY Amount must not be modified');
        GLEntry.Get(EntryNos[2]);
        Assert.AreEqual(855.00, GLEntry.Amount, 'Entry 2: LCY Amount must not be modified');
        GLEntry.Get(EntryNos[3]);
        Assert.AreEqual(2000.00, GLEntry.Amount, 'Entry 3: LCY Amount must not be modified');
        GLEntry.Get(EntryNos[4]);
        Assert.AreEqual(457.50, GLEntry.Amount, 'Entry 4: LCY Amount must not be modified');
        GLEntry.Get(EntryNos[5]);
        Assert.AreEqual(3100.00, GLEntry.Amount, 'Entry 5: LCY Amount must not be modified');

        // Verify the completion message reported the correct count to the admin.
        Assert.IsTrue(
            LastMessage.Contains('5'),
            StrSubstNo('Completion message must reference 5 cleared entries; got: "%1"', LastMessage));
    end;

    // -------------------------------------------------------------------------
    // Scenario 2
    // -------------------------------------------------------------------------
    // The admin only wants to clean up January 2026. February 2026 entries are
    // from a different (legitimate) reporting period and must not be touched.
    // She filters the report to January only and confirms. The expected outcome:
    //   - January entries (3): all ACY fields zero.
    //   - February entries (3): ACY fields unchanged (still 100).
    //   - Message says 3 entries were cleared.
    // -------------------------------------------------------------------------

    [Test]
    [TransactionModel(TransactionModel::AutoRollback)]
    [HandlerFunctions('ConfirmHandlerTrue,MessageHandlerCapture')]
    procedure AdminCleansOnlyTargetPeriodLeavingOtherPeriodsUntouched()
    var
        GLEntry: Record "G/L Entry";
        JanEntryNos: array[3] of Integer;
        FebEntryNos: array[3] of Integer;
        i: Integer;
    begin
        LastMessage := '';
        // Arrange ---------------------------------------------------------------
        // Three entries in January and three in February, all with identical ACY
        // amounts so the distinction between cleared and untouched is unambiguous.
        JanEntryNos[1] := InsertGLEntry('', 100.00, 100.00, 0, 500.00, 20260108D);
        JanEntryNos[2] := InsertGLEntry('', 100.00, 0, 100.00, 500.00, 20260115D);
        JanEntryNos[3] := InsertGLEntry('', 100.00, 100.00, 0, 500.00, 20260122D);

        FebEntryNos[1] := InsertGLEntry('', 100.00, 100.00, 0, 500.00, 20260201D);
        FebEntryNos[2] := InsertGLEntry('', 100.00, 0, 100.00, 500.00, 20260214D);
        FebEntryNos[3] := InsertGLEntry('', 100.00, 100.00, 0, 500.00, 20260228D);

        // The admin scopes the report to January only.
        GLEntry.SetRange("Posting Date", 20260101D, 20260131D);
        // Narrow to just the entries created in this test run to avoid interference.
        GLEntry.SetRange("Entry No.", JanEntryNos[1], FebEntryNos[3]);

        // Act -------------------------------------------------------------------
        Report.RunModal(Report::"Clear Add. Reporting Amounts", true, false, GLEntry);

        // Assert — January entries are cleared ------------------------------------
        for i := 1 to 3 do begin
            GLEntry.Get(JanEntryNos[i]);
            Assert.AreEqual(0, GLEntry."Additional-Currency Amount",
                StrSubstNo('Jan entry %1: "Additional-Currency Amount" must be zero', JanEntryNos[i]));
            Assert.AreEqual(0, GLEntry."Add.-Currency Debit Amount",
                StrSubstNo('Jan entry %1: "Add.-Currency Debit Amount" must be zero', JanEntryNos[i]));
            Assert.AreEqual(0, GLEntry."Add.-Currency Credit Amount",
                StrSubstNo('Jan entry %1: "Add.-Currency Credit Amount" must be zero', JanEntryNos[i]));
        end;

        // Assert — February entries are completely untouched ----------------------
        for i := 1 to 3 do begin
            GLEntry.Get(FebEntryNos[i]);
            Assert.AreEqual(100.00, GLEntry."Additional-Currency Amount",
                StrSubstNo('Feb entry %1: "Additional-Currency Amount" must remain 100 (outside filter period)', FebEntryNos[i]));
        end;

        // Assert — message confirms the correct count to the admin.
        Assert.IsTrue(
            LastMessage.Contains('3'),
            StrSubstNo('Completion message must reference 3 cleared entries; got: "%1"', LastMessage));
    end;

    // -------------------------------------------------------------------------
    // Scenario 3
    // -------------------------------------------------------------------------
    // The admin accidentally opens the cleanup report against production data,
    // realises the mistake, and clicks "No" on the confirmation dialog. This is
    // the last line of defence against accidental financial-data destruction.
    // Every single entry must remain completely unmodified — no ACY field may
    // change, and no completion message must be shown.
    // -------------------------------------------------------------------------

    [Test]
    [TransactionModel(TransactionModel::AutoRollback)]
    [HandlerFunctions('ConfirmHandlerFalse')]
    procedure AdminAbortsAtConfirmLeavesAllDataIntact()
    var
        GLEntry: Record "G/L Entry";
        EntryNos: array[5] of Integer;
        i: Integer;
    begin
        // Arrange ---------------------------------------------------------------
        // Five entries that would normally be cleaned up — except the admin
        // will abort by clicking No on the confirmation dialog.
        EntryNos[1] := InsertGLEntry('', 100.00, 100.00, 0, 1000.00, 20260103D);
        EntryNos[2] := InsertGLEntry('', 100.00, 0, 100.00, 1000.00, 20260110D);
        EntryNos[3] := InsertGLEntry('', 100.00, 100.00, 0, 1000.00, 20260117D);
        EntryNos[4] := InsertGLEntry('', 100.00, 0, 100.00, 1000.00, 20260124D);
        EntryNos[5] := InsertGLEntry('', 100.00, 100.00, 0, 1000.00, 20260131D);

        GLEntry.SetRange("Entry No.", EntryNos[1], EntryNos[5]);

        // Act -------------------------------------------------------------------
        // The admin opens the report and clicks No. CurrReport.Quit() is called
        // inside OnPreDataItem; no modification code is ever reached.
        // NOTE: No MessageHandler is registered because the abort path never
        //       reaches the Message(...) call — registering one would cause the
        //       test framework to fail if the message were unexpectedly raised.
        Report.RunModal(Report::"Clear Add. Reporting Amounts", true, false, GLEntry);

        // Assert ----------------------------------------------------------------
        // Every entry must be completely unchanged — this verifies that aborting
        // at the confirm dialog provides a true safety net.
        for i := 1 to 5 do begin
            GLEntry.Get(EntryNos[i]);
            Assert.AreEqual(100.00, GLEntry."Additional-Currency Amount",
                StrSubstNo('Entry %1: "Additional-Currency Amount" must be unchanged after abort', EntryNos[i]));
            Assert.AreEqual(1000.00, GLEntry.Amount,
                StrSubstNo('Entry %1: LCY Amount must be unchanged after abort', EntryNos[i]));
        end;

        // Verify debit/credit fields on a representative sample.
        GLEntry.Get(EntryNos[1]);
        Assert.AreEqual(100.00, GLEntry."Add.-Currency Debit Amount",
            'Entry 1: "Add.-Currency Debit Amount" must be unchanged after abort');
        Assert.AreEqual(0, GLEntry."Add.-Currency Credit Amount",
            'Entry 1: "Add.-Currency Credit Amount" must be unchanged after abort');

        GLEntry.Get(EntryNos[2]);
        Assert.AreEqual(0, GLEntry."Add.-Currency Debit Amount",
            'Entry 2: "Add.-Currency Debit Amount" must be unchanged after abort');
        Assert.AreEqual(100.00, GLEntry."Add.-Currency Credit Amount",
            'Entry 2: "Add.-Currency Credit Amount" must be unchanged after abort');

        // No LastMessage assertion — MessageHandler is not registered for this test,
        // so if the abort path incorrectly reaches Message(...) the test framework
        // will fail with "unexpected UI handler" which is the implicit guard.
    end;

    // =========================================================================
    // Handlers
    // =========================================================================

    [ConfirmHandler]
    procedure ConfirmHandlerTrue(Question: Text[1024]; var Reply: Boolean)
    begin
        // Admin clicks "Yes" — proceed with the cleanup.
        Reply := true;
    end;

    [ConfirmHandler]
    procedure ConfirmHandlerFalse(Question: Text[1024]; var Reply: Boolean)
    begin
        // Admin clicks "No" — abort the cleanup entirely.
        Reply := false;
    end;

    [MessageHandler]
    procedure MessageHandlerCapture(Message: Text[1024])
    begin
        // Capture the completion message so the test body can assert on it.
        LastMessage := Message;
    end;

    // =========================================================================
    // Fixture helpers
    // =========================================================================

    local procedure InsertGLEntry(GLAccountNo: Code[20]; AddCurrAmt: Decimal; AddCurrDebit: Decimal; AddCurrCredit: Decimal; LCYAmount: Decimal; PostingDate: Date): Integer
    var
        GLEntry: Record "G/L Entry";
        NextEntryNo: Integer;
    begin
        if GLEntry.FindLast() then
            NextEntryNo := GLEntry."Entry No." + 1
        else
            NextEntryNo := 1;

        GLEntry.Init();
        GLEntry."Entry No." := NextEntryNo;
        GLEntry."G/L Account No." := GLAccountNo;
        GLEntry."Posting Date" := PostingDate;
        GLEntry.Amount := LCYAmount;
        GLEntry."Additional-Currency Amount" := AddCurrAmt;
        GLEntry."Add.-Currency Debit Amount" := AddCurrDebit;
        GLEntry."Add.-Currency Credit Amount" := AddCurrCredit;
        GLEntry.Insert(false);
        exit(NextEntryNo);
    end;
}
