# Make Scruffy's existing features faster and easier to follow

* **Author:** Richard Crane
* **Date:** 2026-11-09
* **Baseline:** local `develop` at `7763ec6` (includes `feature/single-instance` and `main`)

## Overview

Scruffy's existing features do not show enough of what they are doing. Scan and Move to Trash feel slow, and for much of that time the window shows a spinner or an hourglass cursor with no percent, no current file and no way to stop.

This brief recommends changes to the existing features only. It covers four things:

1. Where Scan and Move to Trash spend their time, and what would reduce it.
2. Progress, cancellation and failure reporting for every long operation.
3. The eight findings in `docs/reviews/2026-11-09-recording-164925.md`, checked against the code.
4. Other code that makes the app slower or harder to follow.

Every recommendation states its benefit as a number and says where the number came from:

* **Measured** — timed on this Mac for this brief.
* **Counted** — derived by reading the code (calls per file, clicks, pixels).
* **Estimate** — depends on an assumption that is stated next to it.

Almost every time saving below is an estimate. Only one thing was timed (the journal write), and that timing overturned the reviewers' estimate by 10 to 100 times. That is the main reason step 1 of the plan is to measure.

## Analysis

### How this was reviewed

Six independent reviewers read the code with no shared context. None of them ran or changed anything.

| Lens | Agent | Status |
| --- | --- | --- |
| Architecture and concurrency (`egm-design`) | Claude subagent | completed |
| First-time user view (`egm-comprehension`) | Claude subagent | completed |
| Simplicity and reuse (`egm-zoom-out`) | Antigravity/Gemini (`agy`, plan mode) | completed |
| Compatibility and readiness (`egm-implementation-readiness`) | Antigravity/Gemini (`agy`, plan mode) | completed (rerun; first attempt was on Codex) |
| Structure and maintenance (`egm-structural`) | Copilot (plan mode) | completed |
| Code accuracy and cost (`egm-codebase-details`) | Copilot (plan mode) | completed (rerun; first attempt was on Codex) |
| — | Codex | **not run**: both attempts failed with "The 'gpt-6.1-sol' model is not supported when using Codex with a ChatGPT account" |

The synthesis then re-read the Move to Trash and journal code to confirm the claims all six agreed on, and timed the journal write.

### Progress code exists, but the owner has never noticed it

The owner reports never having seen a status or progress display for Scan or Move to Trash. The code contains both. Treat that gap as the finding: a status display the owner does not notice has failed, whatever the code says.

Two things explain it.

**1. What the code draws is easy to miss.**

* **Move to Trash** has a bar, an "x of N" count, moved and skipped counts and a timer (`src/Scruffy/CleanupJob.swift:23-41`, `src/Scruffy/CleanupJobsView.swift:63-72`). They sit in a "Background cleanup" strip at the bottom of the window that only exists once a job has started (`src/Scruffy/ScruffyApp.swift:167-170`). Each job is a 64 px card with caption-size text and a thin bar (`CleanupJobsView.swift:26`, `:67-73`). Nothing appears near the Move to Trash button or the list the user is looking at. The bar also fills twice, the current file is in a popover, and there is no Cancel.
* **Scan** reports "phase · N files checked · M ready to review" about once a second (`src/CleanupCore/Scanner.swift:325-331`). It is caption-size text in the footer (`ScruffyApp.swift:487`). The welcome screen shows a spinner without it (`:327`), the Videos and Purgeable panes have no footer, and the text is replaced while a cleanup runs (`src/Scruffy/AppModel.swift:218`).

**2. The built app is older than the code that was reviewed.** `dist/Scruffy.app` was built on November 9 at 2:40 PM. The background-jobs code was committed at 5:27 PM. The built binary contains the "Background cleanup" heading and the scan status text, but not the later "Show jobs" button or the "Will not resume" failure text. So part of what the reviewers describe has never been on screen. No one has run the current code and looked at it.

Counted across the views in the current code: **6 indeterminate spinners, 1 window-wide hourglass cursor, and 2 determinate bars.**

This changes the bar for step 3 below. Adding fields to the existing strip and footer is not enough. Status has to appear where the user is already looking: on the welcome screen during a scan, beside the Scan button in every pane, and in place of the Move to Trash button and list header while a cleanup runs. The acceptance test is that the owner sees percent, counts and the current file without being told where to look.

### Move to Trash: where the time goes

Confirmed in the code by the synthesis:

* **Every file is validated twice.** Once in a preflight pass (`src/CleanupCore/TrashService.swift:106`) and again just before its move (`:135`).
* **Each duplicate is read in full four times.** Each validation hashes both the copy and the protected original (`src/CleanupCore/Scanner.swift:504`), and validation runs twice. Selecting ten 2 GB copies of one file reads 80 GB.
* **Finding the protected original scans the whole file list** for each selected duplicate (`Scanner.swift:502`). `ScanResult` already holds a lookup table for this (`keepersByHash`, `Scanner.swift:97`) that the cleanup path does not use.
* **Every browser-cache file asks the main thread whether a browser is running** (`TrashService.swift:131`). For the 85,208 cache files in the recording that is 85,208 round trips to the main thread.
* **Every file writes the recovery journal twice**, and each write opens, locks, checks, writes, syncs and closes the file (`src/CleanupCore/TrashJournal.swift:48-79`).

**The journal is not the bottleneck.** Five reviewers estimated the two syncs per file cost between 30 and 640 seconds for a large batch, and recommended batching them. They assumed 0.3 to 8 ms per sync. Timed on this Mac with the same sequence of calls (20,000 appends, two runs):

| Append variant | Time per append |
| --- | --- |
| No sync | 31–42 µs |
| `fsync` (what the code uses, `TrashJournal.swift:75`) | 49–53 µs |
| `F_FULLFSYNC` (not used) | 3,749 µs |

