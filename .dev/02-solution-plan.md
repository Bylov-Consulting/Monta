# Solution Plan: Disable CDC Cross-Company Template Lookup

**Date:** 2026-04-29
**Status:** APPROVED — synthesized from competing architect proposals
**App:** Monta Document Capture Utility (new isolated app, ID range 50100..50199)
**BC target:** platform/application 27.0.0.0, runtime 16.0
**DC dependency:** Continia Document Capture 27.3 (build 27.3.0.330595)

---

## Overview

Five objects in a new `Monta Document Capture Utility/` app suppress Continia Document Capture's cross-company template-copy prompt behind a per-company toggle on DC's Setup card. The subscriber on `OnBeforeFindTemplateInCompanies` short-circuits the lookup when the toggle is on; otherwise CDC's stock behavior is preserved.

The five-object structure is required (not optional) because of a subtle correctness issue: **`InitValue = true` on a tableextension field does NOT apply to rows that already exist when the extension is added.** Almost every Monta tenant has DC installed first — so the singleton DC setup row already exists when our app installs, and our toggle column would default to `false` (Boolean column default), shipping the feature with suppression OFF in violation of D-5. An Install codeunit explicitly setting the field on first install closes that gap. The price is two extra objects (Settings + Install codeunits); the payoff is correctness on the common-case deployment timeline.

The subscriber and Settings codeunit are read-only on the hot path — no DB writes inside the document-processing flow. All mutation lives in the Install codeunit.

---

## Approach Selection: Hybrid (Architect 2's structure + Architect 1's hot-path discipline)

| Element | Source | Rationale |
|---|---|---|
| 5-object structure (TableExt + PageExt + Subscriber + Settings + Install) | Architect 2 | The `InitValue` defect requires an Install codeunit. The Settings/Mgmt seam mirrors the project's MON-94 "logic in `*Mgmt.Codeunit`" pattern. |
| Subscriber/Settings are read-only on hot path | Architect 1 | A subscriber that writes to the DB inside CDC's document-processing transaction can fail in unexpected transaction states. Mutation belongs in the Install codeunit only. |
| `Setup.Get() = false → silent exit` (no runtime EnsureSetupRecord retry) | Architect 1 | If install failed to seed the row, that's a deployment issue, not something the hot path should auto-repair. |
| Page placement: existing `group(GeneralGroup)`, `addafter("Use Acc. and Dim. App. Pms.")` | Architect 1 | The new field is semantically a behavior switch like its GeneralGroup neighbors. Tooltip carries the "Added by Monta Utility" attribution. |
| Telemetry dims: `Company` + `SourceNameLength` (drop `EventType` since `eventId` differentiates) | Hybrid | Two dims — minimum useful diagnostics without bloat. No raw `SourceName` (privacy). |
| Object naming: `MDC` prefix, drop redundant `CDC` mid-name | Refined | `MDC DC Setup Ext` (16) > `MDC CDC Doc. Capt. Setup Ext` (28). The `MDC` namespace alone is enough; `DC` once is enough to indicate the target. |
| `Modify(false)` with `SetLoadFields` in Install codeunit | New (lead refinement) | Avoid clobbering DC-owned fields if anything else modifies the singleton concurrently. Partial load + partial save is the safe pattern. |

---

## Object Design

### Object Allocation Table

| ID | Object | Name (≤30) | File |
|---|---|---|---|
| 50100 | TableExtension | `MDC DC Setup Ext` (16) | `MDCDCSetupExt.TableExt.al` |
| 50101 | PageExtension | `MDC DC Setup Card Ext` (21) | `MDCDCSetupCardExt.PageExt.al` |
| 50102 | Codeunit (Subscriber) | `MDC Cross-Co. Tmpl. Sub.` (24) | `MDCCrossCoTmplSub.Codeunit.al` |
| 50103 | Codeunit (Settings/Mgmt) | `MDC DC Setup Mgmt.` (18) | `MDCDCSetupMgmt.Codeunit.al` |
| 50104 | Codeunit (Install) | `MDC DC Setup Install` (20) | `MDCDCSetupInstall.Codeunit.al` |

96 IDs (50105..50199) reserved for future Monta DC overlays in this app.

Field 50100 on the table-extension:

