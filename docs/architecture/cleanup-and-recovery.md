# Cleanup and recovery

Every selected file is checked before any move, then checked again immediately before its move to Trash. If a file changed or disappeared after scanning, it stays untouched and cleanup continues with other eligible selections. This applies to all file-cleanup categories. The final status reports moved files and skipped files once; skipped files leave the stale results and require a new scan before they can be selected again.

A duplicate copy is skipped if its protected original is missing or changed. Duplicate contents are still verified with SHA-256, including changes that preserve the recorded fingerprint. Selecting a protected original, encountering a symlink, hard link, replaced volume or unsupported existing path remains a safety failure. These protections are not relaxed to increase the cleanup count. Actual Trash failures, recovery-history failures and browsers reopening still stop the remaining batch.

## Browser checks

Only running supported browser applications with a regular application activation policy block browser-cache cleanup. Terminated apps, background-only processes and browser helpers do not require a quit action. When no browser apps are running, the review says cleanup is ready and enables Move to Trash. When browsers are running, it lists them and offers a normal quit request; cleanup waits for their exit and checks again before moving each cache file. Scruffy never force-quits browsers.

Only allowlisted downloaded web resources such as JavaScript and images are eligible. Passwords, cookies, bookmarks and browsing history are excluded.

## Recovery journal

Existing `trash-history.json` remains readable and unchanged. New operations append private, durable events to the companion `trash-history.events.jsonl`: an intent before moving, a completed record after moving and a removal tombstone after restoring. Replaying both files by record ID produces the recovery list. A failed move whose original is provably unchanged removes its intent so it does not create a false recovery entry.

Each event appends constant-size data instead of rewriting all prior records twice per file. A cleanup batch validates history once and reuses that journal instance; unexpected external modifications trigger revalidation. Appending uses an exclusive file lock, single-link regular-file/owner checks, mode 0600 and `fsync`. Only an unterminated final fragment from an interrupted write may be ignored and truncated; a malformed committed event stops cleanup. Recovery history loads off the UI thread.

Trash and the journal cannot form a single atomic filesystem transaction. If the post-move record fails, the app reports that Finder's Trash is needed and stops. Restoring refuses to overwrite an occupied original path. Neither cleanup nor restore empties Trash. The event log grows with operations; automatic compaction or pruning is not implemented.
