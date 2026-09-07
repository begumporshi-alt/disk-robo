# 07 · MVP Scope & Implementation Phases

## 1. MVP scope (spec §46)

1. Native macOS app shell — ✅ SwiftUI, macOS 14+, sidebar navigation
2. Disk scanning engine — ✅ async, bounded concurrency, cancellable, progressive
3. Storage categorization — ✅ deterministic rules
4. Storage map visualization — ✅ sunburst, drill-down, category colors
5. Largest-file explorer — ✅ filters, Quick Look, Reveal, trash w/ confirmation
6. Cleanup candidate detection — ✅ rule inventory (05-data.md §5)
7. Safety classification — ✅ 4-level framework + protected paths + veto
8. Quick Clean — ✅ plus Smart / Deep / Target modes
9. App storage analysis — ✅ footprints + leftovers
10. Duplicate detection — ✅ size → partial hash → full hash
11. Scan history — ✅ snapshots + audit log
12. Basic growth analysis — ✅ snapshot diffs + narratives
13. Robo recommendations — ✅ insights engine + Disk Health Score
14. Safe move-to-Trash workflow — ✅ preview → token → TOCTOU verify → trash → audit
15. Permissions onboarding — ✅ FDA explanation, probe, re-check

## 2. Phases

### P0 — Foundations
**Goal:** models + safety + classification with tests, before any scanning. **User behavior:** none yet. **Modules:** SharedModels, ClassificationEngine, SafetyEngine. **Dependencies:** none. **Data models:** categories, risk, node, fingerprints. **APIs:** `classify(path:)`, `isProtected`, `validateTrash`. **Frameworks:** Foundation. **Permissions:** none. **Failure states:** n/a (pure). **Security:** protected-path tables. **Performance:** O(path) checks. **Tests:** classification, safety. **Acceptance:** `swift test` green. — ✅ done

### P1 — Scanning engine
**Goal:** correct, fast, cancellable, memory-bounded tree scan. **User behavior:** progress with live counters; partial results stream. **Modules:** ScanEngine, VolumeManager, DirectorySizer. **Dependencies:** P0. **Data:** StorageNode tree, ScanResult. **APIs:** `scan(roots:options:) -> AsyncStream<ScanEvent>`. **Frameworks:** Foundation. **Permissions:** FDA improves coverage (honest reporting otherwise). **Failure states:** inaccessible nodes, cancellation. **Security:** no writes; symlink non-follow. **Performance:** §03-9. **Tests:** via P2+ consumers + manual timing. **Acceptance:** full-home scan produces categorized totals; UI never blocks. — ✅ done

### P2 — Cleanup intelligence
**Goal:** explained candidates + plans. **User behavior:** candidate list with risk/confidence/explanations; modes. **Modules:** CleanupEngine, RoboPlanner. **Dependencies:** P0, P1. **Data:** CleanupCandidate, CleanupPlan. **APIs:** `findCandidates(root:)`, `buildPlan(mode:)`. **Failure states:** excluded paths honored; min-size filter. **Security:** risk never from size; greens allowlisted. **Tests:** CleanupEngineTests, PlannerTests. **Acceptance:** quick plan contains greens only; target plan reaches goal safely-first. — ✅ done

### P3 — Safe execution
**Goal:** the safest deletion path possible. **User behavior:** preview → confirm → outcome. **Modules:** TrashExecutor, ApprovalToken, HistoryStore audit. **Dependencies:** P0, P2. **Data:** TrashOutcome, CleanupActionRecord. **APIs:** `trashItems(_)`. **Failure states:** TOCTOU block, veto, per-item failure isolation. **Security:** §04-4/5. **Tests:** SafetyEngineTests (fingerprint, symlink), PolicyEngineTests. **Acceptance:** no path reaches the filesystem without validation; audit log complete. — ✅ done

### P4 — Duplicates & Apps
**Goal:** byte-verified duplicates; per-app footprints. **User behavior:** dup groups w/ keep-one; app breakdowns + leftovers. **Modules:** DuplicateEngine, AppAnalyzer. **Dependencies:** P1. **Data:** DuplicateGroup, AppFootprint. **Failure states:** cancellation; missing bundle IDs. **Security:** dup trash is user-initiated + veto-checked. **Tests:** DuplicateEngineTests. **Acceptance:** no false duplicate groups (full-hash verified). — ✅ done