| Field no. | Name (≤30) | Type | Properties |
|---|---|---|---|
| 50100 | `"Disable CDC Cross-Co. Tmpl."` (28) | Boolean | `Caption = 'Disable CDC Cross-Company Template Lookup'`, `InitValue = true`, `DataClassification = CustomerContent`, no triggers |

`DataClassification` is `CustomerContent` to match the surrounding DC setup table fields. The toggle is per-company config but lives on a customer-data-classified table; staying consistent reduces audit/GDPR confusion.

### 1. TableExtension 50100 — `MDC DC Setup Ext`

```
tableextension 50100 "MDC DC Setup Ext" extends "CDC Document Capture Setup"
{
    fields
    {
        field(50100; "Disable CDC Cross-Co. Tmpl."; Boolean)
        {
            Caption = 'Disable CDC Cross-Company Template Lookup';
            DataClassification = CustomerContent;
            InitValue = true;
        }
    }
}
```

No `OnValidate` — toggling has no side effects beyond the next subscriber call reading the new value.

### 2. PageExtension 50101 — `MDC DC Setup Card Ext`

Extends Page 6085625 `"CDC Setup - Purch. Approval"` (the DC setup card).

```
pageextension 50101 "MDC DC Setup Card Ext" extends "CDC Setup - Purch. Approval"
{
    layout
    {
        addafter("Use Acc. and Dim. App. Pms.")
        {
            field("Disable CDC Cross-Co. Tmpl."; Rec."Disable CDC Cross-Co. Tmpl.")
            {
                ApplicationArea = All;
                ToolTip = 'Specifies whether Monta Document Capture Utility suppresses Continia Document Capture''s cross-company template-copy prompt. When enabled (default), processing a document whose source name matches a template in another company will skip the "Copy template from..." prompt and fall through to the standard create-new-template path. Added by Monta Document Capture Utility.';
            }
        }
    }
}
```

Anchor `"Use Acc. and Dim. App. Pms."` is inside the `group(GeneralGroup)` on the DC setup card (verified by Architect 1 from BC 28 source). The new field sits next to other behavior switches.

### 3. Codeunit 50102 — `MDC Cross-Co. Tmpl. Sub.` (event subscriber)

```
codeunit 50102 "MDC Cross-Co. Tmpl. Sub."
{
    Access = Internal;

    [EventSubscriber(ObjectType::Table, Database::"CDC Document",
        'OnBeforeFindTemplateInCompanies', '', false, false)]
    local procedure SuppressCrossCompanyLookup(
        var FromCompany: Text[30];
        var FromTemplate: Record "CDC Template";
        SourceName: Text[250];
        var Result: Boolean;
        var IsHandle: Boolean)
    var
        Settings: Codeunit "MDC DC Setup Mgmt.";
        TelemetryDims: Dictionary of [Text, Text];
    begin
        if not Settings.IsCrossCompanyTemplateCopyDisabled() then
            exit;

        IsHandle := true;
        Result := false;

        TelemetryDims.Add('Company', CompanyName());
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
}
```

**Notes:**
- `IsHandle` (singular, no 'd') matches DC's publisher exactly — must not be "fixed" to `IsHandled`.
- Procedure is `local`. Codeunit is `Internal`.
- No `SingleInstance` — the subscriber is stateless; per-call instantiation cost is negligible.
- `var FromCompany`/`var FromTemplate` parameters are not mutated by this branch; the publisher's `var` keyword is structural, not a contract.
- `SourceName` content is **never logged** (privacy). Only its length, as a coarse "real docs are flowing" signal.

### 4. Codeunit 50103 — `MDC DC Setup Mgmt.` (Settings/Mgmt)

