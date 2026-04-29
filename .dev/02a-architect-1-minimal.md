# Solution Plan A — MINIMAL Approach

**Architect:** 1 of 2 (MINIMAL)
**Generated:** 2026-04-29
**Based on:** `.dev/01-requirements.md` (decisions D-1..D-10 locked)
**BC target:** v27 platform / runtime 16.0; DC dependency 27.3
**Object count:** 3 (TableExtension, PageExtension, Codeunit)

---

## Headline

Three objects. No wrapper, no install codeunit, no notification. The subscriber reads `"CDC Document Capture Setup"` inline; if the record is missing it exits cleanly (no auto-create, no telemetry). The `InitValue = true` on the toggle field guarantees the default-ON contract (D-5) the moment DC's own setup-record initialiser runs (which it does on first DC use). Telemetry only fires on actual suppression.

---

## Part 1 — Architecture & Design

### 1.1 High-level approach

Subscribe directly to `"CDC Document"::OnBeforeFindTemplateInCompanies`. Inside the subscriber, do three things and only three things:

1. `Setup.Get()` — exit if false (no record = clean tenant or admin-deleted; do not auto-create per D-5/D-7).
2. If the toggle is `false`, exit (FR-6: stock CDC behaviour preserved).
3. Set `IsHandle := true`, leave `Result := false`, emit one `Session.LogMessage` with `MON-DC-0001`.

That's the entire feature. No abstraction, no DI, no install-time bootstrap. The single setup `Get()` is the only side effect inside the subscriber besides the flag mutation.

### 1.2 BC base-app integration

| Object | Action | Reason |
|---|---|---|
| Table 6085573 `"CDC Document Capture Setup"` | Extend with one Boolean field | D-4 — toggle lives on DC's setup table |
| Page 6085625 `"CDC Setup - Purch. Approval"` | Extend — add field after `Rec."Use Acc. and Dim. App. Pms."` in `group(GeneralGroup)` | Sits naturally beside other behaviour switches (Order/Invoice/CreditMemo Approval). Avoids polluting the Email/4-eyes/Templates groups. |
| Table 6086302 `"CDC Document"` | Subscribe to `OnBeforeFindTemplateInCompanies` | Single event covers both call sites (lines 1044 and 1078 in BC 28 source) |

**Subscriber procedure signature (inferred from BC 28 source line 2958):**

```
[EventSubscriber(ObjectType::Table, Database::"CDC Document",
    'OnBeforeFindTemplateInCompanies', '', false, false)]
local procedure SuppressFindTemplateInCompanies(
    var FromCompany: Text[30];
    var FromTemplate: Record "CDC Template";
    SourceName: Text[250];
    var Result: Boolean;
    var IsHandle: Boolean)
```

Note `IsHandle` (singular, no 'd') matches the publisher exactly — typo in the DC API but we must match it.

**Residual risk (carried forward from requirements):** signature is verified against BC 28 source only. /develop must extract the BC 27.3 .app `SymbolReference.json` (or use the BC MCP `find_event_subscribers` / search_objects tools against the loaded 27.3 symbols) and confirm parameter order, types, and the `IsHandle` spelling before pasting the attribute. If 27.3 differs, this plan is wrong on that one line.

### 1.3 Testability architecture (per CLAUDE.md mandate)

**External dependencies:**
- `"CDC Document Capture Setup"` table read (impure — DB).
- `Session.LogMessage` (impure — telemetry sink).
- The event itself (boundary — DC owns it).

**Pure operations:** zero. There is no business logic worth abstracting. The "decision" reduces to `if Setup.Get() and Setup."Disable CDC Cross-Co. Tmpl." then suppress`. Lifting that into an interface would be ceremony, not testability.

**Mockable boundaries:** intentionally none. The minimal approach accepts that this 5-line subscriber cannot be unit-tested without a live DC environment, which matches D-9 (compile-only, sandbox smoke-test gate). This is the explicit trade-off for object-count minimality.

**Test strategy:** sandbox smoke-test only (see §6). No unit tests, no test codeunit, consistent with D-9.

If the BC-idiomatic alternative wants to introduce an `ICdcSetupReader` interface plus a mock — that is its differentiator. We don't.

### 1.4 Performance

