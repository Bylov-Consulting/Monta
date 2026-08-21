# MON-113 — Auto-reject Document Capture documents on duplicate External Doc. No.

Technical design. Target app: `Document Capture/Monta Document Capture Utility` (Bylov Consulting, id `2ce68cba-96aa-4f2b-80bd-502b16187a0f`), dependency Continia Document Capture 27.3.0.0.

Everything under "Verified" was confirmed against the actual CDC 27.3.0.330595 symbol package — by `al_symbolsearch` and by compiling probe code with `al compile`. Everything under "Unverified" cannot be checked statically because the Continia app is an encrypted runtime package; the tests exist to settle those.

---

## 1. What Continia already does

Continia detects the collision and writes it as a **Message Center comment**, not as a field flag.

**Verified:**

- `Codeunit "CDC Message Center Setup Mgt."` exposes `ExternalDocumentNumberAlreadyExists(Document; Field; LineNo; Arg1..Arg4; var ErrorWasAdded)` (internal).
- Its message text is `External Document No. %1 already exists (in %2, %3 = %4).` — four placeholders, matching the four Arg parameters.
- Sibling messages in the same codeunit cover the rest of the ticket's "what counts as already exists" question:
  - `%1 %2 already exists (on %3, %4 = %5).` — posted document
  - `%1 %2 already exists (on unposted invoice %3).` / `(on unposted invoice %3 for %4 = %5).`
  - `%1 %2 already exists (on unposted credit memo %3).` / `(on unposted credit memo %3 for %4 = %5).`
  - `DocFoundOnDiffVendor(...)` — a **separate** message for the cross-vendor hit.
- Every one of these lands in table `CDC Document Comment` via `AddMsgCenter(...; MsgCenterID: Code[50]; InfoAllowed; WarningAllowed; ErrorAllowed; var ErrorWasAdded)`.
- `CDC Document Comment` carries: `Document No.`, `Field Code`, `Line No.`, `Area` (`Capture` | `Match` | `Validation`), `Comment Type` (`Information` | `Warning` | `Error`), `Comment: Text[250]`, **`Message Center ID: Code[50]`**.
- Severity per message is customer configuration, held in table `CDC Msg. Center Setup Template`, keyed by `Message Center ID` + `Template No.` (the older `CDC Message Center Setup` table is marked removed as of tag 8.0 — do not use it).

**This settles two of the ticket's open questions without any code:**

| Open question | Answer |
|---|---|
| Match scope — same vendor only? | Continia's check is already vendor-aware. Same-vendor and cross-vendor are *different* Message Center IDs. Subscribe to the same-vendor one; add the cross-vendor one later if Monta wants it. No filtering logic of our own. |
| What counts as "already exists"? | Continia already covers posted invoice, posted credit memo, unposted invoice, unposted credit memo. Which of them auto-reject is chosen by which Message Center IDs Monta configures — not by code. |

---

## 2. The hook

**`Codeunit "CDC Purch. - Validation"`, event `OnAfterValidateDocument(var Document: Record "CDC Document"; var IsInvalid: Boolean)`.**

Verified: the codeunit exists, the event exists with that signature, and a subscriber to it compiles clean against DC 27.3.

There is **no** dedicated Continia event fired when the duplicate is detected. `CDC Document Comment` publishes no `OnAfterAddMsgCenter`. So the pattern is: let validation finish, then read the comments it wrote.

Also verified as available on the `CDC Document` record, callable from our extension:

- `procedure Reject()` — public, **but unusable here: it prompts.** See section 6.
- `procedure HasWarningComments(): Boolean` — public
- `Status` option members, in order: `Open`, `Registered`, `Rejected`
- table event `OnAfterReject(var Document)`
- `procedure Reopen()` is **internal** — users reopen from the CDC page action, we cannot call it

Other Continia details the build corrected, each found by running against DC 27.3 rather than by reading symbols:

- `CDC Document Comment."Entry No."` is **`AutoIncrement`**. Assigning it yourself fails at runtime.
- `CDC Document Comment.Area` has **six** members — `Capture`, `Validation`, `Processing`, `Match`, `Import`, `Contracts`.
- `"Comment Type"` is an **`Option`, not an `Enum`**, so it cannot be passed as a typed parameter without restating Continia's member list in our code. Read the members off a record variable instead.
- `CDC Document Activity Log` is `Access = Internal`; declaring it as a `Record` fails with `AL0161`.

Fallback hooks, both verified to compile, held in reserve for the risks in section 6:

- `Database::"CDC Document Comment"`, `OnAfterInsertEvent`
- `Codeunit "CDC Purch. - Full Capture"`, `OnAfterFullCapture(var Document)`
- `Codeunit "CDC Document Importer"`, `OnCheckDocAutoReg(var Document; var Handle)`

