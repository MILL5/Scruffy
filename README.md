# Scruffy

A native, local-only Mac cleanup app. Requires macOS 14 or later.

[Project website](https://mill5.github.io/Scruffy/) · [Documentation](docs/README.md)

## Run

```sh
./scripts/build-app.sh
open dist/Scruffy.app
```

Or open `Package.swift` in Xcode and run the Scruffy executable. `swift test` runs isolated filesystem safety tests. The app bundle is locally ad-hoc signed, not notarized for distribution.

The Swift targets live in `src/`, automated tests in `tests/`, and packaging/link-check scripts in `scripts/`. The public website is isolated in `docs/site/`; the remaining documentation stays outside the Pages deployment.

## What it does

- Finds identical data contents using streaming SHA-256 and protects one original in every group; files with resource-fork data are excluded from duplicate detection.
- Reviews Downloads untouched for 30 days and files at least 500 MB in chosen folders.
- Reviews allowlisted browser cache files at least one day old, excluding cookies, credentials, bookmarks and history.
- Optionally reviews pip, uv and npm download caches and user temporary files at least seven days old.
- Provides a category space chart, largest-first file lists, row-click selection, per-section NGramSearch indexes, Quick Look and Reveal in Finder. Each search word matches independently; results must match every word in any order.
- Finds MP4, MOV and M4V videos in chosen folders for reviewed high-quality HEVC compression. Resolution and file container stay the same; only verified smaller outputs replace originals, which move to Trash with a recovery record.
- Moves only explicitly selected files to macOS Trash after a confirmation and fresh validation, using named background jobs per category with file counts and visible failures. Changed or missing files are skipped while eligible files continue; failed/interrupted jobs never resume automatically.
- Keeps a local recovery journal under `~/Library/Application Support/Scruffy/`; restores without overwriting existing files.
- Cleans system-marked discardable data and eligible app-container caches through macOS's purge service after explicit review; cloud documents and snapshots are excluded.
- Separately offers Time Machine snapshot reclamation after explicit review and administrator approval. This action permanently removes some local restore points; it does not use Trash.

Nothing is selected automatically. Scans are read-only. No network requests, analytics, automatic startup or background cleaning. Ordinary file cleanup uses Trash. System-purge and snapshot actions bypass Trash and require explicit review; snapshot reclamation also requests administrator approval. Verified scan results appear incrementally and can be cleaned while the remaining scan continues.

## Safety and limits

Only local files in the user's home or user temp directory are eligible. Known cloud-sync locations, iCloud-marked files, symlinks, aliases, hard links, app bundles, photo libraries, repositories, virtual environments, sensitive Library locations and system folders are excluded. Custom sync tools and unusual mount arrangements cannot be identified universally: choose ordinary local folders and review paths.

Downloads are not junk merely because they are old. A duplicate may still be used by a document, shortcut or another application; review its location. Cached files may be needed offline and can be rebuilt. Browser cleanup targets downloaded web resources such as JavaScript and images; saved passwords, cookies, bookmarks and history are excluded. Close package managers and relevant apps before cleaning their caches. Browser cleanup asks only running supported browser apps to quit normally; when none are running, cleanup is ready immediately. Background helpers alone do not block cleanup, and Scruffy never force-quits browsers. Concurrent filesystem changes cannot be made transactionally atomic with macOS Trash, so the app rechecks snapshots and duplicate contents immediately before each move. Changed or missing files stay untouched and appear in one skipped-files summary; unsafe paths and actual Trash or recovery-history failures still stop the batch. See [cleanup and recovery](docs/architecture/cleanup-and-recovery.md).

Amounts are logical file sizes, not guaranteed physical savings (APFS clones, compression and snapshots differ). Moving to Trash does not free disk space until you manually empty it. Scruffy never empties Trash or edits Photos libraries. Snapshot reclamation is an explicitly reviewed exception for local restore points only; external backup disks are not targeted. Files already emptied from Trash cannot be restored by Scruffy. An interrupted cleanup may require recovery using Finder's Trash if a journal update did not complete.

The chart shows cleanup candidates, not a full disk inventory or DaisyDisk-style filesystem sunburst. Unreadable locations are reported; a partial scan is not a clean bill of health. External volumes are excluded in this first version.

## Research

See [product references](docs/product/product-references.md) for the tools studied and design decisions.

See [verification](docs/verification/README.md) for completed checks and remaining acceptance testing.

See [purgeable storage](docs/architecture/purgeable-storage.md) for the separate snapshot-reclaim operation and its limits.
