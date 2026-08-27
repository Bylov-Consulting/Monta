# Auto-rejecting duplicate documents in Document Capture

**Monta Document Capture Utility**

When the same vendor invoice arrives in Document Capture twice, this feature sets the second one to **Rejected** automatically and records why, so nobody has to spot it and reject it by hand.

It is **off by default**. It rejects documents with no person involved, so it stays inert until someone in the company deliberately turns it on.

---

## Turning it on

**Document Capture Setup** → the **Monta Document Capture Utility** section.

| Field | What to set |
|---|---|
| **Auto-Reject Duplicate Documents** | Turn on. Nothing happens until you do. |
| **Duplicate Message Center ID** | Optional. See *Two kinds of duplicate* below. |

That is the whole configuration. Nothing needs setting per document category or per template.

---

## What counts as a duplicate

A document is auto-rejected when its vendor document number already exists **for the same paying vendor**, on any of:

- a **posted** purchase invoice or credit memo
- an **open, unposted** purchase invoice or credit memo

Two details that matter in practice:

**Scoped to the vendor.** Vendors number their own invoices, so two vendors using the same number is ordinary and is not a duplicate. If a vendor is paid through another vendor — a subsidiary billing through its parent, say — the check uses the **paying** vendor, so the same invoice arriving from two subsidiaries of one parent is caught.

**Invoices and credit memos only.** Orders and receipts are never auto-rejected. An invoice is never matched against a credit memo, or the other way round, even when they carry the same number.

A document whose number was never captured — OCR could not read it — is never auto-rejected. It has nothing to compare.

---

## Two kinds of duplicate

There are two separate situations, and they are detected differently.

**Against something already in Business Central** — a posted entry or an open purchase document. Detected automatically. **No configuration needed.**

**Against another document still sitting in the Document Capture journal** — the same invoice imported twice, both waiting to be registered, neither posted yet. This one is detected only if you fill in **Duplicate Message Center ID**.

To fill it in: open **Message Center Setup**, find the entry for duplicate invoices in the journal — `C6085705_DUPLICATE_INV_JOURNAL` on Monta's environment — and select it in the lookup.

| Field | Switches off |
|---|---|
| **Auto-Reject Duplicate Documents** turned off | Everything |
| **Duplicate Message Center ID** left blank | Journal detection only — the rest keeps working |

---

## What you see on a rejected document

Open the document in Document Capture. Under **Status** on the Document Card:

| Field | |
|---|---|
| **Auto-Rejected as Duplicate** | Ticked when this app rejected it, not a person |
| **Auto-Rejection Reason** | Which document it collided with |

The reason reads like:

> Document no. GBQWC2026050002 already exists on posted vendor ledger entry 1586.

or, for one not yet posted:

> Document no. GBQWC2026050002 already exists on open purchase document PI-00412, which has not been posted.

Continia's own warning stays on the document as well, in the **Comments** list. This feature does not replace or suppress anything Continia does — it acts on top of it.

---

## If it rejected something it should not have

**Reopen the document.** Use Continia's normal **Reopen** action on the Document Card.

The document goes back to **Open** and **stays open**. It will not be auto-rejected again, even though the collision is still there and validation runs again. Once a person has looked at a document and decided it is not a duplicate, this feature leaves it alone permanently.

**Auto-Rejected as Duplicate** stays ticked afterwards. That is deliberate — it is the mark that stops it being rejected a second time, and it records that the rejection was automatic rather than someone's decision.

One consequence worth knowing: a document that has been auto-rejected once is **never** auto-rejected again, even much later and even if it becomes a genuine duplicate. If a batch was rejected because the setup was wrong, correcting the setup does not make those documents eligible again — they stay marked. Check a few documents after changing the configuration rather than assuming.

---

## If it is not rejecting anything

Work down this list.

1. **Is the switch on?** *Auto-Reject Duplicate Documents* on the Document Capture Setup page.
2. **Is the document actually a duplicate for the same paying vendor?** Check the vendor on the collision, and check the **Pay-to Vendor No.** on the vendor card — the check uses the paying vendor, which may not be the one that sent the document.
3. **Is it an invoice or a credit memo?** Orders and receipts are out of scope.
4. **Was the document number captured?** A blank number is never a duplicate.
5. **Is it a journal duplicate?** If the other copy is still in Document Capture and nothing is posted, you need **Duplicate Message Center ID** filled in.
6. **Was the document already Registered?** A document that has already become a purchase invoice is never auto-rejected — the two records would contradict each other.
7. **Has it been auto-rejected before?** Check *Auto-Rejected as Duplicate*. If it is ticked, the document is permanently exempt.

If none of those explain it, telemetry records every automatic rejection under event `MON-DC-0002`, including which detection path decided. An absence of that event for a document you expected to be rejected is the useful signal.

---

## Turning it off

Turn off **Auto-Reject Duplicate Documents**. Detection stops immediately.

Documents already auto-rejected stay rejected — turning the switch off does not reverse anything. Reopen them individually if you want them back in the queue.

There is also a Continia-side control for the journal path: lowering that message to **Information** in **Message Center Setup** stops it triggering an auto-rejection, without changing anything on the Monta setup page.
