# TODO

Deferred, sub-milestone work, each with the trigger that resurfaces it.
Milestones are `ROADMAP.md`; what each platform owes the other is its
`HANDOFF.md`.

## Publication readiness

Keep the repository private until the gates below are complete. The next
coordinated release is **0.3.0**. Product versions, evidence and approval follow
[the release policy](CONTRIBUTING.md#preparing-and-publishing-a-release);
[release notes](docs/releases/0.3.0.md) describe the user-facing changes.

### Complete

- [x] Both platforms implement specification revision **16**, including menu
  viewports, saved-configuration status, ambiguity refusals and the reviewed
  installer/trigger-check fixes. Native suites and relevant mutation coverage
  are recorded in `docs/measurements.md`.
- [x] Windows boot security, administrator/standard-account workflows,
  installation/upgrade, autostart and restricted session-0 physical switching
  have dated evidence. Retain its stated limits: the final restricted physical
  writes ran after local sign-in, and did not prove a detector-triggered or
  pre-login physical write. Detailed coverage is in `windows/RELEASE-CHECKS.md`.
- [x] Privacy cleanup preserved the 251 original commits while replacing private
  identifiers and email metadata. Sanitized main/tag were verified remotely;
  all 39 old Actions runs were privately archived and removed. Mac and Windows
  checkouts use the sanitized history and repository-local noreply identity.
  Native Windows migration validation passed all 23 files without skips.
- [x] The owner confirmed on 2026-10-31 that there are no linked GitHub Projects.
  The accepted limits of the history cleanup are in `docs/privacy.md`.
- [x] The shared README separates setup and everyday use from implementation
  details. Release notes cover changes since `v0.2.0`, upgrades and limitations;
  the roadmap reflects the completed dxva2 observation.
- [x] macOS release preparation: installer regressions, all 14 native test files
  and ShellCheck passed without skips; all 11 publication mutations were caught
  and restored. The only runtime edit is the product version constant.
- [x] Coordinated source versions are **0.3.0** and both specification revisions
  stay at 16. The Windows guide distinguishes released sources from development
  main; isolated installer/status fixtures verify version stamping and retention.
- [x] Windows release preparation at clean `e2636e0`: all 23 native PowerShell
  5.1 test files passed without skips; all three installed-version mutations
  were caught and restored. Existing installation/state and dated hardware,
  profile and reboot evidence are preserved (`docs/measurements.md`).
- [x] Coordinated native validation at `153812a`: macOS passed all 14 test
  files and ShellCheck without skips; the owner confirmed the final Windows
  PowerShell 5.1 run passed all 23 files without skips on this same commit.
  CI passed on both platforms, with the Windows runner's NVIDIA-dependent
  file and two driver cases explicitly skipped. Relevant mutation evidence
  above remains valid for unchanged code.
- [x] Final documentation review removed temporary preparation notices and
  checked 64 local links across the user guides, release notes and supporting
  documentation. Release notes are ready for publication.
- [x] The final privacy review at `153812a` covered 256 reachable commits,
  `v0.2.0`, all 123 tracked files, GitHub metadata and all four retained Actions
  runs and their logs. No known private identifiers or new secrets were found;
  the secret scanner's filename-list false positives were reviewed. Private
  backups and raw receipts remain ignored. The only following edits are
  documentation; validate and scan their final commit before release.

### Remaining

- [ ] Obtain explicit approval for the tested candidate, annotated `v0.3.0`
  tag, release publication and public repository visibility. Do not interpret
  ordinary commit/push authorization as release or visibility approval.
  At release time, confirm the approved commit is unchanged, its CI passed
  and final refs, Actions metadata/logs and any new GitHub surfaces or assets
  remain within the privacy review. Export only tracked files for distribution,
  never a workspace ZIP. Revalidate any candidate change in proportion to its
  effect, as required by the release policy.

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

