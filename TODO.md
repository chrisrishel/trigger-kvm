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

- **Test the boot tier at the actual logon screen.** `ideas/nvapi-transport.md`
  calls this the only untested step in the pre-login path: every session-0 result
  so far was taken with a user logged in, so session 0 had no desktop but the
  machine was not empty of a session. The boot tier's headline claim has never
  been tested in the state it exists for. Log out, flip the switch, watch the
  panels, log back in and read the log. Trigger: next time the machine can be
  logged out of. See `ROADMAP.md` N2.

- **Say plainly, in `status`, that the input map is unverifiable -- and that
  re-running `configure` is the fix.** If a computer's cable moves to a different
  input ON THE MONITOR, a panel with a stable EDID product id (the ASUS reports
  `0x42E0` on every input) still resolves, and `pull` then sends the old input
  value: the panel switches to a dead input and goes black, silently, with a
  success in the log. Detection is barred -- rule 2 forbids reading the value
  back, rule 3 says the success code proves nothing -- so the only move left is
  making the failure legible and cheap to recover. A panel with a per-input
  product id (the LG) already fails safe by refusing. Reasoning, the cases it
  does NOT affect, and why no protocol-level "switch to whoever is talking"
  exists are in `ideas/knowing-which-input-you-are-on.md`. Trigger: when `status`
  or `configure` output is next touched, or when someone reports a pull that
  blanked a monitor.

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
  files are near their caps (`windows/AGENTS.md` has ~300 bytes spare of 10240) and
  the next hazard learned has nowhere to go. The tempting fix — an `agents/` folder
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
