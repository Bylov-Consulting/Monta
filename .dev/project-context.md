# Project Context (Auto-Maintained)

**Last Updated:** 2026-04-21 by MON-94 feature dev

> **Purpose:** This document is the project's memory. ALL agents read this FIRST before doing any exploration or searches. Agents update this when they learn new information. This prevents redundant codebase exploration and speeds up all workflows.

## Project Overview

**App Name:** Monta Utility
**Publisher:** Bylov Consulting
**Version:** 1.0.0.0
**App ID:** 5780c9b9-f121-4c6e-885d-e39417c3e7fc
**Platform / Application Target:** 27.0.0.0 (BC 2025 wave 2 / v27)
**Country:** w1 (worldwide)
**Object ID Range:** 90000–90010 (10 IDs reserved)
**Features Flags:** `NoImplicitWith` (explicit `with` required)
**AL-Go Type:** Per-Tenant Extension (PTE), template `microsoft/AL-Go-PTE@main`
**Base App Objects Used:** _None yet — no extensions defined_

**State:** Fresh scaffold. The AL-Go PTE template and app manifest are in place, but no custom AL objects have been written yet. Sections below marked _empty_ should be filled in as the first objects land.

## Directory Structure

```
/ (repo root)
├── Monta Utility/              # App folder (name contains a space — quote in shells)
│   ├── .vscode/launch.json     # Debug launch config
│   ├── app.json                # App manifest (id, version, idRange, dependencies)
│   └── *.al                    # Objects at folder root (flat structure)
├── Monta Utility Tests/        # Test app folder (listed in testFolders)
│   ├── .vscode/launch.json
│   ├── app.json                # Depends on main app + Library Assert + Any
│   └── *.Codeunit.al           # Test codeunits (Subtype=Test)
├── .AL-Go/
│   ├── settings.json           # Local AL-Go settings
│   ├── localDevEnv.ps1         # Docker-based local dev env bootstrap
│   └── cloudDevEnv.ps1         # BC SaaS dev env bootstrap
├── .github/
│   ├── AL-Go-Settings.json     # Pipeline settings (type=PTE, CodeCop on, self-hosted windows)
│   └── workflows/*.yaml        # AL-Go CI/CD (auto-managed — do not edit by hand)
├── .dev/project-context.md     # ← this file
├── .claude/rules/              # Profile instructions (machine-local, gitignored)
└── al.code-workspace           # VS Code workspace
```

**Object-folder convention:** flat — all `.al` files live directly under `Monta Utility/` (and `Monta Utility Tests/` for tests). Filenames follow PascalCase `<ObjectNameNoSpaces>.<Suffix>.al` (e.g. `ClearAddReportingMgmt.Codeunit.al`) — enforced by CodeCop rule `AA0215`. Object names themselves keep spaces and dots (`"Clear Add. Reporting Mgmt."`). Revisit folder layout if file count grows past ~20 objects.

**`appFolders` / `testFolders`** in `.github/AL-Go-Settings.json` are explicitly set: `["Monta Utility"]` and `["Monta Utility Tests"]`.

## Key Objects Registry

### Tables & Extensions
_Empty — no tables or tableextensions defined yet._

### Pages & Extensions
_Empty — no pages or pageextensions defined yet._

### Codeunits
| Object | ID | Purpose | Key Procedures |
|--------|----|---------|----------------|
| `Clear Add. Reporting Mgmt.` | 90000 | Business logic for blanking Additional Reporting amounts on G/L Entry | `ClearAmounts(var GLEntry: Record "G/L Entry"): Integer` — loops filtered records, blanks fields 68/69/70, returns modified count |

### Enums / Enum Extensions
_Empty._

### Reports / XMLPorts / Queries
| Object | ID | Purpose |
|--------|----|---------|
| Report `Clear Add. Reporting Amounts` | 90001 | ProcessingOnly admin report — request page with Posting Date / G/L Account No. / Document No. filters + confirm dialog; delegates to `Codeunit 90000.ClearAmounts` |

### Permission Sets / Entitlements
| Object | ID | Purpose |
|--------|----|---------|
| PermissionSet `Monta GL Cleanup` | 90002 | Grants Execute on Codeunit 90000 + Report 90001 and Read/Modify on tabledata `G/L Entry` — the minimum surface needed to run the MON-94 cleanup. `Assignable = true`, caption `Monta: Clear Additional Reporting Amounts on G/L Entries`. Assign only to delegated GL-cleanup admins; do not include in general-user profiles. |

## Architectural Patterns

### Logic vs. UX separation (TDD-driven)
- **Rule:** testable logic lives in a `*Mgmt.Codeunit.al`; reports/pages are thin wrappers over the request page + a single codeunit call.
- **Why:** processing reports can't be unit-tested cleanly (Confirm dialogs, request pages) — but a plain codeunit procedure taking a filtered `var Record` is trivial to test.
- **Example:** `Codeunit 90000 "Clear Add. Reporting Mgmt.".ClearAmounts(var GLEntry)` called from `Report 90001.OnPreDataItem`, which then `CurrReport.Break()`s to prevent per-record iteration.

