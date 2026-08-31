
- **Elevating to a *different* admin account breaks the install path.** `Request-Elevation`
  launches the child with `-Verb RunAs`; when the signed-in user is not an admin, Windows
  elevates a different account, whose `%LOCALAPPDATA%` is a different directory. The child
  then finds no config, installs to the wrong profile, and registers a task pointing at it.
  Untested and probably broken. Trigger: when someone reports boot-start failing on a
  standard (non-admin) user account, or before publishing. The fix is to pass the resolved
  paths to the child rather than letting it re-derive them.

- **Write up the deferred advanced escape hatch** (one specific I2C address, one specific
  value, typed by the user, behind a strong disclaimer; never a sweep across a range of
  either). It is step 4 of the ladder in `ideas/unknown-monitor-discovery.md` and the only
  part of that note with no home yet. Trigger: when someone reports a monitor that answers
  neither standard DDC nor a known manufacturer dialect.

- **Windows owes three spec conformance fixes and a duplicate-definition cleanup.**
  Written up in `macos/HANDOFF.md`, with the failing conformance output. The
  sharpest of them: `install.ps1` defines `Test-DisplayInput` twice and the live
  one is the older single-question version, so the monitor check does not behave
  the way `specs/configure.md` §10.4 says. Trigger: next time the Windows side is
  worked on.

- **The Windows suite has no conformance check.** `specs/check-conformance.sh` is
  the macOS implementation; the marker format is the contract and Windows needs
  its own in PowerShell, run by `run.ps1`. Until it exists, a spec edit fails only
  the macOS suite. Trigger: with the handoff above.
