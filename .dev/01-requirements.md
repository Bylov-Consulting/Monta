# Requirements: Disable CDC Cross-Company Template Lookup

**Date:** 2026-04-29
**Status:** APPROVED — open questions resolved, ready for planning

---

## Business Context

Continia Document Capture (CDC) includes a behavior where, when processing a document whose source name does not match any template in the current company, it searches other companies for a matching template and prompts: "Copy template from <CompanyX>?" If the user confirms, the template is copied cross-company.

Monta has requested this behavior be suppressed through code by subscribing to the `OnBeforeFindTemplateInCompanies` integration event published by CDC's `CDC Document` table (Table 6086302), using the IsHandled pattern. The suppression must be controllable per company via a toggle on DC's existing setup table.

The feature ships as a **new isolated AL-Go app** ("Monta Document Capture Utility"), separate from the existing "Monta Utility" app. It has its own `app.json`, ID range, and folder. "Monta Utility" remains untouched.

---

## Decisions Log

| ID | Decision | Rationale |
|---|---|---|
| D-1 | Keep BC platform target at BC 27. Use the BC 27.3 DC build. | Avoid an unrelated platform upgrade; user provided the BC 27.3 .app path. |
| D-2 | Cloud (SaaS) DC variant. | Target tenants are SaaS. |
| D-3 | Suppress for ALL CDC document categories. | Event is generic; no per-category filter in subscriber. |
| D-4 | Configurable via Boolean toggle on DC's "CDC Document Capture Setup" table (TableExtension, not a new Monta setup table). | Keeps configuration adjacent to other DC config; reuses DC's permission model. |
| D-5 | Toggle default = ON (suppression active on install). | Aligns with stated intent — Monta wants this disabled out of the box. |
| D-6 | User-facing UX = silent. Telemetry only via `Session.LogMessage`. | Cleanest UX; provides support visibility without notifying end users. |
| D-7 | No new permission set. Toggle field inherits DC's existing tabledata permissions. | TableExtension fields ride on base-table perms; admins with DC setup access can edit the toggle. |
| D-8 | DC dependency .app committed to `dependencies/` folder in the repo, wired via AL-Go `installApps`. | Standard AL-Go pattern; user's existing convention. Continia license confirmed permits redistribution within private repo. |
| D-9 | **No test app for this feature.** Feature ships compile-verified only. | DC is not installable in the project's BC docker container. Per the user-wide migration/legacy-dependency exception, the feature is honest compile-only with a documented unblock path; al-runner is NOT a substitute. Each commit body must declare "compile-verified only — docker constraint." A pre-merge sandbox smoke test (real BC SaaS sandbox with DC installed) is the substitute proof gate. |
| D-10 | **New isolated AL-Go app**: "Monta Document Capture Utility", publisher "Bylov Consulting", ID range 50100..50199. Created via the AL-Go "Create a new app" workflow. | User-mandated isolation from "Monta Utility" — the GL Cleanup feature is unrelated and should not gain a new external dependency on Continia. |

---

## Functional Requirements

### FR-1: Suppress cross-company template lookup (when toggle is ON)

When `FindTemplateInCompanies` is invoked on Table 6086302 "CDC Document", a subscriber in Monta Utility must:

- Read the new toggle field from `"CDC Document Capture Setup"` (per-company singleton).
- If the toggle is **ON** (true), set `IsHandle := true` and leave `Result := false`. `FindTemplateInCompanies` returns `false` immediately, the Confirm dialog is skipped, and CDC falls through to its standard "create new template" path.
- If the toggle is **OFF** (false), the subscriber takes no action — CDC's stock behavior continues (the cross-company search and Confirm prompt occur as today).

Both call sites in CDC (lines 1044 and 1078 of `CDCDocument.Table.al`) raise the same event, so a single subscriber covers both.

### FR-2: Configuration field on DC Setup

Add a new Boolean field to `"CDC Document Capture Setup"` via TableExtension:

- **Logical name:** "Disable CDC Cross-Company Template Lookup" (final field name to be chosen during /plan with AL0305 30-char limit in mind — likely `"Disable CDC Cross-Co. Tmpl."` or similar).
- **Default value (`InitValue`):** `true` (ON — per D-5).
- **Per-company:** Yes (DC setup table is per-company by BC convention).

### FR-3: Surface the toggle in the DC Setup card

Add a PageExtension on Page 6085625 `"CDC Setup - Purch. Approval"` (caption "Document Capture Setup / Purchase Approval", PageType Card) to surface the new field in an appropriate group with a clear ToolTip explaining what it does and that it is added by Monta Utility.

