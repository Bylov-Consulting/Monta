# Solution Plan (Architect 2 — BC-IDIOMATIC): Disable CDC Cross-Company Template Lookup

**Generated:** 2026-04-29
**Approach:** BC-IDIOMATIC (5 objects: TableExt, PageExt, Subscriber, Settings/Mgmt, Install)
**Based on:** `.dev/01-requirements.md` (decisions D-1..D-10 locked)
**BC Target:** 27.0.0.0 / runtime 16.0
**DC Target:** 27.3.0.330595 (BC 2025 Wave 2 CU3)
**Complexity classification:** MEDIUM (5 files, BC base-app integration, install/upgrade lifecycle)

---

## Part 1: Architecture & Design

### High-Level Approach

A new isolated AL-Go app `Monta Document Capture Utility` ships **five** objects that subscribe to CDC's `OnBeforeFindTemplateInCompanies` IntegrationEvent and suppress cross-company template lookups behind a per-company toggle. Logic is split per the project's MON-94 "logic in `*Mgmt.Codeunit.al`, thin wrappers everywhere else" pattern: a **Settings codeunit** owns Get + auto-init semantics for the toggle; the **Subscriber codeunit** is a thin event handler delegating to Settings; an **Install codeunit** guarantees the singleton row exists with the default-ON value at install/upgrade time. The TableExtension and PageExtension surface the toggle.

### BC Base App Integration

| Surface | Object | Action |
|---|---|---|
| Table 6085573 `"CDC Document Capture Setup"` | TableExtension 50100 | Add Boolean field 50100 with `InitValue = true`. |
| Page 6085625 `"CDC Setup - Purch. Approval"` | PageExtension 50101 | Add a new `group("Monta Utility")` containing the toggle field with ToolTip. |
| Table 6086302 `"CDC Document"` event `OnBeforeFindTemplateInCompanies` | Subscriber Codeunit 50102 | Subscribe; route to Settings; mutate `IsHandle := true`, `Result := false` when toggle is ON. |
| App lifecycle | Install Codeunit 50104 (`Subtype = Install`) | On `OnInstallAppPerCompany` and `OnUpgradePerCompany`, call `Settings.EnsureSetupRecord()`. |

Procedure signatures (NO code) — see "Object designs" below.

### Testability Architecture

This feature ships **compile-verified only** per D-9 — no test app, no `bc-test` run is possible because DC is not installable in the project's BC docker container. The substitute proof gate is a manual SaaS sandbox smoke test (see Part 2 §6).

That said, the BC-idiomatic split was chosen specifically because **the Settings codeunit IS the testable seam**. If/when a DC-bearing test container is provisioned (D-9 long-term unblock), the test surface is already there:

- **Pure-ish operations (Settings codeunit, future-testable):**
  - `IsCrossCompanyTemplateCopyDisabled(): Boolean` — single read of a flag; trivially testable once the setup row can be inserted in test setup.
  - `EnsureSetupRecord()` — idempotent insert; testable by asserting the row exists after a call against an empty-table starting state.
- **Impure operation (Subscriber codeunit, intentionally minimal):**
  - The `OnBeforeFindTemplateInCompanies` subscriber is reduced to: read flag → mutate two var params → emit telemetry. With the flag accessor extracted, the only un-mockable surface is the `Session.LogMessage` call. This is acceptable — telemetry is fire-and-forget and the read path is what matters for FR-1 correctness.
- **External dependencies enumerated:**
  - Database: `Record "CDC Document Capture Setup"` (singleton, per-company). Read by Settings. Written only by Install codeunit's `EnsureSetupRecord()`.
  - Time/Random/HTTP/File: none.
- **Required interfaces:** **None introduced.** Adding an `ICDCSetupRepository` interface for a 1-line `Get` would be over-engineering for a feature this small (single read, no business calculation). The seam is the codeunit boundary; the interface is implicit. If a third future feature also reads DC setup, lift it into an interface then.
- **Mock strategy:** N/A for this ship — but the Subscriber's structure (delegate to Settings, do nothing else of substance) means a future test app can mock by wiring an alternative codeunit via subscriber dispatch or by simply seeding the setup row before the test scenario.

This design satisfies the spirit of the project's testability standard ("logic codeunit testable in isolation") even though the gate cannot be exercised today.

### BC Patterns Applied

- **Singleton setup auto-init** via Install codeunit + idempotent `EnsureSetupRecord()` — the canonical BC pattern for "feature toggle on a base-app setup table." Mirrors how Microsoft's own apps (e.g., `Sales & Receivables Setup`) seed defaults.
- **`InitValue = true` on the field** as a belt-and-suspenders default in case the setup row is created **after** our app installs (e.g., DC reinstalled). `InitValue` only fires on `Init`, so the Install codeunit + `InitValue` together cover both timelines.
- **Logic-in-Mgmt-codeunit** per MON-94 architectural pattern in `project-context.md`.
- **Telemetry shape** mirrors MON-94: `Session.LogMessage('MON-DC-0001', ..., DataClassification::SystemMetadata, TelemetryScope::ExtensionPublisher, 'Company', CompanyName())`. `Locked = true` label.
- **`internal` visibility** on procedures other apps shouldn't call — keeps the Settings codeunit's external surface intentional.

