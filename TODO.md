- **Verify the boot tier on a real standard (non-admin) account.** The install path no
  longer lets the elevated child derive its own answers -- `install.ps1` passes
  `-ForUser` and `-ForAppData`, every path and principal is built from those, and the
  PATH edit stays with the unelevated parent. That is read-verified and covered by
  `windows/tests/elevation.tests.ps1` and the structural checks in
  `windows/tests/conventions.tests.ps1`, but it has never been RUN on a machine where
  the signed-in user is not an admin, because this desk has no such account. Trigger:
  when a standard-user Windows account is available, or when someone reports boot-start
  failing on one. Check: task principal is the standard user, files land in that user's
  `%LOCALAPPDATA%`, and their `PATH` (not the admin's) gains `bin`.

- **A declined UAC prompt records a tier downgrade that did not happen.** Observed
  2026-09-02: `install.ps1:370` writes `install.autostart = login` the moment elevation
  is declined, BEFORE any task work. On this machine the task replacement then failed
  too ("the task was left exactly as it was"), so the config said `login` while the
  registered task was still S4U -- and `Get-EffectiveTier` reads that config, so the
  next bare `install` would have silently demoted a working boot tier. Restored by hand;
  backup at `%LOCALAPPDATA%\trigger-kvm\config.pre-uac-decline.bak`.
  The fallback itself is correct and required (`specs/configure.md` 8: fall back, say so,
  record it) -- what is wrong is recording it before the install it describes has
  succeeded. Likely fix: write the tier once, where the other tier facts are written,
  after registration succeeds. Check `specs/configure.md` 8 still reads true of that.
  Trigger: when the elevation path or `Get-EffectiveTier` is next touched.

- **Check whether `pause` actually stands a BOOT-TIER watcher down.** `Stop-Watchers`
  (`windows/install.ps1`) finds watchers to kill by matching `Win32_Process.CommandLine`,
  and an unelevated caller reads that as empty across the session boundary -- the same
  blindness that made `status` report `watchers : 0` (fixed 2026-09-02, commit `69d8e1e`;
  evidence in `docs/measurements.md`). So `pause` run unelevated may disable the task,
  kill nothing, and leave the session-0 watcher alive holding the mutex -- after which
  the "run one by hand now" it prints fails with "another watcher is already running",
  and the user has no idea why.
  **Not verified**: confirming it means pausing the live watcher, which was out of scope
  for the status fix. `Stop-Watchers` needs PIDs, not a yes/no, so `Test-WatcherRunning`
  is not the fix -- but it is now available to make `pause` *report* honestly when the
  lock is still held after a suspend. Trigger: next time `pause` is used on the boot
  tier, or when `Suspend-Watcher` is next touched.

- **Measure a same-GPU, different-port re-plug.** The 2026-09-01 cable move
  changed GPU and adapter together, so "same card, different socket" is argued
  from the code and never measured. Clean test: move only the GPU end of the LG's
  cable to another 4090 DisplayPort socket, same cable, same LG input; terminal
  on the ASUS first (hard rule 4). Expect no change -- EDID vendor+product are
  unaffected and `outputId` is resolved fresh. Trigger: next time the machine is
  open, or before anyone documents the re-plug behaviour as a guarantee.

- **Write up the deferred advanced escape hatch** (one specific I2C address, one specific
  value, typed by the user, behind a strong disclaimer; never a sweep across a range of
  either). It is step 4 of the ladder in `ideas/unknown-monitor-discovery.md` and the only
  part of that note with no home yet. Trigger: when someone reports a monitor that answers
  neither standard DDC nor a known manufacturer dialect.

- **Measure whether a directory-scoped `AGENTS.md` is loaded by both tools, and if
  so move the test-harness hazards into `windows/tests/AGENTS.md`.** The instruction
  files are near their caps (`windows/AGENTS.md` has **~150 bytes spare of 10240**,
  down from ~300 -- the 2026-09-02 round-trip run spent half the remaining headroom
  on one clause) and the next hazard learned has nowhere to go. The tempting fix — an `agents/` folder
  of instructions loaded on demand — does NOT work by `@`-import:
  `docs/decisions/002` measured that Codex reads the `AGENTS.md` chain by PATH and
  never sees `CLAUDE.md` or anything it imports, so the two agents would silently
  get different instructions. What might work is the mechanism both tools already
  have: Codex loads the chain root-down-to-CWD, and Claude Code loads a
  subdirectory `CLAUDE.md` on first read of a file there.

  What to measure, the same sentinel way 002 measured the byte cap: whether each
  tool actually picks up `windows/tests/AGENTS.md` under realistic working
  patterns. The known asymmetry is that Codex keys on the working DIRECTORY while
  Claude Code keys on the file READ, so editing `windows/tests/*.tests.ps1` from
  `windows/` may give Codex the root+platform chain and not the tests one. Same
  content either way — only the timing differs, which is far weaker than the
  import asymmetry, but it is the thing that decides whether this is worth doing.

  Candidates to move if it holds: the `Import-Subject` first-definition trap, the
  StrictMode note, and `Start-Process -PassThru` never populating `.ExitCode`
  (~1.5 KB). They only bite when writing tests, which is exactly when that
  directory is in play. Trigger: when `windows/AGENTS.md` next needs a rule added
  and there is no room. Outcome is an amendment to decision 002, or a new
  decision record of its own — 003 and 005 are taken.
