# Verification — November 8, 2026

- `swift test`: 11 tests passed, zero failures.
- `scripts/build-app.sh`: release executable built and packaged as `dist/Scruffy.app`; local ad-hoc signing succeeded.
- Native app launched successfully. Welcome screen, disabled cleanup before selection, category navigation and scan-settings sheet were inspected through macOS accessibility and a window screenshot.
- An interactive scan was observed running. Completion and real-file cleanup were not verified in this session.
- Trash and recovery logic were exercised with isolated fixtures and an injected filesystem move, not by deleting personal files. No personal files were selected or moved by the agent.

Covered safety cases: exact duplicate grouping and keeper protection; changed/deleted originals; old versus recent downloads; browser cache allowlist versus credentials/history; running-browser rejection; symlink ancestors; hard links and cloud/package exclusions; resource-fork exclusion; whole-batch validation; recovery without overwriting existing work.

Not yet acceptance-tested: long-running real-home scans, macOS permission-denial dialogs, actual Finder Trash/Put Back behavior, full disks, restart during cleanup, Intel build, notarization, older supported macOS versions and browser-version-specific cache layouts.

## Appearance update

Version 0.2.0 built and passed local code-signature verification. Native window inspection confirmed the Light theme and System appearance on a dark macOS desktop, the appearance picker, the broom mark and removal of the MILL5 wordmark from the main window. The About view is implemented with the sole wordmark placement. The app was relaunched after refreshing LaunchServices registration and now explicitly sets its Dock icon to the bundled broom image; a separate Dock screenshot was unavailable through the computer-use tool.

## System purge and progressive results

25 tests passed. The release helper successfully queried eligible system data without administrator privileges. Native UI showed an enabled Clean purgeable data action with no Time Machine snapshots. A 20 GB target request was observed completing; macOS reported 1.19 GB removed, followed by background refresh. This is the service-reported removal count, not an independently measured physical-space gain. Progressive scanning and stable keeper groups were verified by tests. The brighter app icon was packaged and the app relaunched.
