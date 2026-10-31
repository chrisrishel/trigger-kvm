# TODO

Deferred, sub-milestone work, each with the trigger that resurfaces it.
Milestones are `ROADMAP.md`; what each platform owes the other is its
`HANDOFF.md`.

## Publication readiness

Keep the repository private until these checks are complete. The review baseline
is `318fc79`; remaining Windows release validation is in `windows/HANDOFF.md`
and the command checklist in `windows/RELEASE-CHECKS.md`.

- [x] Define the shared product version, pre-1.0 compatibility rules, build
  identity and release gates in `CONTRIBUTING.md`. Version constants remain
  unchanged until coordinated release preparation.
- [ ] Prepare the next coordinated release, targeting **0.3.0**, after these
  blockers are resolved. The changes since `v0.2.0` include new features and
  specification revisions. Follow the release policy before changing both
  platform constants, tagging or publishing.
- [x] macOS: ambiguity re-baselines without firing, including one-shot checks;
  trigger-check cleanup restores only a watcher it paused; incomplete boot-tier
  removal refuses; Escape discards computer, removal and monitor submenu edits.
  Verified with `make test` (13 files plus shellcheck) and
  `bash tests/mutate.sh publication` (11 mutations caught).
- [x] Windows: publication-review defects resolved with native PowerShell 5.1
  regressions and 21 passing test files. A full 53-mutation publication run
  passed; all 12 affected boot mutations were caught after the final code fix.
  Includes incomplete-check gating, exact-path/owner cleanup with conservative
  execution-boundary recognition, prior watcher state, apostrophes/Unicode,
  fractional settle, restricted DLL loading,
  Escape rollback, recursive conformance coverage and isolated test paths.
- [x] Windows follow-up review at `7a2a9a4`: resolve the boot bootstrap's
  native-confirmed pre-restriction module-loading defect. Task registration now
  embeds a compiled assembly; native adversarial success/error checks and
  mutations cover dependency loading. The UAC assertion and stale README are
  corrected. Native suite: 22 files; relevant mutations: 20 caught. Bounded
  session-0 control/success/failure checks passed on 2026-10-31; reuse completed
  installed/reboot/physical evidence for unchanged behavior.
  The coordinated live upgrade to `6f65aff` passed on 2026-10-31: current config
  bytes/PATH preserved, secured task rebuilt, one ordinary boot watcher running.
- [x] Shared contracts: revision 15 settles horizontal menu overflow and labels
  `status` as the current saved configuration. Both platforms implement it;
  empty saved triggers also retain the restart reminder on Windows.
- [ ] Windows: implement revision 16's terminal-height viewport in both common
  menu primitives. macOS implements scrolling, page/end navigation, resize
  reflow and numbered fallback with state preserved. Prefer synthetic lists
  and native console fixtures; this menu change needs no monitor switching,
  reboot, profile changes or repeat of installed boot validation.
- [x] Documentation: copyable installation and usage examples, explicit
  prerequisites, bounded compatibility claims, accurate file references and
  privacy guidance for diagnostic output. Shared and both platforms' docs are
  updated, including the Windows coordinated release checklist.
- [x] CI configuration: run both platforms' full suites, with hardware skips
  explicit. Inspect hosted results for each pushed candidate; CI cannot prove
  physical switching.
- [x] Windows installed workflows and startup: administrator-capable and standard
  profiles exercised actual paths with spaces/apostrophes/Unicode, approved and
  declined UAC, intended task principals/files/PATH, boot/login/manual tiers,
  real reboot/logon behavior and source-unavailable uninstall. Standard-user
  `6a5afcf` completed credential Cancel/success, installed Save/Cancel/unknown-key
  preservation and fresh-product login fallback on 2026-10-30. Its restricted
  session-0 watcher started before the first login after reboot. Earlier
  administrator-profile and real Ctrl+C results remain in the measurements.
  The separate administrator PATH was also unchanged, verified from a clean
  private hive copy using Windows' read-only offline registry API.
