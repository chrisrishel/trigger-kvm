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
- Real profile/checkout paths containing spaces, apostrophes and non-ASCII text.
- Boot/login/no-autostart transitions, actual logon/reboot behavior, and
  uninstall from the installed shim after the source checkout is unavailable.
- Interactive Ctrl+C during an installed trigger check. Native timeout
  restoration covered enabled/running,
  enabled/stopped and disabled/stopped; error/cancellation remain fixture tests.
- Final-candidate NVAPI physical switching, one panel at a time with visual
  confirmation. The ASUS dxva2 check is complete; no LG write was sent in it.
- Native suites on both platforms at the coordinated release commit, privacy
  review of all refs/GitHub surfaces, and the driver's/port's deferred checks in
  TODO.md when their triggers occur. The post-reboot read-only identity check on
  driver 616.64 is complete; the cable-move/next-driver-update checks remain
  deferred. Never test S3 standby.

On 2026-10-30 clean `2835cb0` was installed and verified against source hashes,
with original config values/PATH and S4U/Limited/enabled/running state preserved.
Installed Save retained a synthetic unknown key and the build stamp; Cancel
preserved config bytes. Original config bytes were restored afterwards.
Privacy review covered reachable history and accessible GitHub surfaces;
historical identifier/author-email publication decisions remain outstanding.

The implementation is at specification revision 15. Product version stays
0.2.0 during remediation; 0.3.0 is the next coordinated release target.
