# Building, signing, and notarizing the CCSync app

The SwiftUI app (`App/CCSync.xcodeproj`) is a thin GUI over `CCSyncCore`. All logic
— backup collection, archive read/write, the selection tree, and the restore engine
— lives in the Swift package at the repository root and is covered by `swift test`.
The app target contains only view code and two view models that forward to Core.

## Layout

```
App/
  CCSync.xcodeproj          Xcode project; depends on the local ../ SwiftPM package
  CCSync/
    CCSyncApp.swift         @main App, Backup/Restore tab shell
    BackupView.swift        Backup screen + BackupViewModel
    RestoreView.swift       Restore screen + RestoreViewModel
    AppPanels.swift         NSOpenPanel helpers
    CCSync.entitlements     App Sandbox OFF (see below)
```

The project references the root package via an `XCLocalSwiftPackageReference`
(`relativePath = ".."`) and links the `CCSyncCore` product. No source is duplicated.

## Build (development)

1. Open `App/CCSync.xcodeproj` in Xcode 15 or later.
2. Xcode resolves the local `CCSyncCore` package automatically on first open.
3. Select the **CCSync** scheme and press Run. The Debug configuration signs to run
   locally (`CODE_SIGN_IDENTITY = "-"`), so no Apple Developer account is required
   just to build and run on your own machine.

Command line:

```sh
xcodebuild -project App/CCSync.xcodeproj -scheme CCSync -configuration Debug build
```

## Target configuration (already set in the project)

- **App Sandbox: OFF** (`CCSync.entitlements`). CCSync reads and writes known paths
  under the user's home (`~/.claude`, `~/.claude.json`) and arbitrary project
  folders the user picks; the sandbox would require per-path security-scoped
  bookmarks, which is out of scope. The app is distributed with Developer ID +
  notarization rather than through the App Store.
- **Hardened Runtime: ON** (`ENABLE_HARDENED_RUNTIME = YES`) — required for
  notarization.
- **Signing:** Debug uses "Sign to Run Locally"; **Release** uses
  `CODE_SIGN_IDENTITY = "Developer ID Application"` with automatic signing. Set your
  team in Xcode (target → Signing & Capabilities → Team, or
  `DEVELOPMENT_TEAM = <TEAMID>`) before an archive/Release build.

## Signing + notarization (for distributing the binary between machines)

Notarization is only needed to move the built `.app` to another Mac without
Gatekeeper warnings. It is **not** required for local development.

1. Set your Developer ID team in the target's Signing settings.
2. Archive a Release build:

   ```sh
   xcodebuild -project App/CCSync.xcodeproj -scheme CCSync \
     -configuration Release -archivePath build/CCSync.xcarchive archive
   ```

3. Export the signed app (Developer ID) from the archive, then notarize the zipped
   app with `notarytool` and staple the ticket:

   ```sh
   ditto -c -k --keepParent build/export/CCSync.app CCSync.zip
   xcrun notarytool submit CCSync.zip \
     --apple-id <APPLE_ID> --team-id <TEAMID> --password <APP_SPECIFIC_PASSWORD> \
     --wait
   xcrun stapler staple build/export/CCSync.app
   ```

## Note on tests

There are no UI unit tests: the selection logic is entirely in Core's
`SelectionTree` and is verified by `SelectionTreeTests` under `swift test`. The
views only bind to it. Run the full suite from the repository root:

```sh
swift test
```
