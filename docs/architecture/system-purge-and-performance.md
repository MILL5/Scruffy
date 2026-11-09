# System purge and progressive scanning

## Clean purgeable data

The Purgeable Space panel offers an actionable **Clean purgeable data** control independent of Time Machine snapshots. It delegates to macOS CacheDelete, restricted to `com.apple.fspurgeable_data` and `com.apple.cache_delete_app_container_caches`. Cloud-document eviction, Time Machine, system-update snapshots and system assets are not in this allowlist. The separate Time Machine action remains explicitly reviewed and administrator-approved.

The system-purge control requires a confirmation and acknowledgement: it bypasses Trash, so discarded cache content is not recoverable through Scruffy. macOS decides which eligible content it can release. The target is not a guaranteed amount.

CacheDelete is undocumented and not an App Store API. It is dynamically resolved in an isolated, unprivileged helper. Missing symbols, failed queries, unexpected volume/service responses, negative values and ignored service filters fail closed. A fresh read-only query checks the service filter before every purge. The helper has finite query/operation deadlines so failure cannot hang the UI indefinitely. A private-interface change may disable this feature or crash only the helper; Scruffy reports failure rather than falling back to direct deletion or disk-filling pressure tricks.

Signatures were cross-checked against the local Xcode SDK's CacheDelete symbol declarations and the independently published [CacheDelete implementation and research](https://github.com/1architect/macspace-releases/blob/main/Platform/CacheDelete/CacheDelete.swift). The implementation here uses its own request validation, response model and process protocol. Read-only probing on this Mac successfully reported approximately 500 MB of eligible data. During native UI verification, a 20 GB target request was observed completing and macOS reported 1.19 GB removed. The interface rechecked storage afterward; an independent physical-space measurement was not taken.

## Responsiveness

- Snapshot/capacity and system-purge queries execute independently and publish as each completes.
- Cached results stay visible. Read-only refresh and actual cleanup have separate busy states; a ready system result can be cleaned while snapshot information is still loading.
- Visible-pane checks run at most once per minute, with a short freshness window on foreground entry. There is no periodic full filesystem scan and no speculative deletion.
- Filesystem scans publish cumulative, verified results incrementally. Cache candidates appear first; personal duplicate groups publish only after their contents and protected original are established.
- Largest same-size groups are processed first. Bounded 64 KiB head/tail look-ahead avoids reading entire files when those samples differ. Full SHA-256 is still required before declaring duplicates.
- Ancestor metadata is cached during discovery with identity checks. Cleanup still revalidates paths and fingerprints freshly.
- Ready files remain selectable during scanning. Successfully trashed paths are excluded from later progress updates; expired scan callbacks cannot replace newer results.

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
