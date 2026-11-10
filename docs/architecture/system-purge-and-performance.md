# System purge and progressive scanning

## Clean purgeable data

The Purgeable Space panel offers an actionable **Clean purgeable data** control independent of Time Machine snapshots. It delegates to macOS CacheDelete, restricted to `com.apple.fspurgeable_data` and `com.apple.cache_delete_app_container_caches`. Cloud-document eviction, Time Machine, system-update snapshots and system assets are not in this allowlist. The separate Time Machine action remains explicitly reviewed and administrator-approved.

The system-purge control requires confirmation because it removes cache content immediately. The helper queries and validates each service separately. It requests that service’s reported amount at urgency 3. When the file-data pass reports progress, the helper checks that service again and makes at most one more request. The helper accepts only `probe` or `purge`. Scruffy uses the probe for button availability and reports the measured change in free space as the result.

CacheDelete is a private macOS interface. Scruffy resolves it dynamically in an unprivileged helper. The helper rejects missing symbols, failed queries, unexpected volumes, service results outside the requested scope and invalid amounts. Both initial queries pass validation before mutation. A private-interface change can disable the feature or crash the helper. Scruffy surfaces the error and any net free-space change, since a later request can fail after an earlier one has completed.

On macOS 27.2 build 26B123, the former grouped request reported 263 MB removed. An immediate 176 MB gain was gone after 13 seconds while the system continued writing. Independent requests for purgeable file data at urgency 3 showed net gains of 434 MB and 253 MB at the three-second mark. The app-container service reported 257 MB eligible and released zero in its isolated test. Urgency 4 reported 4.55 GB eligible and returned zero twice. Scruffy keeps urgency 3 and treats service amounts as estimates. The investigation used [published CacheDelete experiments](https://github.com/1architect/macspace-releases/blob/main/Platform/CacheDelete/CacheDelete.swift) as a starting point and measured results on this Mac.

The rebuilt, signed helper reported 297 MB removed. A separate `df` measurement showed 292 MB more free space after three seconds, while the probe continued to report 605 MB. All 164 Swift tests passed. The live check used the bundled helper directly.

## Responsiveness

- Snapshot/capacity and system-purge queries execute independently and publish as each completes.
- Cached results stay visible. Read-only refresh and actual cleanup have separate busy states; a ready system result can be cleaned while snapshot information is still loading.
- Visible-pane checks run at most once per minute, with a short freshness window on foreground entry. There is no periodic full filesystem scan and no speculative deletion.
- Filesystem scans publish cumulative, verified results incrementally in sidebar order: Duplicates, Old downloads, Browser caches, Developer caches, Temporary files, Large files, then Videos. Disabled categories are skipped. Personal duplicate groups publish only after their contents and protected original are established.
- Personal folders are inventoried once, at the first enabled personal-file category. Other personal candidates and videos wait for their category's turn, so later sections do not populate early or change already-published category totals. Scanning remains off the main thread.
- Largest same-size groups are processed first. Bounded 64 KiB head/tail look-ahead avoids reading entire files when those samples differ. Full SHA-256 is still required before declaring duplicates.
- Ancestor metadata is cached during discovery with identity checks. Cleanup still revalidates paths and fingerprints freshly.
- Ready files remain selectable during scanning. Successfully trashed paths are excluded from later progress updates; expired scan callbacks cannot replace newer results.
- An app-scoped hourglass cursor indicates scans, Trash moves, video compression, recovery-history loading and visible storage checks/cleanup. Mouse events still reach controls. Completing or failing the operation, detaching the view or moving to another window restores normal cursor handling. Trash cleanup additionally shows named category jobs with determinate file counts, phases and retained failures; other file categories stay usable while those workers run.

## Checks

25 tests passed, including safety exclusions, stable progressive keeper groups, same sampled bytes with different middle content, command restrictions, service allowlists and failure handling. The release app and bundled helper build and sign locally. Performance changes were produced with a host scan worker and a separate host UI/responsiveness worker; the root agent integrated and ran the full test suite.

## Scan UI lockup fix — November 9, 2026

Runtime sampling of the reported lockup showed the main thread repeatedly rebuilding selection sets, filtering category totals and filtering visible files. The scan worker spent 98.6% of its sampled stacks sorting cumulative progress snapshots, including repeated `URL.path` conversions. The process used approximately 188–198% CPU. Filesystem scanning already ran off the main actor; repeated result preparation and presentation overwhelmed it.

- Candidate IDs now retain their path once. Immutable result snapshots calculate category totals, selected-file lookup and duplicate-group indexes on the scan worker.
- Unchanged ready-file/notes snapshots reuse their sorted files and indexes. Ordinary progress publishes at most once per second, with explicit phase-completion updates retained.
- A newest-only buffered stream replaces an unbounded queue of main-actor progress tasks. Status-only updates do not rebuild the result, and selection validation looks up only selected IDs.
- Filtering runs in a cancellable background task. Only the latest filter result can publish.
- The file list displays 200 rows per page; filtering searches all results and selections persist across pages. File icons load asynchronously as bounded 54×54 PNG thumbnails.
- Cache candidates no longer occupy the separate personal-file duplicate-inventory dictionary.

All 30 tests pass, including five new regressions for result indexes, keeper-excluding totals, candidate identity and snapshot reuse. The final release build and local app packaging pass. Live verification exercised navigation, full-result filtering, Next-page navigation and cancellation while more than 119,000 cache candidates were available. A quiet five-second sample, with the worker still scanning, showed the main thread waiting normally for 94.5% of samples and no previous aggregate/filter/icon-loading hot frames. This sample preceded the final thumbnail-size refinement, which separately passed release compilation.

Active accessibility inspection itself generated substantial main-thread work, so those samples are not used as an idle-performance measurement. Large scans still retain their inventory in memory; no controlled memory-reduction claim or completed full-home scan is established by these checks. No personal files were moved or purged during verification.
