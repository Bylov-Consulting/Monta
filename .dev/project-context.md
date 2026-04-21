# Project Context (Auto-Maintained)

**Last Updated:** 2026-04-21 by init-context

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
│   └── app.json                # App manifest (id, version, idRange, dependencies)
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

**Object-folder convention:** _not yet established._ When the first objects are added, pick one and record the decision here. Common choices in BC:

- By object type: `Monta Utility/Tables/`, `Monta Utility/Pages/`, `Monta Utility/Codeunits/`, …
- By feature: `Monta Utility/Features/<FeatureName>/` with mixed object types inside
- Flat inside `Monta Utility/src/`

**`appFolders` / `testFolders`** in `.github/AL-Go-Settings.json` are currently empty arrays — update them when the folder layout is decided, otherwise AL-Go builds the repo root as the app.

## Key Objects Registry

### Tables & Extensions
_Empty — no tables or tableextensions defined yet._

### Pages & Extensions
_Empty — no pages or pageextensions defined yet._

### Codeunits
_Empty — no codeunits defined yet._

### Enums / Enum Extensions
_Empty._

### Reports / XMLPorts / Queries
_Empty._

### Permission Sets / Entitlements
_Empty — no permissionset objects yet. Remember: BC 27 requires AL-defined permissionsets (XML permissionsets deprecated)._

## Architectural Patterns

_No patterns are encoded in code yet. Record decisions here as they are made so agents don't have to re-derive them from scattered examples._

### Validation Pattern
- **Location:** _TBD_
- **Approach:** _TBD — e.g. OnValidate triggers for simple field validation; dedicated validation codeunit procedures for anything reused or non-trivial_
- **Example:** _TBD_

### Extension Pattern
- **Field ID range:** will draw from 90000–90010 (very small range — plan carefully; extend with a new app or request a larger range if needed)
- **Field naming prefix:** _TBD — e.g. `Bylov ` or `MNT ` for disambiguation in extended base tables_
- **Events:** _TBD — prefer integration events on codeunits over coupling directly to base-app triggers_
- **Subscriber placement:** _TBD — convention is a dedicated `*EventSubscribers.Codeunit.al` per feature_

### Error Handling
- **Pattern:** _TBD — BC 27 prefers `ErrorInfo` with actions and telemetry over bare `Error()`_
- **Validation Messages:** _TBD — label naming convention, e.g. `ErrXxxMsg: Label '...'`_

## Base App Integration Points

### Tables We Extend
_None yet._

### Events We Subscribe To
_None yet._

### Procedures We Call
_None yet._

## Common Code Locations

_No code yet — populate as features are implemented. Example entries once real:_

- _Credit validation: `Codeunit 90000 "Credit Mgmt".CheckLimit()`_
- _Posting hook: event subscriber in `Codeunit 90001 "Posting Subscribers"`_
- _UI extensions: `PageExt 90000..90005`_

## Dependencies

### Internal Dependencies
_None — single-app project._

### External Dependencies
_None — `app.json` `dependencies` array is empty. Add entries here when dependencies are introduced (id, name, publisher, min version)._

## Testing Infrastructure

### Test Codeunits
_Empty — no test app or test codeunits yet._

### Test Data Setup
- **Location:** _TBD — convention: separate test app under `Monta Utility Tests/` with its own `app.json` and `testFolders` entry in AL-Go settings_
- **Patterns:** _TBD — library codeunits + per-feature test codeunits is the BC norm_

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
