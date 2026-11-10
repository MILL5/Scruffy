# Purgeable storage

Scruffy shows free bytes on the startup Data volume using `statfs` (`f_bavail × f_bsize`). The purgeable estimate subtracts that figure from Foundation's capacity for important usage. The estimate describes storage macOS may make available under pressure. It is separate from the measured result of a cleanup.

The explicit reclaim action uses Apple's `tmutil thinlocalsnapshots / <requested bytes> 1`, documented in the installed macOS `tmutil(8)` manual. It requests the full volume's capacity so macOS can reclaim all eligible snapshot space, without an app-imposed GB limit, while retaining conservative urgency 1. Before the action, Scruffy rechecks the snapshot listing and volume capacity. Only canonical `com.apple.TimeMachine.<date>.local` entries are considered eligible; OS-update snapshots are excluded. Only a positive capacity-derived integer enters the fixed command. No arbitrary paths, commands or snapshot names enter the privileged command.

The action is separate from ordinary Trash cleanup. It requires a review sheet, an explicit acknowledgment that local restore points may be permanently lost, and the native administrator-approval dialog. Reclaiming snapshots can remove historical/deleted-file recovery options even though current files and external backup-disk backups are not targeted. The amount freed can differ from the target because snapshots share blocks and are removed as units. Cancelling administrator approval or a failed listing does not report success.

Both cleanup actions measure free bytes before the request and again three seconds after it returns. Scruffy reports the signed change, including zero, separately from any command error. This is the net change on the volume during the request and includes concurrent disk activity. The UI also refreshes the snapshot list after cleanup.

For iCloud Drive content, Finder’s **Remove Download** can release a local copy while keeping the cloud copy. That is a separate user choice. Scruffy limits system cleanup to the two cache services described in [system purge](system-purge-and-performance.md). macOS manages swap, system-update snapshots and other protected storage.

## Sources

- [About Time Machine local snapshots](https://support.apple.com/en-us/102154)
- [Disk Utility storage figures](https://support.apple.com/guide/disk-utility/get-detailed-information-about-a-disk-dskutl1005/mac)
- [Apple `statfs` manual](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/statfs.2.html)
- [Remove an iCloud Drive download in Finder](https://support.apple.com/en-ie/guide/mac-help/mchl1a02d711/27/mac/27)
- Installed macOS `man tmutil`, `listlocalsnapshots` and `thinlocalsnapshots` sections.

## Verification

Command execution is injected in unit tests. Tests cover unknown/negative capacity differences, ignoring OS-update snapshots and untrusted names, fixed command arguments, no-eligible-snapshot rejection, failed listing and cancelled administrator authorization. No live snapshot deletion or administrator request was performed during development. The read-only listing on the development Mac showed three protected OS-update snapshots and no eligible Time Machine snapshots.
