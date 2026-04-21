codeunit 90102 "Clear Add. Rep. Report Tests"
{
    Subtype = Test;
    TestPermissions = Disabled;

    var
        Assert: Codeunit "Library Assert";
        LastMessage: Text[1024];

    [Test]
    [TransactionModel(TransactionModel::AutoRollback)]
    [HandlerFunctions('RequestPageHandler,ConfirmHandlerTrue,MessageHandler')]
    procedure ReportClearsAndShowsMessage()
    var
        GLEntry: Record "G/L Entry";
        EntryNo: Integer;
    begin
        EntryNo := InsertGLEntry(100.00, 60.00, 40.00, 500.00, 20260101D);
        GLEntry.SetRange("Entry No.", EntryNo);

        Report.RunModal(Report::"Clear Add. Reporting Amounts", true, false, GLEntry);

        GLEntry.Get(EntryNo);
        Assert.AreEqual(0, GLEntry."Additional-Currency Amount", '"Additional-Currency Amount" must be cleared');
        Assert.AreEqual(0, GLEntry."Add.-Currency Debit Amount", '"Add.-Currency Debit Amount" must be cleared');
        Assert.AreEqual(0, GLEntry."Add.-Currency Credit Amount", '"Add.-Currency Credit Amount" must be cleared');
        Assert.IsTrue(LastMessage.Contains('1'), 'Message must contain the count "1"');
        Assert.IsTrue(LastMessage.Contains('G/L Entr'), 'Message must reference G/L Entries');
    end;

    [Test]
    [TransactionModel(TransactionModel::AutoRollback)]
    [HandlerFunctions('RequestPageHandler,ConfirmHandlerFalse')]
    procedure ReportAbortedOnConfirmNo()
    var
        GLEntry: Record "G/L Entry";
        EntryNo: Integer;
    begin
        EntryNo := InsertGLEntry(100.00, 60.00, 40.00, 500.00, 20260101D);
        GLEntry.SetRange("Entry No.", EntryNo);

        Report.RunModal(Report::"Clear Add. Reporting Amounts", true, false, GLEntry);

        GLEntry.Get(EntryNo);
        Assert.AreEqual(100.00, GLEntry."Additional-Currency Amount", '"Additional-Currency Amount" must be unchanged after abort');
        Assert.AreEqual(60.00, GLEntry."Add.-Currency Debit Amount", '"Add.-Currency Debit Amount" must be unchanged after abort');
        Assert.AreEqual(40.00, GLEntry."Add.-Currency Credit Amount", '"Add.-Currency Credit Amount" must be unchanged after abort');
    end;

    [Test]
    [TransactionModel(TransactionModel::AutoRollback)]
    [HandlerFunctions('RequestPageHandlerWithDateFilter,ConfirmHandlerTrue,MessageHandler')]
    procedure ReportPassesRequestPageFiltersToCodeunit()
    var
        GLEntry: Record "G/L Entry";
        JanEntryNo: Integer;
        FebEntryNo: Integer;
    begin
        JanEntryNo := InsertGLEntry(100.00, 60.00, 40.00, 0, 20260101D);
        FebEntryNo := InsertGLEntry(100.00, 60.00, 40.00, 0, 20260201D);
        GLEntry.SetRange("Entry No.", JanEntryNo, FebEntryNo);

        Report.RunModal(Report::"Clear Add. Reporting Amounts", true, false, GLEntry);

        GLEntry.Get(JanEntryNo);
        Assert.AreEqual(0, GLEntry."Additional-Currency Amount", 'January entry must be cleared by the date filter');

        GLEntry.Get(FebEntryNo);
        Assert.AreEqual(100.00, GLEntry."Additional-Currency Amount", 'February entry must be untouched — outside the request page date filter');
    end;

    [RequestPageHandler]
    procedure RequestPageHandler(var RequestPage: TestRequestPage "Clear Add. Reporting Amounts")
    begin
        RequestPage.OK().Invoke();
    end;

    [RequestPageHandler]
    procedure RequestPageHandlerWithDateFilter(var RequestPage: TestRequestPage "Clear Add. Reporting Amounts")
    begin
        RequestPage.GLEntry.SetFilter("Posting Date", '2026-01-01..2026-01-31');
        RequestPage.OK().Invoke();
    end;

    [ConfirmHandler]
    procedure ConfirmHandlerTrue(Question: Text[1024]; var Reply: Boolean)
    begin
        Reply := true;
    end;

    [ConfirmHandler]
    procedure ConfirmHandlerFalse(Question: Text[1024]; var Reply: Boolean)
    begin
        Reply := false;
    end;

    [MessageHandler]
    procedure MessageHandler(Msg: Text[1024])
    begin
        LastMessage := Msg;
    end;

    local procedure InsertGLEntry(AddCurrAmt: Decimal; AddCurrDebit: Decimal; AddCurrCredit: Decimal; LCYAmount: Decimal; PostingDate: Date): Integer
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
        GLEntry."Posting Date" := PostingDate;
        GLEntry.Amount := LCYAmount;
        GLEntry."Additional-Currency Amount" := AddCurrAmt;
        GLEntry."Add.-Currency Debit Amount" := AddCurrDebit;
        GLEntry."Add.-Currency Credit Amount" := AddCurrCredit;
        GLEntry.Insert(false);
        exit(NextEntryNo);
    end;
}
