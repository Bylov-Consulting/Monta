codeunit 90100 "Clear Add. Reporting Tests"
{
    Subtype = Test;
    TestPermissions = Disabled;

    var
        Assert: Codeunit "Library Assert";
        ClearAddReportingMgmt: Codeunit "Clear Add. Reporting Mgmt.";

    [Test]
    procedure ClearsAdditionalCurrencyAmount()
    var
        GLEntry: Record "G/L Entry";
        EntryNo: Integer;
    begin
        EntryNo := InsertGLEntry(100.00, 60.00, 40.00, 500.00, 20260101D);
        GLEntry.SetRange("Entry No.", EntryNo);

        ClearAddReportingMgmt.ClearAmounts(GLEntry);

        GLEntry.Get(EntryNo);
        Assert.AreEqual(0, GLEntry."Additional-Currency Amount", '"Additional-Currency Amount" should be cleared');
    end;

    [Test]
    procedure ClearsAddCurrencyDebitAmount()
    var
        GLEntry: Record "G/L Entry";
        EntryNo: Integer;
    begin
        EntryNo := InsertGLEntry(100.00, 60.00, 40.00, 500.00, 20260101D);
        GLEntry.SetRange("Entry No.", EntryNo);

        ClearAddReportingMgmt.ClearAmounts(GLEntry);

        GLEntry.Get(EntryNo);
        Assert.AreEqual(0, GLEntry."Add.-Currency Debit Amount", '"Add.-Currency Debit Amount" should be cleared');
    end;

    [Test]
    procedure ClearsAddCurrencyCreditAmount()
    var
        GLEntry: Record "G/L Entry";
        EntryNo: Integer;
    begin
        EntryNo := InsertGLEntry(100.00, 60.00, 40.00, 500.00, 20260101D);
        GLEntry.SetRange("Entry No.", EntryNo);

        ClearAddReportingMgmt.ClearAmounts(GLEntry);

        GLEntry.Get(EntryNo);
        Assert.AreEqual(0, GLEntry."Add.-Currency Credit Amount", '"Add.-Currency Credit Amount" should be cleared');
    end;

    [Test]
    procedure DoesNotTouchLocalCurrencyAmount()
    var
        GLEntry: Record "G/L Entry";
        EntryNo: Integer;
    begin
        EntryNo := InsertGLEntry(100.00, 60.00, 40.00, 500.00, 20260101D);
        GLEntry.SetRange("Entry No.", EntryNo);

        ClearAddReportingMgmt.ClearAmounts(GLEntry);

        GLEntry.Get(EntryNo);
        Assert.AreEqual(500.00, GLEntry.Amount, 'Amount (LCY) must not be touched');
    end;

    [Test]
    procedure RespectsFilterOnRecord()
    var
        GLEntry: Record "G/L Entry";
        TouchedEntryNo: Integer;
        UntouchedEntryNo: Integer;
    begin
        TouchedEntryNo := InsertGLEntry(100.00, 60.00, 40.00, 0, 20260101D);
        UntouchedEntryNo := InsertGLEntry(100.00, 60.00, 40.00, 0, 20260201D);
        GLEntry.SetRange("Posting Date", 20260101D, 20260131D);
        GLEntry.SetRange("Entry No.", TouchedEntryNo, UntouchedEntryNo);

        ClearAddReportingMgmt.ClearAmounts(GLEntry);

        GLEntry.Get(TouchedEntryNo);
        Assert.AreEqual(0, GLEntry."Additional-Currency Amount", 'Entry matching filter must be cleared');
        GLEntry.Get(UntouchedEntryNo);
        Assert.AreEqual(100.00, GLEntry."Additional-Currency Amount", 'Entry outside filter must not be modified');
    end;

    [Test]
    procedure ReturnsModifiedCount()
    var
        GLEntry: Record "G/L Entry";
        ModifiedCount: Integer;
        FirstEntryNo: Integer;
        SecondEntryNo: Integer;
    begin
        FirstEntryNo := InsertGLEntry(100.00, 60.00, 40.00, 0, 20260101D);
        SecondEntryNo := InsertGLEntry(200.00, 120.00, 80.00, 0, 20260101D);
        GLEntry.SetRange("Entry No.", FirstEntryNo, SecondEntryNo);

        ModifiedCount := ClearAddReportingMgmt.ClearAmounts(GLEntry);

        Assert.AreEqual(2, ModifiedCount, 'Two entries should have been counted as modified');
    end;

    [Test]
    procedure SkipsEntriesAlreadyBlank()
    var
        GLEntry: Record "G/L Entry";
        ModifiedCount: Integer;
        EntryNo: Integer;
    begin
        EntryNo := InsertGLEntry(0, 0, 0, 500.00, 20260101D);
        GLEntry.SetRange("Entry No.", EntryNo);

        ModifiedCount := ClearAddReportingMgmt.ClearAmounts(GLEntry);

        Assert.AreEqual(0, ModifiedCount, 'Already-blank entries should not be counted as modified');
    end;

    [Test]
    procedure HandlesEmptyResultSet()
    var
        GLEntry: Record "G/L Entry";
        ModifiedCount: Integer;
    begin
        GLEntry.SetRange("Entry No.", -1);

        ModifiedCount := ClearAddReportingMgmt.ClearAmounts(GLEntry);

        Assert.AreEqual(0, ModifiedCount, 'Empty result set should return 0 modified');
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
