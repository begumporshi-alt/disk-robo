# Tier 4 — Storage Intelligence · Design Spec · 2026-09-07

Approved decisions: **SQLite first · FSEvents while app active · warm start with staleness indicator · child-process scan isolation.** Sequence: SQLite foundation (+ warm start) → gentle scan → FSEvents reconcile → child-process scanner. Each lands independently, TDD, verified live.

## 1. SQLite storage index (foundation)

**Goal:** warm start (full dashboard instantly on launch from the last scan), queryable history, and the substrate FSEvents updates.

**Approach:** system libsqlite3 (no dependencies), one database at `~/Library/Application Support/DiskRobo/index.sqlite`, owned by a new RoboCore type `StorageIndex` (serial queue + WAL, same concurrency pattern as HistoryStore). RoboCore links sqlite3 via Package.swift.

**Schema (v1):**
- `meta(key, value)` — schema version, latest scan id.
- `scans(id, started_at, duration, label, is_quick, root_path, files, dirs, total_bytes, volume_total, volume_free, payload)` — one row per scan; scalar columns cover what Growth/Radar query; `payload` holds the rest of today's `Snapshot` as JSON (reuses the Codable struct; cheap migration).
- `tree_nodes(path PK, parent_path, name, kind, size, category, file_count, dir_count, small_file_count, small_file_bytes, mtime)` — the LATEST scan's tree only, transactionally replaced on each completed scan. ~100k rows ≈ 15 MB, one copy, not per-scan (per-scan would be ~1.8 GB at retention 120).
- `cleanup_log(id, date, path, size_bytes, kind, mechanism, result, reason, trash_path)` — replaces `cleanup-log.jsonl`.

**API:** `recordScan(Snapshot)`, `loadSnapshots()`, `saveTree(root:scanInfo:)`, `loadTree()`, `recordCleanup(CleanupActionRecord)`, `loadCleanupRecords()`, `deleteAllHistory()`, one-time legacy import (existing JSON snapshots + JSONL log; JSON files then left in place for safety, reads switch to SQLite).

**Integration:** `finishScan` saves the tree (transaction, off-main; ~1-2 s for 100k inserts) alongside the snapshot. `AppModel.init` warm-starts: `loadTree()` → reconstruct tree → recompute candidates/health/insights/radar off-main → dashboard renders with `warmStarted = true`. Staleness UI: Overview banner "Showing the scan from X hours ago — Rescan for fresh data," cleared on the next scan. Corrupt/missing DB never blocks the app (warm start silently skipped).

**Testing:** temp-DB round-trips (tree fidelity incl. small-file aggregates + packages, snapshots, cleanup log), retention pruning, legacy import, corrupt-file resilience, concurrent record+read.

## 2. Gentle scan mode (quick win)

New setting `scanGentleMode` (Settings toggle + entry in the scan menus). When on: `maxConcurrentDirectoryWalks` 8→2, scan task QoS `.utility`→`.background`, hash pool width 4→1 (pool parameterized). Adds ~10-20% wall time; leaves the Mac quiet — for battery use.

## 3. FSEvents reconcile (while app active)

`FSEventsStore` (RoboCore): stream on the scan roots, `kFSEventStreamEventFlagSinceNow`, 2 s latency, coalescing. Only runs while the main window exists (started with the app, stopped when the app terminates — menu-bar-only life does not monitor). Events map to path-level deltas applied to: the in-memory tree (size/count adjustments up the ancestor chain — same delta math as `removeDescendants`), `tree_nodes` (upsert/delete), and the recomputed derived layers (throttled recompute at ≤1 Hz). A "rescan" after monitored changes becomes a fast reconcile: trust the tree for untouched subtrees, walk only changed paths. Correctness guard: every Nth manual scan is a full walk to re-anchor (drift repair); if the app wasn't running during changes, the next launch's warm start is marked stale and the reconcile falls back to a full scan when paths disagree.

## 4. Child-process scanner (memory return)

New SPM executable `DiskRoboScanner`: reads a JSON request (roots, options incl. exclusions + timeout + gentle flags) on stdin, streams JSONL events on stdout (`progress`, `tree-node` batches, `completed` with aggregates), exits 0. All watchdog/blocking-dir machinery lives in the child (it already never blocks the parent's threads). The parent (`AppModel.startScan`) spawns it via `Process`, parses the stream off-main, and materializes the tree — the parent's retained memory is the ~40-70 MB tree, while the ~1.1 GB scan churn high-water dies with the child on exit. Timeout + crash handling: parent watchdog kills the child after `scan timeout × 4`; child non-zero exit → `.failed` with the message. Build script copies the executable into the .app bundle (Contents/MacOS or Helpers with a known relative path). Rollout: behind a setting (`scanInChildProcess`, default ON after verification) so the in-process path remains a fallback.

## Error handling & security (all components)

DB errors degrade to today's behavior (no warm start, no history — never a crash). The child process inherits the parent's TCC/FDA context as a child of the app. No networking anywhere. Deletion paths unchanged — all four components are read/analyze only.
