# Scruffy documentation

- [Product references](product/product-references.md): research and scope.
- [Branding](design/branding.md) and [logo assets](design/logo-generation.md).
- [Indexed search](architecture/ngram-search.md): native NGramSearch and measured performance.
- [Cleanup and recovery](architecture/cleanup-and-recovery.md): skipped files, conditional browser checks and durable recovery events.
- [System purge and scan responsiveness](architecture/system-purge-and-performance.md).
- [Purgeable storage](architecture/purgeable-storage.md): snapshot reclamation and its limits.
- [Video compression](architecture/video-compression.md): verification, replacement and recovery.
- [Verification record](verification/README.md): completed checks and remaining acceptance coverage.
- [November 9 validation](verification/2026-11-09.md): indexed search, responsive UI, compression and website checks.
- [November 10 validation](verification/2026-11-10.md): 0.6.0. Same-volume rule, faster scans and cleanup, chosen originals, saved settings, journal pruning, the permission-prompt stall and real-machine acceptance.
- [November 9 review](reviews/2026-11-09.md): historical findings against the reviewed source snapshot.
- [4:49 PM recording review](reviews/2026-11-09-recording-164925.md): timestamped navigation, safety and layout findings.
- [Marketing website](site/index.html): the files deployed to GitHub Pages.

Application source lives in `src/`, automated tests in `tests/`, and local packaging scripts in `scripts/`.
