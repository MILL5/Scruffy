# Video compression and replacement

`VideoCompressionService` exports videos locally using AVFoundation's **HEVC Highest Quality** preset, retaining each source's resolution and file container. MP4, MOV and M4V extensions map to the corresponding `AVFileType`; the service skips a file if that exact combination of source, preset and container is unsupported. Alpha video uses the corresponding HEVC-with-alpha preset. It does not resize videos to a common target or silently change their extension.

HEVC is a lossy video codec. “Highest Quality” identifies Apple's export preset, not a promise of bit-identical pixels or a human visual-quality approval. Existing descriptive asset metadata is supplied to the export. HDR input is currently skipped before export: its media characteristic and PQ/HLG transfer tags are checked so an export cannot silently tone-map it. Files with resource forks, multiple video tracks, protection, or extra subtitle/timecode/timed-metadata tracks are rejected rather than discarding those additional data streams.

## Verification before replacement

1. Validate the original against the scan fingerprint and the existing local-path safety rules; independently reject resource-fork data.
2. Export to a private, uniquely named staging directory beside the source, on the same volume. The staged file retains the original filename and extension.
3. Verify a nonempty regular output with no extra links or resource fork. Read the exported video/audio tracks to completion, allowing AVFoundation's legitimate marker-only buffers while requiring actual readable media samples in every track.
4. Compare coded/display dimensions, orientation, alpha/HDR characteristics, duration, video time range, nominal frame rate, audio track count, channel counts and audio time ranges. Source color primaries, transfer function and YCbCr matrix tags must remain present and identical when supplied. Timing tolerance is 100 ms; frame-rate tolerance is the larger of 0.1 fps or 0.5%. Require HEVC output.
5. Require a smaller byte size. Recheck the staged fingerprint, original fingerprint/resource fork, safe ancestors and source-parent identity before touching the original.

A cancelled, incompatible, invalid or non-smaller export leaves the original in place. Owned staging is removed when safe. No external encoder, download or network service is involved.

## Trash, exclusive installation and recovery

Replacement transactions are serialized. After the final cancellation check, an independent task completes the critical transaction even if its caller is cancelled:

- `TrashService.clean` records intent, moves the original to Trash and updates its existing recovery journal.
- `renamex_np(..., RENAME_EXCL)` installs the verified replacement atomically without replacing a concurrently created destination.
- A failed installation or recovery-journal update attempts to restore the original using `TrashService.restore`, which refuses to overwrite an occupied path.
- If rollback cannot restore safely, the service retains the original in Trash and the verified staged replacement, reporting both recovery paths. Concurrently created user data remains untouched.

The compressed file occupies the original path after success; restoring the original through history requires moving that replacement aside first. Process termination or a crash can still interrupt the critical transaction: the original remains recoverable through Trash/history, with Finder's Trash needed if the journal's post-move update did not complete. The service never empties Trash.

## Validation

Twelve backend tests passed with zero compiler warnings/errors. Injected fixtures exercise smaller-output replacement and journaling, non-smaller skips, resolution/timing/frame-rate/audio/alpha/codec rejection, HDR preflight skips, missing/changed color tags, resource forks, source mutation, cancellation, rollback, an occupied destination, recovery-history failure after Trash and completion of the critical transaction after cancellation.

The native integration test actually creates a 320×240, 30 fps H.264 MP4 with one second of stereo audio, exports it through the production HEVC path, verifies the resulting MP4's dimensions/duration/HEVC codec/stereo track, installs it and checks the original's fake-Trash fingerprint. A legal unused `free` atom pads the synthetic source so the smaller-output condition is deterministic; that padding is not evidence of a typical compression ratio. The test uses an injected fake Trash in a disposable directory and does not select, replace or Trash any personal file. Its fixture writer requires the macOS 26 SDK/runtime and is excluded with an explicit test skip on Swift compilers older than 6.2. The service retains macOS 14-compatible export/reader/progress paths; macOS 26-only reader symbols are also compiler-guarded. A typecheck with the modern reader branches disabled passed against the current SDK while targeting macOS 14. Actual Xcode 16 compilation, execution on macOS 14, and native MOV/M4V/alpha visual acceptance remain unverified on this Mac.

The focused run is recorded in `/tmp/scruffy-video-tests.log`. Source-level API availability and preset/container behavior were checked against the installed macOS SDK's AVFoundation/CoreMedia declarations and Apple's [HEVC Highest Quality](https://developer.apple.com/documentation/avfoundation/avassetexportpresethevchighestquality) and [AVAssetExportSession](https://developer.apple.com/documentation/avfoundation/avassetexportsession) documentation.
