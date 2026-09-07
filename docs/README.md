# Disk Robo — Documentation

> An **Agentic Storage Operating System for macOS**: it observes storage, explains what is consuming it, diagnoses what is unnecessary, recommends safe actions, and — only with explicit approval — acts, verifies, and learns.

## Document map

| File | Contents |
|---|---|
| [01-product.md](01-product.md) | Vision, intelligence levels, personas, pain points, competitive positioning, UVP, feature inventory, roadmap, business model, success metrics, non-negotiables |
| [02-ux.md](02-ux.md) | Information architecture, screen map, user journeys, UX flows, wireframe descriptions, design system, Robo Core concept, accessibility |
| [03-architecture.md](03-architecture.md) | Technical architecture, module dependency graph, agent & tool architecture, Robo Planner flow, scanning engine, incremental index plan, APFS awareness, performance strategy, edge-case analysis, dependency gap register |
| [04-safety-privacy.md](04-safety-privacy.md) | Permission architecture, privacy model, security threat model, risk-classification framework, safety rules, deletion pipeline, crash recovery, telemetry policy |
| [05-data.md](05-data.md) | Persistence design & justification, snapshot schema, action log, future SQLite index schema, cleanup rule inventory, duplicate pipeline, growth math, Disk Health Score formula |
| [06-errors-testing-release.md](06-errors-testing-release.md) | Error-state matrix, testing strategy, quality gates, release/signing/notarization, metrics |
| [07-mvp-phases.md](07-mvp-phases.md) | MVP scope, implementation phases with full engineering artifacts, Phase 2/3 outline, current build status |

## Coverage of the 30 required product documents

| # | Required document | Where |
|---|---|---|
| 1 | Product vision | 01 §1 |
| 2 | Target-user personas | 01 §3 |
| 3 | User pain points | 01 §4 |
| 4 | Competitive positioning | 01 §5 |
| 5 | Unique value proposition | 01 §6 |
| 6 | Complete feature inventory | 01 §7 |
| 7 | MVP scope | 01 §8, 07 §1 |
| 8 | Future roadmap | 01 §9, 07 §5–6 |
| 9 | User journeys | 02 §3 |
| 10 | Information architecture | 02 §1 |
| 11 | Screen map | 02 §2 |
| 12 | UX flows | 02 §4 |
| 13 | Wireframe descriptions | 02 §6 |
| 14 | Design system | 02 §5 |
| 15 | Technical architecture | 03 §1–3 |
| 16 | Module dependency graph | 03 §2, §10 |
| 17 | Agent architecture | 03 §4 |
| 18 | Tool architecture | 03 §5 |
| 19 | Permission architecture | 04 §1 |
| 20 | Safety architecture | 04 §4–6 |
| 21 | Database schema | 05 §3–4 |
| 22 | Filesystem scanning architecture | 03 §7 |
| 23 | Cleanup rules | 05 §5 |
| 24 | Risk-classification framework | 04 §3 |
| 25 | Error-state matrix | 06 §1 |
| 26 | Performance strategy | 03 §9 |
| 27 | Privacy model | 04 §2 |
| 28 | Security threat model | 04 §7 |
| 29 | Testing strategy | 06 §2 |
| 30 | Release architecture | 06 §4 |

## The five levels of intelligence

1. **Observe** — what exists on disk (Storage Mapper).
2. **Explain** — what is consuming storage (classification, sunburst map, app footprints).
3. **Diagnose** — what is unnecessary, duplicated, abandoned, or growing (Cleanup, Duplicate, Growth detectives).
4. **Recommend** — safe actions with confidence and explanation (Robo Planner, Safety Guardian).
5. **Act** — approved, verified, reversible cleanup (Trash Executor, audit log).

## Non-negotiable rules (spec §58)

Never silently delete important user data · never bypass macOS security · never pretend inaccessible data was scanned · never classify uncertain files as safe · never fabricate recovered-space numbers · never let an AI model independently authorize destructive operations · never hide what cleanup will do · never upload private file information without permission · never block the UI during scanning · never rescan the whole disk unnecessarily · never use fear-based fake warnings.