---

## 3. Design

One subscriber, one management codeunit, four fields. No lookup against `Purch. Inv. Header` or `Purchase Header` — the ticket asks for reuse and a second implementation would drift from Continia's.

```
Continia: capture -> validate -> writes CDC Document Comment (Msg Center ID)
                                  |
                                  v
              CDC Purch. - Validation :: OnAfterValidateDocument
                                  |
                    MDC Dup. Reject Sub.  (subscriber, 3 lines)
                                  |
                    MDC Dup. Reject Mgt.  (all logic, directly testable)
                                  |
   already auto-rejected? not Open? switch off? no ID? no matching comment? -> exit
                                  |
   one Modify(false): Status + Date-Time for Register/Reject
                    + MDC Auto-Rejected + MDC Auto-Reject Reason
```

**Not `Reject()`**, and no audit comment or telemetry — see sections 4 and 5.

### Objects — as built

| Object | ID | Change |
|---|---|---|
| `tableextension "MDC DC Setup Ext"` extends `CDC Document Capture Setup` | 50100 | **+2 fields** |
| `pageextension "MDC DC Setup Card Ext"` | 50101 | **+2 fields** |
| `tableextension "MDC CDC Document Ext"` extends `CDC Document` | 50105 | **new**, 2 fields |
| `pageextension "MDC DC Document Card Ext"` extends `CDC Document Card` | 50106 | **new**, 2 read-only fields |
| `codeunit "MDC Dup. Reject Sub."` | 50107 | **new**, subscriber only |
| `codeunit "MDC Dup. Reject Mgt."` | 50108 | **new**, the logic |

`MDC DC Setup Install` (50104) is **unchanged** — the new switch needs no install code, see section 4.

All object names ≤ 30 chars (AL0305).

### Object ID ranges — check these before adding an app

The test app was first given 50200–50299, which **Monta Payment Reconciliation already owns**, and its test codeunit was 50200, the same ID as `codeunit 50200 "MON Pmt Recon Post"`. Both apps install into the same Monta tenant, so this would have failed at deploy with a duplicate object ID.

**AL-Go compiles each project in isolation, so no compiler ever sees two apps at once** — a collision between sibling apps in one repo is invisible until both `.app` files reach the same tenant. CI cannot catch it as things stand. A CI step that unions the declared `idRanges` across every `app.json` and fails on overlap would catch the next one at PR time.

| App | Range | Uses |
|---|---|---|
| Monta Document Capture Utility | 50100–50199 | 50100–50108 |
| Monta Document Capture Utility.Test | 50400–50499 | 50400 |
| Monta Payment Reconciliation | 50200–50299 | 50200–50207 |
| Monta Payment Reconciliation.Test | 50300–50399 | 50300–50303 |

### Fields

On `CDC Document Capture Setup`:

| Field | Type | Purpose |
|---|---|---|
| `MDC Auto-Reject Duplicates` | Boolean | Master switch. Default **false** on install — this rejects documents without a human, so it is opt-in per company. |
| `MDC Duplicate Msg. Center ID` | Code[50] | `TableRelation = "CDC Msg. Center Setup Template"."Message Center ID"` — verified to compile. Monta picks the entry from Continia's own list; nothing is hardcoded. |

On `CDC Document`:

| Field | Type | Purpose |
|---|---|---|
| `MDC Auto-Rejected` | Boolean, Editable=false | Loop guard **and** audit marker. Survives Continia deleting comments on re-validation. |
| `MDC Auto-Reject Reason` | Text[250], Editable=false | Copy of the Continia comment text. Satisfies acceptance criterion "the reason is discoverable afterwards". |

### The subscriber (verified to compile, zero errors, zero warnings)

```al
[EventSubscriber(ObjectType::Codeunit, Codeunit::"CDC Purch. - Validation", 'OnAfterValidateDocument', '', false, false)]
local procedure AutoRejectOnDuplicate(var Document: Record "CDC Document"; var IsInvalid: Boolean)
var
    DupRejectMgt: Codeunit "MDC Dup. Reject Mgt.";
begin
    DupRejectMgt.RejectIfDuplicate(Document);
end;
```

### Management codeunit API

```al
internal procedure RejectIfDuplicate(var Document: Record "CDC Document"): Boolean
```

One procedure. The design originally also listed `IsAutoRejectEnabled()` and `GetDuplicateMsgCenterID()`; both were built, then deleted once the setup read was collapsed into a single `Get()` and neither had a caller. Nothing in the suite reached them, so a bug in either would not have failed a test — untested surface that looks tested is worse than none.

Guard order inside `RejectIfDuplicate`, cheapest first. The two free document-property checks sit ahead of the setup read, so a document that can never be auto-rejected costs zero database access:

