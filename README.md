# Disk Robo

**An Agentic Storage Operating System for macOS.**

Disk Robo doesn't just show what uses disk space — it explains *why* storage is consumed, proves *whether* it is safe to remove, remembers *how* it changed over time, and safely executes approved cleanup. All local. All metadata. Zero network.

> "Downloads is using 24 GB. ~13.6 GB appears recoverable. Most growth came from DMG installers and ZIP archives during the last 30 days…"

## What's implemented

### Phase 2 — intelligence layer (✅ built)

| Capability | Where |
|---|---|
| **Robo Radar** — ranked anomalies (severity × recoverable × confidence × recurrence × risk) | `RoboCore/RadarEngines.swift` |
| **Repeat Offenders** — cleaned-then-regrown locations with weekly growth rates | `RoboCore/RadarEngines.swift` |
| **Storage Forecast** — OLS projection with honest confidence; refuses to guess with <3 snapshots | `RoboCore/RadarEngines.swift` |
| **Robo Assistant** — on-device natural language over the engine (no LLM, no network): "why is my disk full?", "can I safely free 20 GB?", "what is Xcode using?" — plans but never deletes | `RoboCore/Assistant.swift`, `Sources/DiskRobo/SmartToolsScreens.swift` |
| **Menu bar companion** — free space, health, top finding, quick actions | `Sources/DiskRobo/DiskRoboApp.swift` |
| **System notifications** — threshold alerts only, opt-out in Settings | `Sources/DiskRobo/NotificationManager.swift` |
| **Robo Uninstall** — per-component app removal review through the safety engine | `RoboCore/AppAnalyzer.swift` (components), Uninstaller screen |

### MVP (Phase 1)

| Capability | Where |
|---|---|
| Async, cancellable, memory-bounded disk scanner (progressive results, bounded parallelism, symlink-safe, honest inaccessibility reporting) | `RoboCore/ScanEngine.swift` |
| Deterministic storage categorization (13 categories) | `RoboCore/ClassificationEngine.swift` |
| Interactive sunburst storage map with drill-down, hover tooltips, go-up hub | `Sources/DiskRobo/SunburstView.swift` |
| Largest-file explorer with filters, Quick Look, Reveal, safe trash | `Sources/DiskRobo/FilesScreen.swift` |
| Rule-driven cleanup candidates — every item explained (what / why / impact / can-return / confidence) | `RoboCore/CleanupEngine.swift` |
| 4-level safety classification (Green/Yellow/Orange/Red) + hard-protected paths | `RoboCore/SafetyEngine.swift` |
| Cleanup modes: Quick · Smart · Deep · Target ("find me 30 GB") | `RoboCore/RoboPlanner.swift` |
| Duplicate detection: size → 64 KB partial hash → full SHA-256 (byte-verified only) | `RoboCore/DuplicateEngine.swift` |
| Per-app footprints (bundle, support, caches, containers, logs) + leftovers of removed apps | `RoboCore/AppAnalyzer.swift` |
| Storage Memory: snapshots, cleanup audit log, A/B diff — "where did my space go?" | `RoboCore/HistoryStore.swift`, `RoboCore/GrowthAnalyzer.swift` |
| Disk Health Score (explained, weighted, never fake-precise) | `RoboCore/HealthScore.swift` |
| Robo Insights feed | `RoboCore/InsightsEngine.swift` |
| Safe move-to-Trash pipeline: preview → approval token → TOCTOU re-verification → per-item safety validation → audit log → verified outcome | `RoboCore/TrashExecutor.swift` |
| Agent tool layer + policy gate (foundation for the Phase-2 natural-language assistant) | `RoboCore/AgentTools.swift` |
| Permissions onboarding with honest Full Disk Access explanation | `Sources/DiskRobo/OnboardingScreen.swift` |

## Build & run

```bash
swift build            # debug build
swift test             # 41 engine/safety tests
./Scripts/build-app.sh # release .app bundle (build/DiskRobo.app)
open build/DiskRobo.app
```

Requirements: macOS 14+, Xcode 15+/Swift 5.9+. For complete coverage of protected user-library locations, grant **Full Disk Access** to Disk Robo after first launch — without it, those folders are reported as inaccessible (never estimated).

## Safety model (the point of the product)

- **Deletion is always move-to-Trash.** Disk Robo never permanently deletes and never empties the Trash.
- **SafetyEngine has veto authority** over every destructive operation, from any component. System files, Mail, Messages, Keychains, iCloud Drive, Group Containers, Safari data, and backups are hard-protected — no flow can delete them.
- **Engine proposals are allowlisted** to known cache/build locations; anything else requires explicit per-item user selection (still veto-checked).
- **Symlink-escape protection** (resolved-path allowlist checks) and **TOCTOU re-verification** (size + mtime fingerprint re-checked immediately before trashing; mismatch blocks the item).
- **Approval tokens** are single-use, path-bound, and expire in 5 minutes. No LLM or agent can authorize deletion — only the user's explicit confirmation can.
- **Every trashed item is journaled** (`cleanup-log.jsonl`) for crash reconciliation and history.

## Architecture

```
DiskRobo (SwiftUI app)  →  AppModel (@MainActor orchestrator)
                             ↓
RoboCore (library)  →  RoboOS layer: RoboPlanner · AgentTools · PolicyEngine · Insights · HealthScore
                        Engines: Scan · Classification · Cleanup · Duplicates · Apps · Growth · History
                        Safety: SafetyEngine (veto authority) · TrashExecutor (only deletion path)
```

Full documentation lives in [`docs/`](docs/README.md) — 7 files covering the 30 required product documents (vision, UX flows, architecture, safety/privacy threat model, data design, error matrix, phased plan).

## Roadmap

- **Phase 1.5** — SQLite incremental index + FSEvents-driven rescans
- **Phase 2** — Robo Radar (anomalies), Repeat Offenders, natural-language Robo Assistant (over the existing typed tool layer), forecasting, automation rules, notifications, menu bar, Robo Uninstall
- **Phase 3** — Mac Storage Intelligence Platform (multi-Mac, external intelligence, plugins)

## Non-negotiables honored

Never silently delete user data · never bypass macOS security · never pretend inaccessible data was scanned · never classify uncertain files as safe · never fabricate recovered-space numbers · never let an AI authorize destructive operations · never hide what cleanup will do · never upload private file information (no networking code exists) · never block the UI during scanning.