Subscriber fires inside `GetTemplate` (line ~1044/1078), which already does cross-company loops. One additional `Setup.Get()` per call is negligible. No FlowFields, no SetLoadFields needed (singleton row).

### 1.5 Error handling

None. The subscriber must not raise errors — it is hot-path code inside a posting-adjacent flow. `Setup.Get()` returning false is the documented happy path for "no decision yet → don't change CDC behaviour." No `Error()`, no `TestField`.

### 1.6 BC patterns used

- TableExtension for adding fields to base tables (mandatory, never modify base).
- Event subscriber with IsHandled pattern (canonical BC injection point).
- Telemetry via `Session.LogMessage` with `Locked = true` label and `TelemetryScope::ExtensionPublisher` (matches MON-94 convention).
- `InitValue` for default semantics rather than an install codeunit.

### 1.7 Alternatives considered

| Alternative | Rejected because |
|---|---|
| Wrapper "Mgmt" codeunit between subscriber and `Setup.Get()` | 5-line subscriber doesn't need a wrapper; ceremony without testability gain (D-9 forbids tests anyway). |
| Install codeunit to write the toggle to true on first install | DC creates the singleton record itself; `InitValue = true` covers the case for free. An install codeunit risks racing DC's own initialiser and writing to a row that doesn't yet exist. |
| New Monta-owned setup table | D-4 explicitly says toggle lives on DC's setup table. |
| Per-category filter | D-3 suppresses for all categories — no filter wanted. |
| User notification on suppression | D-6 silent UX. |

---

## Part 2 — Implementation Plan

### 2.1 App.json fixups (`Monta Document Capture Utility/app.json`)

Current state: scaffolded but **broken** — `platform: "1.0.0.0"`, `application: "22.0.0.0"`, missing `runtime`, missing `dependencies` entry, empty `brief`/`description`, and `resourceExposurePolicy` allows source download (mismatched with intent for a thin redistribution layer).

Required edits:

| Field | New value | Why |
|---|---|---|
| `platform` | `"27.0.0.0"` | Match Monta Utility (D-1, C-1) |
| `application` | `"27.0.0.0"` | Match BC 27 base app target |
| `runtime` | `"16.0"` (add — currently missing) | Match BC 27 runtime, same as Monta Utility |
| `brief` | `"Suppresses Continia Document Capture cross-company template lookup, configurable per company on the DC Document Capture Setup card."` | Distinguish from Monta Utility's brief |
| `description` | `"Adds a per-company toggle to Continia Document Capture's setup card. When enabled (default), suppresses CDC's cross-company template lookup and the associated 'Copy template from CompanyX?' prompt by handling OnBeforeFindTemplateInCompanies. Telemetry-only — no user-facing notifications. Compile-verified only; pre-merge sandbox smoke test required (no automated tests shipped due to docker DC unavailability)."` | Documents D-6, D-9 inline |
| `url` | `"https://github.com/Bylov-Consulting/Monta-Utility"` | Match Monta Utility |
| `help` | `"https://github.com/Bylov-Consulting/Monta-Utility#readme"` | Match Monta Utility |
| `resourceExposurePolicy.allowDownloadingSource` | `true` | Align with Monta Utility (currently `false` in scaffold) |
| `resourceExposurePolicy.includeSourceInSymbolFile` | `true` | Align with Monta Utility |
| `resourceExposurePolicy.allowDebugging` | `true` (already) | Keep |
| `dependencies` | One entry — see below | New — add DC |

**`dependencies` entry for Continia Document Capture** — placeholder values to be confirmed by /develop by extracting the 27.3 .app's `NavxManifest.xml`:

```json
{
  "id": "6da8dd2f-e698-461f-9147-8e404244dd85",
  "name": "Continia Document Capture",
  "publisher": "Continia Software",
  "version": "27.3.0.0"
}
```

**[VERIFY]** /develop extracts the .app (rename to .zip, unpack `NavxManifest.xml`, read `<App>` element attributes) and replaces the four values above with the manifest's exact strings. The `id` and `publisher` are stable and already supplied; `name` and `version` are the most likely to need a typo correction (e.g., trailing build number suffix).

### 2.2 Dependencies folder content

Create `dependencies/` at repo root. Commit the DC 27.3 .app file plus its full transitive chain, because `installApps` does NOT auto-resolve transitive dependencies — every direct and transitive .app must be present.