```
codeunit 50103 "MDC DC Setup Mgmt."
{
    internal procedure IsCrossCompanyTemplateCopyDisabled(): Boolean
    var
        Setup: Record "CDC Document Capture Setup";
    begin
        Setup.SetLoadFields("Disable CDC Cross-Co. Tmpl.");
        if not Setup.Get() then
            exit(false);   // No row → no decision recorded → don't suppress (preserves stock CDC).
        exit(Setup."Disable CDC Cross-Co. Tmpl.");
    end;

    internal procedure EnsureSetupRecordOnInstall()
    var
        Setup: Record "CDC Document Capture Setup";
    begin
        // Called from the Install codeunit only. Install codeunits fire once per company per app version,
        // so this NEVER overwrites an admin's later toggle change.
        Setup.SetLoadFields("Disable CDC Cross-Co. Tmpl.");
        if Setup.Get() then begin
            // Existing row (DC was installed first — common case). InitValue did NOT apply to this row;
            // explicitly set our field to true to honor D-5 (default ON on install).
            Setup."Disable CDC Cross-Co. Tmpl." := true;
            Setup.Modify(false);
            exit;
        end;
        // Row missing (rare — DC's own bootstrap will normally have run). Init applies our field's
        // InitValue=true; Insert(true) lets DC's own OnInsert (if/when added) run too.
        Setup.Init();
        Setup."Primary Key" := '';
        Setup.Insert(true);
    end;
}
```

**Decisions baked in:**
- Both procedures `internal` — no external-app surface. Future intra-app extensions add procedures here without changing visibility.
- `IsCrossCompanyTemplateCopyDisabled` is the read seam. It does NOT auto-init missing rows on the hot path (this is the change from Architect 2's brief — runtime DB writes inside CDC's document-processing transaction are unsafe). Missing row → return false → no suppression → fall through. The Install codeunit is the authoritative bootstrap.
- `SetLoadFields` on the read avoids loading 50+ DC fields just to check one Boolean.
- `EnsureSetupRecordOnInstall`'s Modify path uses `Modify(false)` (skip DC's table-level OnModify, if any — defensive against side effects on a table we don't own) **and** `SetLoadFields` (write only our field, not all 50+ fields, avoiding clobbering concurrent edits).
- `Insert(true)` on the missing-row path. There is no `OnInsert` on the BC 28 DC Setup table; if Continia adds one in the future, our Insert correctly invokes their initializer. /develop should add a code comment referencing this analysis.

### 5. Codeunit 50104 — `MDC DC Setup Install` (Install)

```
codeunit 50104 "MDC DC Setup Install"
{
    Access = Internal;
    Subtype = Install;

    trigger OnInstallAppPerCompany()
    var
        Settings: Codeunit "MDC DC Setup Mgmt.";
    begin
        Settings.EnsureSetupRecordOnInstall();
    end;
}
```

**Why no Upgrade codeunit:** v1.0.0.0 is the first version — there's nothing to upgrade FROM. A `Subtype = Upgrade` codeunit becomes necessary when v2 ships any schema change (and the v2 author should use `Upgrade Tag`s to ensure existing toggle values survive the upgrade). For v1, the Install codeunit alone is sufficient. Document this deferral in `.dev/03-code-review.md` as an explicit non-issue.

**Lifecycle properties:**
- `OnInstallAppPerCompany` fires once per company per app-version on first install. It does NOT re-fire on app upgrade (BC fires `OnUpgradePerCompany` from a different codeunit subtype on upgrade). Admin's later toggle changes survive upgrades.
- `OnInstallAppPerCompany` fires for every existing company at install time, ensuring the toggle defaults to ON on every company that has DC.

---

## BC Base App Integration

| Element | Object | Action |
|---|---|---|
| Table 6085573 `"CDC Document Capture Setup"` | TableExtension 50100 | Add Boolean field 50100 with `InitValue = true`. |
| Page 6085625 `"CDC Setup - Purch. Approval"` | PageExtension 50101 | Add field after `"Use Acc. and Dim. App. Pms."` in `group(GeneralGroup)`. |
| Table 6086302 `"CDC Document"` | Codeunit 50102 (subscriber) | Subscribe to `OnBeforeFindTemplateInCompanies`. |
| App lifecycle | Codeunit 50104 (`Subtype=Install`) | `OnInstallAppPerCompany` calls `EnsureSetupRecordOnInstall`. |

**Hard dependency:** `Monta Document Capture Utility/app.json` declares Continia Document Capture as a dependency. BC refuses to install our app on tenants without DC, so the "DC not installed" race is impossible.

---

## App.json Fixups

The CreateApp scaffold has placeholder values that must be corrected.

