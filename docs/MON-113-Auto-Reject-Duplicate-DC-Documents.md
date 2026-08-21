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

- `procedure Reject()` — public
- `procedure HasWarningComments(): Boolean` — public
- `Status` option members `Open`, `Rejected`, `Registered` (no `New`/`Approved`/`Deleted`)
- table event `OnAfterReject(var Document)`
- `procedure Reopen()` is **internal** — users reopen from the CDC page action, we cannot call it

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
        setup off? already auto-rejected? not Open? no matching comment? -> exit
                                  |
      set MDC Auto-Rejected + MDC Auto-Reject Reason -> Modify -> Reject() -> audit comment -> telemetry
```

### Objects

Existing IDs in use: tableext 50100, pageext 50101, codeunits 50102/50103/50104. Range is 50100–50199.

| Object | ID | Change |
|---|---|---|
| `tableextension "MDC DC Setup Ext"` extends `CDC Document Capture Setup` | 50100 | **+2 fields** |
| `tableextension "MDC CDC Document Ext"` extends `CDC Document` | 50105 | **new**, 2 fields |
| `pageextension "MDC DC Setup Card Ext"` | 50101 | **+2 fields** |
| `pageextension "MDC DC Document Card Ext"` extends `CDC Document Card` | 50106 | **new**, 2 read-only fields |
| `codeunit "MDC Dup. Reject Sub."` | 50107 | **new**, subscriber only |
| `codeunit "MDC Dup. Reject Mgt."` | 50108 | **new**, the logic |
| `codeunit "MDC DC Setup Install"` | 50104 | default the new setup fields |

All object names ≤ 30 chars (AL0305).

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
internal procedure IsAutoRejectEnabled(): Boolean
internal procedure GetDuplicateMsgCenterID(): Code[50]
```

Guard order inside `RejectIfDuplicate`, all four needed:

1. `Document."MDC Auto-Rejected"` already true → exit. **Without this, a user who reopens a false positive gets it re-rejected on the next validation pass.**
2. `Document.Status <> Status::Open` → exit.
3. Setup missing, switch off, or Message Center ID blank → exit.
4. No `CDC Document Comment` for this document with that Message Center ID and `Comment Type` in {Warning, Error} → exit.

Then: set the two document fields, `Modify(false)`, `Reject()`, add an Information comment via the public `CDC Document Comment.Add(...)`, emit `Session.LogMessage('MON-DC-0002', ...)` matching the existing `MON-DC-0001` telemetry style.

### Remaining ticket questions

- **Which category?** The subscriber sits on the *purchase* validation codeunit, so it only fires for purchase categories. That is the stated assumption. Narrowing to one category code is one extra setup field and one extra guard — add it only if Lene names a code.
- **Reversibility?** A user reopens from CDC's own Reopen action; `MDC Auto-Rejected` stays true so we never touch it again. The reason stays visible on the document card.

---

## 4. Footprint

Two new codeunits, one new tableextension, one new pageextension, four fields, one install line. No new tables, no job queue entry, no scheduled task, no duplicate-detection logic of our own.

---

## 5. TDD plan

### Test project

New folder `Document Capture/Monta Document Capture Utility.Test`, added to `testFolders` in `Document Capture/.AL-Go/settings.json` (currently `[]`). Codeunit `"MDC Dup. Reject Tests"` (21 chars).

The tests drive `MDC Dup. Reject Mgt.` directly with `CDC Document` and `CDC Document Comment` rows inserted by the test, and never invoke Continia's capture or OCR pipeline. That keeps them runnable in a container without a Continia Online activation.

**Do this before writing any test:** publish the eight Continia apps from `Document Capture/dependencies/` into a BC 27.3 container and confirm they install. If they refuse without a Continia license, the CLAUDE.md migration/legacy-dependency exception applies — the commit gate cannot be satisfied and this needs an unblock decision, not a workaround.

### Cycles

