codeunit 90104 "Clear Add. Rep. Edge Tests"
{
    Subtype = Test;
    TestPermissions = Disabled;

    var
        Assert: Codeunit "Library Assert";
        ClearAddReportingMgmt: Codeunit "Clear Add. Reporting Mgmt.";

    [Test]
    [TransactionModel(TransactionModel::AutoRollback)]
    procedure NegativeAmountsAreCleared()
    var
        GLEntry: Record "G/L Entry";
        ModifiedCount: Integer;
        EntryNo: Integer;
    begin
        // Arrange: all three ACY fields are negative
        EntryNo := InsertGLEntry(-100.00, -60.00, -40.00, 0);
        GLEntry.SetRange("Entry No.", EntryNo);

        // Act
        ModifiedCount := ClearAddReportingMgmt.ClearAmounts(GLEntry);

        // Assert: HasAdditionalReportingAmount treats negative values the same as positives (<> 0)
        Assert.AreEqual(1, ModifiedCount, 'Negative ACY entry must be counted as modified');
        GLEntry.Get(EntryNo);
        Assert.AreEqual(0, GLEntry."Additional-Currency Amount", 'Negative "Additional-Currency Amount" must be cleared');
        Assert.AreEqual(0, GLEntry."Add.-Currency Debit Amount", 'Negative "Add.-Currency Debit Amount" must be cleared');
        Assert.AreEqual(0, GLEntry."Add.-Currency Credit Amount", 'Negative "Add.-Currency Credit Amount" must be cleared');
    end;

    [Test]
    [TransactionModel(TransactionModel::AutoRollback)]
    procedure MixedSignsClearCorrectly()
    var
        GLEntry: Record "G/L Entry";
        ModifiedCount: Integer;
        EntryNo: Integer;
    begin
        // Arrange: ACY fields carry mixed signs (positive net, negative debit, positive credit)
        EntryNo := InsertGLEntry(100.00, -60.00, 40.00, 0);
        GLEntry.SetRange("Entry No.", EntryNo);

        // Act
        ModifiedCount := ClearAddReportingMgmt.ClearAmounts(GLEntry);

        // Assert: all three fields are zeroed regardless of individual signs
        Assert.AreEqual(1, ModifiedCount, 'Mixed-sign ACY entry must be counted as modified');
        GLEntry.Get(EntryNo);
        Assert.AreEqual(0, GLEntry."Additional-Currency Amount", '"Additional-Currency Amount" must be cleared when mixed signs');
        Assert.AreEqual(0, GLEntry."Add.-Currency Debit Amount", '"Add.-Currency Debit Amount" must be cleared when mixed signs');
        Assert.AreEqual(0, GLEntry."Add.-Currency Credit Amount", '"Add.-Currency Credit Amount" must be cleared when mixed signs');
    end;

    [Test]
    [TransactionModel(TransactionModel::AutoRollback)]
    procedure VerySmallDecimalNonZeroStillCleared()
    var
        GLEntry: Record "G/L Entry";
        ModifiedCount: Integer;
        EntryNo: Integer;
    begin
        // Arrange: ACY amount is below typical currency precision but strictly non-zero
        EntryNo := InsertGLEntry(0.00001, 0, 0, 0);
        GLEntry.SetRange("Entry No.", EntryNo);

        // Act
        ModifiedCount := ClearAddReportingMgmt.ClearAmounts(GLEntry);

        // Assert: the <> 0 check must fire for any non-zero value, not a rounded comparison
        Assert.AreEqual(1, ModifiedCount, 'Sub-precision non-zero ACY amount must be counted as modified');
        GLEntry.Get(EntryNo);
        Assert.AreEqual(0, GLEntry."Additional-Currency Amount", 'Sub-precision "Additional-Currency Amount" must be cleared');
    end;

    [Test]
    [TransactionModel(TransactionModel::AutoRollback)]
    procedure VeryLargeDecimalCleared()
    var
        GLEntry: Record "G/L Entry";
        ModifiedCount: Integer;
        EntryNo: Integer;
    begin
        // Arrange: ACY amount at a very large value — guards against any overflow assumption
        EntryNo := InsertGLEntry(9999999999.99, 0, 0, 0);
        GLEntry.SetRange("Entry No.", EntryNo);

        // Act
        ModifiedCount := ClearAddReportingMgmt.ClearAmounts(GLEntry);

        // Assert
        Assert.AreEqual(1, ModifiedCount, 'Large ACY amount must be counted as modified');
        GLEntry.Get(EntryNo);
        Assert.AreEqual(0, GLEntry."Additional-Currency Amount", 'Large "Additional-Currency Amount" must be cleared');
    end;

    [Test]
    [TransactionModel(TransactionModel::AutoRollback)]
    procedure ClearedEntryCountStableOnRepeatedRuns()
    var
        GLEntry: Record "G/L Entry";
        FirstCount: Integer;
        SecondCount: Integer;
        EntryNo: Integer;
    begin
        // Arrange: one non-zero ACY entry
        EntryNo := InsertGLEntry(100.00, 60.00, 40.00, 0);
        GLEntry.SetRange("Entry No.", EntryNo);

        // Act: first call clears the entry
        FirstCount := ClearAddReportingMgmt.ClearAmounts(GLEntry);

        // Act: second call on the same filter — entry is already blank
        SecondCount := ClearAddReportingMgmt.ClearAmounts(GLEntry);

        // Assert: idempotent — second run must not count already-blank entries
        Assert.AreEqual(1, FirstCount, 'First run must report one modified entry');
        Assert.AreEqual(0, SecondCount, 'Second run on already-cleared entry must report zero modified');
    end;

    [Test]
    [TransactionModel(TransactionModel::AutoRollback)]
    procedure LCYAmountUnchangedWithAllSignsOfACYValues()
    var
        GLEntry: Record "G/L Entry";
        ModifiedCount: Integer;
        EntryNoA: Integer;
        EntryNoB: Integer;
    begin
        // Arrange:
        //   Entry A — positive LCY, negative ACY values
        //   Entry B — negative LCY, positive ACY values
        EntryNoA := InsertGLEntry(-100.00, -60.00, -40.00, 500);
        EntryNoB := InsertGLEntry(100.00, 60.00, 40.00, -500);
        GLEntry.SetRange("Entry No.", EntryNoA, EntryNoB);

        // Act
        ModifiedCount := ClearAddReportingMgmt.ClearAmounts(GLEntry);

        // Assert: both entries processed, LCY Amount untouched, all ACY fields zeroed
        Assert.AreEqual(2, ModifiedCount, 'Both entries must be counted as modified');

        GLEntry.Get(EntryNoA);
        Assert.AreEqual(500, GLEntry.Amount, 'Entry A LCY Amount must not be modified');
        Assert.AreEqual(0, GLEntry."Additional-Currency Amount", 'Entry A "Additional-Currency Amount" must be cleared');
        Assert.AreEqual(0, GLEntry."Add.-Currency Debit Amount", 'Entry A "Add.-Currency Debit Amount" must be cleared');
        Assert.AreEqual(0, GLEntry."Add.-Currency Credit Amount", 'Entry A "Add.-Currency Credit Amount" must be cleared');

        GLEntry.Get(EntryNoB);
        Assert.AreEqual(-500, GLEntry.Amount, 'Entry B LCY Amount must not be modified');
        Assert.AreEqual(0, GLEntry."Additional-Currency Amount", 'Entry B "Additional-Currency Amount" must be cleared');
        Assert.AreEqual(0, GLEntry."Add.-Currency Debit Amount", 'Entry B "Add.-Currency Debit Amount" must be cleared');
        Assert.AreEqual(0, GLEntry."Add.-Currency Credit Amount", 'Entry B "Add.-Currency Credit Amount" must be cleared');
    end;

    local procedure InsertGLEntry(AddCurrAmt: Decimal; AddCurrDebit: Decimal; AddCurrCredit: Decimal; LCYAmount: Decimal): Integer
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
        GLEntry."Posting Date" := 20260101D;
        GLEntry.Amount := LCYAmount;
        GLEntry."Additional-Currency Amount" := AddCurrAmt;
        GLEntry."Add.-Currency Debit Amount" := AddCurrDebit;
        GLEntry."Add.-Currency Credit Amount" := AddCurrCredit;
        GLEntry.Insert(false);
        exit(NextEntryNo);
    end;
}