Source folder (user's filesystem): `C:\Users\JeppeBylov\Downloads\DC27.3+EM27.3-NA-APP\App\BC 27.3 (BC 2025 Wave 2 CU3)\`

Files to copy into `dependencies/`:

| File (from source) | Purpose |
|---|---|
| `Document Capture/DC 27.3.0.330595 - 27.3 (BC 2025 Wave 2 CU3).app` | The DC app itself |
| `Base/Continia_System Application_*.app` | Continia System Application (transitive) |
| `Base/Continia_Online Connector_*.app` | Continia Online Connector (transitive) |
| `Base/Continia_Business Foundation_*.app` | Continia Business Foundation (transitive) |
| `Base/Continia_Approvals_*.app` | Continia Approvals (transitive) |
| `Core/Continia_Connector App_*.app` | Continia Connector App (transitive) |
| `Core/Continia_Core_*.app` | Continia Core (transitive) |
| `Delivery Network/Continia_Delivery Network_*.app` | Continia Delivery Network (transitive) |
| `Document Capture/Continia_Document Output_*.app` | Continia Document Output (transitive — used by DC) |

**[VERIFY]** /develop confirms the exact file list by either:
(a) inspecting DC 27.3 .app's `NavxManifest.xml` `<Dependencies>` block and walking each dependency's manifest until the closure is complete, or
(b) running an installApps dry-run against a clean BC 27.3 sandbox and adding any "missing dependency" errors to the list.

Azure OpenAI dependency may or may not apply — DC 28 lists it but DC 27.3 may not. /develop verifies and includes only if present in the 27.3 manifest.

**License/redistribution notice:** add `dependencies/README.md` with a short note: "These .app files are Continia Software's property, redistributed in this private repository under Continia's confirmed permission for internal AL-Go pipeline use. Do not redistribute outside this repository."

### 2.3 AL-Go settings changes

**`.github/AL-Go-Settings.json`** — append to `appFolders`:

```json
"appFolders": [
  "Monta Utility",
  "Monta Document Capture Utility"
],
"testFolders": [
  "Monta Utility Tests"
]
```

(Already correct for Monta Utility / testFolders.)

**`.AL-Go/settings.json`** — currently fully empty arrays; populate:

```json
{
  "country": "w1",
  "appFolders": ["Monta Utility", "Monta Document Capture Utility"],
  "testFolders": ["Monta Utility Tests"],
  "bcptTestFolders": [],
  "repoVersion": "1.3"
}
```

**`installApps` wiring** — the cleanest place is in `.github/AL-Go-Settings.json` so it applies to all CI runs. Add:

```json
"installApps": [
  "./dependencies/Continia_System Application_*.app",
  "./dependencies/Continia_Online Connector_*.app",
  "./dependencies/Continia_Business Foundation_*.app",
  "./dependencies/Continia_Approvals_*.app",
  "./dependencies/Continia_Connector App_*.app",
  "./dependencies/Continia_Core_*.app",
  "./dependencies/Continia_Delivery Network_*.app",
  "./dependencies/Continia_Document Output_*.app",
  "./dependencies/DC 27.3.0.330595 - 27.3 (BC 2025 Wave 2 CU3).app"
]
```

Order matters — DC last, transitive deps in dependency order. /develop should test by running the AL-Go "Update AL-Go System Files" workflow, then `CI/CD` build, and watch for any "missing reference" errors.

**[VERIFY]** Globs (`*`) inside `installApps` may or may not be supported by the AL-Go action version pinned at SHA `28c060a`. If not, /develop replaces each glob with the exact filename.

### 2.4 Object designs

#### Object A — TableExtension 50100

| Property | Value |
|---|---|
| Object ID | 50100 |
| Object name | `"Monta DC Setup Ext"` (16 chars, well within AL0305) |
| Filename | `Monta Document Capture Utility/MontaDCSetupExt.TableExt.al` |
| Extends | `"CDC Document Capture Setup"` |

**Field design:**

| Property | Value |
|---|---|
| Field number | 50100 |
| Field name | `"Disable CDC Cross-Co. Tmpl."` (28 chars — fits AL0305 with two slack chars) |
| Type | `Boolean` |
| Caption | `'Disable CDC Cross-Company Template Lookup'` (caption can exceed 30; only identifier is bound by AL0305) |
| ToolTip | `'Specifies whether Monta Document Capture Utility suppresses Continia Document Capture''s cross-company template lookup. When enabled, processing a document whose source name has no template match in the current company will skip the cross-company search and the "Copy template from..." prompt entirely, falling through to the "create new template" path. Default is enabled.'` |
| `InitValue` | `true` |
| `DataClassification` | `CustomerContent` (matches the rest of the setup table fields per the source we read) |

No `OnValidate` trigger — the field is a passive flag read by the subscriber. Mutation has no side effects beyond the next subscriber invocation reading the new value.

#### Object B — PageExtension 50101

| Property | Value |
|---|---|
| Object ID | 50101 |
| Object name | `"Monta DC Setup PurchAppr Ext"` (28 chars — fits AL0305) |
| Filename | `Monta Document Capture Utility/MontaDCSetupPurchApprExt.PageExt.al` |
| Extends | `"CDC Setup - Purch. Approval"` |

**Layout placement:**

`addafter("Use Acc. and Dim. App. Pms.")` inside `group(GeneralGroup)` (the inner group, which contains the existing approval-toggle fields). This places the new field next to other behaviour switches and before the `"Enable Standard Notification"`/`"Include Appr. Entries On Hold"`/`"Keep On Hold"` cluster.

**Field on page:**

```
field("Disable CDC Cross-Co. Tmpl."; Rec."Disable CDC Cross-Co. Tmpl.")
{
    ApplicationArea = All;
    ToolTip = 'Specifies whether Monta Utility suppresses Continia Document Capture''s cross-company template lookup. When enabled (default), the "Copy template from CompanyX?" prompt is skipped and CDC creates a new template directly. Added by Monta Document Capture Utility.';
}
```

The page-level ToolTip is a slightly shorter restatement of the field-level ToolTip — BC pages override field-level ToolTip with their own when both are present.

**No `OnValidate` trigger on the page side either** — same reason as the field.

#### Object C — Codeunit 50102 (event subscriber)

| Property | Value |
|---|---|
| Object ID | 50102 |
| Object name | `"Monta DC Suppress Tmpl. Sub."` (28 chars — fits AL0305) |
| Filename | `Monta Document Capture Utility/MontaDCSuppressTmplSub.Codeunit.al` |
| `SingleInstance` | `false` (default — subscriber doesn't hold state; SingleInstance carries lifecycle risks for nothing in return) |
| `Subtype` | (default — no Test/Install) |

**Procedure body (full):**

```
[EventSubscriber(ObjectType::Table, Database::"CDC Document",
    'OnBeforeFindTemplateInCompanies', '', false, false)]
local procedure SuppressCrossCompanyTemplateLookup(
    var FromCompany: Text[30];
    var FromTemplate: Record "CDC Template";
    SourceName: Text[250];
    var Result: Boolean;
    var IsHandle: Boolean)
var
    Setup: Record "CDC Document Capture Setup";
    TelemetryDims: Dictionary of [Text, Text];
begin
    if not Setup.Get() then
        exit;
    if not Setup."Disable CDC Cross-Co. Tmpl." then
        exit;

    IsHandle := true;
    Result := false;

    TelemetryDims.Add('EventType', 'CdcCrossCompanyLookupSuppressed');
    TelemetryDims.Add('CompanyName', CompanyName());
    TelemetryDims.Add('SourceNameLength', Format(StrLen(SourceName)));
    Session.LogMessage(
        'MON-DC-0001',
        SuppressedTelemetryLbl,
        Verbosity::Verbose,
        DataClassification::SystemMetadata,
        TelemetryScope::ExtensionPublisher,
        TelemetryDims);
end;

var
    SuppressedTelemetryLbl: Label 'Monta Utility suppressed CDC cross-company template lookup.', Locked = true;
```

**Implementation notes for /develop:**

- The label is `Locked = true` so it never gets translated — telemetry is always English (matches MON-94 convention).
- Verbosity is `Verbose` per FR-4. (MON-94 used `Normal`; suppression is more frequent so `Verbose` is correct here — only surfaces if Application Insights is filtered down.)
- `SourceName` itself is **not** logged (privacy — D-6 implies SystemMetadata, no customer doc names). Only its length, as a coarse signal that suppression is hitting real documents not edge cases.
- `CompanyName()` is fine as SystemMetadata — it's a tenant-internal identifier, not a person-identifiable data point.
- `FromCompany`, `FromTemplate`, `SourceName` are read-only in this branch — we don't mutate them, even though they're `var`. The publisher's `var` keyword is structural; semantics are ours to choose.
- Procedure is `local` because the event subscriber attribute is the only entry point.

**Why no SingleInstance:** the subscriber is stateless. SingleInstance would mean the codeunit instance survives across calls in the session, which is fine functionally but adds a session-leak surface for zero benefit when the per-call cost is one `Setup.Get()` (cached by the BC kernel anyway).

### 2.5 Object allocation

| ID | Object | Folder |
|---|---|---|
| 50100 | TableExtension `"Monta DC Setup Ext"` | `Monta Document Capture Utility/` |
| 50101 | PageExtension `"Monta DC Setup PurchAppr Ext"` | `Monta Document Capture Utility/` |
| 50102 | Codeunit `"Monta DC Suppress Tmpl. Sub."` | `Monta Document Capture Utility/` |

97 IDs (50103..50199) reserved for future DC extensions in this app.

### 2.6 Implementation sequence (steps for /develop, in order)

1. **Fix `Monta Document Capture Utility/app.json`** — set `platform`, `application`, add `runtime`, populate `brief`/`description`/`url`/`help`, align `resourceExposurePolicy`, leave `dependencies: []` for now (next step adds DC after manifest extraction).
2. **Create `dependencies/` folder at repo root and copy DC 27.3 .app + transitive chain** — file list per §2.2. Add `dependencies/README.md` redistribution note.
3. **Extract DC 27.3 manifest** — rename `DC 27.3.0.330595*.app` → `.zip`, unzip, open `NavxManifest.xml`, read `<App Id Name Publisher Version>` and dependency closure. Confirm/correct the file list in §2.2.
4. **Update `app.json` `dependencies` array** with the exact id/name/publisher/version from the manifest.
5. **Update `.AL-Go/settings.json`** — populate `appFolders`, `testFolders`, `country`, `repoVersion`.
6. **Update `.github/AL-Go-Settings.json`** — append `"Monta Document Capture Utility"` to `appFolders`; add `installApps` array; ensure DC and all transitives are listed in dependency-resolution order.
7. **Run AL-Go "Update AL-Go System Files" workflow** to sync any pipeline changes the dependencies need.
8. **Local symbol download** — `Ctrl+Shift+P` → `AL: Download symbols` against a sandbox with DC installed, OR rely on the .app files in `dependencies/` being picked up by the AL extension via `al.packageCachePath` settings. Confirm `Microsoft.Dynamics.Nav.AddIns.dll` and DC symbols are visible to IntelliSense.
9. **Verify event signature against BC 27.3 symbols** — open DC's symbolReference (via the AL extension's "Go to Definition" on `Database::"CDC Document"`, then search for `OnBeforeFindTemplateInCompanies`). Confirm parameter list matches §1.2. If different, update §1.2 and the subscriber attribute before writing the codeunit.
10. **Write TableExtension 50100** (`MontaDCSetupExt.TableExt.al`).
11. **Write PageExtension 50101** (`MontaDCSetupPurchApprExt.PageExt.al`).
12. **Write Codeunit 50102** (`MontaDCSuppressTmplSub.Codeunit.al`).
13. **Compile** — `al-compile` against the new app folder. Must be clean (no warnings, no errors). CodeCop is on; `NoImplicitWith` is enabled — every `with` (we have none) and every uncaught field reference must compile without warning.
14. **Commit** — three commits or one, the user's call. Each commit body must include the line: `compile-verified only — docker constraint: DC not in test container.` (per D-9).
15. **Open PR.**
16. **Sandbox smoke test** (per §6 below) — REQUIRED before merge.
17. **Merge to main.**
18. **Update `.dev/project-context.md`** — append the three new objects, the DC dependency note, the `MON-DC-NNNN` telemetry-ID convention, and a link to the sandbox-smoke-test result.

### 2.7 Assumptions

- **[VERIFY]** DC 27.3's `OnBeforeFindTemplateInCompanies` signature exactly matches BC 28's (5 params: `var Text[30]`, `var "CDC Template"`, `Text[250]`, `var Boolean`, `var Boolean`, in that order, with `IsHandle` spelled without 'd').
- **[VERIFY]** DC's app id `6da8dd2f-e698-461f-9147-8e404244dd85` is identical between DC 27.3 and DC 28.
- **[VERIFY]** Transitive dependency closure for DC 27.3 matches the list in §2.2; specifically that Azure OpenAI is not required at the 27.3 build.
- **[VERIFY]** Field ID `50100` on the DC setup table doesn't clash with another extension already deployed on the target SaaS tenants. (Risk is low — 50100 is a customer extension ID range and DC's own setup table should not have other extensions on a typical Monta tenant, but worth confirming.)
- **[VERIFY]** `group(GeneralGroup)` (inner) is the right placement; if Monta has UX preference for a separate `group("Monta Utility")` outside `General`, /develop adjusts.
- **[VERIFY]** AL-Go `installApps` accepts globs at template SHA `28c060a`; otherwise replace with exact filenames.
- Assumed: DC creates the singleton `"CDC Document Capture Setup"` row on its own first invocation (this is canonical DC behaviour). If DC ever ships a build where that's not true, our `Setup.Get() = false` early-exit is the correct silent-fallback.
- Assumed: `CompanyName()` is safe SystemMetadata in this telemetry context (it is — same call is used in MON-94 implicitly via session metadata).

