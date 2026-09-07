# Professional Review + Performance Brainstorm — Disk Robo · 2026-09-07

> **FIX LOG — 2026-09-07 (later same day):** All tiers implemented except Tier 4 (architectural roadmap). 87/87 tests green; live-verified: quick scan at **28,342 files/sec (≈2× the pre-review 13–17k)**, zero end-of-scan freeze, all Overview cards populated instantly, Downloads/Archives categories now visible (SV-4). Per finding: **SV-1** fixed (bundle-ID guard + Library-root exact protection) · **SV-2** fixed structurally (per-job timers replaced by one shared sweep timer — no arming race exists anymore) · **SV-3** fixed (FDA probe async through the pool, "Checking…" state at launch) · **SV-4** fixed (Downloads root materializes ≥1 MB; regression-tested) · **SV-5** fixed (parallel hashing ~4×, HashCancellation flag, hard-link inode dedupe; regression-tested) · **SV-6** fixed (progressiveNodes deleted; per-directory events off by default) · **PF-1** fixed (detached event loop; candidates/snapshot/history off-main; async history load) · **PF-2** fixed (task-group fan-out over the pool) · **PF-3** fixed (cached list + dict lookups + search field) · **PF-4** fixed (cached geometry, split base/hover canvases, O(n) labels, dead shadow removed) · **PF-5** fixed (single-stat walk, Set hoist, GC listing hoist; watchdog timers → 1 shared sweep) · **PF-6** fixed (async refreshHistory + launch, time-based progress throttle 150 ms, trash-batch history IO off-main) · **PF-7** fixed (static formatters, bounded largestFiles materialization, progressiveNodes removed) · **UI-1..UI-5** fixed (single header, path-keyed selections surviving prunes + preselect-on-completion-only, real selection state on Dev/Browser rows, app-selection reconciliation, sheet dismissal bound to execution) · **A11y-1/2** fixed (real Buttons + labels + values; labeled pickers, send, toggles, reveal) · **Virtualization** fixed (LazyVStack on cleanup candidates, duplicate groups, leftovers). **Open (Tier 4 roadmap):** XPC scan child process (memory return), SQLite incremental index + FSEvents, low-power scan mode, duplicate-result caching, TrashExecutor freed-bytes overstatement on blocked dirs (minor).

Three parallel professional reviews (RoboCore correctness, performance/resources, SwiftUI layer) over the entire codebase, plus runtime analysis. 80/80 tests green at review time. This report is analysis only — nothing has been changed. Findings are grouped by area, then ranked into an implementation brainstorm.

---

## 1. Safety & correctness (RoboCore)

### SV-1 · P0 — Damaged app bundles can offer your ENTIRE Library folders for deletion
`AppAnalyzer.footprint` (AppAnalyzer.swift:228): when a `.app` has no readable bundle ID (damaged/partial bundles, renamed folders), `bidValue` becomes `""` and every bid-keyed component path collapses to the **folder root** — `~/Library/Application Support/`, `Caches/`, `Containers/`, `Logs/`, `WebKit/`, `HTTPStorages/` — the whole folder gets attributed to that "app," preselected in the Uninstaller, and passed as *user-initiated*, which passes every safety layer (none of those roots are protected trees; depth floor passes). One confirmation → entire Library folder to Trash.
**Fix:** guard `bid` non-empty before bid-keyed lookups (name-based fallback is already safe); defense-in-depth: add `~/Library/Application Support` etc. to `protectedExactPaths`.

### SV-2 · P1 — Watchdog timer-arming race can permanently skip healthy directories
`EnumerationWorkers.submit` (ScanEngine.swift:195-216): the job is enqueued and signaled **before** its watchdog timer is created and assigned to `job.timer`. A fast worker can finish and read `job.timer` as nil (unsynchronized — formal data race), the timer later fires on a *successful* listing, and `noteBlocked` poisons the session blocklist — every later scan of that healthy directory instantly returns "Skipped, system-protected" with 0 bytes. Silent size loss for the whole session.
**Fix:** create/schedule/resume the timer and store it on the job (under the pool lock) *before* enqueueing the job.

### SV-3 · P1 — Full Disk Access probe can hang the app at launch
`PermissionManager.checkFullDiskAccess` (PermissionManager.swift:20) synchronously lists `~/Library/Safari` — TCC-protected, the exact failure class as the 24 stalled directories on this machine — called from `AppModel.init` **on the main thread**. On an affected machine: beachball at launch.
**Fix:** route the probe through `ScanEngine.listDirectory` (1-2s timeout); timeout → `granted: false, "unresponsive"`.