### FR-4: Telemetry on suppression

When the subscriber suppresses a call:

- Emit `Session.LogMessage` with:
  - A stable event ID (e.g., `'MON-DC-001'`).
  - Verbosity: `Verbose`.
  - Data classification: `SystemMetadata` (no customer data — log fact of suppression, not the document name or company).
  - Message: e.g., `"Monta Utility suppressed CDC cross-company template lookup."`
  - Custom dimensions: optional — note the company name where it fired.

No user-facing message, notification, or page action.

### FR-5: No changes to existing copied templates

This feature is forward-only. Templates already copied cross-company before installation are not removed, altered, or flagged.

### FR-6: Toggle OFF preserves stock CDC behavior

When the toggle is OFF, the subscriber must be a no-op (no telemetry, no flag mutation). Users who set the toggle off must observe identical CDC behavior to a tenant without Monta Utility installed.

---

## Validation Rules

No data validation rules. The feature is purely behavioral — a subscriber sets flags before the standard CDC logic runs based on a configuration read.

---

## User Workflows

### Current (before feature)
1. User processes a document whose source name has no local template match.
2. CDC calls `FindTemplateInCompanies`.
3. A matching template is found in another company.
4. User sees: "Copy template from CompanyX? [Yes] [No]"
5. On Yes: template is copied into current company.
6. On No: "create new template" path.

### After install, toggle ON (default)
1. User processes a document whose source name has no local template match.
2. CDC calls `FindTemplateInCompanies`.
3. Monta Utility subscriber fires; reads toggle = true; sets `IsHandle := true`, `Result := false`; emits telemetry.
4. `FindTemplateInCompanies` returns `false` immediately — no cross-company search.
5. Confirm dialog NEVER appears.
6. "Create new template" path is taken directly.

### After install, toggle OFF (manually flipped)
Identical to "Current (before feature)" — Monta subscriber is a no-op.

### Toggling
Admin opens "Document Capture Setup / Purchase Approval" card → finds the new "Disable CDC Cross-Company Template Lookup" boolean field → toggles → standard BC modify behavior, no commit hooks needed.

---

## Data Requirements

### TableExtension on "CDC Document Capture Setup" (Table 6085573)

| Field | Type | Default | Notes |
|---|---|---|---|
| "Disable CDC Cross-Company Template Lookup" (working name) | Boolean | true (`InitValue`) | New extension field. Final name must fit AL0305 30-char limit. |

No new tables. No setup record management code (DC already manages the singleton record).

---

## BC Integration

### Event subscription (ground truth)

| Property | Value |
|---|---|
| Publisher table | Table 6086302 "CDC Document" |
| Event name | `OnBeforeFindTemplateInCompanies` |
| Signature (BC 28 source) | `(var FromCompany: Text[30]; var FromTemplate: Record "CDC Template"; SourceName: Text[250]; var Result: Boolean; var IsHandle: Boolean)` |
| Event type | `[IntegrationEvent(false, false)]` |
| Source line (BC 28) | 2958 of `CDCDocument.Table.al` |
| Callers (BC 28) | Lines 1044 and 1078 of the same table |
| Suppression pattern | Set `IsHandle := true` and `Result := false` in subscriber |

**Residual risk to verify in /plan:** The event signature has not been verified against the BC 27.3 .app symbols (only against the BC 28 source). The signature is expected to be stable across DC versions, but planning must confirm by inspecting the .app symbols (e.g., extract `.alpackages/` symbol package and grep) before code is written. If the BC 27.3 signature differs, FR-1 wiring may need adjustment.

### New AL objects (in `Monta Document Capture Utility/`)

| Object kind | Purpose | Approx. ID | Naming constraint |
|---|---|---|---|
| TableExtension | Adds toggle field to "CDC Document Capture Setup" | 50100 | Name ≤ 30 chars |
| PageExtension | Surfaces toggle on "CDC Setup - Purch. Approval" | 50101 | Name ≤ 30 chars |
| Codeunit (event subscriber) | Subscribes to `OnBeforeFindTemplateInCompanies`; reads toggle; mutates flags; emits telemetry | 50102 | Name ≤ 30 chars |

ID range: 50100..50199 (100 IDs) — fully isolated from Monta Utility's 90000–90010 range. Three new objects use 50100–50102; 97 IDs remain free for future DC-related extensions in this app.

### App folder & app.json (new isolated app)

