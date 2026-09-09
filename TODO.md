# TODO

Deferred, sub-milestone work, each with the trigger that resurfaces it.
Milestones are `ROADMAP.md`; what each platform owes the other is its
`HANDOFF.md`.

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

- **Send something over `dxva2` on the shipped path, and watch it.** Every
  dxva2 run to date was `-WhatIf` (`docs/decisions/003`). Terminal onto the LG
  first; ASUS on `transport = dxva2`; `pull` and `to mac` both directions by
  eye; confirm the boot row is drawn disabled while dxva2 is set; restore.
  Record in `docs/measurements.md`. Trigger: next time the ASUS can be spared.

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

- **Put `$PID` in every Windows test fixture path.** Each test file writes a
  fixed name under `%TEMP%`, so two concurrent `run.ps1` instances corrupt each
  other's fixtures (hit 2026-09-04). Trigger: next time `windows\tests` is
  touched, or a suite hangs for no visible reason.

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