### Bulk-record mutation
- **Shape:** procedure takes `var Record` with filters applied; does `CopyFilters` to a local Record, then `SetLoadFields` on only the columns read or mutated, then `FindSet(true)` for write-lock, loops with in-code condition check, `Modify(false)` per change, returns count.
- **Why `SetLoadFields`:** G/L Entry has 80+ fields; loading all of them on a multi-million-row scan wastes SQL-to-server bandwidth. `SetLoadFields("Entry No.", "Additional-Currency Amount", "Add.-Currency Debit Amount", "Add.-Currency Credit Amount")` cuts per-page data transfer ~5×. Partial loading interacts cleanly with `Modify(false)` — only loaded fields are written, unloaded fields retain their DB values.
- **Why `Modify(false)`:** these are one-shot cleanups on plain Decimal fields — `Validate` triggers aren't needed and would break the bulk semantics.
- **Why in-code condition (vs. `SetFilter "<>0"`):** AL has no clean OR-across-fields filter; an in-code `HasAdditionalReportingAmount` check is simpler than three passes and keeps the modified-count accurate.

### Validation Pattern
- **Location:** _still TBD for extended base-app fields — MON-94 doesn't touch them._

### Extension Pattern
- **Field ID range:** 90000..90010 for main app code, 90100..90199 for tests. 10 main-app IDs is tight — revisit the range if we add more than 5 more objects.
- **Field naming prefix:** _still TBD — MON-94 doesn't add custom fields._

### Error Handling
- **Pattern for admin reports:** Confirm dialog guarded by `GuiAllowed()` + `Message` on success. `Error()` is reserved for invariant violations.
- **Label naming:** `*Qst` for confirm prompts, `*Msg` for informational messages (see `ConfirmClearQst` / `ClearedCountMsg` in Report 90001).

## Base App Integration Points

### Tables We Read/Write
- **G/L Entry (17):** `Codeunit 90000` modifies fields 68 `"Additional-Currency Amount"`, 69 `"Add.-Currency Debit Amount"`, 70 `"Add.-Currency Credit Amount"`. No extension — we only write existing standard fields via `Record.Modify(false)`.

### Events We Subscribe To
_None yet._

### Procedures We Call
_None from base app (yet) — MON-94 is standalone._

## Common Code Locations

- **Clear Additional Reporting amounts (MON-94):** `Codeunit 90000 "Clear Add. Reporting Mgmt.".ClearAmounts(var GLEntry)`
- **Processing-report entry point for the above:** `Report 90001 "Clear Add. Reporting Amounts"` (Role Explorer → Administration)

## Dependencies

### Internal Dependencies
_None — single-app project._

### External Dependencies
_None — `app.json` `dependencies` array is empty. Add entries here when dependencies are introduced (id, name, publisher, min version)._

## Testing Infrastructure

