# Scruffy — agent guide

Native macOS cleanup app (Swift 6, SwiftUI, SwiftPM). It moves user files to Trash, so safety rules outrank features.

## Platforms

- Apple silicon only. Never add Intel or universal builds.
- Supports the current macOS and the one before it, nothing older. Today that is macOS 27 and 26: the deployment target in `Package.swift`, `LSMinimumSystemVersion` in `scripts/build-app.sh` and the CI runner all say 26. Raise all three together when a new macOS ships, and delete availability checks that become always true.

## Commands

- `swift build` and `swift test` must finish with no failures and no warnings. One test mounts a 4 MB disk image with `hdiutil` and skips itself where that fails.
- `./scripts/build-app.sh` packages `dist/Scruffy.app` (ad-hoc signed). `./scripts/release.sh` signs and notarizes; never run it or `--publish` unasked.
- `python3 scripts/check-links.py` checks local links in docs and the site.

## Layout

- `src/CleanupCore/`: scanning, safety checks, Trash service, recovery journal, video compression. No UI.
- `src/Scruffy/`: SwiftUI app and `AppModel`. `src/ScruffyStorageHelper/`: unprivileged purge helper.
- `tests/`: every test uses fixture folders under the temp directory and an injected fake Trash.
- `docs/site/` is the public website (GitHub Pages). The rest of `docs/` is internal.

## Safety invariants

Change these only when asked, and add a test that fails without the change.

- Fail closed: a file that cannot be proven eligible is not offered and not moved.
- Nothing is selected automatically. Scans are read-only and make no network requests.
- `CleanupScanner.allowed` gates every path: inside the home or temp folder, on that folder's volume, no symlink, alias, iCloud item or cloud placeholder in the path, and outside the protected locations and names. Hard-linked files are rejected by the link count in the fingerprint.
- Compare path boundaries as bytes. Swift's `hasPrefix` and `lastIndex(of:)` work on whole characters and miss a slash that sits next to a combining mark.
- Every file is revalidated immediately before its move. A duplicate copy and its protected original are read in full at that point.
- One original per duplicate group stays unless every copy is in the same batch; originals move last.
- A recovery record is written before each move. Restore never overwrites and never creates folders.
- A recovery record is dropped only when nothing can be restored from it for certain (`TrashService.isBeyondRecovery`). Only the app tidies the journal, at launch; tests inject their own `TrashService`.
- Scruffy never empties Trash, never force-quits a browser, and never resumes an interrupted job.
- The administrator command is a fixed `tmutil` call plus one integer derived from volume capacity. The purge helper accepts only `probe` or `purge`. No filename, UI text or process output enters either.

## Conventions

- Tests never touch real personal files, the real Trash, running browsers or system purge.
- On someone's real Mac, do not change the app's saved settings (`defaults` domain `com.richcrane.scruffy`) and do not drive its window while they are using it. If a check needs either, say so first, use fixture files you created, and put the settings back before handing the app back.
- Record what was and was not verified in `docs/verification/<date>.md`, and link it from `docs/README.md`.
- User-facing sizes are decimal (`ByteCountFormatter` file style).
