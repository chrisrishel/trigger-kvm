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
  regressions, 17 passing test files and 28 caught publication mutations.
  Includes incomplete-check gating, exact-path/owner cleanup, prior watcher
  state, apostrophes/Unicode, fractional settle, restricted DLL loading,
  Escape rollback, recursive conformance coverage and isolated test paths.
- [x] Shared contracts: revision 15 settles menu overflow and labels `status`
  as the current saved configuration. Both platforms implement revision 15;
  empty saved triggers also retain the restart reminder on Windows.
- [x] Documentation: copyable installation and usage examples, explicit
  prerequisites, bounded compatibility claims, accurate file references and
  privacy guidance for diagnostic output. Shared and both platforms' docs are
  updated, including the Windows coordinated release checklist.
- [x] CI configuration: run both platforms' full suites, with hardware skips
  explicit. Inspect hosted results for each pushed candidate; CI cannot prove
  physical switching.
- [ ] Windows release checks: fresh profiles, administrator and standard-user
  installation paths, apostrophe/non-ASCII paths, and both autostart tiers.
  Existing-profile boot-tier upgrade, installed status/Cancel, timeout state
  restoration and ASUS `dxva2` switching both ways were observed on 2026-10-29.
  Fresh profiles, standard-user UAC, decline/fallback, tier transitions,
  installed Save, interactive cancellation and uninstall remain outstanding.
- [ ] Privacy: shared measurement notes now use consistent labels for device
  identifiers; unnecessary current Windows device examples are synthetic.
  A limited history scan found prior identifier content in six file paths
  and one historical author email; identifying values are not repeated here.
  Decide whether that metadata/content is intended to be public. A current-file
  scan for common credential patterns found none; it is not a full secrets or
  history clearance. Before any approved history rewrite, prepare a private
  backup and exact replacement
  preview, finish both platforms' work, and synchronize both checkouts. Re-scan
  all published refs and GitHub surfaces afterward. Do not remove human
  authorship or rewrite history as part of ordinary fixes.
- [ ] Final release review: both native suites and relevant mutations pass;
  skipped hardware checks remain explicitly unverified; the documentation
  matches the release commit and privacy review covers its history.

## Deferred work

- **Re-read the NVAPI ids at the first reboot on driver 616.64.** The 2026-09-05
  upgrade was applied live, so "reboot on a new driver" is the one combination
  untaken; one `windows\nvapi-probe.ps1` run answers it. Trigger: the next
  reboot of the Windows PC.

- **Re-take the NVAPI identity comparison after each graphics driver update.**
  Baseline: NVIDIA 616.64 (`docs/measurements.md`, 2026-09-05). Compare
  `outputId` and `displayId`, that NVAPI still initialises with the recorded
  struct versions (`docs/nvapi-bindings.md`), that a panel still moves both ways
  watched by eye, and `reachable by` per panel. GDI names are expected to move
  and mean nothing. Trigger: the next driver update.

- **Verify the boot tier on a standard (non-admin) Windows account.** The
  elevation path is read-verified and covered by `elevation.tests.ps1`, never
  run on such an account. Check the task principal, the files' `%LOCALAPPDATA%`
  and whose `PATH` gains `bin`. Trigger: a standard-user account is available.

- **Run a first install on a fresh profile, from the installed shim.** Both
  halves of the old handoff entry are fixed and covered -- the listing modes no
  longer read the config, and `Write-ConfigFile` creates
  `%LOCALAPPDATA%\trigger-kvm\` -- but the walkthrough has only ever been driven
  by tests writing under an existing temp directory, and this desk's profile has
  had that directory since before the rename. `configure` from the shim, then
  `status`. Trigger: the same throwaway account as the item above.

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