---

## Part 3 — Telemetry

| Property | Value |
|---|---|
| Event ID | `MON-DC-0001` |
| Verbosity | `Verbose` |
| DataClassification | `SystemMetadata` |
| TelemetryScope | `ExtensionPublisher` |
| Label name | `SuppressedTelemetryLbl`, `Locked = true` |
| Custom dimension 1 | `EventType = 'CdcCrossCompanyLookupSuppressed'` (stable string for KQL filtering) |
| Custom dimension 2 | `CompanyName = CompanyName()` (tenant-internal identifier — SystemMetadata-safe) |
| Custom dimension 3 | `SourceNameLength = Format(StrLen(SourceName))` (coarse signal that real docs are flowing through; raw name not logged) |

ID convention `MON-DC-NNNN` distinguishes from `MON-94-NNNN` (existing MON-94 audit telemetry). Future DC-related events in this app increment the trailing 4-digit counter (`MON-DC-0002`, `MON-DC-0003`, …). The `DC` segment is the area code, not a ticket — appropriate because this app may host multiple unrelated DC extensions over time. Document the convention in project-context.md after merge.

---

## Part 4 — Sandbox smoke-test plan (substitute proof gate per D-9)

Run before merging the PR. All steps performed manually on a real BC SaaS sandbox.

