- **Re-read the NVAPI ids at the first reboot on driver 616.64.** The 2026-09-05
  upgrade was applied LIVE -- `LastBootUpTime` never changed -- so "reboot on a new
  driver" is the one combination still untaken. Reboot alone is measured stable and
  a driver change alone is measured stable, so this is very likely a formality; it
  is here because "very likely" is inference and this repo distinguishes the two.
  One `windows\nvapi-probe.ps1` run answers it. Trigger: the next reboot.

- **Re-take the NVAPI identity comparison after the next graphics driver update.**
  Recurring. The current baseline is NVIDIA **616.64**, in `docs/measurements.md`
  (2026-09-05, "a driver upgrade moved the GDI names"). Re-take it the same
  read-only way -- `windows\nvapi-probe.ps1`, `trigger-kvm list -Raw`,
  `nvidia-smi --query-gpu=driver_version` -- and compare, in this order of
  consequence:
  1. **`outputId` and `displayId`.** If either moves, the tiebreak design in
     `ideas/telling-two-identical-monitors-apart.md` loses its foundation, and the
     fallback is the EDID `0xFF` descriptor, which both panels are measured to
     carry. Held across 610.62 -> 616.64; one upgrade is not a guarantee.
  2. **NVAPI still initialises and its struct versions are still accepted**
     (`NV_GPU_DISPLAYIDS` `0x00030010`, `NV_EDID` `0x00030110`). A bumped struct
     version fails the call with an unhelpful error, and the probe says so.
  3. **A panel still MOVES.** Hard rule 3: no command answers this. `to <other>
     --only` then `pull --only`, watched, one monitor at a time with the terminal
     on the other (hard rule 4). The pull back from an inactive link is the half
     that matters.
  4. **`reachable by`, per panel.** One that silently became dxva2-only is
     login-tier only (`docs/decisions/003`) and would stop following at the login
     screen. `status` names it.
  **Expect the GDI names to move and do not read it as a fault** -- they went
  `\\.\DISPLAY1`/`2` -> `\\.\DISPLAY10`/`11` across the last upgrade while every
  NVAPI id held. Nothing resolves by that name, so it costs nothing.
  Also settled and not worth re-checking unless something looks wrong: the watcher
  fires nothing during an install (observed 2026-09-05). Do not flip the USB
  switch mid-install. Trigger: the next graphics driver update on this machine.

- **Send something over `dxva2` on the shipped path, and watch it.** Nothing ever has:
  every dxva2 run to date was `-WhatIf`, so under hard rule 3 no claim is made that a
  panel has moved over it (`docs/decisions/003`, `ROADMAP.md`). No re-cabling needed --
  measured 2026-09-02, `trigger-kvm list` reports both panels as `nvapi, dxva2` with the
  ASUS on the 4090, so the motherboard output's 138 Hz -> 60 Hz cost does not apply.
  Order: terminal onto the LG FIRST (hard rule 4; the ASUS is the panel moving); point
  the ASUS at `transport = dxva2`; `pull` and `to mac` BOTH directions, confirmed BY EYE
  -- the pull-back from an inactive link is the one that matters; confirm the boot row is
  drawn disabled and says why while dxva2 is set; set the ASUS back to `nvapi`, verify,
  restore the boot tier; record the readings in `docs/measurements.md`, dated.
  Still not measured and must not be claimed either way: AMD, a DisplayPort motherboard
  output, and anything sent to the LG over Intel. Trigger: next time the ASUS can be
  spared for a few minutes. (Was Phase B of the dxva2 plan, `.context/PLAN.md`.)

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
  Note: that expectation holds only while nothing STORES a per-port id. If the
  tiebreak in `ideas/telling-two-identical-monitors-apart.md` is ever built, this
  same measurement also answers "how stale does a stored one get, and when?" --
  so take the reading either way, and record it against both. Record `displayId`
  as well as `outputId`: the reboot reading (2026-09-05) showed both stable and
  that note now records `displayId` as the field to store, so a port change is
  the one event left that could separate them.

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

