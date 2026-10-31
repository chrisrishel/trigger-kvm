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
  regressions, 19 passing test files and 42 caught publication mutations.
  Includes incomplete-check gating, exact-path/owner cleanup with conservative
  execution-boundary recognition, prior watcher state, apostrophes/Unicode,
  fractional settle, restricted DLL loading,
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
  Clean `2835cb0` was installed on 2026-10-30; installed source/build identity,
  config/PATH preservation, single watcher and intended task state passed.
  Installed Save retained an unknown key and the stamp; Cancel preserved config
  bytes, and the original config was restored. On that installed candidate,
  real Ctrl+C restored enabled/running before scheduler self-heal, and both
  panels' NVAPI away-and-back switching was visually confirmed separately.
  Standard-user product registration and its fresh-profile workflow remain open.
  The profile session must restore
  the owner's boot/enabled/running state afterwards.
  A fresh administrator-capable login installation passed with spaces,
  apostrophe and Unicode in both profile/source paths. It exposed a boot-row
  eligibility defect: the managed groups API omits deny-only administrator
  membership. Corrected `4c0f13b` passed installed boot selection unelevated,
  declined-UAC login fallback with existing config, approved-UAC boot
  registration, and profile Save/Cancel. Native regression/mutation coverage
  accompanies the fix; standard-user elevation and corrected installation
  paths still need their coordinated repeat.
  A real reboot on `4c0f13b` started exactly one intended S4U/Limited watcher
  in session 0 without the test user signing in. This is native startup
  evidence; no physical switching was performed by that check.
  The installed boot-to-login transition and real sign-out/sign-in also passed,
  with one new intended watcher in the new interactive session.
  Login-to-no-autostart started a watcher immediately and left it stopped after
  a real sign-out/sign-in, with the task enabled and no triggers.
  Real Ctrl+C on `4c0f13b` also preserved enabled/stopped and disabled/stopped
  in elevated no-autostart consoles with no helper recovery or self-heal.
  Each required three presses before CMD's termination prompt; this establishes
  cleanup, not single-press responsiveness.
  Fresh product-state declined-UAC fallback passed after retaining the test
  profile's data separately. Uninstall retained config/log bytes and removed
  task/program/PATH but reported exit 1; the self-deleting CMD shim is corrected
  with native regressions. User-tier replacement now elevates only removal of
  a protected task and registers the replacement in the normal parent.
  Installed `462204a` preserved config/PATH through upgrade and verified
  user-owned login/manual tasks, one watcher and no second UAC prompt for
  login-to-no-autostart. Its source-unavailable uninstall returned 0, removed
  task/program/PATH and stopped the watcher, retaining config/log bytes and
  original PATH entries. No assertion was weakened.
  The fresh standard-user native probe accepted separate administrator
  credentials but exposed false boot-menu eligibility. The correction reads
  UAC policy and retains explicit denial. Installed `ed1a0c0` offered boot and
  accepted UAC, but S4U registration was denied; there is no task/watcher.
  Standard-user boot remains a blocker pending its corrected installed repeat.
  Its own S4U fixture also failed; native process-token inspection confirmed
  the administrator S4U/Limited control was elevated. Actual boot-token
  restriction is a separate release blocker. Password-authenticated S4U plus
  batch-logon permission succeeded in bounded native diagnostics. The source
  now implements that registration and an embedded token-restricting bootstrap;
  the actual installed token, cleanup and restricted device access still need
  validation. Diagnostic cleanup restored rights and removed all fixture tasks.
  Nonterminating task errors also exposed false success output, now covered
  by regression/mutation tests. Full native validation passed; its installed
  repeat remains with the standard-user registration gate.
- [ ] Privacy: shared measurement notes now use consistent labels for device
  identifiers; unnecessary current Windows device examples are synthetic.
  The 2026-10-30 audit at `2835cb0` covered 112 tracked files, 226 commits/1,192
  text blobs, all advertised refs, accessible GitHub metadata and 14 Actions
  logs. Current matches are synthetic/redacted examples or API constants; no
  known credential-pattern matches were found. Historical identifiers and one
  author email remain, including that email in Actions metadata. See the
  location/category inventory and limits in `docs/measurements.md`, "Release
  validation and privacy". GitHub secret scanning was disabled/unavailable.
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

- **Verify the boot tier on a standard (non-admin) Windows account.** The
  credential-only native probe passed on 2026-10-30; product installation is
  still unverified. Check the task principal, the files' `%LOCALAPPDATA%`
  and whose `PATH` gains `bin`. Trigger: a standard-user account is available.

- **Complete the fresh standard-user installed workflow.** The fresh
  administrator-capable profile passed initial setup, installed-shim
  `configure`, Save/Cancel and `status` on 2026-10-30. Repeat those checks in
  the separate standard-user profile, including creation of its new
  `%LOCALAPPDATA%\trigger-kvm\` directory and intended-user ownership.
  Trigger: the approved standard-user session in the release matrix.

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