| Field | Target value |
|---|---|
| `platform` | `"27.0.0.0"` (was `"1.0.0.0"`) |
| `application` | `"27.0.0.0"` (was `"22.0.0.0"`) |
| `runtime` | `"16.0"` (add — currently absent) |
| `brief` | `"Monta-tuned behavior overlays for Continia Document Capture, starting with cross-company template-copy suppression."` |
| `description` | `"Monta Document Capture Utility ships behavior overlays for Continia Document Capture (CDC). The first overlay suppresses CDC's cross-company template-copy prompt by default (configurable per company on the DC setup card). Telemetry is emitted on each suppression. The toggle defaults to ON on install."` |
| `help` | `"https://github.com/Bylov-Consulting/Monta-Utility#readme"` |
| `url` | `"https://github.com/Bylov-Consulting/Monta-Utility"` |
| `resourceExposurePolicy` | `{ "allowDebugging": true, "allowDownloadingSource": true, "includeSourceInSymbolFile": true }` (align with Monta Utility) |
| `dependencies` | One entry — see below |

**Dependency entry:**

```json
{
  "id": "6da8dd2f-e698-461f-9147-8e404244dd85",
  "name": "Continia Document Capture",
  "publisher": "Continia Software",
  "version": "27.3.0.0"
}
```

`id` is stable across DC versions (verified via DC 28 source `app.json`). `version` floor is `27.3.0.0`; AL-Go's `installApps` will provide the actual `27.3.0.330595` build artifact.

**[VERIFY in step 1 of impl order]** — confirm `id`, `name`, `publisher`, exact version against the BC 27.3 .app's `NavxManifest.xml`.

---

## Dependencies Folder Content

