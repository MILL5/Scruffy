# Purgeable storage

Scruffy shows current free space and an estimate computed from Foundation's available-for-important-usage capacity minus the ordinary free-capacity figure. This estimate is not a measured snapshot size and not a guarantee that all of it can be reclaimed by Scruffy.

The explicit reclaim action uses Apple's `tmutil thinlocalsnapshots / <target bytes> 1`, documented in the installed macOS `tmutil(8)` manual. It is restricted to fixed targets of 1, 5, 10 or 20 decimal GB and conservative urgency 1. Before the action, Scruffy rechecks the snapshot listing. Only canonical `com.apple.TimeMachine.<date>.local` entries are considered eligible; OS-update snapshots are excluded. No arbitrary paths, commands or snapshot names enter the privileged command.

The action is separate from ordinary Trash cleanup. It requires a review sheet, an explicit acknowledgment that local restore points may be permanently lost, and the native administrator-approval dialog. Reclaiming snapshots can remove historical/deleted-file recovery options even though current files and external backup-disk backups are not targeted. The amount freed can differ from the target because snapshots share blocks and are removed as units. Cancelling administrator approval or a failed listing does not report success.

Scruffy does not create huge disk-filling files, run `purge`, force eviction of cloud files, delete swap/sleep images, or delete OS-update snapshots. Other purgeable data remains managed by macOS; existing browser/developer cache review is available separately. The app reports observed free-space change after the request and asks users to refresh because macOS accounting can lag.

## Sources

- [Apple: About Time Machine local snapshots](https://support.apple.com/en-gb/102154)
- [Apple: URLResourceValues](https://developer.apple.com/documentation/foundation/urlresourcevalues)
- Installed macOS `man tmutil`, `listlocalsnapshots` and `thinlocalsnapshots` sections.

## Verification

Command execution is injected in unit tests. Tests cover unknown/negative capacity differences, ignoring OS-update snapshots and untrusted names, fixed command arguments, no-eligible-snapshot rejection, failed listing and cancelled administrator authorization. No live snapshot deletion or administrator request was performed during development. The read-only listing on the development Mac showed three protected OS-update snapshots and no eligible Time Machine snapshots.
