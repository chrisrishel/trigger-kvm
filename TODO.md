# TODO

Deferred, sub-milestone work, each with the trigger that resurfaces it.
Milestones are `ROADMAP.md`; what each platform owes the other is its
`HANDOFF.md`.

## Publication readiness

[Release 0.3.0](https://github.com/chrisrishel/trigger-kvm/releases/tag/v0.3.0)
was published on 2026-10-31, and the repository is public. The annotated tag
points to `0d5401d35cba77b151ce3a9b6c05b759c08a43bf`; both platforms implement
specification revision 16. The coordinated validation, privacy review and
explicit release/visibility approval gates are complete. Dated evidence is in
[`docs/measurements.md`](docs/measurements.md); changes, upgrade instructions
and compatibility limits are in the [release notes](docs/releases/0.3.0.md).

For subsequent releases, follow [the release policy](CONTRIBUTING.md#preparing-and-publishing-a-release):
validate the candidate in proportion to its changes, repeat the privacy review
for new history and GitHub surfaces, and obtain explicit release approval.
Keep released tags immutable and export only tracked files for distribution.
The accepted limits of the history cleanup remain in
[Publication privacy](docs/privacy.md#audit-limits).

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

