# Disclaimer and License inside the CCSync App

## Overview

Surface the terms of use directly inside the built CCSync.app: bundle the root
LICENSE without duplicating its text, show a non-dismissible disclaimer sheet on
first launch (persisting acknowledgement in UserDefaults), and add an About panel
with the app version and the full MIT license text. Changes are app-target only;
CCSyncCore and the CLI are untouched.

## Context

- Files to modify:
  - `App/CCSync.xcodeproj/project.pbxproj` — hand-authored pbxproj with sequential
    IDs `AA0000…`; add a PBXFileReference to `../LICENSE`, a PBXBuildFile, and an
    entry in the empty Resources build phase (`AA…000F`).
  - `App/CCSync/CCSyncApp.swift` — the `@main` entry point; the disclaimer sheet and
    the About menu command are wired in here.
- Files to create:
  - `App/CCSync/AppLegalText.swift` — single source of the disclaimer wording (a
    constant) plus helpers that read LICENSE and extract the copyright line from
    `Bundle.main`.
  - `App/CCSync/DisclaimerSheet.swift` — the non-dismissible first-launch sheet.
  - `App/CCSync/AboutView.swift` — the About panel (name, version, copyright,
    scrollable license).
- Reference patterns: `App/CCSync/AppPanels.swift` (UI plumbing without logic), the
  README "Disclaimer" section as the basis for the wording, and the root `LICENSE`
  as the single source of MIT text and copyright.
- Key facts: bundle id `ws.karmanov.CCSync`; version from
  `CFBundleShortVersionString` (`MARKETING_VERSION = 1.0`,
  `GENERATE_INFOPLIST_FILE = YES`); LICENSE has no extension — read it as
  `Bundle.main.url(forResource: "LICENSE", withExtension: nil)`; the copyright line
  in LICENSE is `Copyright (c) 2026 Anton Karmanov`.

## Project invariant

CCSyncCore is not changed at all. `didAcknowledgeDisclaimer` is UI state
(UserDefaults/@AppStorage), not selection, so the "logic lives in Core" invariant is
not affected. The app target has no automated test harness — the gates for the app
side are a successful xcodebuild plus manual verification; `swift test` remains the
regression gate (must stay green with no edits).

## Development Approach

- **Testing approach**: Regular. The app target has no unit-test harness, so
  per-task verification is a successful xcodebuild; `swift test` is the untouched
  Core regression gate. All acceptance/manual checks are collected in the
  Post-Completion task.
- Complete each task fully before moving to the next.
- Do not touch CCSyncCore or the CLI.
- Keep the disclaimer wording in exactly one place (`AppLegalText`); MIT text and the
  copyright line come only from the bundled root LICENSE — never duplicated in code.

## Implementation Steps

### Task 1: Bundle the root LICENSE as a resource

**Files:**
- Modify: `App/CCSync.xcodeproj/project.pbxproj`

- [x] Add a PBXFileReference to LICENSE: `path = "../LICENSE"`, `name = LICENSE`,
  `lastKnownFileType = text`, `sourceTree = "<group>"`, placed in the root group
  (resolves as `App/../LICENSE` = repo root) with a fresh unique ID in the `AA0000…`
  style.
- [x] Add a PBXBuildFile for that reference and add it to the `files` of the empty
  Resources build phase `AA000000000000000000000F`.
- [x] Add the reference to the children of the root/CCSync group so the file is
  visible in the navigator (no text copy).
- [x] Verify: `xcodebuild -project App/CCSync.xcodeproj -scheme CCSync
  -configuration Debug CONFIGURATION_BUILD_DIR="$PWD/dist" build` succeeds and
  `dist/CCSync.app/Contents/Resources/LICENSE` is present.

### Task 2: Single source of text — disclaimer, license reader, copyright extractor

**Files:**
- Create: `App/CCSync/AppLegalText.swift`
- Modify: `App/CCSync.xcodeproj/project.pbxproj`

- [x] Declare `enum AppLegalText` with a `disclaimer` constant — a short text based
  on the README Disclaimer section (overwrites files in `~/.claude`,
  `~/.claude.json`, and per-project `settings.local.json`; a snapshot is written
  before overwrite; software provided "as is"; author accepts no liability; use at
  your own risk). Do not "invent" legal wording beyond the README.