### Test App
- **Folder:** `Monta Utility Tests/`
- **app.json id:** `66ea9ba7-587d-4c7e-922c-6cca1682b962`
- **idRanges:** 90100..90199
- **Dependencies:** Main app (`Monta Utility`, id `5780c9b9-...`), Microsoft `Library Assert` (`dd0be2ea-...`), Microsoft `Any` (`e7320ebb-...`)
- **Created via:** GitHub Actions workflow `Create a new test app` (AL-Go PTE). Run `gh workflow run "Create a new test app" --ref <branch> -f name="..." -f publisher="..." -f idrange="..." -f sampleCode=true -f directCommit=true -f useGhTokenWorkflow=true` from any feature branch.
- **Post-scaffold fix-ups:** (a) add the main app as a dependency (AL-Go doesn't do this automatically); (b) register the folder in `.github/AL-Go-Settings.json` under `testFolders`.

### Test Codeunits
| Object | ID | Covers |
|--------|----|--------|
| `Clear Add. Reporting Tests` | 90100 | `Codeunit 90000.ClearAmounts` — 8 baseline tests: field-by-field clearing, LCY untouched, filter respect, modified count, blank no-op, empty-set no-op |
| `Clear Add. Rep. Unit Tests` | 90101 | Gap-fill unit tests: mixed-batch counter, single-field-only variants, no-filter full-table path (5 tests) |
| `Clear Add. Rep. Report Tests` | 90102 | Report 90001 integration: RunModal success, confirm-abort, request-page filter propagation (3 tests) |
| `Clear Add. Rep. Scenario Tests` | 90103 | End-to-end admin workflows: single-account cleanup, period-scoped cleanup, abort-preserves-everything (3 tests) |
| `Clear Add. Rep. Edge Tests` | 90104 | Boundaries: negatives, mixed signs, sub-precision, very-large decimals, idempotency, LCY-untouched-all-signs (6 tests) |

**Total coverage:** 25 tests. Baseline CI run for the first 8: `24718619557` (8/8 pass). Full-suite result pending the next `Test Current` dispatch.

### Test Data Setup
- **Pattern:** local helper `InsertGLEntry(...)` in each test codeunit. Uses `FindLast + 1` for unique `Entry No.` and `Insert(false)` to bypass validation.
- **Why `Insert(false)`:** we need raw G/L Entries with specific ACY values; running the real posting engine would be orders of magnitude slower and isn't what's under test.
- **Isolation:** every `[Test]` carries `[TransactionModel(TransactionModel::AutoRollback)]` — inserts and codeunit-side `Modify(false)` calls roll back at test end. This is how we handle the `FindLast + 1` collision concern.
- **Message capture:** codeunit-level `var LastMessage: Text[1024]` assigned in `[MessageHandler]`, assert with `LastMessage.Contains(...)`. Avoids adding `Tests-TestLibraries` dependency.
- **TestPermissions:** `Disabled` (test codeunit directly manipulates G/L Entry).

## Build & Pipeline

- **Pipeline:** AL-Go PTE (`microsoft/AL-Go-PTE@main`, SHA `28c060a` at last system-files update)
- **Runner:** `self-hosted, windows`
- **CICD trigger branches:** `main`, `release/*`
- **Code analyzers:** CodeCop enabled (`enableCodeCop: true`). UI/AppSource/PerTenant cops not explicitly toggled — default behavior applies.
- **`appFolders` / `testFolders`:** both empty in `.github/AL-Go-Settings.json` — update when folder layout is decided.
- **Local dev:** `.AL-Go/localDevEnv.ps1` (Docker) or `.AL-Go/cloudDevEnv.ps1` (BC SaaS sandbox).

## Publishing Metadata (unfilled in app.json)

The following fields in `Monta Utility/app.json` are empty strings and must be populated before any marketplace-style distribution (not blocking for PTE deployment to a tenant, but worth setting):

- `privacyStatement`, `EULA`, `help`, `url`, `logo`, `brief`, `description`

## Recent Changes Log

### 2026-04-22 — MON-94 warnings round
- Report 90001: `ApplicationArea` narrowed from `All` → `Suite`; blocks headless execution with `HeadlessNotSupportedErr` instead of silently skipping Confirm; shows a distinct `NoEntriesClearedMsg` when the cleanup finds nothing (no more misleading "Cleared ... on 0 G/L Entries"). (Teaching tips via `AboutTitle`/`AboutText` are Page-only and cannot be applied at the report level — see `memory/al_property_objecttype_gotchas.md`.)
- Codeunit 90000: emits audit telemetry via `Session.LogMessage('MON-94-0001', ..., TelemetryScope::ExtensionPublisher)` with `UserId`, `Filters`, and `ModifiedCount` dimensions — every run is now traceable in Application Insights. Telemetry label is `Locked = true`.
- Report test codeunit 90102: added `ReportShowsNoEntriesMessageOnZeroCount` to lock in the new distinct-zero-message behaviour.
- Main `app.json`: populated `brief`, `description`, `url`, and `help`.

### 2026-04-21 — MON-94 post-review hardening
- Added `SetLoadFields` on the G/L Entry scan in `Codeunit 90000` — significant perf win on large tenants.
- Aligned test app `platform` / `application` to `27.0.0.0` (was `1.0.0.0` / `22.0.0.0` — template leftovers).
- Added `PermissionSet 90002 "Monta GL Cleanup"` so the cleanup isn't silently SUPER-gated.

### 2026-04-21 — MON-94 feature dev
- Scaffolded test app `Monta Utility Tests` (id range 90100..90199) via GitHub Action `Create a new test app`; added main-app dependency and registered `appFolders` / `testFolders` in AL-Go settings.
- Added `Codeunit 90000 "Clear Add. Reporting Mgmt."` and `Report 90001 "Clear Add. Reporting Amounts"` implementing the MON-94 cleanup.
- Added `Codeunit 90100 "Clear Add. Reporting Tests"` with 8 tests driving the implementation (TDD).
- Established architectural patterns: logic-in-codeunit / UX-in-report separation, bulk-mutation shape (`CopyFilters` → `SetLoadFields` → `FindSet(true)` → in-code condition → `Modify(false)` → count), label naming (`*Qst` / `*Msg`).

### 2026-04-21 — init-context
- Created `.dev/project-context.md` (this file) from the AL dev profile template.
- Linked profile instructions at `.claude/rules/al-development-profile.md` (machine-local; added `.claude/rules/` and `.claude/worktrees/` to `.gitignore`).
- Confirmed project state: AL-Go PTE scaffold, BC v27 target, ID range 90000–90010, zero custom objects, zero dependencies.

---

## Instructions for Agents

**BEFORE doing ANY Glob/Grep searches or exploration:**
1. Read this document completely
2. Check if the information you need is already here
3. Only search if information is missing or unclear
4. UPDATE this document after you learn something new about the project

**When updating:**
- Append to relevant sections (don't rewrite everything)
- Add a dated entry to Recent Changes Log with your agent name
- Be concise but specific
- Include file paths and object IDs

This document is your first stop — use it to save time.