Each cycle: `RED:` commit with the failing test, `GREEN:` commit with the implementation, `REFACTOR:` if warranted. `bc-test` run fresh at every commit.

| # | Test | Proves |
|---|---|---|
| 1 | `AutoRejectsWhenDuplicateCommentPresent` — Open document + Warning comment with the configured ID → Status becomes Rejected, `MDC Auto-Rejected` true, `MDC Auto-Reject Reason` equals the comment text | The core requirement |
| 2 | `LeavesDocumentUntouchedWhenOtherMsgCenterID` — comment present but with a **different** Message Center ID → Status stays Open, flag stays false | We key on the specific message, not on "has a warning". Without this test, a broken implementation that rejects on any warning passes cycle 1. |
| 3 | `DoesNothingWhenAutoRejectDisabled` — switch off → untouched | Opt-in is real |
| 4 | `DoesNotRejectAgainAfterReopen` — `MDC Auto-Rejected` true, Status Open → untouched | The false-positive escape hatch survives re-validation |
| 5 | `AutoRejectsWhenDuplicateCommentIsError` — same as 1 but `Comment Type::Error` | Works whichever severity Monta configures |
| 6 | `WritesAuditCommentOnAutoReject` — an Information comment carrying the duplicate text exists afterwards | Acceptance criterion "reason discoverable" |
| 7 | `IgnoresInformationSeverityComment` — comment with the right ID but `Comment Type::Information` → untouched | We act on warnings and errors only, so Monta can dial the message down to Information to switch the behaviour off from Continia's own setup page |

Cycles 2, 4 and 7 are the ones that make the suite prove rather than pass. Tests 1, 3, 5 and 6 alone would go green on an implementation that rejects every document carrying any comment.

### Sandbox smoke test — required before merge

The AL test harness bypasses the license layer and never exercises Continia's pipeline, so container-green is not evidence the feature works. On the Monta sandbox (tenant `8e9e7bfd-c925-4ae1-a1ca-20240f386627`):

1. Open the Message Center Setup page, find the entry whose Comment (example) is `External Document No. %1 already exists (in %2, %3 = %4).`, note its Message Center ID, set it in DC setup and turn the switch on.
2. Confirm the purchase category's template actually uses `CDC Purch. - Validation` as its validation codeunit.
3. Import a document whose External Doc. No. matches a **posted** purchase invoice for the same vendor → arrives Rejected, reason visible.
4. Same against an **open** purchase invoice.
5. Import a non-duplicate → normal flow, untouched.
6. Reopen an auto-rejected document → it stays Open through the next validation.

---

## 6. Unverified — the tests settle these

Continia ships as an encrypted runtime package, so its implementation cannot be read. Four things are assumed and each has a stated fallback.

1. **`ExternalDocumentNumberAlreadyExists` runs before `OnAfterValidateDocument` fires.** If the sandbox test shows the comment is not there yet, latch the hit in a subscriber on `Database::"CDC Document Comment"` `OnAfterInsertEvent` and act in `OnAfterValidateDocument`. Both events compile.
2. **`Reject()` does not prompt.** CDC has `Register()` and `RegisterYN()` as separate methods but only one `Reject()`, which suggests the confirm lives on the page action. If it does prompt it will fail under the job queue import path — then set `Status::Rejected` and `Date-Time for Register/Reject` directly instead. The tests must run **without** a `ConfirmHandler` so a dialog fails them loudly.
3. **Our `Modify` is not overwritten by Continia's own `Modify` later in the call stack.** Mitigated by writing our fields before calling `Reject()`. The sandbox test is the arbiter.
4. **The category's template uses `CDC Purch. - Validation`.** `CDC Template` carries a validation codeunit ID; if Monta's template points elsewhere, the subscriber never fires. Step 2 of the smoke test checks this.

---

## 7. Not doing

No independent lookup against `Purch. Inv. Header` or `Purchase Header`. The ticket asks for reuse, and two implementations of the same rule will eventually disagree — at which point the DC document says one thing and the posting engine says another.
