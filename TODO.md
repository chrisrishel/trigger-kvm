
- **Elevating to a *different* admin account breaks the install path.** `Request-Elevation`
  launches the child with `-Verb RunAs`; when the signed-in user is not an admin, Windows
  elevates a different account, whose `%LOCALAPPDATA%` is a different directory. The child
  then finds no config, installs to the wrong profile, and registers a task pointing at it.
  Untested and probably broken. Trigger: when someone reports boot-start failing on a
  standard (non-admin) user account, or before publishing. The fix is to pass the resolved
  paths to the child rather than letting it re-derive them.
