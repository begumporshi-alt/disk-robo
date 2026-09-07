# 06 · Errors, Testing & Release

## 1. Error-state matrix

Every error explains: what happened · why · whether anything is at risk · what Disk Robo recommends.

| State | Detection | User message (gist) | Risk | Recovery |
|---|---|---|---|---|
| Permission denied (dir) | walk error | "N locations couldn't be inspected (macOS privacy). Grant Full Disk Access for complete coverage." | None — partial results only | Button → System Settings; re-scan |
| File disappeared during scan | enumerator error | counted silently, excluded from totals | None | rescan |
| Inaccessible folder | same as above | flagged node, size unknown (never estimated) | None | FDA |
| Corrupted metadata | resourceValues nil | item skipped, counted as unreadable | None | rescan |
| External drive disconnected | URL resource errors / volume UUID missing | "Volume disconnected" state on its snapshots | None — scan fails safe (no deletion path active) | reconnect + rescan |
| File modified during analysis | fingerprint mismatch at execution | item **blocked**: "changed since the scan — re-scan before cleaning" | Data protected by design | rescan, re-plan |
| Cleanup failed (per item) | trashItem throw | item listed as failed with reason; batch continues | Other items unaffected | retry / reveal in Finder |
| Partial cleanup | outcome aggregates blocked+failed | explicit counts, never silent success | None hidden | shown in outcome + audit log |
| Database/history corruption | decode failure | history entry skipped; app continues | Advisory data only | old entries kept aside, retention prunes |
| Interrupted scan | task cancellation | scan stops cleanly, partial state discarded | None | rescan |
| Insufficient permissions for FDA probe | probe error | status shown as "not detected" (never guessed) | None | re-check |
| Volume full (< threshold) | free-space check | prominent warning (in-app MVP; system notification Phase 2) | OS-level, communicated | cleanup / free space |
| Crash during cleanup | audit-log reconciliation on next launch | report of what was verified trashed vs. unknown | Reversible — items were trashed, not deleted | audit trail |

## 2. Testing strategy (spec §57)

| Layer | Implementation |
|---|---|
| Unit — classification | `ClassificationEngineTests` (path/extension rules) |
| Unit — safety | `SafetyEngineTests`: protected paths, allowlist, symlink-escape veto, TOCTOU fingerprint mismatch, user-initiated vs engine-initiated |
| Unit — cleanup rules | `CleanupEngineTests` on synthetic node trees (injected temp home): caches, aged installers/downloads thresholds, trash |
| Unit — duplicates | `DuplicateEngineTests` on real temp fixtures: identical, same-size-different-content, group math |
| Unit — planner | `PlannerTests`: quick = green-only; target fill order (safest first); expected recovery sums |
| Unit — growth | `GrowthAnalyzerTests`: category/dir deltas, narrative |
| Unit — health score | `HealthScoreTests`: bounds, renormalization without history |
| Unit — layout | `SquarifiedLayoutTests`: area preservation, containment, empty input |
| Unit — policy | `PolicyEngineTests`: destructive tool without token denied; valid/expired token paths |
| Manual QA (documented) | trash round-trip in Finder, FDA grant flow, full-home scan timing, external volume scan |

Deletion-related code carries the strongest coverage — synthetic filesystem fixtures cover dangerous edge cases (symlink traps, vanished files). Run: `swift test`.

## 3. Quality gates (per spec §53)

Reliability: no accidental data loss (allowlist + veto + trash-only + audit). Performance: UI smooth during scans (utility-priority background, event-driven UI). Memory: bounded node materialization. Energy: no polling; scans on demand. Accuracy: no double-counting within a scan (single-pass tree, packages as leaves, symlinks excluded). Trust: explained, categorical confidence; measured freed bytes. Transparency: uncertainty stated (inaccessible counts, purgeable notes).

## 4. Release architecture

- **Build:** `Scripts/build-app.sh` — `swift build -c release`, wrap into `DiskRobo.app` (Info.plist: min macOS 14, HiDPI), ad-hoc codesign for local use.
- **Distribution target:** Developer ID signing + notarization (hardened runtime) via `codesign`/`notarytool`; no entitlements required in MVP.
- **Updates:** Phase 2 — Sparkle-style signed appcast or inline notarized update; secure update mechanism per spec §33.
- **No telemetry** ships in MVP.

## 5. Metrics (product-level, privacy-preserving, when telemetry ever ships)

Time-to-first-insight · scan performance · identified vs. recovered bytes · cleanup failure/false-positive rates (target 0) · crash-free sessions · recommendation acceptance · permission abandonment · background impact. North star: **zero preventable user-data-loss incidents.**
