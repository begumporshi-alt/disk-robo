# Disk Robo

A native macOS agentic storage operating system — an interactive sunburst map of everything on your disk, a safe cleanup pipeline that explains every recommendation, and an on-device assistant that answers "where did my space go?"

macOS 14+ · Swift 5.9 · SwiftUI · zero networking · all analysis on-device

---

## Install

### Option A — Download a pre-built release

Go to [**Releases**](https://github.com/begumporshi-alt/disk-robo/releases) and download the latest `DiskRobo.app.zip`. Unzip, drag `DiskRobo.app` into `/Applications`, and open it.

**First launch — macOS Gatekeeper:**
Because the app is ad-hoc signed (no Apple Developer ID yet), macOS will show a "cannot be opened because the developer cannot be verified" alert. To dismiss it:

1. Right-click (or Control-click) `DiskRobo.app` and choose **Open**
2. Click **Open** in the confirmation dialog

macOS will remember this exception and open normally from now on.

**Full Disk Access:**
Disk Robo needs Full Disk Access to measure system directories. On first launch, a guided onboarding screen will walk you through granting it in **System Settings → Privacy & Security → Full Disk Access**. The app will never function without explicitly granted, user-revocable permission.

### Option B — Build from source

**Prerequisites:**
- macOS 14 Sonoma or later
- [Xcode](https://apps.apple.com/us/app/xcode/id497799835) (the Command Line Tools alone won't work — the app uses CoreGraphics for icon generation)

Then run:

```bash
git clone https://github.com/begumporshi-alt/disk-robo.git
cd disk-robo
./Scripts/build-app.sh release
open build/DiskRobo.app
```

The script builds in release mode, generates the app icon, creates the `.app` bundle, and signs it ad-hoc. Grant Full Disk Access when prompted.

---

## What's inside

| Component | What it does | Module |
|---|---|---|
| **Sunburst storage map** | Two-ring interactive chart of your disk by category and subfolder; hover tooltips, click to drill down, center hub goes up a level | `Sources/DiskRobo/SunburstView.swift` |
| Async, cancellable, memory-bounded disk scanner | Progressive results as files are found, bounded parallelism, symlink-safe, honest inaccessibility reporting | `RoboCore/ScanEngine.swift` |
| Deterministic storage categorization | 13 rules-based categories — every file classified by path, never guessed | `RoboCore/ClassificationEngine.swift` |
| Safety-first cleanup pipeline | Every recommendation is explained: what / why / impact / can it return / confidence score; deletion always goes to Trash, never permanent removal | `RoboCore/CleanupEngine.swift` · `RoboCore/RoboPlanner.swift` |
| Duplicate finder | Partial + full file hashing, size-sorted groups, recommended "keep" per group, wastage estimate | `RoboCore/DuplicateEngine.swift` |
| App footprints + uninstaller | Per-app storage breakdown (binaries, caches, containers, leftovers) with uninstall-safe paths | `RoboCore/AppAnalyzer.swift` |
| Health score + radar | 0–100 disk health score with a ranked list of actionable findings | `RoboCore/HealthScore.swift` · `RoboCore/RadarEngines.swift` |
| Growth tracker | Week-over-week storage growth with chart and top-growing paths | `RoboCore/GrowthAnalyzer.swift` |
| SQLite warm-start index | Next launch shows your last scan instantly in the dashboard (no re-scan needed) | `RoboCore/StorageIndex.swift` |
| Live reconcile via FSEvents | Dashboard updates seconds after files change on disk — no scan required | `RoboCore/FSEventsMonitor.swift` · `RoboCore/TreeReconciler.swift` |
| Child-process scanner | Scanning runs in a separate process so memory returns to the OS when it finishes; in-process fallback if the binary is missing | `RoboCore/ChildProcessScanner.swift` |
| On-device assistant | Rule-based natural-language interface for exploring your storage; never sends data anywhere | `RoboCore/Assistant.swift` |

---

## Project structure

```
disk-robo/
├── Sources/RoboCore/       # All engines — pure Swift, no UI, no networking
│   ├── Models.swift        # StorageNode, ScanResult, categories
│   ├── ScanEngine.swift    # async disk walk, bounded parallelism
│   ├── StorageIndex.swift  # SQLite warm-start + scan history
│   ├── ChildProcessScanner.swift
│   └── … (15 more modules)
├── Sources/DiskRobo/       # SwiftUI app
│   ├── AppModel.swift      # single @MainActor orchestrator
│   ├── DiskRoboApp.swift   # app shell + AppDelegate frame guard
│   ├── SunburstView.swift  # sunburst + tooltips + breadcrumbs
│   ├── OverviewScreen.swift
│   ├── SmartToolsScreens.swift
│   └── … (10 more screens)
├── Sources/DiskRoboScanner/ # child-process scanner executable
├── Tests/RoboCoreTests/    # 97 tests
├── Scripts/
│   ├── build-app.sh        # builds the .app bundle
│   └── generate-icon.swift # programmatic app icon
├── Resources/AppIcon.icns
├── docs/                   # 7 product spec documents
└── .github/workflows/release.yml
```

---

## Contributing

1. Fork the repo and create a feature branch
2. Make your changes — follow the existing conventions (dark theme, `DashboardCard`, `StatCard`, 4-level risk badges with color+symbol+label)
3. Ensure `swift test` passes with 97/97 tests green
4. Open a pull request against `main`

Key invariants you must not break:
- Deletion is always `FileManager.trashItem` — never permanent removal
- SafetyEngine has veto power over all deletion; protected trees are never deletable
- No networking code anywhere in the app
- No blocking of Swift cooperative threads on filesystem calls

---

## License

This project is private source-available software. Do not redistribute without permission.