### Preconditions

1. BC SaaS sandbox tenant provisioned (BC v27.3 or later — `https://businesscentral.dynamics.com/<tenant>?company=<X>&aid=PRODUCTION` with sandbox flag).
2. Continia Document Capture 27.3 installed and licensed. Confirm via `Extension Management` page that DC shows version 27.3.0.330595 (or build the user's evaluation has).
3. At least two companies in the sandbox: e.g., `CRONUS US` and `CRONUS US 2`. Both companies have DC installed and at least one PDF/Document Category set up.
4. In `CRONUS US 2`, create a CDC vendor template named e.g. `"ACME-INVOICE-TEMPLATE"` matching a known source name. In `CRONUS US`, do NOT create that template.
5. Side-load the new `Monta Document Capture Utility` app via `Extension Management → Upload Extension` (Dev scope is fine for smoke test).

### Test 1 — Toggle ON (default), suppression confirmed

1. In `CRONUS US`, open page `"Document Capture Setup / Purchase Approval"`.
2. **Verify:** the new field `"Disable CDC Cross-Company Template Lookup"` is visible in the General group, value = TRUE (default), tooltip mentions Monta Utility.
3. Send a PDF (or use CDC's "Test Document" feature) into `CRONUS US` whose source name matches `"ACME-INVOICE-TEMPLATE"` exactly. CDC should look for a local template, fail, and would normally search other companies.
4. **Expected:** NO Confirm dialog appears. CDC falls through to the "create new template" path. Document is registered with no template.
5. **Verify telemetry** — open `Help → Help & Support → Troubleshooting → View telemetry` (or query Application Insights with `traces | where customDimensions.eventId == 'MON-DC-0001'`). Confirm one row with:
   - `eventId = MON-DC-0001`
   - `customDimensions.EventType = CdcCrossCompanyLookupSuppressed`
   - `customDimensions.CompanyName = CRONUS US`
   - `customDimensions.SourceNameLength` is a positive integer.
   - Message: `Monta Utility suppressed CDC cross-company template lookup.`

### Test 2 — Toggle OFF, stock CDC behaviour preserved (FR-6)

1. In `CRONUS US`, on the same setup card, toggle the field OFF.
2. Repeat the document-import step from Test 1.
3. **Expected:** the `"Copy template from CRONUS US 2?"` Confirm dialog appears (stock CDC behaviour). Click `No`.
4. **Verify telemetry:** NO new `MON-DC-0001` row recorded for this run (subscriber was a no-op, FR-4).

### Test 3 — Setup record absent (clean-tenant edge case)

1. In a fresh sandbox company (`CRONUS US 3`) where DC has been installed but no document has yet been processed (so `"CDC Document Capture Setup"` row may not yet exist):
2. **Verify:** opening the setup page should auto-insert the record with `InitValue = true` honoured. Page shows the toggle as TRUE.
3. Process a document. Suppression should fire (Test 1 path). If the page-open-creates-record assumption is wrong and the row doesn't exist when `FindTemplateInCompanies` fires, the subscriber's `Setup.Get() = false` branch silently falls through — stock CDC behaviour. **Either outcome is acceptable per the design contract.**

### Test 4 — Page tooltip & UX

1. Hover the new field. **Verify:** tooltip text is exactly the string from §2.4 Object B.
2. Toggle OFF, then ON, then refresh the page. **Verify:** value persists.

### Test 5 — No regression in Monta Utility (existing app)

1. Run the `Clear Add. Reporting Amounts` report from `CRONUS US`. Confirm it still works (this is the MON-94 feature, totally unrelated). **Verify:** unchanged behaviour.

### Pass criteria (all must hold)

- [ ] Test 1 suppression silent + telemetry visible.
- [ ] Test 2 stock dialog appears + no telemetry.
- [ ] Test 3 either auto-create-with-default OR silent-fallthrough — one of the two.
- [ ] Test 4 tooltip + persistence correct.
- [ ] Test 5 no regression.

Document the run in `.dev/03-code-review.md` D-list as the proof-of-correctness, with sandbox URL, run date, and screenshots of telemetry rows.

---

## Part 5 — Trade-offs & weaknesses (honest)

### What MINIMAL does NOT handle

1. **No abstraction = no unit testability.** The subscriber cannot be unit-tested. D-9 makes this acceptable, but if D-9 is ever lifted (DC becomes installable in a docker image), the BC-idiomatic approach already has its mockable interface in place; we'd have to refactor.

2. **No install codeunit means edge case: tenant where DC is installed but the singleton row never got created before the first document arrives.** The subscriber's `Setup.Get() = false` branch silently falls through, which means stock CDC behaviour for that one call. By the next call DC's own `Setup-Get` codeunit will have inserted the row and `InitValue = true` will kick in. The "first call after install" is therefore a one-shot stock-behaviour event — telemetry will show no `MON-DC-0001` for that document. **This is invisible to users but is a small contract violation against D-5 ("default = ON on install").** Acceptable trade-off for the simplicity gain; but a 4th object (install codeunit doing `Setup.Init()` + `Setup.Insert(true)` if missing) would close it.

3. **No error fence.** If DC ever changes the event signature in a minor build (which is what the residual-risk verification step is for), the subscriber stops compiling — caught at build time, not runtime. But if DC adds a 6th parameter in a minor release of 27.3 (unlikely but possible), our app fails to install on tenants with the newer DC. There is no graceful fallback. The BC-idiomatic approach with a wrapper codeunit and parameter-by-parameter mapping is no better here — both approaches break on signature drift.

### Edge cases

| Edge case | Behaviour | Acceptable? |
|---|---|---|
| Customer deletes the setup record entirely | `Setup.Get() = false` → no-op → stock CDC behaviour. No errors, no telemetry. | Yes — admin's choice |
| DC upgrade resets the setup record | New row likely insert with `InitValue = true` → suppression resumes by default. | Yes — matches D-5 |
| DC ships a field with the same name `"Disable CDC Cross-Co. Tmpl."` | TableExtension compile fails with name-collision error. | Detected at next CI build. /develop renames our field. Risk: low (DC is unlikely to ship such a specific Monta-coined name). |
| Multiple subscribers to the same event (some other ISV) | All run; if any sets `IsHandle := true`, suppression wins. Order is BC-defined (publisher-installation order). | Yes — IsHandle is monotonic |
| Subscriber raises an unexpected error | Whole `GetTemplate` call fails; document processing breaks. | **Risk** — but the subscriber has zero error paths by design (no `TestField`, no `Error`, no `if not Insert then Error`), so this requires a kernel-level fault. Acceptable. |
| `SourceName` contains PII (e.g., a customer name in a filename) | We log only its length, not contents. | Yes |

### Future expansion

If Monta wants to add a 2nd DC-related toggle later (e.g., "Suppress CDC vendor auto-create"):

- **MINIMAL impact:** add 1 field to the existing TableExtension (50100), add 1 field to the existing PageExtension (50101), add 1 new event subscriber procedure inside the existing Codeunit (50102) OR a new Codeunit 50103 if the new toggle is in a different DC area. Telemetry uses `MON-DC-0002`.
- **The single-Codeunit approach scales cleanly to ~3-5 toggles before it should be split.** If Monta plans 10+ toggles, the BC-idiomatic approach with a wrapper would have been a better long-term bet.

### What distinguishes MINIMAL from BC-idiomatic

1. **Subscriber reads setup inline; no wrapper codeunit.** The BC-idiomatic plan likely introduces an `ICdcSetupReader` (or similar) for testability and a "Mgmt" wrapper codeunit. We don't — D-9 makes the testability gain illusory and the wrapper adds 30 lines of plumbing for zero behavioural change.

2. **No install codeunit / no setup-record bootstrap.** We rely entirely on `InitValue = true` and DC's own initialiser. The BC-idiomatic plan likely ships a small Install codeunit that asserts the record exists and writes the toggle. We accept the one-shot first-call-after-install gap (see weakness #2) as the cost of dropping that object.

3. **No abstraction layer = direct event-to-telemetry pipeline.** The 5-line subscriber is the entire feature. There is no `Mgmt.SuppressLookup()` indirection, no `Telemetry.LogSuppression()` indirection. Easier to read, harder to extend; perfect for a single-toggle feature, suboptimal for a future multi-toggle suite.

---

## Part 6 — Design review checklist

- [x] TableExtension (not base table mod)
- [x] PageExtension (not page mod)
- [x] Event subscriber (not code mod)
- [x] AL0305 30-char limit observed: `"Monta DC Setup Ext"` (16), `"Monta DC Setup PurchAppr Ext"` (28), `"Monta DC Suppress Tmpl. Sub."` (28), field `"Disable CDC Cross-Co. Tmpl."` (28). All compliant.
- [x] CodeCop / NoImplicitWith compliant — no `with` statements, all field refs `Rec.<Field>` or `Setup.<Field>`.
- [x] `InitValue = true` covers the default-ON contract per D-5.
- [x] Per-company semantics inherit from DC's setup table (no extra work).
- [x] No new permission set (D-7).
- [x] Silent UX (D-6) — telemetry only, no `Message`/`Notification`.
- [x] Telemetry follows MON-94 convention (`Locked` label, `ExtensionPublisher` scope, `SystemMetadata` classification).
- [x] Compile-verified only flag in commit messages (D-9).
- [x] Sandbox smoke-test plan documented (D-9 substitute proof gate).
- [x] Residual risk on BC 27.3 signature is documented and assigned to /develop step 9.
- [x] Object IDs 50100/50101/50102 within the app's 50100..50199 range; 97 IDs free.
- [x] Filenames follow `<NoSpaces>.<Suffix>.al` convention.
- [x] App.json fixups documented (current scaffold has wrong platform/application/runtime).
- [x] AL-Go settings changes documented (appFolders + installApps).
- [x] Dependencies folder + transitive chain enumerated.
- [x] /develop verification steps explicitly listed for residual risks (event signature, DC manifest, transitive chain).

---

**End of Plan A — MINIMAL.**
