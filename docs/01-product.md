# 01 · Product

## 1. Vision

Disk Robo acts like an intelligent storage engineer living inside the Mac. A traditional cleaner says:

> "Downloads = 24 GB"

Disk Robo says:

> "Downloads is using 24 GB. ~13.6 GB appears recoverable. Most growth came from DMG installers and ZIP archives during the last 30 days. Seven files haven't been opened in more than 90 days. You can safely review these files and potentially recover 11.8 GB."

Positioning: **Finder + DaisyDisk + Storage Settings + system diagnostics + intelligent cleanup + an AI storage agent** — but simpler than any of them. The dashboard answers one question: *"Why is my Mac running out of space?"*

The workflow transforms **Scan → Delete** into **Observe → Understand → Diagnose → Predict → Recommend → Approve → Act → Verify → Learn**.

## 2. Core promise

Within seconds of opening Disk Robo the user understands: how much storage is available, where it is going, what recently grew, which apps consume hidden storage, which files are unusually large, duplicated, or unused, which caches are safe, how much is recoverable, what is safe vs. dangerous to delete, which consumers repeatedly grow, and what Disk Robo recommends doing next.

## 3. Personas

| Persona | Profile | Primary need |
|---|---|---|
| **Maya — Creative Professional** | Video editor, Final Cut + Photoshop; 1 TB nearly full | "Give me 50 GB before my next shoot" — Target Cleanup, render-cache awareness |
| **Dev — Developer** | Xcode, Docker, node, Python; storage eaten by build artifacts | Developer Storage Intelligence: DerivedData, simulators, package caches — with build-time impact warnings |
| **Sam — Everyday User** | Non-technical; "System Data" mystery | Plain-language explanation, one-click safe cleanup, zero risk of losing photos |
| **Priya — Power User** | Multi-drive, automation-minded | Exclusions, thresholds, history diffs, precise explorer, repeat-offender tracking |

## 4. Pain points

1. macOS "System Data" is opaque and scary.
2. Cleaner apps lie — fake "junk" numbers, fear-based upsells.
3. Deletion feels dangerous; no explanation of consequences.
4. Storage fills back up and nobody says *why* or *which app* regrew it.
5. Full-disk scans are slow, block the UI, and must be repeated from scratch.
6. Developer storage (DerivedData, simulators, Docker, package caches) is invisible to normal tools.
7. Downloads become a graveyard of DMGs and duplicate archives.
8. Uninstalled apps leave gigabytes of leftovers.

## 5. Competitive positioning

| | Storage Settings | DaisyDisk / GrandPerspective | CleanMyMac | **Disk Robo** |
|---|---|---|---|---|
| Visualization | minimal | excellent | basic | sunburst + drill-down |
| Explainability | none | sizes only | claims, opaque | **every recommendation explained** |
| Safety model | trusted-delete only | manual delete | proprietary | **deterministic 4-level risk engine, veto power** |
| History / growth | none | none | none | **snapshots, timeline, "where did my space go"** |
| App intelligence | category only | none | some | **per-app footprint incl. hidden library data** |
| Dev storage | none | none | some | **first-class** |
| Agentic planning | none | none | "Smart" button | **target-aware plans, approval-gated actions** |
| Privacy | local | local | cloud components | **local-first, metadata-only, zero network** |

## 6. Unique value proposition

**The only Mac storage tool that explains *why* storage is consumed, proves *whether* it is safe to remove, remembers *how* it changed over time, and safely executes approved plans — locally, with no data ever leaving the Mac.**

Differentiators: Storage Knowledge relationships (app ↔ cache ↔ file ↔ growth) · Storage Memory · Growth Detective · Repeat Offenders · Target Cleanup ("find me 50 GB") · Robo Radar anomalies · Explainable cleanup · Agentic planning with deterministic safety veto · Developer storage intelligence · Predictive storage (Phase 2).

## 7. Feature inventory

| Feature | Phase |
|---|---|
| Native SwiftUI app shell, sidebar navigation | MVP ✅ |
| Async, cancellable, progressive disk scanner | MVP ✅ |
| Storage categorization engine | MVP ✅ |
| Sunburst storage map with drill-down | MVP ✅ |
| Largest-file explorer + Quick Look + Reveal | MVP ✅ |
| Cleanup candidate detection (rules) | MVP ✅ |
| 4-level safety classification + protected paths | MVP ✅ |
| Quick / Smart / Deep / Target cleanup modes | MVP ✅ |
| App footprint analysis + leftovers detection | MVP ✅ |
| Duplicate detection (size → partial hash → full hash) | MVP ✅ |
| Scan history snapshots + growth timeline | MVP ✅ |
| Robo recommendations + Disk Health Score | MVP ✅ |
| Safe move-to-Trash with TOCTOU re-verification + audit log | MVP ✅ |
| Permissions onboarding (Full Disk Access) | MVP ✅ |
| Exclusions, thresholds, retention settings | MVP ✅ |
| Robo Radar (anomalies) | P2 |
| Repeat Offenders register | P2 |
| Natural-language Robo Assistant | P2 |
| Predictive storage forecast | P2 |
| Automation rules (observe/recommend/act tiers) | P2 |
| System notifications | P2 |
| Menu bar companion | P2 |
| Robo Uninstall (full app removal flows) | P2 |
| External/network volume intelligence | P2 |
| SQLite incremental index + FSEvents background intelligence | P1.5 |
| Multi-Mac insights, archival recommendations, plugins, local ML | P3 |

## 8. MVP scope

The 15 MVP items from spec §46 — implemented in this repository (status in [07-mvp-phases.md](07-mvp-phases.md)). Explicitly **not** in MVP: LLM features, radar anomaly engine, forecasts, automation, menu bar, uninstall flows, incremental index.

## 9. Roadmap

- **MVP** — correct storage engine, safe cleanup, history. Ship it.
- **Phase 1.5** — SQLite storage index; incremental rescans driven by FSEvents; metadata caching.
- **Phase 2** — Robo Radar, Repeat Offenders, NL assistant driving the existing typed tool layer, forecasts, automation rules, notifications, menu bar, Robo Uninstall.
- **Phase 3** — Mac Storage Intelligence Platform: multi-Mac, external intelligence, archival recommendations, plugin architecture, richer local ML.

## 10. Business model

Free: visualization, basic scan, large-file analysis, limited Quick Clean. Pro (one-time purchase + optional major upgrades, or subscription): RoboOS intelligence, history, radar, duplicates, automation, developer analysis, assistant. No fake warnings, no crippled scares — **trust over short-term conversion**.

## 11. Success metrics

Time-to-first-insight (< 10 s to volume + health state; < 60 s to first full-home result) · scan completion performance · storage identified vs. actually recovered · cleanup failure rate · false-positive recommendation rate (target 0) · crash-free sessions · recommendation acceptance · permission abandonment · background resource impact. **North star: zero preventable user-data-loss incidents.**
