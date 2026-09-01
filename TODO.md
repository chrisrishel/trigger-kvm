
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

- **Write up the deferred advanced escape hatch** (one specific I2C address, one specific
  value, typed by the user, behind a strong disclaimer; never a sweep across a range of
  either). It is step 4 of the ladder in `ideas/unknown-monitor-discovery.md` and the only
  part of that note with no home yet. Trigger: when someone reports a monitor that answers
  neither standard DDC nor a known manufacturer dialect.
