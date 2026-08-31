
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

- **Rename `$IsMachine` to `$IsComputer` in `install.ps1`.** `specs/configure.md`
  §2's reason for "computer, never machine" is that the term must not change
  between the config key, the prompt and the code; the user-visible half is done,
  the parameter name is the seed of the next slip. It is a contract change across
  `Test-DisplayInput`, `Test-OneComputer` and three test stubs, so it needs a
  reference sweep rather than a find-and-replace. Trigger: next time
  `Test-DisplayInput` or the monitor check is touched.

- **`event-watch.ps1`'s `-Arg` comment still talks about "a scene".** Scenes were
  deleted (`AGENTS.md` hard rule 1a); the comment on the `$Arg` parameter is the
  last mention. Harmless and wrong. Trigger: next edit to that param block.
