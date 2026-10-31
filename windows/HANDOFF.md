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

## Complete the coordinated release gates

Kind:     defect report
Spec:     CONTRIBUTING.md, Versioning and releases; TODO.md, Publication readiness
Why:      validated Windows behavior does not approve publication of historical identifiers or complete coordinated release preparation
Owed:     complete the separately requested privacy review and run both native platforms' suites at the final coordinated release commit
Verified: 2026-10-30, Windows PowerShell 5.1 suite: 21 files without skips; installed 6a5afcf standard-user workflow, owner restoration/reboot and actual ordinary session-0 watcher tokens; both panels' NVAPI away/back through the installed restricted session-0 path, explicitly confirmed by the owner; administrator PATH unchanged

No Windows implementation or installed/hardware defect remains from this
remediation queue. Detailed candidate evidence and limits are in
`../docs/measurements.md` and `RELEASE-CHECKS.md`. Do not repeat completed
profile checks. The owner installation is `6a5afcf`, with original config/PATH
and boot/enabled/running state restored; the temporary Switch user policy is
also restored. Both disposable accounts/profiles were privately backed up and
removed with approval; the standard account's test-added right was restored
first. Independent verification passed after cleanup.

Keep fixture tests, native OS/installed checks and physical observations
distinct. The final physical writes ran after local sign-in in session 0,
one panel at a time. They did not test a detector-triggered or pre-login
physical write. Earlier ASUS dxva2 and local-console NVAPI confirmations cover
unchanged switcher/config source. Driver-update/port-move checks keep their
TODO triggers; never test S3 standby.

Publication remains blocked by the owner's 2026-10-30 privacy-review decision.
Product version remains 0.2.0, specification revision 15; 0.3.0 is the next
coordinated release target. Do not tag, publish or change visibility as part
of this validation.