| Field | Value |
|---|---|
| Folder | `Monta Document Capture Utility/` (repo root) |
| `name` | `"Monta Document Capture Utility"` |
| `publisher` | `"Bylov Consulting"` |
| `version` | `1.0.0.0` (initial) |
| `platform` | `27.0.0.0` (matches Monta Utility) |
| `application` | `27.0.0.0` |
| `runtime` | `16.0` |
| `idRanges` | `[ { "from": 50100, "to": 50199 } ]` |
| `features` | `["NoImplicitWith"]` |
| `dependencies` | One entry for Continia Document Capture (publisher, id, name, version extracted from the BC 27.3 `.app` symbol package during /plan) |

### Dependency declaration

The new app's `app.json` `dependencies` array must include Continia Document Capture. Planning extracts the publisher, app ID, name, and version from the BC 27.3 .app symbol package.

The `Monta Utility` app remains unchanged — it does NOT gain a DC dependency.

### AL-Go CI wiring (`.AL-Go/settings.json`)

Currently `appFolders: []`, `testFolders: []`, `bcptTestFolders: []`. Changes required:

1. Add `"Monta Document Capture Utility"` to `appFolders`. (The AL-Go CreateApp action does this automatically when run; no manual edit needed if it succeeds.)
2. Verify `"Monta Utility"` is also listed in `appFolders` after CreateApp runs (it should be — CreateApp appends, not replaces). If not, add it.
3. Populate `testFolders` with `"Monta Utility Tests"` so existing tests still build.
4. Add `installApps` entry pointing to the DC .app at `dependencies/DC 27.3.0.330595 - 27.3 (BC 2025 Wave 2 CU3).app` (relative path).

Commit the DC .app to a new `dependencies/` folder in the repo root.

---

## UI/UX Requirements

### Toggle field on DC Setup card

- Page extended: 6085625 `"CDC Setup - Purch. Approval"` (caption "Document Capture Setup / Purchase Approval").
- Field placement: a logical group on the page (final group name TBD in /plan — e.g., a `"Monta Utility"` group, or appended to an existing group like `"Templates"` if one exists).
- ToolTip: explain (a) what suppressing cross-company lookup does, (b) that the field is added by Monta Utility, (c) the default is ON.

### No notifications, messages, or new pages

Suppression is silent to the end user; only telemetry records the action.

---

## Permission Model

- **No new permission set introduced by this feature.**
- The toggle field rides on DC's existing tabledata permissions for `"CDC Document Capture Setup"`. Admins who can already edit DC setup can edit the toggle.
- The subscriber runs under the user's session permissions and only reads from the setup table — DC's own R-permission for the table covers this.
- The existing `"Monta GL Cleanup"` permset is unchanged.

---

## Constraints

| ID | Constraint |
|---|---|
| C-1 | BC version: New app targets BC 27 (`platform 27.0.0.0, application 27.0.0.0, runtime 16.0`) — same as Monta Utility. DC dependency is BC 27.3. |
| C-2 | Target deployment: SaaS (cloud) only. |
| C-3 | New app's ID range 50100..50199: 3 to be used (50100–50102). 97 IDs remain free. |
| C-4 | AL identifier length 30 chars (AL0305) — field, tableextension, pageextension, and codeunit names must all comply. |
| C-5 | DC license: Continia redistribution permitted within private repo (confirmed). |
| C-6 | Test container: DC is not installable in the project's BC docker container, so end-to-end tests against real DC behavior are not possible (see Test Strategy). |
| C-7 | App isolation: the new "Monta Document Capture Utility" app is fully isolated from "Monta Utility". The two apps share only the repo and the AL-Go pipeline; neither depends on the other. |

---

## Test Strategy

Per user-wide rule (`bc-test` is the gate; `al-runner` cannot satisfy it; commits without a green `bc-test` run must explicitly declare "compile-verified only — docker constraint" with documented unblock requirements).

### Approach: compile-verified only — no test app shipped (D-9)

DC is not installable in the project's BC docker container (license/image constraint). The user has elected NOT to ship a paired test app for this feature. This is an explicit invocation of the user-wide migration/legacy-dependency exception.

**What we WILL do:**

