# 04 · Safety, Permissions & Privacy

Safety is a first-class feature. The Safety Engine has **veto authority over every destructive operation** proposed by any other component — planner, agent, or UI.

## 1. Permission architecture

- **Full Disk Access (FDA)** — required to measure protected user-library locations (Mail, Safari data, Containers of other apps, MobileSync backups). Probed honestly by attempting to list `~/Library/Safari`; status reported as *granted / not detected*, never guessed. Onboarding explains scope verbatim: *"Full Disk Access allows Disk Robo to measure storage used by applications and protected user-library locations. Disk Robo does not upload scanned file information — it contains no networking code."*
- **Without FDA** the app still works: accessible areas scan normally; protected subtrees appear as *inaccessible* nodes with counts — never silently skipped, never estimated (spec §58: never pretend inaccessible data was scanned).
- **Sandbox decision:** the MVP ships **non-sandboxed** (direct distribution, notarized). Rationale: a storage analyzer must read broadly across the user domain; sandboxing would restrict scans to user-selected folders, crippling the product promise. If App Store distribution is ever pursued, the fallback design is user-selected folders + security-scoped bookmarks — the engine already accepts arbitrary roots, so this is a packaging change, not a rewrite.
- **Never bypass:** no TCC workarounds, no helper daemons to dodge permissions, no attempts on SIP-protected paths.

## 2. Privacy model

**Local-first, metadata-only, zero network.** The MVP literally contains no networking code. Analysis uses filename, extension, path, size, timestamps, hashes, app relationships — never file *contents* (hashing reads bytes but emits only digests). Cloud AI would be opt-in and clearly labeled if ever added. Telemetry: none in MVP; if ever introduced, anonymous product-level events only — never filenames, paths, or folder structures (spec §43).

## 3. Risk-classification framework

| Level | Meaning | Examples | Automation |
|---|---|---|---|
| 🟢 **Green — Generally safe** | Disposable or auto-regenerable | caches, temp files, DerivedData, package-manager caches, obsolete logs, Trash contents | Offered in Quick Clean; still user-approved |
| 🟡 **Yellow — Review recommended** | Probably unused, user should glance | old downloads, installers, old archives | Offered with review; never in Quick Clean |
| 🟠 **Orange — Potentially important** | May cost time/data to recreate | project assets, app databases, backups, VM images, cloud placeholders, app leftovers | Listed for investigation; never auto-planned; explicit per-item selection only |
| 🔴 **Red — Protected** | Never touched | `/System`, `/usr`, `/private/var/db`, `~/Library/Mail`, `~/Library/Messages`, Keychains, iCloud Drive (`Mobile Documents`), Group Containers, Safari data, MobileSync backups, active system structures | **Hard veto — no user path can authorize engine deletion of these in bulk flows** |

Classification is deterministic (path tables + rules). Risk is *never* inferred from size alone ("never classify as safe merely because it is large").

Confidence is categorical (Very High / High / Medium / Low) derived from rule specificity — no fake numeric precision.

## 4. Safety rules (deterministic)

1. **Allowlist for engine-proposed deletion.** Only: `~/.Trash/**`, `~/Library/Caches/**`, `/Library/Caches/**`, `~/Library/Logs/**`, `/Library/Logs/**`, `~/Library/Developer/Xcode/DerivedData/**`, `~/Library/Developer/Xcode/iOS DeviceSupport/**`, `~/Library/Developer/CoreSimulator/Caches/**`, `~/.npm/**`, `~/.cache/**`, and files directly inside `~/Downloads/**`. Everything else requires explicit user selection in the UI (which still passes protected-path veto).
2. **Protected-path denylist** (always veto, even user-selected): system volumes/dirs, keychains, Mail/Messages, iCloud Drive, Group Containers, Safari containers, MobileSync backups, volume roots, home directory itself.
3. **Symlink-escape check:** every target is resolved (`resolvingSymlinksInPath`); the *resolved* path must satisfy the allowlist. A "cache" symlink pointing into Documents is vetoed.
4. **TOCTOU re-verification:** each item is fingerprinted (size + mtime + path) when discovered and re-stat'd immediately before trashing; any mismatch blocks that item ("changed since scan — re-run the scan").
5. **Approval tokens:** plan execution requires a token issued by explicit UI confirmation, bound to the exact approved path set, single-use, 5-minute expiry.
6. **Path normalization:** `/private` prefix equivalence and `..` normalization applied before every comparison; minimum depth checks prevent engine-initiated deletion of shallow/user-root paths.
7. **Exclusions are global:** user-excluded paths are removed from scans, candidates, duplicates, and plans — enforced in `ScanOptions` and re-checked at validation time.

## 5. Deletion pipeline

```
discover → fingerprint (size, mtime, path)
        → plan (risk-ranked, explained)
        → PREVIEW (user sees items, sizes, risk, impact — nothing hidden)
        → explicit confirm  → ApprovalToken(paths, 5 min)
        → for each item: re-stat (block on mismatch) → SafetyEngine.validate (veto possible)
                       → FileManager.trashItem → audit record → verify original gone
        → outcome: freed / blocked (reasons) / failed (reasons)
```

Reversibility: deletion is always **move-to-Trash** — Disk Robo never empties the Trash and never `rm`s. Audit log records timestamp, original path, size, mechanism, and outcome for every item (spec §14).

## 6. Crash recovery

No multi-item filesystem transactions exist (by design — each trash op is atomic and immediately journaled). On relaunch after a crash mid-cleanup: the audit log (JSONL, appended per item *after* each success) is the source of truth; the UI compares records against the filesystem and reports honestly — never assuming an unrecorded deletion succeeded or failed. Snapshot reconciliation marks prior scans stale.

## 7. Security threat model

| Threat | Vector | Mitigation |
|---|---|---|
| Symlink swap | attacker replaces cache dir with link to documents | resolved-path allowlist check at execution time |
| TOCTOU race | file swapped between scan and delete | fingerprint re-verification immediately before trash |
| Path traversal | `..`/normalization tricks | `standardizingPath` + prefix comparison on normalized paths |
| Agent overreach | rogue/incorrect tool proposal | typed tools only (no shell), PolicyEngine, approval tokens, SafetyEngine veto |
| DB tampering | history poisoning | history is advisory-only, never a deletion authority; validation always re-stats the live filesystem |
| Data exfiltration | "cloud cleaner" pattern | zero networking code; metadata-only processing |
| Purgeable misreporting | over-promising freed space | freed bytes are measured (re-stat), not fabricated; purgeable space explained as system-managed |
| External volume yank | deletion on wrong volume | volume keyed by UUID at snapshot time; re-stat fails safely if unmounted |
| Fake precision | inflated recoverable numbers | confidence is categorical; totals are sums of verified item sizes |

## 8. Least privilege

The app requests no entitlements in MVP. Scanning reads metadata; deletion writes nothing except `trashItem` calls and its own Application Support directory (which is excluded from its own scans). Agents cannot execute shell commands — the typed tool layer is the only action surface (spec §33–34).
