
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

- **The macOS side is now well behind Windows.** `macos/trigger-kvm.sh` still speaks the
  pre-machines config (`display.<label>.self`, `scene.*`), which no longer exists, and knows
  nothing about `computer.this`, the input map, `install.autostart`, or Bluetooth triggers.
  `docs/macos-parity.md` has been kept current as the handoff brief. Trigger: before using
  the Mac side again, or before publishing — whichever comes first. Until then the Mac
  cannot read a config this repo writes.