- [x] Add a helper that reads the full license text from the bundle:
  `Bundle.main.url(forResource: "LICENSE", withExtension: nil)` →
  `String(contentsOf:)`. If the resource is missing, the fallback message must point
  the user to the LICENSE file in the project repository (e.g. "License text
  unavailable in this build. See the LICENSE file in the project repository:
  https://github.com/…/blob/master/LICENSE") — never a bare "not found", so the
  terms remain locatable even if the bundled resource ever drops out.
- [x] Add a `copyright` helper that derives the copyright line from the bundled
  LICENSE text — scan its lines for the one starting with `Copyright` and return it
  verbatim (`Copyright (c) 2026 Anton Karmanov`). Do not hardcode a separate
  copyright string; the root LICENSE stays the single source of truth for the
  copyright too. Fall back to an empty/neutral string only if the line is absent.
- [x] Add the file to PBXFileReference/PBXBuildFile/Sources build phase in
  `project.pbxproj` (unique `AA0000…`-style ID).
- [x] Verify: build succeeds.

### Task 3: First-launch disclaimer sheet

**Files:**
- Create: `App/CCSync/DisclaimerSheet.swift`
- Modify: `App/CCSync/CCSyncApp.swift`
- Modify: `App/CCSync.xcodeproj/project.pbxproj`

- [ ] Create `DisclaimerSheet` (View): title, text from `AppLegalText.disclaimer`,
  an "I Understand" button. Scrollable content in case the window is small.
- [ ] In `CCSyncApp`/`RootView` add `@AppStorage("didAcknowledgeDisclaimer")` and
  `.sheet(isPresented:)` shown while the flag is not set. Apply
  `.interactiveDismissDisabled(true)` to the sheet content — this is the modifier
  that blocks dismissal via Escape and click-outside — and provide no close button,
  so the sheet closes only via "I Understand", which sets the flag to `true`.
- [ ] Add the file to `project.pbxproj` (FileReference/BuildFile/Sources).
- [ ] Verify: build succeeds.

### Task 4: About panel with version and full license text

**Files:**
- Create: `App/CCSync/AboutView.swift`
- Modify: `App/CCSync/CCSyncApp.swift`
- Modify: `App/CCSync.xcodeproj/project.pbxproj`

- [ ] Create `AboutView`: app name, version from `CFBundleShortVersionString`, the
  copyright line from `AppLegalText.copyright` (derived from the bundled LICENSE —
  not a newly invented string), and the full MIT license text from the
  `AppLegalText` helper inside a `ScrollView`.
- [ ] Replace the About menu item via `.commands { CommandGroup(replacing: .appInfo)
  { Button("About CCSync") { … } } }`, opening `AboutView` (a dedicated
  `Window`/`WindowGroup` by id, or a state-driven sheet presentation). Choose the
  approach that guarantees the full text is scrollable.
- [ ] Add the file to `project.pbxproj` (FileReference/BuildFile/Sources).
- [ ] Verify: build succeeds; About opens and shows the correct copyright line and
  the full license text.

### Task 5: Verify acceptance criteria (Post-Completion — manual checks)

- [ ] `swift test` green with no Core edits (regression gate).
- [ ] `xcodebuild -project App/CCSync.xcodeproj -scheme CCSync -configuration Debug
  CONFIGURATION_BUILD_DIR="$PWD/dist" build` succeeds.
- [ ] `dist/CCSync.app/Contents/Resources/LICENSE` is present and matches the root
  LICENSE.
- [ ] Manual: after `defaults delete ws.karmanov.CCSync`, first launch shows the
  sheet.
- [ ] Manual: with the sheet open, press Escape — the sheet does not close (the
  default macOS way to dismiss a sheet is blocked by `.interactiveDismissDisabled`).
- [ ] Manual: clicking outside the sheet does not close it; only "I Understand"
  closes it.
- [ ] Manual: after acknowledgement the sheet does not reappear on relaunch.
- [ ] Manual: About opens and shows the full MIT license text scrollably, the
  correct version, and the copyright line `Copyright (c) 2026 Anton Karmanov` sourced
  from the bundled LICENSE.

### Task 6: Update documentation

- [ ] If it adds clarity for a builder, note in `App/README-build.md` that LICENSE is
  part of the bundle resources and reachable from About/the disclaimer (only if
  genuinely helpful).
- [ ] Do not change CLAUDE.md — Core internal patterns and the contract are
  untouched.
