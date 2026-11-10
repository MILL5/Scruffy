# Cleanup and recovery

Every selected file is checked before any move, then checked again immediately before its move to Trash. The first pass covers the whole batch and checks locations and fingerprints only, so an unsafe path stops the job before anything moves. The second pass repeats those checks for one file and, for a duplicate, reads that copy and its protected original in full. If a file changed or disappeared after scanning, it stays untouched and cleanup continues with other eligible selections. This applies to all file-cleanup categories. The final status reports moved files and skipped files once; skipped files leave the stale results and require a new scan before they can be selected again.

A duplicate copy is skipped if its protected original is missing or changed. Duplicate contents are verified with SHA-256 in that second pass, including changes that preserve the recorded fingerprint. Each copy and its original are therefore read twice per cleanup (once each), not four times; a content problem found there skips or stops at that file, after earlier files in the job have moved. Selecting a protected original without every other copy in its group, encountering a symlink, hard link, replaced volume or unsupported existing path remains a safety failure. These protections are not relaxed to increase the cleanup count. Actual Trash failures, recovery-history failures and browsers reopening still stop the remaining batch.

## Browser checks

Only running supported browser applications with a regular application activation policy block browser-cache cleanup. Terminated apps, background-only processes and browser helpers do not require a quit action. When no browser apps are running, the review says cleanup is ready and enables Move to Trash. When browsers are running, it lists them and offers a normal quit request; cleanup waits for their exit and checks again before moving each cache file. Scruffy never force-quits browsers.

Cleanup asks whether a browser is running before every browser-cache file. The app answers from a list that macOS keeps current as apps launch and quit, rebuilt at least once a second in case a report is missed, with apps that have quit filtered out on every read. Building the list from macOS for each file took about 18 ms per file in a real cleanup: 102 of 115 seconds for 5,663 files.

Only allowlisted downloaded web resources such as JavaScript and images are eligible. Passwords, cookies, bookmarks and browsing history are excluded.

## Recovery journal

Existing `trash-history.json` remains readable and unchanged. New operations append private, durable events to the companion `trash-history.events.jsonl`: an intent before moving, a completed record after moving and a removal tombstone after restoring. Replaying both files by record ID produces the recovery list. A failed move whose original is provably unchanged removes its intent so it does not create a false recovery entry.

Each event appends constant-size data instead of rewriting all prior records twice per file. A cleanup batch validates history once and reuses that journal instance; unexpected external modifications trigger revalidation. Appending uses an exclusive file lock, single-link regular-file/owner checks, mode 0600 and `fsync`. Only an unterminated final fragment from an interrupted write may be ignored and truncated; a malformed committed event stops cleanup. Recovery history loads off the UI thread.

Trash and the journal cannot form a single atomic filesystem transaction. If the post-move record fails, the app reports that Finder's Trash is needed and stops. Restoring refuses to overwrite an occupied original path. Neither cleanup nor restore empties Trash. Restoring a single file leaves the scan results on screen: the file left them when it was cleaned, and a new scan lists it again.

### Pruning and compaction

When the app opens it drops the records nothing can be restored from, then rewrites the event log in its shortest equivalent form. A record is dropped only on certainty:

- Its Trash item is gone while the Trash folder that held it is present: emptied, put back in Finder or deleted. A missing or unreadable Trash folder (an unmounted volume, no permission) proves nothing, so the record stays.
- Its move never happened: the record has no Trash location and the original is still the same file (same fingerprint) in place.

A record for an interrupted move whose original is gone stays, because Finder's Trash may still hold the file.

Compaction writes one line per live record, plus one removal line for each legacy record that is gone; the legacy file is still never rewritten. The new log is written to a companion file, flushed, and renamed over the old one, so an interruption leaves one complete log or the other. Another journal instance that opened the old file reopens the new one before reading or appending. Tests and previews never run this step; only the app does, against its own journal.

## Background cleanup jobs

Confirming file cleanup creates one named background job per selected category. Each job captures its own file list, folder permissions and protected-original snapshot. Other categories remain selectable while it runs. Queued files and their category cannot be submitted to another active job. Starting new scans, video replacement and system-purge mutations stay blocked while Trash jobs run to prevent conflicting operations; an existing progressive scan can continue.

The job panel stays available across sections, with compact rows and two columns when the window is at least 680 points wide. Every job reports its checking or moving phase, file number and total, moved/skipped counts and elapsed time. Its details show the current filename, logical bytes, start time and full failure reason. The panel can be collapsed; starting another job expands it. In compact windows the chart gives way to the expanded job panel so file rows stay usable. Updates are coalesced to five per second per job, with forced phase/final updates. Result pruning and rebuilding happen off the main actor; an explicit finishing phase remains visible until the updated results are ready. Cleanup rebuilds use the latest unfiltered scan source so finishing a job cannot discard newly discovered files. Generation checks prevent old rebuilds from replacing newer results. Foundation temporaries are drained per file and per decoded journal event rather than retained across a large queue.

A real error stops that job and leaves its reason and partial counts visible; other jobs continue independently. Changed/missing files still count as skips and do not fail the job. Workers never retry or resume automatically. Starting another job requires a fresh explicit selection and confirmation.

`cleanup-jobs.json` stores private status metadata at job start and finish. It does not store runnable queues. On a later launch, any saved running job is shown as failed/interrupted, with its last saved progress and no attempt to resume. Progress saved at start can be zero even when some files reached Trash before interruption; the recovery journal remains the record of actual moves. Finished and failed job records remain visible. All workers share the same in-process recovery-journal state so concurrent appends do not replay the entire log for each file.

## Which copy is the original

The scan protects one file per duplicate group: a copy outside `~/Downloads` when the group has one, otherwise the oldest by modification time, with the path as the tie-break. The files are byte-identical, so the choice only decides which location is kept.

"Keep this copy instead of the original" in a copy's context menu moves the protection to that copy for the rest of the scan. The previous original becomes an ordinary copy that can be selected, and the newly protected copy leaves the selection. The choice is reapplied to later results of the same scan and after cleanup refreshes; a new scan or changed scan settings discard it. It is unavailable while a job is cleaning duplicates, because a running job verifies its copies against the original it captured when it started.

## Whole duplicate groups, undo and job removal

An original may be moved only when every other copy in its group is in the same batch. The batch moves the copies first and the original last. The interface reaches this state by repeated clicks on a duplicate's checkbox or a Control-click, and the confirmation sheet warns that no copy will be kept.

Each record written during a job carries that job's id. Undo restores the job's records that are still in Trash through the ordinary restore path, so existing files are never replaced. It reports counts only: restored, already deleted, and not restored. Jobs run by earlier builds have no tagged records and report nothing left to restore. A finished job with no tagged file left in Trash can be removed from the job list; recovery history is unchanged.