Create `dependencies/` at repo root. Commit the full Continia chain for BC 27.3 from `C:\Users\JeppeBylov\Downloads\DC27.3+EM27.3-NA-APP\App\BC 27.3 (BC 2025 Wave 2 CU3)\`:

| Source folder | File to commit |
|---|---|
| `Base/` | `Continia System Application 27.3.0.330477 - 27.3.app` |
| `Base/` | `Continia Online Connector 27.3.0.330477 - 27.3.app` |
| `Base/` | `Continia Business Foundation 27.3.0.330477 - 27.3.app` |
| `Base/` | `Continia Approvals 27.3.0.330477 - 27.3.app` |
| `Base/` | `Continia Connector App 27.3.0.330477 - 27.3.app` |
| `Base/` | `Continia Azure OpenAI 27.3.0.330477 - 27.3.app` (include if DC 27.3 manifest references it) |
| `Core/` | `Core 27.3.0.330522 - 27.3 (BC 2025 Wave 2 CU3).app` |
| `Delivery Network/` | `CDN 27.3.0.330582 - 27.3 (BC 2025 Wave 2 CU3).app` |
| `Document Capture/` | `DC 27.3.0.330595 - 27.3 (BC 2025 Wave 2 CU3).app` |

**Do NOT commit `_na/` localized variants** — target is SaaS W1 only (D-2).

**Verify whether `Continia Document Output` is in DC 27.3's chain** — DC 28's manifest lists it, but it doesn't appear in the BC 27.3 folder listing the user provided. If DC 27.3 references it, source separately. If not, omit.

Add `dependencies/README.md` with the redistribution-license note: "Continia .app artifacts are redistributed in this private repository under Continia's confirmed permission for internal AL-Go pipeline use. Do not redistribute outside this repository."

---

## AL-Go Settings Changes

### `.github/AL-Go-Settings.json` — append new app folder

```json
"appFolders": [
  "Monta Utility",
  "Monta Document Capture Utility"
]
```

`testFolders` unchanged. (No test app per D-9.)

### `.AL-Go/settings.json` — populate installApps

```json
{
  "$schema": "https://raw.githubusercontent.com/microsoft/AL-Go-Actions/v9.0/.Modules/settings.schema.json",
  "country": "w1",
  "appFolders": [],
  "testFolders": [],
  "bcptTestFolders": [],
  "repoVersion": "1.3",
  "installApps": [
    "dependencies/Continia System Application 27.3.0.330477 - 27.3.app",
    "dependencies/Continia Business Foundation 27.3.0.330477 - 27.3.app",
    "dependencies/Continia Online Connector 27.3.0.330477 - 27.3.app",
    "dependencies/Continia Approvals 27.3.0.330477 - 27.3.app",
    "dependencies/Continia Connector App 27.3.0.330477 - 27.3.app",
    "dependencies/Continia Azure OpenAI 27.3.0.330477 - 27.3.app",
    "dependencies/Core 27.3.0.330522 - 27.3 (BC 2025 Wave 2 CU3).app",
    "dependencies/CDN 27.3.0.330582 - 27.3 (BC 2025 Wave 2 CU3).app",
    "dependencies/DC 27.3.0.330595 - 27.3 (BC 2025 Wave 2 CU3).app"
  ]
}
```

Order: Continia base/foundation → connector apps → Core → CDN → DC. Verify exact order matches each .app's own `dependencies[]` and reorder if any forward reference exists. Omit Azure OpenAI if DC 27.3 doesn't reference it.

`appFolders`/`testFolders` left empty here — `.github/AL-Go-Settings.json` is authoritative for those.

---

## Telemetry

| Property | Value |
|---|---|
| Event ID | `'MON-DC-0001'` |
| Verbosity | `Verbose::Verbose` |
| DataClassification | `DataClassification::SystemMetadata` |
| TelemetryScope | `TelemetryScope::ExtensionPublisher` |
| Label | `SuppressedTelemetryLbl: Label 'Monta Utility suppressed CDC cross-company template lookup.', Locked = true` |
| Custom dim 1 | `Company = CompanyName()` |
| Custom dim 2 | `SourceNameLength = Format(StrLen(SourceName))` |

**ID convention:** `MON-DC-NNNN`. Distinguishes from `MON-94-NNNN` (existing GL Cleanup audit telemetry). NNNN sequential within the prefix. Document the convention in `.dev/project-context.md` after merge.

**Privacy:** raw `SourceName` (which may contain vendor/file identifiers) is never logged. Only its length.

---

## Implementation Order (for /develop)

1. **Verify BC 27.3 DC symbols.** Extract `DC 27.3.0.330595 ... .app` (see "Symbol-extraction technique" below). Confirm:
   - DC app id `6da8dd2f-e698-461f-9147-8e404244dd85` matches.
   - `OnBeforeFindTemplateInCompanies` event exists on Table 6086302 with the BC 28 signature: `(var FromCompany: Text[30]; var FromTemplate: Record "CDC Template"; SourceName: Text[250]; var Result: Boolean; var IsHandle: Boolean)` — with `IsHandle` spelled without 'd'.
   - Table 6085573 `"CDC Document Capture Setup"` exists with PK `"Primary Key": Code[10]`.
   - Page 6085625 `"CDC Setup - Purch. Approval"` exists.
   - **STOP and escalate** if any signature differs from BC 28.
2. **Verify the dependency chain.** Extract DC 27.3's own manifest. Confirm chain composition (8 vs 9 apps; whether Continia Document Output is required). Update §Dependencies Folder Content to reflect.
3. **Commit the `dependencies/` folder** with the verified chain. Add `dependencies/README.md` with the redistribution-license note.
4. **Edit `.AL-Go/settings.json`** — add `installApps` array in dependency-resolved order.
5. **Edit `.github/AL-Go-Settings.json`** — append `"Monta Document Capture Utility"` to `appFolders`.
6. **Edit `Monta Document Capture Utility/app.json`** per §App.json Fixups.
7. **Push WIP commit (no AL objects yet).** Confirm CI build job resolves all dependencies and compiles the empty `Monta Document Capture Utility` against DC symbols. If CI fails on dep resolution, fix `installApps` ordering before writing AL.
8. **Write Codeunit 50103 `MDC DC Setup Mgmt.`** first — both Subscriber and Install depend on it.
9. **Write TableExtension 50100 `MDC DC Setup Ext`** — the field Settings reads.
10. **Write Codeunit 50104 `MDC DC Setup Install`** (`Subtype = Install`).
11. **Write Codeunit 50102 `MDC Cross-Co. Tmpl. Sub.`** — using the verified BC 27.3 event signature from step 1 (NOT the BC 28 source signature — paranoia win).
12. **Write PageExtension 50101 `MDC DC Setup Card Ext`** — last; UI-only.
13. **Local compile.** CodeCop on. AL0305 enforced. NoImplicitWith required. Must be clean.
14. **Commit.** Each commit body must include the line: `compile-verified only — docker constraint: DC not in test container.` (per D-9).
15. **Open PR.** Trigger CI; confirm green compile.
16. **Run sandbox smoke-test plan.** Capture results in `.dev/03-code-review.md`.
17. **Merge to main** only after smoke test passes.
18. **Update `.dev/project-context.md`** — append the 5 new objects, the DC dependency chain, the `MON-DC-NNNN` telemetry convention, and a link to the smoke-test result.

### Symbol-extraction technique

BC `.app` files are zip files with a 40-byte NAVX header prefix. To extract:

```powershell
# In PowerShell (gitbash equivalents work too):
$bytes = [IO.File]::ReadAllBytes('path\to\DC 27.3.0.330595 ... .app')
[IO.File]::WriteAllBytes('dc.zip', $bytes[40..($bytes.Length-1)])
Expand-Archive dc.zip -DestinationPath dc-extracted
# Look for: NavxManifest.xml (publisher, id, version, dependencies),
#           SymbolReference.json (event signatures, table/page definitions)
```

If `SymbolReference.json` is gzip-compressed (it usually is), inflate with `Expand-Archive` again or any gzip tool.

---

## Sandbox Smoke-Test Plan (Substitute Proof Gate per D-9)

The substitute proof gate per D-9. Manual test on a real BC SaaS sandbox tenant with DC 27.3 installed. **This is the only proof gate** — no automated tests ship in v1.

### Pre-requisites

1. BC SaaS sandbox tenant provisioned with admin access.
2. DC 27.3 installed via Continia's standard install path. Verify version on `Extension Management`.
3. At least two companies (e.g., `CRONUS Test`, `CRONUS Other`).
4. In `CRONUS Other`, create a CDC vendor template with a recognizable Source Name (e.g., `"ACME Corp"`).
5. In `CRONUS Test`, no local template for that Source Name.
6. Signed `Monta Document Capture Utility` v1.0.0.0 deployed via `Extension Management → Upload Extension`.

### Test 1 — Install codeunit fires per company; toggle defaults ON

1. Before installing Monta DCU: in `CRONUS Test`, open `"Document Capture Setup / Purchase Approval"` and confirm toggle field is NOT visible.
2. Install Monta DCU v1.0.0.0.
3. Re-open the page in `CRONUS Test`. **Pass:** toggle visible, value = ON.
4. Switch to `CRONUS Other`. Open the same page. **Pass:** toggle visible, value = ON (Install codeunit fires per-company).

### Test 2 — Toggle ON suppresses prompt (FR-1)

1. In `CRONUS Test`, ensure toggle = ON.
2. Process a document whose source identifier matches `"ACME Corp"` (template exists only in `CRONUS Other`).
3. **Pass:** NO `"Copy template from CRONUS Other?"` Confirm dialog appears. CDC falls through to "create new template."

### Test 3 — Telemetry emitted (FR-4)

1. Immediately after Test 2, query Application Insights: `traces | where customDimensions.eventId == 'MON-DC-0001'`.
2. **Pass:** at least one entry from the last 5 minutes; `customDimensions.Company = 'CRONUS Test'`; `customDimensions.SourceNameLength` is a positive integer; `severityLevel = 0` (Verbose).

### Test 4 — Toggle OFF preserves stock CDC (FR-6)

1. In `CRONUS Test`, toggle the field OFF. Save.
2. Repeat the document-capture flow from Test 2.
3. **Pass:** `"Copy template from CRONUS Other?"` prompt DOES appear (stock CDC).
4. **Pass:** NO new `MON-DC-0001` telemetry from this run.

### Test 5 — App upgrade preserves admin's choice

1. With `CRONUS Test` toggle currently OFF (from Test 4), build a v1.0.1.0 of Monta DCU (any trivial change). Deploy as upgrade.
2. After upgrade, re-open the setup card in `CRONUS Test`.
3. **Pass:** toggle is still OFF. (Install codeunit's `OnInstallAppPerCompany` does not fire on upgrade — Install fires only on first install per app version.)
4. If this fails: the v2 Upgrade-codeunit work is no longer "deferred" and must be added before any v2 ships.

### Test 6 — DC reinstall scenario (informational)

1. Uninstall DC (also uninstalls Monta DCU since DC is hard dep).
2. Reinstall DC, then reinstall Monta DCU.
3. **Pass:** toggle = ON in `CRONUS Test`. Install codeunit fires fresh on the new install.

### Test 7 — No regression in Monta Utility

1. From `CRONUS Test`, run the `Clear Add. Reporting Amounts` report (Monta Utility / MON-94 feature).
2. **Pass:** unchanged behavior.

### Pass criteria (all required for merge)

- [ ] Tests 1–5, 7 all pass.
- [ ] Test 6 passes OR is documented as an informational result.

Document the run in `.dev/03-code-review.md` D-list under "Substitute proof gate" with sandbox URL, run date, and screenshots of telemetry rows.

---

## D-list Entry for `.dev/03-code-review.md`

To be appended during /develop:

> **Gap (per D-9):** End-to-end CDC suppression is not covered by automated tests. DC is not installable in the project's BC docker container.
>
> **Substitute proof gate:** Sandbox smoke-test plan in `.dev/02-solution-plan.md` §Sandbox Smoke-Test Plan executed on [DATE]. Result: [PASS/FAIL]. Sandbox: [URL]. Telemetry screenshots: [LINK].
>
> **Long-term unblock:** Provision a BC docker image that includes DC 27.3 plus a Continia evaluation license. Then add a paired test app exercising `FindTemplateInCompanies` with multi-company template setup.
>
> **v2 follow-up:** Add a `Subtype = Upgrade` codeunit (using `Upgrade Tag`) before any v2 schema change ships, to ensure existing toggle values survive upgrades.

---

## Trade-offs Accepted

| Trade-off | Acceptable because |
|---|---|
| 5 objects (vs 3 in minimal approach) | Required for D-5 correctness on DC-installed-first tenants. The 2 extra objects (Settings + Install) are small, focused, and provide a clean expansion path. |
| No automated tests in v1 | D-9: DC unavailable in test container. Sandbox smoke-test is the substitute proof gate. Long-term unblock documented. |
| BC 27.3 event signature verified against BC 28 source only at plan time | Step 1 of /develop forces .app symbol extraction and verification before code is written. STOP-and-escalate trigger if anything differs. |
| DC dependency chain enumerated against BC 28 manifest | Step 2 of /develop verifies the chain against the BC 27.3 .app's own manifest. Continia Document Output presence in 27.3 is unconfirmed — handled by a verification step. |
| `Modify(false)` skips DC's table-level OnModify (none currently exists) | Defensive against future DC changes. Code comment references this analysis. |
| `Insert(true)` invokes DC's OnInsert (none currently exists) | If Continia adds one in the future, our Insert correctly applies their initializer for DC-owned fields. Code comment references this analysis. |
| No Upgrade codeunit in v1 | v1 is the first version — nothing to upgrade FROM. v2 work explicitly captured in the D-list. |

---

## Pre-implementation Verification Checklist (BLOCKERS for /develop)

These must be confirmed before any AL is written:

- [ ] BC 27.3 DC `.app` extractable; `NavxManifest.xml` and `SymbolReference.json` accessible.
- [ ] DC app id `6da8dd2f-e698-461f-9147-8e404244dd85` confirmed in BC 27.3 manifest.
- [ ] `OnBeforeFindTemplateInCompanies` event signature in BC 27.3 matches the BC 28 source (parameter list + `IsHandle` spelling).
- [ ] Table 6085573 `"CDC Document Capture Setup"` and Page 6085625 `"CDC Setup - Purch. Approval"` confirmed in BC 27.3 symbols.
- [ ] BC 27.3 DC dependency chain identified; whether Continia Document Output is required confirmed.
- [ ] All required `.app` files copied to `dependencies/` and `installApps` order verified.
- [ ] CI compiles the empty `Monta Document Capture Utility` (after step 7 of impl order) against the resolved dependency chain.
- [ ] Field ID 50100 doesn't collide with another extension on the target tenant. (Low risk — but verify on the smoke-test sandbox.)

---

**End of plan.**