| # | Guard | Cost | Test that fails without it |
|---|---|---|---|
| 1 | `MDC Auto-Rejected` already true → exit | free | `DoesNotRejectAgainAfterReopen` |
| 2 | `Status <> Status::Open` → exit | free | `DoesNotRejectARegisteredDocument` |
| 3 | Setup row missing → exit | 1 row | — |
| 4 | Switch off → exit | same row | `DoesNothingWhenAutoRejectDisabled` |
| 5 | Message Center ID blank → exit | same row | — |
| 6 | No comment matching document + ID + Warning/Error → exit | 1 `FindFirst` | `LeavesDocumentUntouchedWhenOtherMsgCenterID`, `IgnoresInformationSeverityComment` |

Guard 2 is an **allow-list, not a deny-list**. With members `Open, Registered, Rejected`, blocking only `Registered` would still let an already-Rejected document be re-rejected and have its `Date-Time for Register/Reject` rewritten, and would silently admit any status Continia adds later.

Then one `Modify(false)` writing `Status`, `Date-Time for Register/Reject`, `MDC Auto-Rejected` and `MDC Auto-Reject Reason`.

**Not `Reject()`** — see section 6. The audit comment and telemetry described in the original design were not built; the two document fields plus the page extension cover the acceptance criterion, and a comment would be deleted by Continia on re-validation anyway.

### Remaining ticket questions

- **Which category?** The subscriber sits on the *purchase* validation codeunit, so it only fires for purchase categories. That is the stated assumption. Narrowing to one category code is one extra setup field and one extra guard — add it only if Lene names a code.
- **Reversibility?** A user reopens from CDC's own Reopen action; `MDC Auto-Rejected` stays true so we never touch it again. The reason stays visible on the document card.

---

## 4. Footprint

As built: two new codeunits (`MDC Dup. Reject Mgt.` 50108, `MDC Dup. Reject Sub.` 50107), one new tableextension (50105 on `CDC Document`), one new pageextension (50106 on `CDC Document Card`), two fields added to the existing setup tableextension and two to the existing setup page extension. **No install code** — see below. No new tables, no job queue entry, no scheduled task, no duplicate-detection logic of our own.

Install needs nothing because `MDC Auto-Reject Duplicates` carries no `InitValue`, so it is false on a fresh company through `Init()` and false on an existing row because that is the column default. The neighbouring `Disable CDC Cross-Co. Tmpl.` field *does* need explicit handling in `EnsureSetupRecordOnInstall`, precisely because its desired default is `true` and `InitValue` does not backfill existing rows. Ours wants `false`, which is what it already is.

---

## 5. TDD plan

### Test project

New folder `Document Capture/Monta Document Capture Utility.Test`, added to `testFolders` in `Document Capture/.AL-Go/settings.json` (currently `[]`). Codeunit `"MDC Dup. Reject Tests"` (21 chars).

The tests drive `MDC Dup. Reject Mgt.` directly with `CDC Document` and `CDC Document Comment` rows inserted by the test, and never invoke Continia's capture or OCR pipeline. That keeps them runnable in a container without a Continia Online activation.

**Do this before writing any test:** publish the eight Continia apps from `Document Capture/dependencies/` into a BC 27.3 container and confirm they install. If they refuse without a Continia license, the CLAUDE.md migration/legacy-dependency exception applies — the commit gate cannot be satisfied and this needs an unblock decision, not a workaround.

### Cycles — as built

Seven RED/GREEN pairs plus a REFACTOR, `bc-test` run fresh against container `bcmondc` at every commit. Each RED test is the cycle-1 test with **exactly one token changed**, so there is only one thing that can make it pass.

| # | Test | RED → GREEN | bc-test |
|---|---|---|---|
| 1 | `AutoRejectsWhenDuplicateCommentPresent` — asserts Status only | `9ed621b` → `9696b9f` | 0/1 → 1/1 |
| 2 | `LeavesDocumentUntouchedWhenOtherMsgCenterID` | `5b73f99` → `3518f03` | 1/2 → 2/2 |
| 3 | `IgnoresInformationSeverityComment` | `b168f75` → `ea04852` | 2/3 → 3/3 |
| 4 | `DoesNothingWhenAutoRejectDisabled` | `7a63867` → `751fc8a` | 3/4 → 4/4 |
| 5 | `RecordsReasonWhenAutoRejecting` | `8a7a851` → `a7bcdd8` | 4/5 → 5/5 |
| 6 | `DoesNotRejectAgainAfterReopen` | `ce1174d` → `eea95de` | 5/6 → 6/6 |
| 7 | `DoesNotRejectARegisteredDocument` | `8fb06ae` → `da9550d` | 6/7 → 7/7 |
| — | REFACTOR: one setup row read instead of two | `ea4a0ef` | 7/7 |
| — | GREEN: subscriber, page extensions | `3c839b0` | 7/7 |

