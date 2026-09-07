# 05 · Data Design & Engine Rules

## 1. Persistence overview

| Store | MVP implementation | Why |
|---|---|---|
| Scan snapshots | JSON files (one per scan) in `~/Library/Application Support/DiskRobo/history/` | dozens–hundreds of records, human-inspectable, atomic writes, zero migration cost |
| Cleanup audit log | append-only `cleanup-log.jsonl` | per-item journal for crash reconciliation & repeat-offender analysis |
| Settings | `UserDefaults` (Codable blob) | tiny, standard |
| File index (per-file records) | **not persisted in MVP** — scans rebuild in memory | millions of rows need SQLite; persisted index is an accelerator (Phase 1.5), not a correctness dependency |

**SQLite vs Core Data vs GRDB (Phase 1.5):** SQLite via `libsqlite3` (or GRDB on top) — schema-first, raw SQL for set-based diffing (scan N files vs index in one query), no object-graph overhead for millions of rows, trivially testable. Core Data rejected: object-graph overhead and main-context footguns at this scale; GRDB optional as a thin layer later.

## 2. Snapshot schema (v1, Codable)

```
Snapshot {
  id: UUID, date: Date, rootPath: String, isQuickScan: Bool
  volumeTotalBytes / volumeFreeBytes: Int64?
  usedBytes: Int64                      // scanned total
  categories: [category: bytes]
  topDirectories: [path: bytes]         // top 400 by size
  largestFiles: [ {path, size} ] × 100
  appFootprints: [ {name, bundleID, totalBytes} ] × 50   // when app analysis ran
  scanDurationSeconds, filesCount, directoriesCount, inaccessibleCount
}
```
Retention: default keep 120 snapshots (configurable). Snapshots store **metadata only — never file contents** (spec §7).

## 3. Cleanup audit log (JSONL, one record per item)

```
{ date, path, sizeBytes, kind, mechanism: "trash", result: "trashed|blocked|failed", reason? }
```

## 4. Future SQLite index schema (Phase 1.5)

Entities per spec §50:

```sql
volumes(uuid PK, name, is_internal, total_bytes, first_seen, last_seen)
files(file_id PK, volume_uuid FK, path UNIQUE, parent_id, name, is_dir, is_package,
      size_bytes, mtime, category, app_id NULL, hash_status, risk_state, last_indexed)
directories(file_id PK, small_file_count, small_file_bytes)      -- 1:1 with files
applications(app_id PK, bundle_id, name, installed, footprint_json)
file_app_relationships(file_id FK, app_id FK, role)              -- cache|support|container|...
scans(scan_id PK, started, finished, root, kind, stats_json)
scan_snapshots(scan_id FK, path, size_bytes)                     -- top-dir rollups
storage_events(event_id PK, scan_id FK, path, delta_bytes)       -- growth detective input
cleanup_candidates / cleanup_actions / duplicate_groups / recommendations /
rules / exclusions / agent_actions                               -- policy + audit domain
```
Indexes: `files(parent_id)`, `files(path)`, `files(size_bytes DESC)`, `files(app_id)`, `storage_events(scan_id)`. Retention: raw per-file rows pruned for volumes unseen 90 days; aggregates retained indefinitely (bounded by snapshot retention).

## 5. Cleanup rule inventory (MVP)

Each rule: trigger root → candidate kind → risk → confidence → explanation → impact → canReturn.

| Rule (root) | Kind | Risk | Conf. | Explanation summary | Returns |
|---|---|---|---|---|---|
| `~/Library/Caches/*` | cache | 🟢 | Very High | App cache; apps rebuild automatically | Yes |
| `/Library/Caches/*` | cache | 🟢 | High | System-wide app cache | Yes |
| `~/Library/Logs/*`, `/Library/Logs/*` | log | 🟢 | High | Rotated/obsolete logs | Yes |
| `~/Library/Developer/Xcode/DerivedData/*` | derivedData | 🟢 | High | Generated build artifacts; next build regenerates (slower) | Yes |
| `~/Library/Developer/Xcode/iOS DeviceSupport/*` | deviceSupport | 🟢 | Medium | Device symbol caches; re-created on reconnect | Yes |
| `~/Library/Developer/CoreSimulator/Caches/*` | simulatorCache | 🟢 | High | Simulator caches (device data **not** touched) | Yes |
| `~/.npm/*`, `~/.cache/*` | packageCache | 🟢 | High | Package-manager download caches | Yes |
| `~/.Trash/*` | trash | 🟢 | High | Already-trashed items; emptying Trash is user's decision | No |
| `~/Downloads/*.dmg|pkg` age > 30 d | oldInstaller | 🟡 | High | Installers likely already used; re-downloadable | Yes |
| `~/Downloads/*` (any file) age > 90 d | oldDownload | 🟡 | Medium | Not modified in 90 days | Yes |
| `~/Downloads/*.zip|rar|7z|tar…` age > 90 d | oldArchive | 🟡 | Medium | Old archives in Downloads | Yes |
| Xcode Archives | archive | 🟠 | Medium | May be needed for App Store submissions | No |
| App leftovers (AppAnalyzer) | leftover | 🟠 | Medium | Data from apps no longer installed; ambiguous names require review | No |
| Duplicates (DuplicateEngine) | duplicate | 🟡 | Medium | Byte-identical copies; keep-one enforced in UI | No |

Minimum candidate size: 1 MB (noise control). Never green merely because large.

## 6. Duplicate pipeline

```
collect files ≥ minSize (default 1 MB; scoped to Downloads / home / custom)
→ group by exact size (groups of 1 discarded)
→ hash first 64 KB (SHA-256) → regroup
→ full-content SHA-256 (1 MB chunks) → verified equal
→ DuplicateGroup { files, wastedBytes = size × (n−1) }
```
No expensive hashing without a size match; partial hash avoids full reads of same-size-but-different files. Cancellation checked at every stage.

## 7. Growth math

`StorageDelta = diff(snapshotA, snapshotB)` over categories, top directories, volume free space. Narratives: biggest grower, biggest shrink, net trend, per-category arrows. Phase-2 forecast: ordinary-least-squares on daily `usedBytes` with R²-gated confidence ranges ("at recent growth, < 20 GB free in ~17 days ± range") — never presented when data is insufficient.

## 8. Disk Health Score (0–100)

Weighted, deterministic, and **explained** (never claimed as scientific):

| Factor | Weight | Scoring |
|---|---|---|
| Free-space ratio | 40 % | ≥ 30 % → 100 · 15 % → 80 · 10 % → 55 · 5 % → 25 · ≤ 2 % → 0 (piecewise linear) |
| Green-recoverable ratio | 20 % | 100 − ratio×600 (clamped) — junk accumulation lowers health |
| Duplicate ratio | 15 % | 100 − ratio×500 (clamped) |
| Growth trend (7 d) | 15 % | negative → 100 · +1 % → 75 · +3 % → 40 · ≥ +5 % → 0 |
| Trash + log ratio | 10 % | 100 − ratio×800 (clamped) |

Factors with insufficient data (e.g., no history yet) are excluded and weights renormalized. UI shows each factor's contribution and the dominant issue ("Developer caches are consuming 47 GB").