### SV-4 · P2 — 1–10 MB files are invisible to cleanup
Scanner materializes only files ≥ 10 MB (`largeFileThresholdBytes`) but `CleanupEngine`'s floor is 1 MB and it only sees materialized children — so a 5 MB four-month-old `.dmg` in Downloads can never become a candidate. Unit tests mask this (synthetic trees). Recoverable totals are understated.
**Fix:** materialize Downloads leaves ≥ 1 MB in `walk`, or clamp the candidate floor to the threshold.

### SV-5 · P2 — Duplicate hashing can't be cancelled + hard links overcount
`fullHash`'s `Task.isCancelled` is always false on dedicated pool threads (no task context) — cancelling a duplicate scan keeps hashing the current multi-GB file to completion. Separately, hard links (same inode) pass byte-verification as "duplicates" and overstate `wastedBytes` — trashing one link frees nothing (known limitation, now confirmed as unhandled).
**Fix:** cancellation flag the hash loop reads per chunk; group candidates by `(st_dev, st_ino)` and auto-keep-one.

### SV-6 · P2 — Post-yield tree mutation
`classifyTree` rewrites `category` on nodes already handed to the UI via `.directoryCompleted` — unsynchronized write to a class rendered by the main actor (low practical severity; becomes moot if SV-9's `progressiveNodes` removal lands).

**Verified clean:** SafetyEngine veto chain & protected-path tables, TrashExecutor pipeline (token gate → TOCTOU → audit), RoboPlanner, HistoryStore (serial queue, tolerant decode), Growth/Health/Radar/Forecast math, SquarifiedLayout, Assistant grounding, AgentTools policy gate. The reviewer's verdict: *"the safety architecture is genuinely well-engineered — the P0 slips past every safety layer because the wrong path is fed in as user-initiated."*

---

## 2. Performance & smoothness

The 1.2 GB memory question, answered: the scan tree itself is only **~40–70 MB** (82k dir nodes + large-file leaves at ~300-400 B each). The rest is **allocator high-water** — transient churn from 742k URL/URLResourceValues/Set allocations, 82k watchdog timers, BFS queues that materialize every URL in package subtrees, and largestFiles materializing every leaf before sorting. malloc keeps those arenas.

### PF-1 · P0 — End-of-scan freeze (the worst-timed jank in the app)
The scan event Task inherits `@MainActor` (AppModel.swift:276-328): every progress event hops to main, and on `.completed` the app runs — synchronously on the main thread — `findCandidates` (full-tree walk + a stat syscall per candidate), `Snapshot.from` (second full traversal), snapshot disk write, then `refreshHistory()` which **re-reads and re-decodes every snapshot JSON from disk** and recomputes growth/radar twice. Estimated 0.5–5 s beachball exactly when results should appear.
**Fix:** consume the stream off-main; hop to main only for state assignment; do candidates/snapshot/IO on a background task; cache loaded snapshots in memory.

### PF-2 · P0 — Duplicate hashing is serialized despite the pool
`for file in group { await pool.run { hash } }` (DuplicateEngine.swift:100,115) awaits one file at a time — the 4-thread pool never has more than one active job. Duplicate scans run at ~25% of available parallelism.
**Fix:** task-group over `pool.run` per file within each size-group (pool still bounds parallelism at 4). ~3-4× faster. Pairs with SV-5's cancellation flag.

### PF-3 · P0 — Files screen: up to ~25,000 stat syscalls per click
`FilesScreen.files` runs `FileManager.fileExists` on all ~300 rows on **every body evaluation**, and `selectedBytes` re-runs the whole filter chain **once per selected row**. Selecting 50 files ⇒ ~15,000 synchronous main-thread stats per render, repeated per interaction.
**Fix:** compute the filtered list once per data/filter change into `@State`; keep a `[id: FileRecord]` dictionary for O(1) selection math. Also: the search filter references a `searchText` state that has **no TextField** — dead code (either add the field or delete the state).

### PF-4 · P0 — Sunburst/treemap rebuild full geometry per mouse-move
Every hover event re-runs `SunburstGeometry.segments` / `SquarifiedLayout.layout` (thousands of Path constructions, ~60 Hz) and re-renders all wedges. Flagship visualization stutters after big scans.
**Fix:** cache segments/rects per (node, size) in `@State`; hit-test the cache; draw hover highlight as a cheap overlay. (Also delete the dead `shadow` Path code, SunburstView.swift:133-139.)

### PF-5 · P1 — Per-directory overhead in the scanner
One `DispatchSourceTimer` created+cancelled per directory listing (~82k/scan) though virtually none fire; each file entry pays `resourceValues(Set(6 keys))` **plus** a second `lstat` that already provides size/mtime/type; `DirectorySizer` pays a pool roundtrip per directory inside every package; `AppAnalyzer` lists Group Containers once **per app** (hoist to once total).
**Fix:** arm watchdog timers lazily (shared 1s sweep); hoist the key Set; single-stat entry typing; submit whole-subtree walks as one pool job that recurses on the worker thread. Combined: large cut of the syscall count and most of the allocator churn behind the 1.2 GB.

### PF-6 · P1 — Main-thread work at other moments
`applyTrashOutcome` (full-tree prune + categoryTotals re-traversal + synchronous history reload) after every trash batch; `AppModel.init` loads all snapshots/records + recomputes radar synchronously before the first frame; progress throttle is count-based (every 24th dir) which can exceed 100 main-actor events/sec at 8-way peak.
**Fix:** background the prune + derive categories by subtracting pruned bytes (the prune already knows them); async history load at launch; time-based progress throttle (150-250 ms).

### PF-7 · P2 — Cheap broad wins
Static cached formatters (`Format.bytes` allocates per call — per row, per progress event); `largestFiles` bounded heap instead of materialize-all-then-sort; sunburst `angleCursor` O(n²) label layout; `progressiveNodes` accumulator is **read by nothing** — delete it (removes thousands of main-actor hops per scan).

---

## 3. UI state correctness (SwiftUI)

- **UI-1 · P1 (introduced in the G20 restructure):** DuplicatesScreen renders `headerBar` twice — once in `body`, once inside `list`. Remove the one in `list`.
- **UI-2 · P1, destructive-adjacent:** duplicate review selections are wiped mid-review — group UUIDs are recreated on every prune, and `onChange(of: model.duplicates)` re-runs keep-newest preselection on **any** mutation (including trash batches from *other* screens). A user who deselected "keep this older copy" can have it re-selected and trashed by the next batch. **Fix:** key selections by file path (stable), preserve deselections, preselect only on scan completion.
- **UI-3 · P1:** Developer/Browser screens pass `isExcluded: false` constant to `CandidateRow` — every candidate shows a green "already selected" checkmark on two destructive-action screens. Wire the real selection state.
- **UI-4 · P2:** `selectedApp` in Apps/Uninstaller is never reconciled after `model.apps` mutates — detail pane can show an already-uninstalled app.
- **UI-5 · P2:** plan-preview sheet dismissed by an arbitrary 1-second sleep; if execution is slower, the sheet vanishes with no feedback (bind dismissal to the model's completion, which already clears `showPlanPreview`).

**Verified OK:** sheet/alert conflicts (none co-present), keyboard shortcuts (no conflicts), onChange signatures, all empty/error states, binding hygiene, assistant focus/scroll.

## 4. Accessibility

- **A11y-1 · P1:** duplicate file selection is an `Image` + `onTapGesture` — not a control: no VoiceOver trait/label/value, no keyboard access, on the screen's core function. Replace with a real Button + label + selected value. (CleanupScreen's `CandidateRow` already does this correctly — copy that pattern.)
- **A11y-2 · P2:** icon-only buttons without labels (uninstaller toggles, exclusions remove, assistant send, ellipsis menu); unlabeled threshold/retention pickers in Settings.

## 5. Virtualization

Cleanup (523 candidates), Duplicates (all groups × files), Uninstaller leftovers render as plain non-lazy `VStack`+`ForEach` in `ScrollView` — every row built eagerly, every toggle re-diffs everything. Use `LazyVStack`/`List`.

---

## The brainstorm — ranked implementation tiers

**Tier 0 · Safety (do first, small):** SV-1 bundle-ID guard (+ protected exact paths) · SV-2 timer-arming order · SV-3 FDA probe through pool. ~Half a day, all TDD-able.

**Tier 1 · The four P0 experience wins:** PF-1 off-main scan pipeline (+ delete `progressiveNodes`) · PF-2+SV-5 parallel hashable hashing with real cancellation · PF-3 Files screen caching (+ dead searchText) · PF-4 cached sunburst/treemap geometry. This is where "laggy" dies.

**Tier 2 · Syscall/allocation diet:** PF-5 (lazy timers, single-stat typing, subtree jobs, GC-listing hoist) + PF-6 (background trash prune, async launch, time-based throttle) + PF-7 (formatters, bounded heap). This is where the 1.2 GB and scan time shrink.

**Tier 3 · UI correctness & a11y:** UI-1..UI-5, A11y-1/2, virtualization, SV-4 (1-10 MB candidates), SV-6.

**Tier 4 · Architectural (roadmap):** scan engine in an XPC child process so all scan memory returns to the OS on completion (DaisyDisk-style); incremental SQLite index + FSEvents (already Phase 1.5) for instant rescans; a "low-power scan" mode; duplicate-result caching keyed by size+mtime.

**Suggested order:** Tier 0 → Tier 1 → UI-1/UI-2 (state bugs on destructive screens) → Tier 2 → Tier 3 → Tier 4 roadmap. Tiers 0+1 are roughly a day of careful TDD work and transform the felt experience.