- [x] Windows installed-candidate and hardware validation: the original owner
  is restored to clean `6a5afcf` with its config/PATH unchanged and one
  enabled/running restricted boot watcher. Its final real reboot started that
  watcher before interactive login. The installed switcher passed both panels'
  NVAPI away/back checks under the same restricted session-0 bootstrap, one panel at a time with explicit
  visual confirmation. These physical writes ran after local sign-in; they
  do not establish a detector-triggered or pre-login physical switch. Earlier
  ASUS dxva2 and local-console NVAPI confirmations remain separate evidence;
  switcher/config code is unchanged from that tested candidate.
  The standard account's only added right was the
  expected batch-logon grant, retained after successful uninstall by design.
  Temporary Switch user policy is restored. Both disposable profiles were
  privately backed up and removed with approval; the standard account's
  test-added batch-logon right was restored first. See `windows/RELEASE-CHECKS.md`
  for the evidence and remaining
  coordinated release/privacy gates. This does not mark the repository ready
  for publication.
- [ ] Privacy: shared measurement notes now use consistent labels for device
  identifiers; unnecessary current Windows device examples are synthetic.
  The 2026-10-30 audit at `2835cb0` covered 112 tracked files, 226 commits/1,192
  text blobs, all advertised refs, accessible GitHub metadata and 14 Actions
  logs. Current matches are synthetic/redacted examples or API constants; no
  known credential-pattern matches were found. Historical identifiers and one
  author email remain, including that email in Actions metadata. See the
  location/category inventory and limits in `docs/measurements.md`, "Release
  validation and privacy". GitHub secret scanning was disabled/unavailable.
  The refresh through `1f00e7e` covered 242 commits / 1,298 text blobs and all
  30 Actions runs' logs, with no new findings or authorship records.
  On 2026-10-30 the owner chose to keep publication blocked for a separate
  privacy review; retaining that historical content/metadata for publication
  is not approved. Before any
  separately approved history rewrite, prepare a private
  backup and exact replacement
  preview, finish both platforms' work, and synchronize both checkouts. Re-scan
  all published refs and GitHub surfaces afterward. Do not remove human
  authorship or rewrite history as part of ordinary fixes.
- [ ] Final release review: both native suites and relevant mutations pass;
  skipped hardware checks remain explicitly unverified; the documentation
  matches the release commit and privacy review covers its history.

## Deferred work

- **Re-take the NVAPI identity comparison after each graphics driver update.**
  Baseline: NVIDIA 616.64 (`docs/measurements.md`, 2026-09-05). Compare
  `outputId` and `displayId`, that NVAPI still initialises with the recorded
  struct versions (`docs/nvapi-bindings.md`), that a panel still moves both ways
  watched by eye, and `reachable by` per panel. GDI names are expected to move
  and mean nothing. Trigger: the next driver update.

- **Measure a same-GPU, different-port re-plug on Windows.** The 2026-09-01
  cable move changed GPU and adapter together. Move only the GPU end of the
  LG's cable to another 4090 socket, terminal on the ASUS first; expect no
  change; record `outputId` and `displayId`. Trigger: next time the machine is
  open.

- **Write up the advanced escape hatch**: one I2C address and one value typed
  by the user behind a strong disclaimer, never a sweep. Step 4 of
  `ideas/unknown-monitor-discovery.md`. Trigger: someone reports a monitor that
  answers neither standard DDC nor a known dialect.

- **Build the `configure` output fixture.** Replace string-presence conformance
  with staged inputs (`attached`, `devices`, `answers`) and an expected config
  and transcript per case, asserted on output; keep `normative` fences for the
  safety and refusal strings. Trigger: the next spec revision that changes
  wording without changing behaviour, or the next string-check false positive.

- **Delete `$EARLIER_LAYOUT` and the pre-rename tolerances that remain.** The
  `display-switch`-era task, directory and log cleanup went in the 2026-09-08
  reshaping, since this machine had none of them left. What is still carried:
  `install.ps1`'s `$EARLIER_LAYOUT` list, `$RENAMED_KEYS` and the install
  warning for it, `Get-EffectiveTier`'s `install.start` / `install.tier` rows,
  and `Stop-Watchers`' `usb-watch.ps1` alternative. Trigger: when no machine can
  plausibly still hold a config or a program directory that predates the
  2026-08-30 rename.

