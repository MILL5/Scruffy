# File-section NGramSearch

Scruffy uses a native Swift adaptation of MILL5 FastSearch's `NGramSearch` posting-list algorithm. The local reference is `../fastsearch/FastSearch/Algorithms/NGramSearch.cs` and its `docs/NGramSearch-Spec.md`. No .NET process, network service or third-party runtime is needed.

## Search behavior

- Every file category has its own logical index. Overview searches the category indexes together.
- The full cached path is indexed, including the filename. Text is lowercased and normalized to Unicode NFC; accents are preserved.
- Each whitespace-delimited word searches independently. Matching positions are intersected, so **all words must match**, in any order and in any parts of the path. For example, `summer London zip` can match `London/2026 summer holiday.zip`.
- Empty or whitespace-only input shows all files in the current section. Duplicate keepers remain visible and retain their selection protection.
- Results keep the current scan's ordering. Removed files and entries whose category changed are checked against the current snapshot before returning.

## Index implementation

`NGramSearch.swift` packs every distinct one-, two- and three-UTF16-unit gram into a `UInt64` key. Each posting list contains ascending input positions, stored as delta-varints or a dense bitmap, whichever is smaller. One- to three-unit queries decode their exact posting list. Longer words start with the rarest trigram list, intersect useful lists and verify surviving paths to remove gram false positives.

The Swift adaptation omits the C# implementation's optional frequent four-gram optimization and Latin-1 text packing. It retains UTF16 verification text and all one-/two-/three-gram indexes; short words therefore do not fall back to scanning every filename.

`FileSearchIndex` runs on its own actor. Each section adds immutable segments of at most 2,048 new file IDs as progressive results arrive. Completed segments survive a cancelled update, and later snapshots reuse them rather than rebuilding the previous inventory. Queries reuse an already indexed snapshot. A new scan generation drops the old indexes; within a generation, removed entries can remain in compressed segments but are excluded using the current snapshot's active IDs and category. The snapshot's position map preserves ordering without scanning every file for every search word.

## Checks and measured sample

Twelve focused core tests cover short words, Unicode normalization and case, dense/sparse postings, gram false positives, independent query words and ordering, section isolation, incremental extension, removals, category changes, generation replacement and cancellation. They passed with zero failures.

A separate `swiftc -O` executable measured 100,000 synthetic full paths containing 6,687,256 UTF16 units. Each query measurement below used 100 calls; times include full result enumeration, and actor timings include scheduling and mapping back to candidates.

| Measurement | Result |
|---|---:|
| Standalone NGramSearch build | 0.590 s |
| Standalone compressed postings / UTF16 text | 3.94 MB / 13.37 MB |
| Standalone exact archive-ID query, 1 hit, median | 14.1 µs |
| Standalone `zip`, 33,334 hits, median | 82.5 µs |
| All six section indexes, 54 segments, build | 0.608 s |
| Section-index compressed postings / UTF16 text | 3.70 MB / 13.37 MB |
| Overview exact archive-ID query, 1 hit, median | 0.257 ms |
| Overview `summer london`, 2,858 hits, median | 6.57 ms |
| Duplicates `london summer`, 477 hits, median | 0.626 ms |
| Duplicates `zi`, 16,667 hits, median | 13.7 ms |
| Add one item to the 100,000-item snapshot | 43.6 ms; one new segment |

These are local synthetic measurements, not a guarantee for every filesystem or query. The standalone and section-index processes peaked at 67.2 MB and 267.0 MB RSS respectively, including their different input/fixture objects; those figures are not isolated index sizes. Build/query source and full benchmark output were retained under `/tmp/ScruffyNGramBenchmark.swift` and `/tmp/scruffy-ngram-benchmark-*.log` for this run.