Cycle 1's GREEN deliberately rejected on *any* comment. That is triangulation: it is what makes cycle 2 genuinely fail rather than pass on arrival.

**Two changes from the plan above.** Cycle 7 (`DoesNotRejectARegisteredDocument`) was not in the original list — the `Status <> Open` guard was specified in section 3 and no cycle was scheduled for it, and no existing test could have caught the omission because every one of them builds an Open document. And `AutoRejectsWhenDuplicateCommentIsError` was dropped: after cycle 3 added the severity filter it would have passed on arrival, and the TDD gate rejects a green RED.

The tests that make the suite prove rather than pass are 2, 3, 6 and 7 — the four that assert something is *not* done. Without them an implementation that rejects every document carrying any comment goes green on the rest.

### Sandbox smoke test — required before merge

The AL test harness bypasses the license layer and never exercises Continia's pipeline, so container-green is not evidence the feature works. On the Monta sandbox (tenant `8e9e7bfd-c925-4ae1-a1ca-20240f386627`):

1. Open the Message Center Setup page, find the entry whose Comment (example) is `External Document No. %1 already exists (in %2, %3 = %4).`, note its Message Center ID, set it in DC setup and turn the switch on.
2. Confirm the purchase category's template actually uses `CDC Purch. - Validation` as its validation codeunit.
3. Import a document whose External Doc. No. matches a **posted** purchase invoice for the same vendor → arrives Rejected, reason visible.
4. Same against an **open** purchase invoice.
5. Import a non-duplicate → normal flow, untouched.
6. Reopen an auto-rejected document → it stays Open through the next validation.

---

## 6. The four assumptions — two settled, two still open

Continia ships as an encrypted runtime package, so its implementation cannot be read. Four things were assumed. Running the code settled two of them; the other two need the sandbox.

### Settled — assumption 2 was wrong

**`Reject()` prompts.** It raises `Confirm Do you want to reject the document?` from `CDC Document` (table 6085590) line 7, and there is no reachable way to suppress it: `ResetSkipConfirmMsg()` is a reset, not a setter, and `CDC Template.SkipConfirm(Boolean)` is `internal` to Continia.

This was never only a test problem. The feature runs inside document validation:

- **Job queue / OCR import**, the normal path — `GuiAllowed` is false, so `Confirm` returns its default and the rejection silently does not happen.
- **Interactive** — a dialog appears in front of a user who took no action.

Either way the feature would have looked correct in review and failed in production, on the path that matters, without an error. It only surfaced by running against the real engine; the call compiles fine.

### Settled — assumption 3 holds, and is now measured

Writing `Status` and `Date-Time for Register/Reject` directly is **equivalent** to `Reject()`, not an approximation. A throwaway diagnostic walked every comparable field of the `CDC Document` row with a `RecordRef` — a generic walk, not a guess list — before and after a real `Reject()` with a `ConfirmHandler`, and found exactly two changes:

```
Status:                        Open -> Rejected
Date-Time for Register/Reject: <blank> -> now
```

No activity-log row, no comment, no `Document Status Text` refresh. `CDC Document Activity Log` and `CDC Document Comment` row counts were unchanged at 0 → 0. The diagnostic was deleted once read; the finding is recorded in a comment on the implementation.

### Still open — the sandbox is the only place these can be answered

1. **`ExternalDocumentNumberAlreadyExists` runs before `OnAfterValidateDocument` fires.** The entire design rests on this. If Continia writes the comment later, `FindFirst` finds nothing and the feature does nothing — indistinguishable from "no duplicate found". Fallback: latch the hit in a subscriber on `Database::"CDC Document Comment"` `OnAfterInsertEvent` and act in `OnAfterValidateDocument`. Both events compile.
2. **The category's template uses `CDC Purch. - Validation`.** `CDC Template` carries a validation codeunit ID; if Monta's template points elsewhere the subscriber never fires. Step 2 of the smoke test checks this.

Two more that the build added to the list:

3. **`Modify(false)` inside the subscriber.** Every test calls `RejectIfDuplicate` directly. Under Continia's validation the record may be mid-transaction or held by the caller. Per the project's memory note, a licence error on `Modify` is fixed with `Permissions`, not a redesign.
4. **The real Message Center ID.** Every test invents one. Nobody has yet confirmed the ID of Continia's actual duplicate message, or that it appears in the `CDC Msg. Center Setup Template` lookup the setup field relates to. The container's copy of that table is empty until Continia's "Create Default setup" action runs.

---

## 7. Not doing

No independent lookup against `Purch. Inv. Header` or `Purchase Header`. The ticket asks for reuse, and two implementations of the same rule will eventually disagree — at which point the DC document says one thing and the posting engine says another.
