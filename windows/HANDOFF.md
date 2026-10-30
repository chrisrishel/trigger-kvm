# Handoff — work the Windows side owes

**This is an INBOX.** Anyone may append an entry; only the Windows side works
through it and deletes resolved entries. Git keeps the history.

Never change another platform's code, tests or documentation. Appending a
reading-based defect report to its `HANDOFF.md` is the one exception. Shared
specification changes arrive through `specs/CHANGELOG.md` and the revision
check, not duplicate inbox entries (`specs/README.md`).

## Entry format

```markdown
## A short title, in the imperative

Kind:     defect report
Spec:     relevant specification section (or: n/a)
Why:      the user-visible problem
Owed:     the remaining work
Verified: what was and was not checked, on which platform
```

A report is evidence to investigate, not proof of behavior on another platform.
Resolve it with native evidence; remove it in the commit that lands the fix.

---

## Complete the coordinated Windows release validation

Kind:     defect report
Spec:     CONTRIBUTING.md, Versioning and releases; TODO.md, Publication readiness
Why:      automated regressions and one existing-profile upgrade do not establish all installation/support claims
Owed:     run the remaining checks in RELEASE-CHECKS.md with the owner present
Verified: Windows PowerShell 5.1 suite and publication mutations; native Unicode/apostrophe child, WSH and CMD fixtures; cleanup execution boundaries across 13 native invocation forms and generated launcher/watcher fixtures (2026-10-30); real boot-tier upgrade, installed status/Cancel, native task restoration after timeout; shipped ASUS dxva2 switching both ways visually confirmed on 2026-10-29

Still required before release:

- Fresh administrator-capable and separate standard-user profiles; approve and
  decline UAC, verifying the intended user's files, task principal and PATH.
  The first fresh administrator-capable login installation passed on `2835cb0`,
  but its boot row rejected the unelevated administrator. Corrected `4c0f13b`
  passed selection from ordinary PowerShell, declined-UAC login fallback with
  existing config, and approved-UAC S4U/Limited installation for the intended
  user. Fresh product-state declined-UAC fallback also passed after preserving
  this profile's retained data. Separate standard-user elevation is unverified.
- Real profile/checkout paths containing spaces, apostrophes and non-ASCII text
  through standard-user elevation and uninstall. Administrator-capable login,
  upgrade and approved/declined UAC covered those characters in both paths.
- Repeat installed boot-to-login/no-autostart transitions with the corrected
  removal-only elevation path in `462204a`, then uninstall with the source
  unavailable. Its clean native suite passed 19 files without skips; CI passed
  both platforms with hosted hardware skips explicitly recorded.
  The `4c0f13b` uninstall removed task/program/PATH and retained config/log
  bytes but returned 1 when CMD lost its deleted shim; the generated-shim fix
  has native fixture coverage and awaits an installed repeat.
  On `4c0f13b`, a real reboot started exactly one
  intended S4U/Limited watcher in session 0 without the test user signing in.
  This is native startup evidence, not physical switching evidence.
  Boot-to-login also passed through the installed shim; a real test-user
  sign-out/sign-in produced one new watcher in the new interactive session.
  Login-to-no-autostart started one watcher immediately; after another real
  sign-out/sign-in the enabled task had no triggers and no watcher was running.
- Native suites on both platforms at the coordinated release commit, privacy
  review of all refs/GitHub surfaces, and the driver's/port's deferred checks in
  TODO.md when their triggers occur. The post-reboot read-only identity check on
  driver 616.64 is complete; the cable-move/next-driver-update checks remain
  deferred. Never test S3 standby.

On 2026-10-30 clean `2835cb0` was installed and verified against source hashes,
with original config values/PATH and S4U/Limited/enabled/running state preserved.
Installed Save retained a synthetic unknown key and the build stamp; Cancel
preserved config bytes. Original config bytes were restored afterwards.
The same installed candidate passed real interactive Ctrl+C from enabled/running
and NVAPI away-and-back switching on both panels, each visually confirmed with
the other display kept on Windows. These local-console writes do not establish
fresh-boot/session-0 behavior. The owner watcher is deliberately paused for the
coordinated profile matrix; restore the original boot/enabled/running state when
that session ends.
Installed `4c0f13b` also restored enabled/stopped and disabled/stopped after
real Ctrl+C in elevated test-profile consoles, with config bytes unchanged and
no helper recovery. Each required three presses before CMD's termination
prompt; no single-press responsiveness claim is made. These no-autostart tasks
had no self-heal trigger. Native timeout checks cover all three states; error
paths remain fixture coverage.
Privacy review covered reachable history and accessible GitHub surfaces;
historical identifier/author-email publication decisions remain outstanding.

The implementation is at specification revision 15. Product version stays
0.2.0 during remediation; 0.3.0 is the next coordinated release target.
