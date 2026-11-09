# Mac disk cleanup references

Reviewed November 8, 2026 using official product pages and documentation. These are product research observations, not runtime comparisons or safety certifications. No third-party code or assets are reused.

| Product | Focus | Useful reference for Scruffy |
| --- | --- | --- |
| [DaisyDisk](https://daisydiskapp.com/) | Visual space analysis using a sunburst, file previews and a collection area; $9.99 one-time license advertised | Make space understandable before asking the user to remove anything; separate exploration from the final action |
| [GrandPerspective](https://grandperspectiv.sourceforge.net/) | File-size treemap; free direct download, paid App Store option | Show size proportions and cluster related files |
| [OmniDiskSweeper](https://www.omnigroup.com/more/) | Browse files largest-first, open or Trash them | Keep a straightforward size-ranked list alongside visualization |
| [Gemini 2](https://macpaw.com/support/gemini/faq) | Exact and similar duplicate discovery; selection rules and Trash recovery | Protect an original, distinguish identical from similar, provide recovery |
| [CleanMyMac](https://macpaw.com/support/cleanmymac/knowledgebase/missing-features) | Broad cleanup suite including caches, logs, downloads/clutter and application tools; features vary by edition | Organize actionable findings into understandable categories |
| [AppCleaner](https://freemacsoft.net/appcleaner/) | Uninstall apps with associated files | Related-file review is useful, but app deletion is outside Scruffy v0.1 scope |
| [OnyX](https://www.titanium-software.fr/en/onyx.html) | Free system maintenance and cache utilities; version tied to macOS | Keep advanced maintenance separate from personal-file cleanup |
| [Pearcleaner](https://github.com/alienator88/Pearcleaner) | Source-available app uninstaller, orphan search, developer environment tools | Useful scope reference; maintainer currently states active development is on hold |

## Scruffy direction

Native SwiftUI; calm charcoal and mint interface; a compact category chart with size-ranked files; previews and full paths; explicit selection; final review; Trash-only cleanup and recovery history. No unsubstantiated “speed boost,” RAM cleaning, app thinning, backup pruning or system database modification. Folder-age and exact-duplicate heuristics identify review candidates, not proof a file is unwanted.

## Implementation references

- [Apple FileManager trashItem](https://developer.apple.com/documentation/foundation/filemanager/trashitem(at:resultingitemurl:)) supplies the actual Trash destination used by recovery history.
- [Apple URLResourceValues](https://developer.apple.com/documentation/foundation/urlresourcevalues) supplies package, symlink, alias and iCloud metadata checks.