1. **Compile gate:** the new app must compile cleanly against the BC 27.3 DC symbols inside AL-Go CI (`installApps` wiring satisfies this).
2. **No new test codeunit, no new test app.** The existing `Monta Utility Tests` app is unrelated to this feature and is not modified.
3. **Pre-merge sandbox smoke test (mandatory substitute proof gate):** before the PR for this feature merges to `main`, the app must be deployed to a real BC SaaS sandbox tenant with DC 27.3 installed, and a manual smoke test must verify:
   - With toggle ON (default), processing a document whose source name matches a template in another company does NOT show the "Copy template from..." prompt.
   - With toggle OFF, the prompt appears as it would on stock CDC.
   - The toggle field appears on the "Document Capture Setup / Purchase Approval" card with a working ToolTip.
   - Telemetry entry is emitted on suppression (visible in BC's Application Insights or via `Get-BcLogEntries` if available).
   - This is documented in `.dev/03-code-review.md` as the proof-of-correctness for this feature, alongside the D-list gap entry.

**Commit body discipline:** every commit that ships AL changes for this feature must include a line:
`compile-verified only — docker constraint: DC not in test container.`

**`.dev/03-code-review.md` D-list entry:** a documented gap stating "End-to-end CDC suppression not covered by automated tests. **Substitute proof gate**: pre-merge SaaS sandbox smoke test required (criteria above). **Long-term unblock**: provision a BC container image that includes DC 27.3 and a Continia evaluation license, then add a paired test app exercising `FindTemplateInCompanies` with multi-company template setup."

---

## Out of Scope

- Removing or modifying templates that were copied cross-company prior to installation.
- Modifying the "Copy from File" path in CDC.
- Changing any CDC Template page or other CDC UI directly (besides the single setup field surfaced via pageextension).
- Suppressing or modifying any other CDC cross-company behavior beyond `FindTemplateInCompanies`.
- Upgrading the CDC extension or providing a CDC build path.
- Changes to how CDC handles the "create new template" fallback path (owned by CDC).
- Populating `appFolders` / `testFolders` in `.AL-Go/settings.json` is needed for CI to build at all but is a wider repo-hygiene fix; it is documented here as a precondition but the scope of /plan should call out whether it's bundled with this feature or a separate ticket.

---

## Success Criteria

- [ ] On a SaaS tenant with **Monta Document Capture Utility** installed alongside DC 27.3, with the toggle ON (default), processing a document whose source name matches a template in another company NEVER shows the "Copy template from <CompanyX>?" prompt.
- [ ] With the toggle OFF, behavior is identical to a tenant without the new app installed.
- [ ] `Session.LogMessage` entry with the agreed event ID is emitted on each suppressed call (verifiable via Application Insights).
- [ ] The new app compiles cleanly against the BC 27.3 DC .app in AL-Go CI.
- [ ] AL-Go pipeline build succeeds with both apps (`Monta Utility` and `Monta Document Capture Utility`) listed in `appFolders`, DC installable from `dependencies/`.
- [ ] Pre-merge sandbox smoke test passes per Test Strategy criteria (substitute proof gate, since no automated tests are shipped per D-9).
- [ ] No regression in existing Monta Utility / GL Cleanup functionality (the existing Monta Utility app is not modified by this feature).
- [ ] AL0305 (30-char identifier limit) not violated by any new object or field.
- [ ] Continia license redistribution status documented in repo README or LICENSE notes (since the .app is committed).

---

## Preconditions for /plan

1. **AL-Go CreateApp workflow has run** and scaffolded `Monta Document Capture Utility/` with the agreed name, publisher, and ID range. Branch must be back in the worktree (`worktree-feature`) with the new folder committed.
2. BC 27.3 DC .app at `C:\Users\JeppeBylov\Downloads\DC27.3+EM27.3-NA-APP\App\BC 27.3 (BC 2025 Wave 2 CU3)\Document Capture\DC 27.3.0.330595 - 27.3 (BC 2025 Wave 2 CU3).app` is the source artifact. Planning copies it into `dependencies/` in the worktree.
3. Verify `OnBeforeFindTemplateInCompanies` exists with the same signature in the BC 27.3 .app symbol package before writing the subscriber.
4. Extract Continia publisher name, app ID, version, and app name from the BC 27.3 .app for the new app's `app.json` `dependencies` entry.

---

## Open Questions

None blocking. The following minor items are deferred to /plan:

- Final identifier names for the field, tableextension, pageextension, and subscriber codeunit (must satisfy AL0305 30-char limit).
- Exact placement (group) of the toggle field on the DC setup card.
- Whether populating `.AL-Go/settings.json` `appFolders`/`testFolders` is bundled with this feature or split out.
- Telemetry event ID convention (e.g., `MON-DC-001`) — confirm pattern matches any existing Monta telemetry IDs.