### P5 — Memory & insight
**Goal:** history, growth, health, recommendations. **User behavior:** timeline, diffs, score, insights. **Modules:** HistoryStore, GrowthAnalyzer, HealthScore, InsightsEngine. **Dependencies:** P1–P3. **Data:** Snapshot, StorageDelta. **Failure states:** corrupt entries skipped; missing history renormalizes score. **Tests:** GrowthAnalyzerTests, HealthScoreTests. **Acceptance:** "where did my space go" answered from two snapshots. — ✅ done

### P6 — Experience
**Goal:** complete native shell. **User behavior:** all screens (02-ux), onboarding, settings, exclusions. **Modules:** DiskRobo target (AppModel, screens, components). **Dependencies:** P0–P5. **Frameworks:** SwiftUI, AppKit (icons, Finder reveal), QuickLook. **Permissions:** onboarding + Settings management. **Failure states:** empty/loading/error per screen. **Security:** no direct filesystem mutation outside executor. **Performance:** Canvas sunburst; MainActor event consumption. **Tests:** build + unit suite; UI manual QA list. **Acceptance:** app builds (`swift build`), suite passes, flows J1–J6 walkable. — ✅ done

### P7 — RoboOS tool layer
**Goal:** typed agent tools + policy gate (foundation for Phase-2 assistant). **Modules:** AgentTools, PolicyEngine. **Acceptance:** destructive tool denied without token; allowed with valid token. — ✅ done

## 3. Verification in this repository

- `swift build` — full app compiles
- `swift test` — engine + safety suite passes
- `Scripts/build-app.sh` — distributable .app bundle

## 4. Known limitations (honest list)

Hard links may double-count (rare; §03-10 G5) · last-used dates not yet sourced (Phase 2 Spotlight) · System Data decomposition partial by SIP design · no incremental index yet (full rescans; cancellable) · notifications are in-app banners only · menu bar companion Phase 2 · assistant is rule-based; NL layer Phase 2.

## 5. Phase 2 (built — 2026-09-06)

- **Robo Radar** — ✅ `RadarEngine`: ranked findings (severity × recoverable × confidence × recurrence × risk) over free-space pressure, growth rate, biggest grower, cache bloat, duplicate mass, repeat offenders, leftovers, Trash buildup, old installers. Live screen with severity badges (S1–S5, color + symbol + label).
- **Repeat Offenders** — ✅ `RepeatOffenderEngine`: cross-references the cleanup audit log with the current scan; cleaned-then-regrown locations with weekly growth estimates; surfaced on Radar.
- **Predictive storage** — ✅ `ForecastEngine`: OLS over snapshot free-space; days-below-threshold, 30-day projection, R²-derived confidence (Very High…Low); narrative on Growth Tracker; returns nil with <3 snapshots (never guesses).
- **Natural-language assistant** — ✅ `AssistantIntentParser` + `AssistantEngine` + chat UI. Rule-based and fully on-device (privacy model: no network code). Understands: why-disk-full, free-space status, safely-free-N-GB, target cleanup, clean-now, app usage ("what is Xcode using"), what-grew, where-did-space-go, duplicates, largest files, developer storage, System Data explainer, help. Assistant actions are navigation/planning ONLY — cleanup still requires the normal preview → approval-token → safety pipeline. "Scan my disk" triggers a real scan.
- **Automation (Observe/Recommend tiers)** — ✅ built-in rules: free-space threshold alert + severity-4 radar finding alert, evaluated after each scan. Act tier deliberately absent (safety).
- **System notifications** — ✅ `NotificationManager` (UserNotifications, local only, permission asked lazily, toggle in Settings).
- **Menu bar companion** — ✅ `MenuBarExtra` (window style): free space + health ring, recoverable summary, top finding, Quick Scan, Open Dashboard/Review Cleanup/Ask Assistant. No polling — reads the live model.
- **Robo Uninstall** — ✅ real flow: app picker → per-component review (bundle, support, caches, containers, logs, saved state, preferences, WebKit/HTTP data with paths) → select → Trash through the safety engine (protected components vetoed and reported).
- **Storage Memory (richer events)** — ✅ snapshot-driven growth + forecast feed.

Phase-2 regression hardened: `AppSettings` now decodes tolerantly (new fields default instead of resetting user state).

## 6. Phase 3 outline

Mac Storage Intelligence Platform: multi-Mac sync (opt-in, end-to-end encrypted), external-volume intelligence, cloud-storage awareness, archival recommendations, plugin architecture, richer local ML.
