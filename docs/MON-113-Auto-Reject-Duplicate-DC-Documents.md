# MON-113 — Auto-reject Document Capture documents on duplicate External Doc. No.

Technical design and build record. Target app: `Document Capture/Monta Document Capture Utility` (Bylov Consulting, id `2ce68cba-96aa-4f2b-80bd-502b16187a0f`), dependency Continia Document Capture 27.3.0.0.

**Status: built, 23 tests green, smoke-tested on `Sandbox__XML` and confirmed working.**

This document was rewritten after the first sandbox test failed. The original design rested on a premise that turned out to be false, and the section below says so plainly rather than quietly presenting the corrected version as if it had always been the plan — because the mistake is the most useful thing in here for whoever maintains this next.

---

## 1. The mistake, and what it cost

The original design detected duplicates by reading the **Message Center ID** on the `CDC Document Comment` that Continia writes when it finds a collision. That mechanism was designed, built, tested with seven RED/GREEN cycles, reviewed, merged into a green CI run — and did nothing at all in the sandbox.

**Continia writes the comment we cared about with `DocumentComment.Add(...)`, which has no `MsgCenterID` parameter.** The row lands with a blank Message Center ID. No filter can match it.

The message that *is* Message-Center-routed — `ExternalDocumentNumberAlreadyExists`, text `External Document No. %1 already exists (in %2, %3 = %4).` — genuinely exists in the symbols. It is simply not the message that fires for these documents. Symbol reading found a plausible candidate, and the design was written against it without confirming it was the one in play.

Only a real import could have caught that. It is the reason the sandbox smoke test was a gate rather than a formality.

### What the three checks actually are

From `CDCPurchValidation.Codeunit.al`, the `CHECK EXTERNAL DOCUMENT NO.` block:

| # | Checks against | How the comment is written | Message Center ID |
|---|---|---|---|
| 1 | `Vendor Ledger Entry` — posted | `DocumentComment.Add(...)` | **blank** |
| 2 | `Purchase Header` — unposted invoice and credit memo | `DocumentComment.Add(...)` | **blank** |
| 3 | Other open DC documents in the journal | `MessageCenterSetupMgt.DuplicateInvoiceInJournal(...)` | `C6085705_DUPLICATE_INV_JOURNAL` |

Case 3 is the only one with an ID — which is why the ID configured on the sandbox looked right and changed nothing. It identifies a different check.

### Why not match the comment text

It is the obvious fallback and it was rejected. The comment is built from a `Label`, so it is translated. A text filter works until someone runs BC in Danish, then silently stops — the same invisible failure, arriving later and harder to diagnose. **The feature must not depend on the user's language.**

That constraint is what forces the current design.

---

## 2. Design

Two independent detection paths, neither depending on comment text.

```
Continia: capture -> validate -> writes its comments, whatever they say
                                  |
              CDC Purch. - Validation :: OnAfterValidateDocument
                                  |
                    MDC Dup. Reject Sub.   (subscriber, one call)
                                  |
                    MDC Dup. Reject Mgt.
                                  |
   already auto-rejected? not Open? no setup row? switch off?  -> exit
                                  |
                          FindDuplicate
                          /              \
              our own lookup          message centre comment
        posted ledger entries,        another OPEN DC document
        unposted invoices and         still in the journal
        credit memos
                          \              /
                                  |
   one Modify(false): Status + Date-Time + MDC Auto-Rejected + Reason
                                  |
                     telemetry MON-DC-0002
```

### Why our own lookup, when the ticket said not to duplicate

MON-113 says *"prefer extending Continia's existing validation over duplicating its duplicate-detection logic."* That is good advice and it is not achievable here: nothing language-independent identifies which comment Continia wrote. The duplication is forced by the language requirement, and its cost is real — if Continia changes those filters, ours will not follow.

Three things limit the damage:

- **The inputs are not re-derived.** `PurchDocMgt.GetDocumentNo()` and `GetDocumentType()` are Continia's own public API — the same accessors its check uses. Only the six `SetRange` calls are ours.
- **Continia's check still runs.** We suppress nothing, so its comments still appear on the document card for anyone reading documents by hand.
- **The mirrored source is pinned in a code comment** — `CDCPurchValidation.Codeunit.al`, DC 28.3.0.302359 — so the next person knows what to diff on a Continia upgrade. Filters verified identical across DC 26.2 and 28.3.

