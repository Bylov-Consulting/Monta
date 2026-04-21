# Test Plan: MON-94 Clear Additional Reporting Amounts

## Test Coverage Summary

| Category | Tests | Codeunit | File |
|----------|-------|----------|------|
| Unit (original) | 8 | 90100 | `ClearAddReportingTests.Codeunit.al` |
| Unit (gap-fill) | 5 | 90101 | `ClearAddReportingUnitTests.Codeunit.al` |
| Integration (report) | 3 | 90102 | `ClearAddReportingReportTests.Codeunit.al` |
| Scenario (end-to-end) | 3 | 90103 | `ClearAddReportingScenarioTests.Codeunit.al` |
| Edge cases | 6 | 90104 | `ClearAddReportingEdgeTests.Codeunit.al` |

**Total: 25 tests** across 5 codeunits, all isolated via `[TransactionModel(TransactionModel::AutoRollback)]` so inserts roll back at each test boundary.

## Key Test Scenarios

### Codeunit contract (unit + edge)
- Each of the three ACY fields is cleared individually when it is the only non-zero field (`SingleField*Only` × 3)
- Mixed batches return only the count of rows actually modified (`MixedBatchReturnsOnlyModifiedCount`) — the critical guard on the skip-logic/counter interaction
- Full-table scan path: no filter applied, all non-zero rows processed (`NoFilterProcessesAllNonZeroEntries`) — important because Confirm is the only gate against this in production
- Idempotency: repeated runs return count 0 after first clear (`ClearedEntryCountStableOnRepeatedRuns`)
- Sign-agnostic: negative, positive, and mixed-sign ACY values are all cleared (`NegativeAmountsAreCleared`, `MixedSignsClearCorrectly`, `LCYAmountUnchangedWithAllSignsOfACYValues`)
- Decimal boundaries: sub-precision (`0.00001`) and very large (`9999999999.99`) values are still cleared
- LCY `Amount` is never touched, regardless of its sign or the ACY field values

### Report UX (integration)
- `Report.RunModal` clears the target entry, shows the success `Message`, and the message text contains the count
- Confirm-returns-false aborts: no fields are modified, no `Message` is shown (verified via deliberate omission of `MessageHandler` — the test framework fails loudly if the path is ever accidentally reached)
- Request-page filters propagate correctly from the UI through the dataitem into the codeunit (`ReportPassesRequestPageFiltersToCodeunit`)

### Admin workflows (scenario)
- Single-account, single-month cleanup with five entries and varied LCY amounts (`AdminCleansUpAccidentalACYOnSingleAccount`) — realistic production case
- Period-scoped cleanup leaves other periods completely untouched (`AdminCleansOnlyTargetPeriodLeavingOtherPeriodsUntouched`) — the misuse scenario the Jira ticket describes
- Abort-at-confirm preserves every byte of data (`AdminAbortsAtConfirmLeavesAllDataIntact`) — the most important safety-net test for a destructive admin tool

## Test Infrastructure

- **Framework:** AL Test Framework, `Assert: Codeunit "Library Assert"` (Microsoft, BC 27).
- **Dependencies:** `Library Assert` + `Any` (as scaffolded by AL-Go `Create a new test app`). No reliance on `Tests-TestLibraries` / `Library - Variable Storage` so we can keep the dep graph minimal.
- **Fixture pattern:** each codeunit has its own local `InsertGLEntry(...)` with `FindLast + 1` for unique Entry No and `Insert(false)` to bypass validation. Independence between tests is guaranteed by `[TransactionModel(TransactionModel::AutoRollback)]`, which rolls back all inserts and codeunit-side `Modify(false)` calls at the end of each test.
- **Message capture:** codeunit-level `var LastMessage: Text[1024]` assigned in the `[MessageHandler]`; tests assert with `LastMessage.Contains(...)`. Simpler than `Library - Variable Storage` queues and sufficient because each test triggers at most one `Message(...)` call.
- **Abort detection:** the abort-path tests deliberately omit `MessageHandler` — if the code ever mistakenly calls `Message(...)` on the abort path, the BC test framework raises "unexpected UI handler" and the test fails.

## Test Execution

- **Local runner:** not yet configured (see `memory/tdd_red_phase_required.md` — local container + VS Code integration is on the roadmap).
- **CI runner:** GitHub Actions workflow `Test Current` against the feature branch. Dispatch with:
  ```
  gh workflow run "Current.yaml" --ref MON-94-gl-entries-addl-reporting-cleanup
  ```
- **Prior result (baseline, 8 tests):** run `24718619557` — 8/8 pass in 0.485s.
- **Current expected result (25 tests):** recorded after the next dispatch.

## Coverage Analysis

**Covered:**
- Every branch of `HasAdditionalReportingAmount` OR (individually and combined)
- Counter accuracy in homogeneous, mixed, empty, and already-blank batches
- Sign, precision, and magnitude boundaries of Decimal values
- Request-page filter propagation through the report
- Confirm-yes, Confirm-no, and `GuiAllowed`-gate-skipped paths (the last implicitly, because `Report.RunModal` in a test session has `GuiAllowed = true`)
- Isolation between tests via TransactionModel

**Not covered (deliberate deferrals):**
- **Headless execution path** (`GuiAllowed = false` → Confirm skipped entirely). Blocked by the fact that `Report.RunModal` in a test session behaves as GUI-allowed. The security reviewer flagged this as a design hole (see recommendations); once fixed, a test becomes possible.
- **Permission-set enforcement.** Blocked by not yet shipping a permission set. When one exists, add a `TestPermissions = Restrictive` codeunit that asserts unauthorised users get a permission error.
- **Lock escalation / batched commit behaviour.** Requires a multi-million-row fixture to exercise meaningfully — not feasible in this test suite.

## Test Maintenance Notes

- If the implementation ever changes from `Modify(false)` per row to `ModifyAll` per field, the `MixedBatchReturnsOnlyModifiedCount` and `ClearedEntryCountStableOnRepeatedRuns` tests will fail — that is intentional and signals a design regression.
- If any test's `InsertGLEntry` helper is changed to call `Validate` instead of raw field assignment, it will trigger base-app triggers on G/L Entry that may post additional records, breaking the tight count assertions. Keep the helpers raw.
- File naming follows PascalCase (CodeCop AA0215). Adding any new test codeunit in this feature family should follow `ClearAddReporting*Tests.Codeunit.al`.