At about 50 µs per append and 2 appends per file, 85,208 files cost about **8.5 seconds** in total, of which the sync itself is about 1 to 2 seconds. Batching syncs would save a second or two per 85,000 files and would weaken crash recovery. It is dropped. (The timing was a Python script that imitates the system calls; it excludes Swift's JSON encoding.)

**Not measured: the move itself.** `FileManager.trashItem` runs once per file (`TrashService.swift:74`) and no reviewer could say what it costs. It may be the largest term. `clean()` already accepts a replacement move function (`TrashService.swift:72`), so a test can time everything except the real move without touching real files.

### Measured after the review (2026-11-09, branch `feature/timing-and-quick-fixes`)

Step 1 is now built. These numbers replace the estimates in this brief wherever they disagree.

**One full scan on this Mac: 2 min 07 s for 168,299 files** (`~/Downloads` plus browser caches; second run, so file data was already cached by macOS. The first run took about 3 min 15 s).

| Phase | Time | Per item |
| --- | --- | --- |
| Walk `~/Downloads` (67,410 files) | 31.4 s | 466 µs |
| Compare starts and ends of same-size files (50,118 files) | 41.9 s | 835 µs |
| Read whole files to confirm duplicates (8,232 files, 29.48 GB) | 19.3 s | 1.5 GB/s |
| Walk browser caches (100,889 files) | 34.3 s | 340 µs |
| Sort and index results for display (98 updates) | 4.3 s | 44 ms |

Inside the two walks, the **safety check took 44.7 s (249 µs per file)** and reading file metadata took 4.6 s (25 µs per file). The safety check is 35% of the whole scan by itself. The same check runs, without its cache, before every start-and-end comparison, which is the likely reason that step costs 835 µs for at most 128 KB of reading.

**Move to Trash with the move replaced by a no-op (1,000 test cache files):**

| Step | Per file |
| --- | --- |
| Safety check before any move | 695 µs |
| Safety recheck before each move | 715 µs |
| Recovery journal, two writes | 188 µs |
| Browser-running check | under 1 µs in the test; unmeasured in the app |

That is about 1.6 ms per file before the move itself. For 85,208 cache files it is about 2 min 15 s, of which the two safety checks are 2 minutes and the journal is 16 seconds.

**Conclusion: the safety check (`allowed`, `src/CleanupCore/Scanner.swift`) is the largest measured cost in both Scan and Move to Trash.** It should be the first speed change, ahead of everything in step 4 below. The cost of the real move to Trash is still unmeasured; the next real cleanup will record it in the job's details.

### Scan: where the time goes

* **Each file is asked for its metadata about five times.** The walk rebuilds the URL (`Scanner.swift:341`), which appears to discard the values the directory listing already fetched (`:337`). The safety check then asks again (`:183`, `:217`), re-checks the parent folder even when it is cached (`:205-207`), and the walk asks twice more (`:348`, `:350`). The safety check also rebuilds a list of 12 protected paths for every file (`:185-191`).
* **Duplicate checking hashes one file at a time** (`Scanner.swift:398-455`).
* **Browser, developer and temp-file results wait for duplicate hashing to finish** (`Scanner.swift:459-480` runs after `:392-457`). The architecture doc says results publish in sidebar order on purpose, so this is a design choice to revisit, not a bug.
* **Each one-second update re-sorts every ready file** and rebuilds the lookup tables (`Scanner.swift:317`, `:107-125`), and then the main thread refreshes the search index, the visible rows and the selection (`AppModel.swift:259`). The existing performance doc already recorded this pattern as the cause of an earlier lockup.
* **Compressing a video, restoring a file, or closing Settings throws away the whole scan** and starts another (`ScruffyApp.swift:146`, `:521`, `AppModel.swift:406`).

### What the user cannot tell today

* **The scan looks frozen during duplicate checking.** The "files checked" count only rises while walking folders (`Scanner.swift:351`). Nothing is reported while a large file is being hashed (`:282-286`). The welcome screen shows only a spinner until the first result (`ScruffyApp.swift:327`).
* **In a category view, checkboxes switch off about once a second during a scan.** Each partial result re-runs the search filter, and rows are disabled while it runs (`ScruffyApp.swift:411`, `:432`). This is the same cause as the recording's "stale rows" finding and is worse than the recording showed.
* **A cleanup cannot be stopped** except by quitting. The worker already checks for cancellation between files (`TrashService.swift:103`, `:129`) and the tasks are stored (`AppModel.swift:340`), but no button calls it.
* **The cleanup bar fills to 100% for "Checking", then starts again for "Moving"** (`CleanupJob.swift:25`).
* **Failure reasons and the current file sit behind a popover** (`CleanupJobsView.swift:78-88`). Finished jobs cannot be cleared, and a failed job reopens the panel at every launch (`:48`).
* **The confirmation sheet lists bare paths** in a box 90 to 180 px tall (`ScruffyApp.swift:548-552`): about 4 to 8 rows of up to 85,208, with no sizes or totals per category.
* **Video compression sits at 90%** while it verifies the output, with no updates (`src/CleanupCore/VideoCompression.swift:99-116`). The bar gives a 4 GB video the same share as a 50 MB one (`src/Scruffy/VideoView.swift:156`), and there is no "video k of n".
* **Purge shows one static message** for both "waiting for approval" and "working" (`src/Scruffy/PurgeableView.swift:95`, `:170`). macOS reports no progress for this work, so no percent is possible.
* **The hourglass cursor covers the whole window** during background work even though the controls still respond (`src/Scruffy/BusyCursor.swift:4`).
* **"Scan my Mac" scans `~/Downloads` and browser caches by default** (`AppModel.swift:8`, `Scanner.swift:75-81`, button at `ScruffyApp.swift:312`).

### The eight recording findings

All eight were confirmed in the code. None of them covers progress or speed; the recording review says so itself.

| # | Finding | Verdict | Quantified benefit |
| --- | --- | --- | --- |
| 1 | Old category's rows shown under the new title | Keep P1, and widen it: same cause as the once-a-second checkbox lockout | Stale period goes from 0.2–0.4 s (recorded) to 0. Removes 1 index wait and 1 re-sort per category click (counted) |
| 2 | `.crdownload` offered as a normal file | Keep P1 | Removes one way to trash a download in progress; the recorded case was 1.6 GB. A safety gain, not a speed gain. Also exclude `.part`, `.download`, `.partial` |
| 3 | One-slice donut in each category | Keep; reviewers split between P2 and P3 | The card is 183 px (135 px chart + 48 px padding). A compact summary recovers 88–120 px, about 2 rows (counted) |
| 4 | Too little information to decide | Split | Show the modified date now: it is already in memory (`Scanner.swift:40`), 0 extra file reads. Drop the video metadata cache: Quick Look already shows it on demand. Do not label it "last used" |
| 5 | Footer count covers all categories | Raise to P1 | That footer line is also the only scan progress text. Removes 1 conflicting count per category view |
| 6 | 8–10 pt secondary text | Keep P2 | +1 to 3 pt. No measurable gain beyond legibility. Drop the formal contrast audit unless someone measures it |
| 7 | "Could not be scanned" notice sits below the list | Keep P2 | Visible without scrolling. One label currently covers four different causes (`Scanner.swift:335`, `:338`, `:409`, `:414`) |
| 8 | Full paths in Videos, `~` paths elsewhere | Keep P3 | About 25 fewer characters per row |

### Recommended order

**Step 1 — Measure (small).** Add timing around each scan phase and each cleanup phase, store per-phase durations on the cleanup job, and add a test that times `clean()` with a no-op move. Benefit: turns every estimate below into a number. The one measurement taken for this brief already removed a medium-size, safety-sensitive change from the plan.

**Step 2 — Two small fixes with a safety or correctness gain.**

| Change | Benefit | Basis | Cost | Safety |
| --- | --- | --- | --- | --- |
| Exclude pending-download files | See finding 2 | Counted | S | Improves |
| Serve category lists from a prepared per-category table when the search box is empty | Finding 1, plus up to 1 checkbox lockout per second removed during scans | Counted; 0.2–0.4 s recorded | S | None |

**Step 3 — Show what is happening.**

| Change | Benefit | Basis | Cost | Safety |
| --- | --- | --- | --- | --- |
| Scan reports a structure (step k of 7, files checked, current folder) shown beside the Scan button in every pane and on the welcome screen | 3 panes and the welcome screen gain visible status | Counted | M | None |
| Determinate bar during duplicate checking (bytes hashed of bytes to hash), updated inside each file | Longest gap with no visible change goes from "the time to hash one file" to 1 s or less | Counted | M | None |
| Cleanup row: one continuous bar, current file inline, Cancel, failure reason inline, "Clear finished", time remaining during the move phase | 1 bar reset, 1 click and 1 hover removed per job; stop without quitting the app; up to 280 px of panel recovered | Counted | S–M | Cancel is safe: the worker stops between files and each move is journalled first |
| Confirmation sheet: count and size per category plus the 10 largest files | 100% of bytes summarised without scrolling, against about 0.01% of rows visible today | Counted | S | Improves |
| Video: "k of n", bar weighted by bytes, updates during verification | Removes the stall at 90% | Counted | S | None |
| Purge: elapsed time and bytes freed (free space before and after) | 2 states gain elapsed time; 1 result number where there is none | Counted | S | None |
| Remove the window-wide hourglass for background work | 1 false "blocked" signal removed | Counted | S | None |
| Name the scan scope on or under the "Scan my Mac" button | 1 wrong first impression removed | Counted | S | None |

**Step 4 — Speed, after step 1 confirms where the time goes.**

| Change | Benefit | Basis | Cost | Safety |
| --- | --- | --- | --- | --- |
| Use `keepersByHash` for the protected-original lookup | Up to 2.4 billion comparisons removed when 10,000 duplicates are selected from 120,000 files | Counted (2 passes × 10,000 × 120,000) | S | None |
| Hash each selected copy once, at move time, and each protected original once per batch | Ten 2 GB copies: 80 GB read becomes 22 GB. About 40 s becomes about 11 s | Estimate at 2 GB/s | S–M | Accepted by the owner. The original is no longer re-hashed before every move; the fingerprint check before each move stays |
| Replace the per-file browser check with a flag kept current by app launch notifications | 85,208 main-thread round trips become 0 for the recorded cache set | Counted; time unmeasured | S | A browser launched mid-batch must still stop the batch |
| Scan: reuse the metadata the directory listing already fetched; check protected folders per directory | About 5 metadata calls per file become 1: about 480,000 calls removed on 120,000 files, roughly 2–4 s | Estimate | S–M | Keep the full, uncached check in the Move to Trash path |
| Update scan results in place after compress or restore; rescan after Settings only if options changed | One full rescan (10–60 s) and the loss of every selection removed per batch or restore | Estimate | M | Low |
| Publish scan updates as additions instead of re-sorting everything each second | 50–200 ms of work per second removed at 85,000–100,000 files | Estimate | M | None |
| Publish cache categories before duplicate hashing finishes; hash several size groups at once | First cache rows appear before hashing ends; hashing about 2–3 times faster on SSD | Estimate | M | None. Changes the documented sidebar-order publishing |

**Step 5 — Layout.** Findings 3, 4 (modified date), 5, 6, 7 and 8 from the table above. Each is small.

#### Smaller items found along the way

* History view checks whether each trashed file still exists on the main thread for every row (`ScruffyApp.swift:603`). Move it to the background load.
* Each row icon is drawn, encoded to PNG and decoded again on every page change: 200 encode/decode cycles per page (`ScruffyApp.swift:78-105`). Cache by file type.
* The journal replays every past event and is never trimmed (`TrashJournal.swift:12-43`). After 50,000 trashed files it holds about 100,000 lines. Trim records whose Trash file no longer exists.
* One reviewer reported that a USB drive mounted inside the home folder would pass the "local volume" check (`Scanner.swift:183-184`). **Not verified**; check before acting.

### Compatibility rules for any of this work

* `Fingerprint` is stored inside the recovery journal. A new required field makes old journals fail to load, which blocks all Move to Trash (`TrashJournal.swift:105`, `:122`; `TrashService.swift:119`). New stored fields must be optional.
* The same applies to `cleanup-jobs.json`: a load error turns job persistence off (`AppModel.swift:373`).
* Keep the journal's one-event-per-line format so an older build can still read it.

## Goals vs. Non-Goals

* **In-Scope Goals:**
  * Per-phase timing for Scan and Move to Trash, so later changes are judged on measured numbers.
  * A visible status for every long operation: a determinate bar where a total is known, and a count plus elapsed time where it is not.
  * Cancel for cleanup jobs.
  * Category switches that never show another category's rows.
  * Pending downloads excluded from cleanup.
  * Removing repeated work in Move to Trash and Scan that step 1 shows to be significant.
  * The eight recording findings, in the order above.
* **Out-of-Scope Non-Goals:**
  * New cleanup categories or new features.
  * Percent complete for the folder walk or for purge. Neither total is knowable.
  * Changes to how the recovery journal syncs.
  * Moving several files to Trash at once.

## Alternatives Weighed

* **Batch or skip journal syncs.** Rejected by author: measured at about 50 µs per append on this Mac, the whole journal costs about 8.5 s per 85,208 files and the sync is 1–2 s of that. The saving does not justify a wider window of unrecorded moves.
* **Skip the journal for cache categories.** Rejected by author: same measurement, and it would remove recovery for those files.
* **Move files to Trash in parallel.** Rejected by author: the journal is serial under a lock, the cost of the move itself is unmeasured, and no benefit can be stated.
* **Drop the preflight pass entirely.** Rejected by author: preflight is what stops a batch before any file moves when a path is unsafe. Keep the location checks there; move the hashing to the per-file check.
* **Time remaining on every operation.** Rejected by author: one reviewer argued any estimate is misleading because file sizes vary widely. Show it only for the Move to Trash move phase, video compression and duplicate hashing, where the total is known. Show elapsed time elsewhere.
* **A second directory pass to give the folder walk a percent.** Rejected by author: it would roughly double walk time to draw a bar. Show a count and the current folder; the previous scan's total can serve as a rough guide.
* **A cache of video duration, resolution and codec for list rows.** Rejected by author: Quick Look already shows this on demand. If it is wanted later, load it only for the 200 visible rows.
* **One shared progress type for all five operations.** Rejected by author as a goal in itself: it has no user-visible benefit. Add only the fields step 3 needs.
* **Dedicated threads for blocking work** and **letting a scan start during a cleanup.** Rejected by author: no measurement or user report supports either.
* **A formal contrast audit.** Rejected by author: the recording is too compressed to measure it.

## Key Decisions & Staging for Next Steps

* **Decided:** measure first. Step 1 comes before any speed work.
* **Decided:** the recovery journal's write and sync behavior stays as it is.
* **Decided:** no percent for the folder walk or for purge.
* **Decided (owner, 2026-11-09):** hash each selected copy once and the protected original once per batch, instead of both before every move. The owner accepted the risk that a rewrite of the original during a cleanup that keeps its exact size and modified time would go unnoticed. The size, modified-time and file-identity check still runs before every move.
* **Open — owner decision:** publish browser, developer and temp results before duplicate hashing finishes, which changes the sidebar-order rule in `docs/architecture/system-purge-and-performance.md`.
* **Open:** the cost of `trashItem` per file. If step 1 shows it dominates Move to Trash, none of the step 4 cleanup changes will be felt on cache batches, and the benefit there comes only from step 3.
* **Open:** build and run the current `develop` code and record what Scan and Move to Trash show on screen. Every statement about the current display in this brief comes from reading code, not from watching the app.
* **Open:** Codex did not review this. Fix the model in `~/.codex/config.toml` to include it in a later pass.
* **Next:** `/egm:egm-draft` reads this file and turns it into a design document under `docs/designs/`.
