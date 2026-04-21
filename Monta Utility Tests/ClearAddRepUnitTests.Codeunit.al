codeunit 90101 "Clear Add. Rep. Unit Tests"
{
    Subtype = Test;
    TestPermissions = Disabled;

    var
        Assert: Codeunit "Library Assert";
        ClearAddReportingMgmt: Codeunit "Clear Add. Reporting Mgmt.";

    [Test]
    [TransactionModel(TransactionModel::AutoRollback)]
    procedure MixedBatchReturnsOnlyModifiedCount()
    var
        GLEntry: Record "G/L Entry";
        ModifiedCount: Integer;
        EntryNo1: Integer;
        EntryNo2: Integer;
        EntryNo3: Integer;
    begin
        // Arrange: two non-zero entries and one already-blank entry
        EntryNo1 := InsertGLEntry(150.00, 90.00, 60.00, 0, 20260101D);
        EntryNo2 := InsertGLEntry(0, 0, 0, 500.00, 20260101D);
        EntryNo3 := InsertGLEntry(200.00, 120.00, 80.00, 0, 20260101D);
        GLEntry.SetRange("Entry No.", EntryNo1, EntryNo3);

        // Act
        ModifiedCount := ClearAddReportingMgmt.ClearAmounts(GLEntry);

        // Assert: only the two non-zero rows count as modified
        Assert.AreEqual(2, ModifiedCount, 'Only non-zero entries should be counted as modified');

        // All three rows must have zero ACY amounts afterwards
        GLEntry.Get(EntryNo1);
        Assert.AreEqual(0, GLEntry."Additional-Currency Amount", 'Entry1 "Additional-Currency Amount" must be zero');
        Assert.AreEqual(0, GLEntry."Add.-Currency Debit Amount", 'Entry1 "Add.-Currency Debit Amount" must be zero');
        Assert.AreEqual(0, GLEntry."Add.-Currency Credit Amount", 'Entry1 "Add.-Currency Credit Amount" must be zero');

        GLEntry.Get(EntryNo2);
        Assert.AreEqual(0, GLEntry."Additional-Currency Amount", 'Entry2 "Additional-Currency Amount" must remain zero');
        Assert.AreEqual(0, GLEntry."Add.-Currency Debit Amount", 'Entry2 "Add.-Currency Debit Amount" must remain zero');
        Assert.AreEqual(0, GLEntry."Add.-Currency Credit Amount", 'Entry2 "Add.-Currency Credit Amount" must remain zero');

        GLEntry.Get(EntryNo3);
        Assert.AreEqual(0, GLEntry."Additional-Currency Amount", 'Entry3 "Additional-Currency Amount" must be zero');
        Assert.AreEqual(0, GLEntry."Add.-Currency Debit Amount", 'Entry3 "Add.-Currency Debit Amount" must be zero');
        Assert.AreEqual(0, GLEntry."Add.-Currency Credit Amount", 'Entry3 "Add.-Currency Credit Amount" must be zero');
    end;

    [Test]
    [TransactionModel(TransactionModel::AutoRollback)]
    procedure SingleFieldAdditionalCurrencyOnly()
    var
        GLEntry: Record "G/L Entry";
        ModifiedCount: Integer;
        EntryNo: Integer;
    begin
        // Arrange: only "Additional-Currency Amount" is non-zero
        EntryNo := InsertGLEntry(75.00, 0, 0, 0, 20260101D);
        GLEntry.SetRange("Entry No.", EntryNo);

        // Act
        ModifiedCount := ClearAddReportingMgmt.ClearAmounts(GLEntry);

        // Assert
        Assert.AreEqual(1, ModifiedCount, 'Entry with only "Additional-Currency Amount" set should be counted as modified');
        GLEntry.Get(EntryNo);
        Assert.AreEqual(0, GLEntry."Additional-Currency Amount", '"Additional-Currency Amount" must be cleared');
    end;

    [Test]
    [TransactionModel(TransactionModel::AutoRollback)]
    procedure SingleFieldAddCurrencyDebitOnly()
    var
        GLEntry: Record "G/L Entry";
        ModifiedCount: Integer;
        EntryNo: Integer;
    begin
        // Arrange: only "Add.-Currency Debit Amount" is non-zero
        EntryNo := InsertGLEntry(0, 50.00, 0, 0, 20260101D);
        GLEntry.SetRange("Entry No.", EntryNo);

        // Act
        ModifiedCount := ClearAddReportingMgmt.ClearAmounts(GLEntry);

        // Assert
        Assert.AreEqual(1, ModifiedCount, 'Entry with only "Add.-Currency Debit Amount" set should be counted as modified');
        GLEntry.Get(EntryNo);
        Assert.AreEqual(0, GLEntry."Add.-Currency Debit Amount", '"Add.-Currency Debit Amount" must be cleared');
    end;

    [Test]
    [TransactionModel(TransactionModel::AutoRollback)]
    procedure SingleFieldAddCurrencyCreditOnly()
    var
        GLEntry: Record "G/L Entry";
        ModifiedCount: Integer;
        EntryNo: Integer;
    begin
        // Arrange: only "Add.-Currency Credit Amount" is non-zero
        EntryNo := InsertGLEntry(0, 0, 30.00, 0, 20260101D);
        GLEntry.SetRange("Entry No.", EntryNo);

        // Act
        ModifiedCount := ClearAddReportingMgmt.ClearAmounts(GLEntry);

        // Assert
        Assert.AreEqual(1, ModifiedCount, 'Entry with only "Add.-Currency Credit Amount" set should be counted as modified');
        GLEntry.Get(EntryNo);
        Assert.AreEqual(0, GLEntry."Add.-Currency Credit Amount", '"Add.-Currency Credit Amount" must be cleared');
    end;

    [Test]
    [TransactionModel(TransactionModel::AutoRollback)]
    procedure NoFilterProcessesAllNonZeroEntries()
    var
        GLEntry: Record "G/L Entry";
        ModifiedCount: Integer;
        EntryNo1: Integer;
        EntryNo2: Integer;
    begin
        // Arrange: two non-zero entries; no filter applied to GLEntry (full-table scan path)
        EntryNo1 := InsertGLEntry(100.00, 60.00, 40.00, 0, 20260101D);
        EntryNo2 := InsertGLEntry(200.00, 120.00, 80.00, 0, 20260201D);
        // Intentionally no SetRange/SetFilter — simulates the unscoped production call

        // Act
        ModifiedCount := ClearAddReportingMgmt.ClearAmounts(GLEntry);

        // Assert: both inserted entries are cleared (count >= 2; other pre-existing zeros don't inflate it)
        Assert.IsTrue(ModifiedCount >= 2, 'Without a filter, all non-zero entries in the table must be processed');

        GLEntry.Get(EntryNo1);
        Assert.AreEqual(0, GLEntry."Additional-Currency Amount", 'Entry1 "Additional-Currency Amount" must be cleared without a filter');
        Assert.AreEqual(0, GLEntry."Add.-Currency Debit Amount", 'Entry1 "Add.-Currency Debit Amount" must be cleared without a filter');
        Assert.AreEqual(0, GLEntry."Add.-Currency Credit Amount", 'Entry1 "Add.-Currency Credit Amount" must be cleared without a filter');

        GLEntry.Get(EntryNo2);
        Assert.AreEqual(0, GLEntry."Additional-Currency Amount", 'Entry2 "Additional-Currency Amount" must be cleared without a filter');
        Assert.AreEqual(0, GLEntry."Add.-Currency Debit Amount", 'Entry2 "Add.-Currency Debit Amount" must be cleared without a filter');
        Assert.AreEqual(0, GLEntry."Add.-Currency Credit Amount", 'Entry2 "Add.-Currency Credit Amount" must be cleared without a filter');
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