### Alternatives Considered

| Alternative | Why rejected |
|---|---|
| Subscriber reads setup table directly (no Settings codeunit) | Couples telemetry, subscriber-dispatch and storage-read in one object. Future "also disable foo on bar" features land in the same codeunit. Bad scaling. |
| Single Mgmt codeunit, no Install codeunit | Relies on `InitValue = true` alone. Works **if** the setup row is created via an Init call after our extension installs. If the row already exists (DC was installed first, which is the common case), `InitValue` does NOT retroactively populate the field — but the field's default at column-add time is `false` for Boolean. **Result: feature ships disabled by default, contradicting D-5.** Install codeunit fixes this. |
| Use `OnAfterCompanyInitialize` instead of Install codeunit | Fires only on new-company creation, not on app install into an existing company. Misses every existing tenant company. |
| Use `InitValue = true` only, document that admins must "kick" the row | User-hostile; D-5 says default ON without admin action. |

The 2-extra-objects cost (Settings + Install) is the price of "default ON works on every install timeline." See trade-offs Part 2 §7 for honest cost accounting.

---

## Part 2: Implementation Plan

### 1. App.json fixups (`Monta Document Capture Utility/app.json`)

Current scaffold has placeholder `platform: 1.0.0.0`, `application: 22.0.0.0`, no `runtime`, empty `dependencies`, empty `brief`/`description`. Required edits:

| Field | Target value |
|---|---|
| `platform` | `"27.0.0.0"` (was `"1.0.0.0"`) |
| `application` | `"27.0.0.0"` (was `"22.0.0.0"`) |
| `runtime` | `"16.0"` (add — currently absent; matches Monta Utility) |
| `brief` | `"Monta-tuned behavior overlays for Continia Document Capture, starting with cross-company template lookup suppression."` |
| `description` | `"Monta Document Capture Utility ships behavior overlays for Continia Document Capture (CDC). The first overlay suppresses CDC's cross-company template-copy prompt by default (configurable per company on the DC setup card). Telemetry is emitted on each suppression. The toggle defaults to ON on install."` |
| `help` | `"https://github.com/Bylov-Consulting/Monta-Utility#readme"` |
| `url` | `"https://github.com/Bylov-Consulting/Monta-Utility"` |
| `resourceExposurePolicy` | Tighten to `{ allowDebugging: true, allowDownloadingSource: true, includeSourceInSymbolFile: true }` to match Monta Utility (currently `allowDownloadingSource: false, includeSourceInSymbolFile: false` — inconsistent with sibling app; flip for consistency). |
| `dependencies` | Add **one** entry for `Continia Document Capture` — see below. |

**Dependency entry (single entry — only direct dependency is DC; transitive Continia apps are pulled by AL compiler / installed via `installApps`):**

```json
{
  "id": "6da8dd2f-e698-461f-9147-8e404244dd85",
  "name": "Continia Document Capture",
  "publisher": "Continia Software",
  "version": "27.3.0.0"
}
```

`id` was extracted from BC 28 source `app.json` (id is stable across versions; verified in DC 28 manifest). `version` is set to `27.3.0.0` (the floor version of the BC 27.3 build; `installApps` will hand the compiler the actual `27.3.0.330595` artifact).

**Residual risk (call out to /develop):** the BC 27.3 .app symbol package was NOT inspected for this plan — only the BC 28 source. /develop must verify by inspecting the BC 27.3 .app (use `Compress-Archive -Path *.app` rename trick or `Get-NAVAppInfo` if available) that:
1. The app id `6da8dd2f-e698-461f-9147-8e404244dd85` matches.
2. The event `OnBeforeFindTemplateInCompanies` exists on Table 6086302 with the same signature `(var FromCompany: Text[30]; var FromTemplate: Record "CDC Template"; SourceName: Text[250]; var Result: Boolean; var IsHandle: Boolean)`.
3. Table 6085573 `"CDC Document Capture Setup"` exists with PK `"Primary Key"; Code[10]`.
4. Page 6085625 `"CDC Setup - Purch. Approval"` exists.

If any signature/object differs in 27.3, escalate before writing code.

### 2. Dependencies folder content