### The hook

`Codeunit "CDC Purch. - Validation"`, event `OnAfterValidateDocument(var Document; var IsValid: Boolean)`.

Confirmed at source: the duplicate comment is written around line 155, the event fires at line 642 at the end of `Run`. The ordering assumption held.

Two source facts worth keeping:

- The publisher declares the parameter as `IsInvalid` but passes `IsValid`. The name is the opposite of the meaning. We ignore it; anyone who reads it should not.
- Immediately after the event, Continia runs `if IsValid <> Rec.OK then begin Rec.OK := IsValid; Rec.Modify(); end;` on the **same record instance** we were handed, so our `Status` write is carried into that `Modify` rather than clobbered by it.

### Guard chain

Cheapest first. The two free document-property checks sit ahead of any database access.

| # | Guard | Cost | Pinned by |
|---|---|---|---|
| 1 | `MDC Auto-Rejected` already true | free | `DoesNotRejectAgainAfterReopen` |
| 2 | `Status <> Open` | free | `DoesNotRejectARegisteredDocument` |
| 3 | setup row missing | 1 row | — |
| 4 | switch off | same row | `DoesNothingWhenAutoRejectDisabled` |

Then `FindDuplicate`, then one `Modify(false)` writing all four fields.

### Inside `HasDuplicate`

```
blank document number      -> false
resolve pay-to vendor      -> false if the vendor does not exist
resolve document kind      -> false for Order, Receipt, blank
posted lookup   (Vendor Ledger Entry)   -> true, with its reason
unposted lookup (Purchase Header)       -> true, with its reason
```

Posted wins: the unposted lookup runs only when the posted one missed, so a document colliding with both is never reported against the open invoice when a posted one exists.

### Three deliberate divergences from Continia

Each is commented in the code as intentional, because "we mirror Continia" is a claim the next reader will rely on and it needs its exceptions listed.

| Divergence | Why |
|---|---|
| `else exit(false)` on document type | Continia's `case` has no `else`, so `Order`, `Receipt` and blank leave its lookup **unfiltered on type**. MON-113 is scoped to invoices and credit memos, and an unfiltered type lookup is a false-positive source. |
| Guarded `Vendor.Get` | Continia calls it unguarded from `OnRun`, where a missing vendor errors the whole validation. `HasDuplicate` returns a boolean and must not throw — an error escaping the subscriber would kill Continia's entire validation run. |
| Omitted legacy `SetCurrentKey` | Continia's `if PurchHeader.SetCurrentKey(...) then;` is a NAV 7 guard for a key that exists in BC 27. Replaced with a plain `SetCurrentKey` on Key4, which covers two of three filters where the default covers one. |

`FilterOnFiscalYear` is not replicated: it returns false unless localization is `'ES'`.

---

## 3. Objects and configuration

| Object | ID | |
|---|---|---|
| `codeunit "MDC Dup. Reject Mgt."` | 50108 | the logic |
| `codeunit "MDC Dup. Reject Sub."` | 50107 | subscriber, one call |
| `tableextension "MDC CDC Document Ext"` | 50105 | `MDC Auto-Rejected`, `MDC Auto-Reject Reason` |
| `pageextension "MDC DC Document Card Ext"` | 50106 | surfaces both, read-only |
| `tableextension "MDC DC Setup Ext"` | 50100 | +2 setup fields |
| `pageextension "MDC DC Setup Card Ext"` | 50101 | +2 setup fields |

Test app `Monta Document Capture Utility.Test` uses **50400–50499**. It originally claimed 50200–50299, which Monta Payment Reconciliation already owns — a collision that would have failed at deploy, not at build, because **AL-Go compiles each project in isolation and no compiler ever sees two apps at once**. A CI step unioning the declared `idRanges` across every `app.json` would catch the next one at PR time.