- **Two suite runs at once share fixed temp paths and can interfere.** Each test
  file that needs a config writes to a FIXED name under `%TEMP%` --
  `trigger-kvm-tests.cfg`, `trigger-kvm-trigcheck.cfg`,
  `trigger-kvm-question.cfg`, and the round-trip file `config.tests.ps1` uses --
  with no PID in any of them, unlike `mutate.ps1`'s output file which does carry
  one. So two concurrent `run.ps1` instances read and write each other's
  fixtures. Hit 2026-09-04: several suite runs were left alive at once (a
  supervising shell timed out without stopping its grandchildren, the same
  shape as the task/wscript/watcher problem `windows/AGENTS.md` records), and
  the suite stopped completing until they were killed. The runs were the
  proximate cause and the shared paths are the reason it was destructive rather
  than merely wasteful; the hang itself was never root-caused.
  Fix: put `$PID` in every fixture path, as `mutate.ps1` already does.
  Trigger: next time anything in `tests/` is touched, or the first time a suite
  hangs for no visible reason.

- **`macos/AGENTS.md` is now out of room too, and a hazard is waiting for it.**
  It is at **10,172 bytes of 10,240** -- 68 spare. The hazard with nowhere to go:
  **an assertion inside a `cmd | while read` loop is thrown away**, because the
  loop runs in a subshell and the `FAILED` it increments dies with it, so the
  case reports PASS however wrong the answer is. Found 2026-09-06 by a mutation
  surviving against a deliberately broken build; the test looked right and could
  not fail. Use a here-string. It is enforced by a self-tested scan in
  `macos/tests/conventions.tests.sh`, which is stronger than a doc line, so
  nothing is currently lost -- but it belongs in a `macos/tests/AGENTS.md`
  alongside the Windows candidates already listed above.
  This is the SECOND platform to hit the cap, which strengthens the case for
  measuring directory-scoped `AGENTS.md` rather than deferring it further.
  Trigger: the same one as the entry above, now fired on both platforms.

- **Settle whether `detector.md` §4.1 means a token may be written when it is NOT
  unique.** Two sentences in that section pull against each other, and macOS is
  the first implementation to reach the gap:
  - *"A writer picks a value held by exactly one of the devices sharing that id,
    and where none exists, writes no token."*
  - and the matching table's row *"several have it, one at `where`"*, plus
    *"`where` is a TIEBREAK ONLY, consulted when and only when `token` still
    matches more than one present device."*

  The grammar is `usb:VVVV:PPPP[@token[@where]]`, so **a `where` cannot be
  written without a token**. If the first sentence is absolute, the tiebreak row
  and the whole `where` suffix are unreachable -- dead grammar that the same
  section spends four bullets specifying.

  **macOS read it as: the first sentence governs a token written ALONE, and the
  tiebreak row is what a shared token plus a port is for.** So where two devices
  share an id and a token, it writes `@token@where`; where they share an id and
  the token would be unique, it writes `@token` and no port; where there is no
  token at all it writes the bare id, because a placeholder would match nothing,
  which is worse than matching both. The reasoning is at the decision point in
  `macos/lib/walkthrough.sh` (`wt_triggers`) and is covered by three tests in
  `macos/tests/walkthrough.tests.sh`.

  **Windows has not reached this**: measured on that desk, the two receivers
  report distinct product strings, so a token always resolves and the tiebreak
  row never runs. macOS reaches it on every one of these receivers, because both
  report `USB Receiver` (`docs/measurements.md`, 2026-09-06). So the two
  implementations do not disagree today -- but they would the first time Windows
  meets twins with a shared name, which is exactly the divergence `specs/` exists
  to prevent, and no conformance check can see it because no normative string is
  involved.
  Fix is one clarifying sentence in §4.1, not a behaviour change; if it lands the
  other way, macOS's writer is what changes. Trigger: when §4.1 is next touched,
  or the first time Windows meets two devices sharing an id AND a name.