Create `dependencies/` at repo root (sibling to `Monta Utility/`, `Monta Document Capture Utility/`, etc.). Commit the **full Continia chain** for BC 27.3 — DC has 8 transitive dependencies (per BC 28 `dependencies` array; the chain in 27.3 is the same shape, only different filenames). All from `C:\Users\JeppeBylov\Downloads\DC27.3+EM27.3-NA-APP\App\BC 27.3 (BC 2025 Wave 2 CU3)\`:

| Source folder | File to commit | Continia app name |
|---|---|---|
| `Base/` | `Continia Approvals 27.3.0.330477 - 27.3.app` | Continia Approvals |
| `Base/` | `Continia Azure OpenAI 27.3.0.330477 - 27.3.app` | Continia Azure OpenAI |
| `Base/` | `Continia Business Foundation 27.3.0.330477 - 27.3.app` | Continia Business Foundation |
| `Base/` | `Continia Connector App 27.3.0.330477 - 27.3.app` | Continia Connector App |
| `Base/` | `Continia Online Connector 27.3.0.330477 - 27.3.app` | Continia Online Connector |
| `Base/` | `Continia System Application 27.3.0.330477 - 27.3.app` | Continia System Application |
| `Core/` | `Core 27.3.0.330522 - 27.3 (BC 2025 Wave 2 CU3).app` | Continia Core |
| `Delivery Network/` | `CDN 27.3.0.330582 - 27.3 (BC 2025 Wave 2 CU3).app` | Continia Delivery Network |
| `Document Capture/` | `DC 27.3.0.330595 - 27.3 (BC 2025 Wave 2 CU3).app` | Continia Document Capture |

**Note 1:** The BC 28 manifest also declares `Continia Document Output` as a DC dependency (id `f4b69b55-...`). It does NOT appear in the BC 27.3 folder listing. /develop must verify by inspecting the BC 27.3 DC `app.json` (extract `.app` → unzip → read manifest) whether DC 27.3 has the same 8-app dep chain or a smaller one. If `Continia Document Output` is in 27.3's chain, it must be sourced separately or noted as missing.

**Note 2:** The `_na/` subfolder contains a US (NA) localization variant — **do NOT commit** unless tenant is NA-localized. SaaS world-wide tenants take only the W1 chain.

**Continia license redistribution:** D-8 confirms this is permitted for private repos. Document the license note in the repo `README.md` next to the `dependencies/` folder reference (a one-liner: "Continia .app artifacts are redistributed here under Continia's private-repo evaluation license; do not distribute further").

### 3. AL-Go settings changes

#### `.github/AL-Go-Settings.json`

Currently lists `Monta Utility` in `appFolders`. **Add** the new app folder:

```json
"appFolders": [
  "Monta Utility",
  "Monta Document Capture Utility"
]
```

`testFolders` and other settings unchanged. (No test app per D-9.)

#### `.AL-Go/settings.json`

Currently has empty `appFolders`/`testFolders`. **Add `installApps`** so AL-Go's compile job pulls DC + chain into `.alpackages` before compiling:

```json
{
  "$schema": "...",
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

**Order matters:** AL-Go installs in array order; dependencies before dependents. The order above puts Continia base/foundation first, then Core, then CDN, then DC. /develop must verify the exact ordering against each .app's `dependencies[]` (extract from each .app → check) and reorder if a forward reference exists.

**Why both `.AL-Go/settings.json` AND `.github/AL-Go-Settings.json`?** AL-Go merges them (repo-level `.github/AL-Go-Settings.json` is global; `.AL-Go/settings.json` is project-local). `installApps` belongs in the project-local file.

### 4. Object designs (5 objects)

**Naming prefix:** `MDC` (= **M**onta **D**ocument **C**apture, distinct from `MON` reserved for the legacy Monta Utility line). All names are AL0305-validated (≤ 30 chars).

#### 4.1 TableExtension 50100 — `MDC CDC Doc. Capt. Setup Ext` (28 chars)

**File:** `Monta Document Capture Utility/MDCCDCDocCaptSetupExt.TableExt.al`

| Property | Value |
|---|---|
| ID | `50100` |
| Object name | `"MDC CDC Doc. Capt. Setup Ext"` |
| Extends | `"CDC Document Capture Setup"` |

**Field added:**

| Field no. | Name (≤30 chars) | Type | Properties |
|---|---|---|---|
| `50100` | `"Disable CDC Cross-Co. Tmpl."` (28 chars) | Boolean | `Caption = 'Disable CDC Cross-Company Template Lookup'`, `InitValue = true`, `DataClassification = CustomerContent`, no `OnValidate` trigger |

**No triggers.** Toggling does not need to do work — the next subscriber call reads fresh.

**Why field ID 50100 (not e.g. 50001)?** The Monta Document Capture Utility's full id range is `50100..50199`. Field IDs added by an extension must be inside the **extending app's** id range (CodeCop AA0228 / table-ext linter). `50100` is the first available.

#### 4.2 PageExtension 50101 — `MDC CDC Setup Purch. App. Ext` (29 chars)

**File:** `Monta Document Capture Utility/MDCCDCSetupPurchAppExt.PageExt.al`

| Property | Value |
|---|---|
| ID | `50101` |
| Object name | `"MDC CDC Setup Purch. App. Ext"` |
| Extends | `"CDC Setup - Purch. Approval"` |

**Layout addition:**

- Add a new `addlast(Content)` group `group("Monta Utility")` with `Caption = 'Monta Utility'`. Anchoring `addlast` puts it at the bottom of the Content area, visually separate from CDC's native groups so the Monta-added field is unambiguous to the admin.
- Inside the group, one field `field("Disable CDC Cross-Co. Tmpl."; Rec."Disable CDC Cross-Co. Tmpl.")`.

**ToolTip text** (per FR-3, must explain WHAT, that it's added by Monta, and the default):

> `'Specifies whether to suppress CDC''s prompt to copy a matching template from another company when no local template matches the document''s source. When enabled, CDC falls through to the standard "create new template" path silently. This field is added by Monta Document Capture Utility and defaults to ON.'`

`ApplicationArea = All;` matches the parent page (which is `ApplicationArea = All`). No `Visible`/`Editable` conditions — admins with DC setup access edit it freely.

#### 4.3 Codeunit 50102 — `MDC CDC Tmpl. Lookup Subscr.` (28 chars)

**File:** `Monta Document Capture Utility/MDCCDCTmplLookupSubscr.Codeunit.al`

| Property | Value |
|---|---|
| ID | `50102` |
| Object name | `"MDC CDC Tmpl. Lookup Subscr."` |
| `Access` | `Internal` |
| `Subtype` | (default — none) |

**Single procedure** (event subscriber):

```
[EventSubscriber(ObjectType::Table, Database::"CDC Document",
    'OnBeforeFindTemplateInCompanies', '', false, false)]
local procedure OnBeforeFindTmplInCos_Suppress(
    var FromCompany: Text[30];
    var FromTemplate: Record "CDC Template";
    SourceName: Text[250];
    var Result: Boolean;
    var IsHandle: Boolean)
```

Body (English; /develop writes AL):

1. Declare local var `Settings: Codeunit "MDC CDC Setup Mgmt."`.
2. If NOT `Settings.IsCrossCompanyTemplateCopyDisabled()` → `exit` (no-op preserves stock CDC behavior, FR-6).
3. Set `Result := false` and `IsHandle := true`.
4. Emit telemetry (see §5).

**No direct table access.** All knowledge of the toggle field lives in Settings.

**Why `local`, `Internal` codeunit, manual binding (`false, false`)?**
- `local` event subscriber procedure: standard for handler methods that should not be called by anyone else.
- `Internal` codeunit: nothing in this app or external apps needs to invoke the subscriber directly.
- Manual binding `false, false` (vs. SingleInstance): subscriber is stateless and invoked rarely (only on document capture). No reason to keep it instantiated.

#### 4.4 Codeunit 50103 — `MDC CDC Setup Mgmt.` (19 chars)

**File:** `Monta Document Capture Utility/MDCCDCSetupMgmt.Codeunit.al`

| Property | Value |
|---|---|
| ID | `50103` |
| Object name | `"MDC CDC Setup Mgmt."` |
| `Access` | (default — public, callable from other Monta apps) |

**Procedures:**

| Procedure | Access | Signature | Purpose |
|---|---|---|---|
| `IsCrossCompanyTemplateCopyDisabled` | `internal` | `(): Boolean` | Read-path. `Get` the singleton; if `Get` fails (row missing), call `EnsureSetupRecord()` and re-`Get`; return the Boolean field. **Belt-and-suspenders against the install-codeunit-didn't-fire edge case.** |
| `EnsureSetupRecord` | `internal` | `()` | Idempotent insert. If `Get` succeeds → no-op. If `Get` fails → `Init`, set `"Primary Key" := ''`, `Insert(true)`. `InitValue = true` on the new field auto-populates during `Init`. |

**Why `internal` and not `public` even though "future feature additions extend this codeunit"?**

The brief said `EnsureSetupRecord` could be `internal` or visible to other apps. **Recommendation: `internal`.** The two consumers are (a) the Subscriber codeunit in the same app and (b) the Install codeunit in the same app. No external app should reach into `EnsureSetupRecord` — that's a private lifecycle concern. If a future extension app needs to read the toggle, it should subscribe to a Monta-published event or call a fresh dedicated public read API, not re-run the install logic. Future-feature additions extending this codeunit (the brief's stated rationale) are extensions **inside** this app — `internal` does not block in-app extension. So: keep both procedures `internal`.

**Why no third "set" procedure?** YAGNI. Admins toggle via the page. Programmatic toggling is not a requirement.

**Mock affordance for future testing:** The codeunit has no constructor injection (AL has no DI). The seam for testing is the codeunit-call boundary itself: a future test app can substitute behavior by emitting an event from `IsCrossCompanyTemplateCopyDisabled` and subscribing in the test, OR by simply seeding the setup row before calling the Subscriber. The latter is what the project's MON-94 tests already do (insert raw records + assert) and is the recommended approach.

#### 4.5 Codeunit 50104 — `MDC CDC Setup Install` (21 chars)

**File:** `Monta Document Capture Utility/MDCCDCSetupInstall.Codeunit.al`

| Property | Value |
|---|---|
| ID | `50104` |
| Object name | `"MDC CDC Setup Install"` |
| `Access` | `Internal` |
| `Subtype` | `Install` |

**Triggers implemented:**

```
trigger OnInstallAppPerCompany()
trigger OnUpgradePerCompany()  -- (in a separate Codeunit with Subtype = Upgrade, see below)
```

**IMPORTANT correction on the brief:** AL splits Install vs. Upgrade into TWO codeunit subtypes. A single codeunit cannot carry both `Subtype = Install` and `Subtype = Upgrade`. The brief asked "which trigger/event it implements (`OnInstallAppPerCompany` vs `OnUpgradePerCompany` vs both)". Honest answer: BOTH are needed, which means **two codeunits in practice OR one codeunit `Subtype = Install` for fresh-install + an `OnUpgradePerCompany` trigger in a `Subtype = Upgrade` codeunit**.

**Recommendation:** keep this single Install codeunit (`Subtype = Install`) for the v1.0.0.0 ship. The `OnUpgradePerCompany` path is academic for v1 — there is no prior version to upgrade FROM. Add an Upgrade codeunit (`Subtype = Upgrade`, ID `50105`) **only** when v2 ships and a schema change requires it. Document this deferral in `.dev/03-code-review.md` as an explicit non-issue.

**This means the 5-object count is correct for v1 — Upgrade codeunit is a v2 concern.**

**Body of `OnInstallAppPerCompany`** (English):

1. Declare local var `Settings: Codeunit "MDC CDC Setup Mgmt."`.
2. Call `Settings.EnsureSetupRecord()`.
3. **Done.** No telemetry needed (install events are already audited by the platform).

**Idempotency story:**

- **Fresh install, no prior DC setup row:** `EnsureSetupRecord` calls `Get` (fails) → `Init` (assigns `InitValue = true` to our new field) → `Insert(true)`. Toggle is `true`. ✓
- **Fresh install, DC setup row already exists** (DC was installed first — common case): `EnsureSetupRecord` calls `Get` (succeeds) → no-op. **The toggle field on the existing row is `false` (Boolean column default)**, NOT `true`. ✗

That last bullet is the **critical edge case** — and it's why `EnsureSetupRecord` as written is INSUFFICIENT for this scenario. **Fix:** in `EnsureSetupRecord`, after the Get-success branch, check whether the new toggle field has been "touched" via a sentinel approach. AL has no "field was just added" detection, so the pragmatic fix is:

**Refined `EnsureSetupRecord` semantics** (corrected version /develop must implement):

1. If `Get` fails → `Init` + `Insert(true)`. `InitValue = true` populates the field. Done.
2. If `Get` succeeds AND record predates this app's install → we cannot tell from BC metadata. **Decision: explicitly set the field to `true` on first install, period.** This is the documented D-5 behavior (default ON on install). Code: `Get` succeeds → set `"Disable CDC Cross-Co. Tmpl." := true` → `Modify(false)`.
3. **Critical:** this path only runs on **install** (Subtype=Install codeunit), never on re-runs. Install codeunits fire **once per company per version**. So step 2 is not a re-set on every app start — it's a one-time set-to-default at install time. ✓

**Upgrade behavior (deferred to v2):** when v2 ships, a `Subtype = Upgrade` codeunit will use `App.GetCurrentModuleInfo` + a tag-based guard (see `Codeunit "Upgrade Tag"`) to ensure existing toggles are preserved across upgrades. Current admin choices NEVER get reset. /develop should add a stub upgrade codeunit (or a code-review note) capturing this for v2.

**No DC type dependencies in the Install codeunit:** the codeunit references `Codeunit "MDC CDC Setup Mgmt."` only, which in turn references `Record "CDC Document Capture Setup"`. **`Record "CDC Document Capture Setup"` IS a DC type.** So the Install codeunit DOES transitively depend on DC. The brief's caveat ("Install codeunit must NOT depend on any DC types directly because DC's symbols may not be loaded at install time on a tenant where DC isn't installed yet") deserves a careful answer:

- Our app declares DC as a **hard dependency** in `app.json` (D-8). BC's extension manager will NOT install our app on a tenant that lacks DC — the install fails before our `OnInstallAppPerCompany` can run. So the "DC not installed" timing race cannot occur. ✓
- **The only failure mode** is `dependency-resolution time` (BC tries to install our app but DC isn't there, install aborts cleanly). Our Install codeunit is never reached. No special handling needed. ✓

### 5. Telemetry

**Event ID convention** (mirrors MON-94's `MON-94-0001`, `MON-94-0002` pattern):

- `MON-DC-0001` — "Suppressed CDC cross-company template lookup" (FR-4).

Pattern: `MON-DC-NNNN`. The prefix `MON-DC` distinguishes Document Capture telemetry from `MON-94` (GL Cleanup). NNNN is sequential within the prefix.

**LogMessage call shape** (parameter values, NO code):

| Parameter | Value |
|---|---|
| `EventId` | `'MON-DC-0001'` (Locked label `SuppressedTok: Label 'MON-DC-0001', Locked = true`) |
| `Message` | `'Monta Utility suppressed CDC cross-company template lookup.'` (Locked label) |
| `Verbosity` | `Verbose::Verbose` |
| `DataClassification` | `DataClassification::SystemMetadata` |
| `TelemetryScope` | `TelemetryScope::ExtensionPublisher` |

**Custom dimensions** (per FR-4, "optional — note the company name where it fired"):

| Dimension | Value |
|---|---|
| `Company` | `CompanyName()` |
| `SourceName` | **DELIBERATELY OMITTED** — FR-4 says "log fact of suppression, not the document name or company". Wait — FR-4 actually says "company name where it fired" is OK. Re-read: yes, company name OK; document/source name NOT OK. So: include `Company`, exclude `SourceName`. |

**No `UserId`:** Application Insights captures `userPrincipalName` automatically; adding it to dimensions is redundant.

### 6. Sandbox smoke-test plan (substitute proof gate per D-9)

The substitute proof gate is a manual smoke test on a real BC SaaS sandbox tenant with DC 27.3 installed. The tester is the user (Jeppe). Steps:

#### Pre-requisites
1. BC SaaS sandbox tenant provisioned with admin access.
2. DC 27.3 installed in the sandbox via Continia's standard install path.
3. At least TWO companies in the tenant (call them `CRONUS Test` and `CRONUS Other`).
4. In `CRONUS Other`, create one CDC Vendor template with a recognizable Source Name (e.g., `"ACME Corp"`).
5. In `CRONUS Test`, ensure NO local template exists for source `"ACME Corp"`.
6. The signed `Monta Document Capture Utility` v1.0.0.0 .app deployed to the sandbox.

#### Test 1 — Install codeunit: fresh install (toggle defaulting to ON)
1. Before installing the Monta app, in `CRONUS Test`, open page `"Document Capture Setup / Purchase Approval"` and confirm the toggle field is NOT visible.
2. Install Monta Document Capture Utility v1.0.0.0.
3. Re-open the same page in `CRONUS Test`. **Pass criteria:** the toggle `"Disable CDC Cross-Co. Tmpl."` is visible, in a group `"Monta Utility"`, and the value is **ON (true)**.
4. Switch to `CRONUS Other`. Open the same page. **Pass criteria:** toggle is visible, value is **ON** (Install codeunit fires per-company).

#### Test 2 — FR-1: toggle ON suppresses prompt
1. In `CRONUS Test`, ensure toggle is ON.
2. Process a document (any vendor invoice PDF) whose source identifier matches the `"ACME Corp"` template that exists only in `CRONUS Other`.
3. Drive CDC's "find template" path (the standard new-document workflow that internally calls `FindTemplateInCompanies`).
4. **Pass criteria:** NO `"Copy template from CRONUS Other?"` Confirm dialog appears. CDC falls through to "create new template."

#### Test 3 — FR-4: telemetry emitted
1. Immediately after Test 2, open Application Insights for the sandbox tenant (or `Get-BcLogEntries` if available).
2. Filter on `customDimensions.eventId == 'MON-DC-0001'`.
3. **Pass criteria:** at least one log entry from the last 5 minutes; `customDimensions.Company == 'CRONUS Test'`; `severityLevel = 0` (Verbose).

#### Test 4 — FR-1 / FR-6: toggle OFF preserves stock behavior
1. In `CRONUS Test`, open the setup card. Toggle the field OFF (false). Save.
2. Repeat the document-capture flow from Test 2.
3. **Pass criteria:** the `"Copy template from CRONUS Other?"` prompt DOES appear (= stock CDC). Confirming Yes copies the template; confirming No takes the create-new-template path.
4. Re-check telemetry — **no new** `MON-DC-0001` entry from this run (confirms FR-6: subscriber is fully no-op when OFF).

#### Test 5 — Install codeunit: app upgrade preserves admin choice
1. With `CRONUS Test` toggle currently OFF (from Test 4), build a v1.0.1.0 of Monta Document Capture Utility (any trivial change, e.g., updated description in `app.json`). Deploy as upgrade.
2. After upgrade completes, re-open the setup card in `CRONUS Test`.
3. **Pass criteria:** toggle is still OFF (admin's choice was preserved). The Install codeunit's `OnInstallAppPerCompany` does NOT fire on upgrade — Install fires only on first install per version-line. **If this fails, the v2 Upgrade-codeunit work has been escalated and is no longer "deferred."**

#### Test 6 — DC reinstall scenario (edge case from §7)
1. Uninstall DC from the sandbox (this WILL also uninstall Monta DCU — DC is a hard dep).
2. Reinstall DC, then reinstall Monta DCU.
3. Open the setup card in `CRONUS Test`.
4. **Pass criteria:** toggle is ON (default re-asserted because Install codeunit fires for the fresh install of v1.0.0.0 after DC came back). **Note:** the DC setup row may have been preserved (if DC's uninstall doesn't wipe its tables) OR re-created. Either way the Monta install codeunit ensures the toggle is ON.

If any of Tests 1–5 fail, the feature does NOT merge. Test 6 is informational — a graceful-degradation check.

#### Smoke-test report artifact
The tester records pass/fail + Application Insights screenshot in `.dev/03-code-review.md` under the D-list "Substitute proof gate" entry.

### 7. Trade-offs & weaknesses (honest)

#### What this BC-idiomatic approach handles that the minimal approach doesn't

1. **Default-ON on existing-DC tenants.** A minimal "subscriber-reads-table-directly" approach relies on `InitValue = true`, which only fires when the row is **created**. Tenants where DC is installed FIRST already have a setup row — `InitValue` does nothing. The toggle column added by our extension defaults to `false` (Boolean column default). **The minimal approach ships disabled-by-default for the most common tenant timeline, contradicting D-5.** The Install codeunit closes that gap by explicitly setting the field on install.
2. **Future feature growth.** When a second behavior overlay lands (e.g., "Disable CDC's auto-categorization on incoming PDFs"), the Settings codeunit absorbs the second toggle's read path with one new procedure. The Subscriber stays thin. The minimal approach would either accumulate setup-table reads in subscriber bodies (becomes spaghetti) or require a refactor to introduce Settings later.
3. **Testability seam.** Even though no test app ships in v1, the read path is isolated. When a DC-bearing test container becomes available, the existing structure is test-friendly without a refactor.
4. **Lifecycle clarity.** Install codeunit is the documented BC pattern for "ensure singleton row with default value at app install." Auditors / code reviewers immediately recognize the shape. Minimal approach has no such hook — install behavior is implicit and easy to misread.

#### Real cost of 2 extra objects (Settings + Install)

- **Compile time:** ~0.2s per object on a self-hosted runner. Negligible (~0.4s total).
- **Mental load:** higher. Three call sites instead of one (subscriber → settings → table). New contributors must trace through more layers. Mitigation: codeunit names are explicit (`MDC CDC Setup Mgmt.` is self-describing) and procedure count per codeunit is tiny (Settings has 2; Install has 1).
- **Attack surface:** marginally higher. Two more codeunits exposed to permission-set authoring. Mitigated by `Internal` access on Install codeunit and `internal` on Settings procedures.
- **Object IDs consumed:** 5 instead of 3, out of 100 reserved. Plenty of headroom (95 IDs free).
- **app.json maintenance:** identical. Same single DC dependency entry.
- **PR review time:** ~5 extra minutes for a reviewer to verify the Install codeunit's idempotency story.

**Verdict:** the cost is real but small relative to the default-ON correctness payoff. For a feature that is shipped explicitly to **change a default**, the architecture that delivers the default reliably is the right architecture.

#### What if Continia changes the setup table's Insert/Modify trigger behavior?

The Install codeunit calls `Insert(true)` on the singleton — this fires DC's `OnInsert` trigger. We inspected `CDCDocumentCaptureSetup.Table.al` (BC 28 source); there is no `trigger OnInsert()` declared on the table — only `OnValidate` triggers on individual fields, none of which fire because we only set `"Primary Key" := ''` plus our own field. **So `Insert(true)` is functionally equivalent to `Insert(false)` here, and it's safe.**

**However**, if Continia adds an `OnInsert` trigger in a future DC version (e.g., to seed default file paths), our `Insert(true)` would invoke it. That's actually the correct behavior — we WANT DC's defaults applied — but it means our install behavior implicitly tracks DC's evolving init logic.

**Mitigation:** /develop should add a code comment on the `Insert(true)` line referencing this analysis: `// Insert(true) per BC convention: invokes DC's OnInsert if/when added, ensuring DC-managed defaults are applied. Verified no OnInsert trigger as of DC 27.3 — see .dev/02a-architect-2-idiomatic.md §7.`

#### Edge cases

**Tenant has DC installed AFTER our app:** impossible. DC is a hard dependency in `app.json` (D-8). BC will refuse to install Monta DCU on a tenant without DC. The "install order" question doesn't arise.

**Tenant has DC uninstalled then reinstalled:** uninstalling DC cascades-uninstalls Monta DCU (BC enforces dep integrity). Reinstalling DC alone does NOT re-install Monta DCU — admin must reinstall it. When admin reinstalls Monta DCU, the Install codeunit fires fresh, defaulting the toggle to ON (whether the DC setup row was preserved or wiped during DC's uninstall is irrelevant — `EnsureSetupRecord` handles both branches). See Test 6.

**DC version mismatch (admin upgrades DC first):** DC 27.3 → DC 27.4. Our `app.json` declares `version: 27.3.0.0` as the FLOOR. BC accepts DC 27.4 because it's ≥ 27.3. The `OnBeforeFindTemplateInCompanies` event signature is the contract — if Continia changes it in 27.4, our subscriber unbinds at runtime (silent failure: no error, just the subscriber stops firing). **This is a real risk, not blocked by anything in this plan.** Mitigation is at the Monta-Utility-vendor process level: subscribe to Continia release notes; on each DC release, /develop verifies the event signature is unchanged before bumping the dependency floor.

### 8. Implementation order (for /develop)

Strict dependency ordering:

1. **Verify BC 27.3 DC symbols** — extract `DC 27.3.0.330595 - 27.3 (BC 2025 Wave 2 CU3).app` (rename to `.zip`, unzip, find `SymbolReference.json`). Confirm: (a) DC app id `6da8dd2f-...`, (b) `OnBeforeFindTemplateInCompanies` event with the BC 28 signature, (c) Table 6085573 with Code[10] PK, (d) Page 6085625. Document findings inline in the commit message. **STOP and escalate if any signature differs from BC 28.**
2. **Verify the dependency chain** — extract the BC 27.3 DC `app.json`. Compare to BC 28 chain (8 deps). If `Continia Document Output` is present in 27.3, source it; if not, omit it. Confirm version floors.
3. **Commit `dependencies/` folder** — copy the 9 .app files (8 Continia chain + DC) into `dependencies/`. Add `README.md` line documenting Continia license redistribution per D-8.
4. **Edit `.AL-Go/settings.json`** — add `installApps` array with the 9 paths in dependency order.
5. **Edit `.github/AL-Go-Settings.json`** — append `"Monta Document Capture Utility"` to `appFolders`.
6. **Edit `Monta Document Capture Utility/app.json`** — fix `platform`, `application`, `runtime`, `dependencies`, `brief`, `description`, `help`, `url`, `resourceExposurePolicy` per §1.
7. **Verify CI compiles** — push a WIP commit (no AL objects yet, just app.json + settings + dependencies). The CI build job should now compile the empty `Monta Document Capture Utility` against DC symbols. If CI fails on dep resolution, fix `installApps` ordering before writing AL.
8. **Write Settings codeunit (50103)** first — it's the dependency for Subscriber and Install. `IsCrossCompanyTemplateCopyDisabled` and `EnsureSetupRecord` per §4.4.
9. **Write TableExtension (50100)** — the field the Settings codeunit reads. After this compiles, Settings codeunit will too.
10. **Write Install codeunit (50104)** — calls Settings. Confirm `Subtype = Install` set explicitly.
11. **Write Subscriber codeunit (50102)** — calls Settings. Use the verified BC 27.3 event signature from step 1 (NOT the BC 28 source — paranoia win).
12. **Write PageExtension (50101)** — field surfacing. Last because it has no callers; exists purely as UI.
13. **Local compile** — verify clean compile against `.alpackages` populated by `installApps`. CodeCop on. AL0305 on.
14. **Commit** — body must include `compile-verified only — docker constraint: DC not in test container.` per D-9.
15. **Open PR.** Trigger CI. Confirm green compile.
16. **Run sandbox smoke-test plan §6.** Capture results in `.dev/03-code-review.md`.
17. **Merge to main** only after smoke test passes.

### Assumptions

- Assumes BC 27.3 DC `.app` carries the same `OnBeforeFindTemplateInCompanies` event signature as BC 28 source. **[VERIFY]** — step 1 of implementation order.
- Assumes BC 27.3 DC has the same 8-app dependency chain as BC 28 (or fewer — `Continia Document Output` may or may not be present). **[VERIFY]** — step 2.
- Assumes Continia's redistribution license permits committing all 9 .app files to a private GitHub repo per D-8. (Confirmed by user; documented in repo README per implementation order step 3.)
- Assumes the project's self-hosted Windows AL-Go runner has internet egress to GitHub raw URLs IF `installApps` ever switches from local paths to URLs. (Currently using local repo paths, so no egress needed. Stays self-contained.)
- Assumes `appFolders` in `.AL-Go/settings.json` (project-local, currently empty) is intentionally empty and the runtime config in `.github/AL-Go-Settings.json` is authoritative. **[VERIFY]** — confirm no AL-Go-Setting merge surprise (the empty array doesn't override the populated repo-level array).
- Assumes `InitValue = true` on a Boolean field works on extension fields the same way it does on base fields. **[VERIFY]** — official AL docs; pattern is standard but worth a quick smoke check during step 9 (open the page after first install on a fresh CRONUS company, confirm checkbox shows ticked).
- Assumes `MDC` prefix does not collide with any existing AL identifier in the dependency chain (unlikely — all our objects are app-scoped — but a `MDC` substring within a Continia object name would be cosmetic at worst). No verification needed; AL namespace per-publisher.
- Assumes the Install codeunit's `OnInstallAppPerCompany` fires on every existing company on first install of the app. **[VERIFY]** — this is documented BC behavior, but Test 1 step 4 verifies it on the live tenant.
- Assumes no existing object in DC is named `"MDC ..."` causing a name collision. (Continia uses `CDC ...` prefix, so MDC is collision-free.)

---

## Object Allocation Table

| ID | Object | Name | File |
|---|---|---|---|
| 50100 | TableExtension | `MDC CDC Doc. Capt. Setup Ext` | `MDCCDCDocCaptSetupExt.TableExt.al` |
| 50101 | PageExtension | `MDC CDC Setup Purch. App. Ext` | `MDCCDCSetupPurchAppExt.PageExt.al` |
| 50102 | Codeunit (Subscriber) | `MDC CDC Tmpl. Lookup Subscr.` | `MDCCDCTmplLookupSubscr.Codeunit.al` |
| 50103 | Codeunit (Settings/Mgmt) | `MDC CDC Setup Mgmt.` | `MDCCDCSetupMgmt.Codeunit.al` |
| 50104 | Codeunit (Install) | `MDC CDC Setup Install` | `MDCCDCSetupInstall.Codeunit.al` |

Field 50100 on table-ext 50100 is the only data shape. 95 object IDs and 99 field IDs remain free.

---

**End of plan.** /develop writes AL code; nothing in this plan is executable AL.