| App | Range | Uses |
|---|---|---|
| Monta Document Capture Utility | 50100–50199 | 50100–50108 |
| Monta Document Capture Utility.Test | 50400–50499 | 50400 |
| Monta Payment Reconciliation | 50200–50299 | 50200–50207 |
| Monta Payment Reconciliation.Test | 50300–50399 | 50300–50303 |

### The two setup fields have different scopes

| Field | Gates | Default |
|---|---|---|
| **Auto-Reject Duplicate Documents** | **Everything.** Off means no detection at all. | off |
| **Duplicate Message Center ID** | **The journal path only.** Blank disables journal detection; the vendor-invoice lookup runs regardless. | blank |

That second row changed in v2. Under the original design a blank ID disabled the whole feature. It now scopes one path.

No install code is needed: the switch has no `InitValue`, so it is false on a fresh company through `Init()` and false on an existing row because that is the column default. The neighbouring `Disable CDC Cross-Co. Tmpl.` field *does* need explicit handling in `EnsureSetupRecordOnInstall`, precisely because its desired default is `true` and `InitValue` does not backfill.

---

## 4. Tests

**23 tests, all green, run in CI as well as locally.** Fifteen RED/GREEN cycles across two designs, plus two REFACTORs.

The tests that carry the weight are the ones asserting something is **not** done. In every pair, the positive test would pass against an implementation that searches too broadly — and since we are now the authority rather than a reader of Continia's verdict, "too broad" means auto-rejecting legitimate invoices with no human in the loop.

| Falsifier | What it prevents |
|---|---|
| `IgnoresPostedInvoiceForADifferentVendor` | Vendor A's invoice rejected because vendor B once used that number |
| `IgnoresPostedCreditMemoWhenDocumentIsInvoice` | An invoice matched against a credit memo |
| `IgnoresUnpostedInvoiceWhenDocumentIsCreditMemo` | A credit memo matched against an unrelated open invoice |
| `IgnoresDocumentTypesOutsideInvoiceAndCreditMemo` | `Order` / `Receipt` / blank matched with no type filter |
| `IgnoresABlankDocumentNumber` | Every uncaptured document matched against every entry with no external number |
| `IgnoresAVendorThatDoesNotExist` | An error escaping the subscriber and killing Continia's whole validation run |
| `PostedDuplicateWinsOverUnposted` | The reason pointing at an open invoice when a posted document exists |
| `DoesNotRejectAgainAfterReopen` | A reopened false positive re-rejected forever |
| `DoesNotRejectARegisteredDocument` | A document that already became a purchase invoice being rejected after the fact |

Four tests pass on arrival and were verified by **mutation** rather than a fake RED — the guard was temporarily removed, the red captured, the guard restored, and the mutated state never committed. Notably, `IgnoresDocumentTypesOutsideInvoiceAndCreditMemo` guards a `case` with no `else`, for which **AL raises no warning at all**: removing our `else exit(false)` compiles clean and passes every analyzer. Only that test notices.

---

## 5. Known limitations

**Continia's `OnAfterReject` never fires.** We write `Status` directly because `Reject()` raises a `Confirm` with no reachable suppression — under the job queue `GuiAllowed` is false, `Confirm` returns its default, and the rejection would silently not happen. A runtime diagnostic walked every comparable field before and after a real `Reject()` and found it changes exactly `Status` and `Date-Time for Register/Reject` — so the row is identical, but subscribers to `OnAfterReject` do not run. Measured: **nothing in the installed app set subscribes to it**, so this currently costs nothing. Re-check after adding Continia modules.

**`MDC Auto-Rejected` can never be cleared.** A document flagged during a misconfiguration is permanently exempt from future auto-rejection. Reopening works normally; the flag is what stops a reopened false positive being re-rejected. Accepted deliberately.

**The reason may name an arbitrary match.** When a vendor has two or more open purchase documents of the same type carrying the same number, which one the reason names depends on key order. The verdict is unaffected. Making it deterministic is a product decision, not a refactor.

**The setup field cannot be filled before Continia's "Create Default setup" has run**, because `TableRelation` blocks manual entry into an empty template table. Accepted.

**We are now the authority.** Previously the feature only acted on something Continia had already flagged. It now decides independently, so a divergence between our filters and Continia's would produce a rejection with no corresponding Continia comment. The falsifier tests exist for that reason.
