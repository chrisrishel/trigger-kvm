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

Completed installed/hardware evidence is retained; the changed bootstrap's
bounded session-0 check also passed on 2026-10-31. Detailed candidate evidence
and limits are in `../docs/measurements.md` and `RELEASE-CHECKS.md`. Do not repeat
completed profile checks. The owner installation was restored at `6a5afcf` on
2026-10-30 and upgraded to `ab82fce` on 2026-10-31 with current config/PATH and
boot/enabled/running state preserved. The temporary Switch user policy is also
restored. Both disposable accounts/profiles were privately backed up and
removed with approval; the standard account's test-added right was restored
first. Independent verification passed after cleanup.

Keep fixture tests, native OS/installed checks and physical observations
distinct. The final physical writes ran after local sign-in in session 0,
one panel at a time. They did not test a detector-triggered or pre-login
physical write. Earlier ASUS dxva2 and local-console NVAPI confirmations cover
unchanged switcher/config source. Driver-update/port-move checks keep their
TODO triggers; never test S3 standby.

Publication remains blocked by the owner's 2026-10-30 privacy-review decision.
Product version remains 0.2.0; 0.3.0 is the next coordinated release target.
Windows source and the installed `ab82fce` implement specification revision 16.
Do not tag, publish or change visibility as part of this validation.

The 2026-10-31 review findings are resolved in Windows code/tests/docs. Native
5.1 adversarial reproduction, all 22 suite files, 20 mutations and the actual
S4U session-0 success/control/failure checks passed. Fixture tasks were removed
and the current owner configuration, task, PATH and watcher state were preserved.
See the dated measurement and release-check records for details.

The authorized live upgrade to `ab82fce` used the supported installer and
rebuilt the secured task. Installed hashes/stamp, exact config bytes, PATH,
boot/enabled/running state, one owned watcher and its ordinary session-0 token
passed verification. Private backups are retained. No repeat of the complete
manual matrix is required for unchanged detector, switcher or token-restriction
code; no reboot or physical write was performed during this upgrade.

Privacy remains a separate task. The owner's policy is to retain public
authorship/name and GitHub handle while removing private email addresses,
device identifiers and personal machine/profile details from everything
published. This work authorizes neither history/author-metadata changes nor
publication, tags or visibility changes. Product version remains 0.2.0.

Revision 16's menu-height defect was reproduced in a native 12-row console
before implementation. Both primitives now share the viewport renderer; 30
automated native console cases and 21 relevant mutations cover scrolling,
wrapping, resize, navigation, Done, disabled/separator rows and fallback state.
See the dated evidence in `../docs/measurements.md`. This menu-only work does
not repeat hardware, reboot, profile or installed boot validation. The separate
privacy and coordinated-release gates remain open.

## Refresh the checkout after the authorized privacy rewrite

Kind:     defect report
Spec:     ../docs/privacy.md; CONTRIBUTING.md, Versioning and releases
Why:      the old checkout carries identifiers and email metadata that must not be merged or pushed back into the sanitized history
Owed:     archive the old checkout privately, clone main anew, set the repository-local GitHub noreply email, open the new checkout in development tools, and run the native Windows PowerShell 5.1 suite
Verified: the owner authorized the cross-platform privacy substitutions, historical commit/message/metadata rewrite, replacement of main and v0.2.0, and removal of affected Actions records on 2026-10-31; this supersedes earlier statements withholding history-cleanup approval, but does not authorize publication

Follow the exact migration instructions in `../docs/privacy.md`. Preserve and
review any uncommitted file edits before copying them into the new clone; do
not import old branches, tags or Git metadata. The display-row fixture uses a
synthetic serial with every existing assertion retained. Historical commit
references now identify the sanitized source; installed copies retain their
original stamps. Privacy-only edits do not require a reinstall, new profiles,
reboot or physical monitor testing. Record the native suite outcome and skips;
product version remains 0.2.0 and the next coordinated release is 0.3.0.
