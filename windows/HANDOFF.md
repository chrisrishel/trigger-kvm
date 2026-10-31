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
Owed:     complete final sanitized remote-surface/linked-Projects review and release approval, and run both native platforms' suites at the final coordinated release commit
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

Publication remains blocked by the final review and approval gates in TODO.md.
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

The owner's privacy policy is to retain public
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

The Windows checkout migration completed on 2026-10-31. A clean sanitized clone
at `2551331` is now the active top-level workspace, with repository-local
noreply email and no imported old objects/refs. The old checkout, local edits,
private backups and linked worktrees are preserved in a separate private archive.
All 23 native PowerShell 5.1 test files passed without skips. Installed stamp,
config bytes, PATH and the enabled/running boot task are unchanged. Installed
stamps retain their original IDs; historical source references use sanitized
IDs (`../docs/privacy.md`). No reinstall, profile, reboot or physical test was
needed. See `../docs/measurements.md` for the migration evidence.

## Prepare Windows for the coordinated 0.3.0 release

Kind:     defect report
Spec:     ../CONTRIBUTING.md, Preparing and publishing a release; ../TODO.md, Publication readiness
Why:      the final release must have matching platform versions, current user documentation and native validation of the same candidate
Owed:     update the Windows version constant and guide, validate the resulting clean candidate under native PowerShell 5.1, and return its exact commit and results for macOS validation
Verified: the owner approved release preparation and a concise user-focused README on 2026-10-31; the root README and draft notes at ../docs/releases/0.3.0.md are prepared, macOS TK_VERSION is 0.3.0, and both platforms implement revision 16; tagging, release publication and visibility still require final approval

This is a bounded release-preparation task. The migration at `2551331` already
passed all 23 native files without skips; completed bootstrap/profile/reboot/
physical checks remain valid for unchanged code. The owner confirmed there are
no linked Projects. Final remote privacy checks still cover the release commit
and subsequent Actions output.

1. Update `$VERSION` in `windows/install.ps1` from `0.2.0` to `0.3.0`.
   Keep `SPEC-REVISION` at 16. Verify the install stamp and installed `status`
   receive that version using existing isolated installer fixtures; avoid an
   unnecessary live upgrade. Search for affected version assertions and docs.
2. Bring `windows/README.md` into line with the root guide: a brief user-facing
   introduction, a clear choice between a released tag/archive and development
   main before installation, and a link to the 0.3.0 notes. Preserve the
   detailed account/password, policy, transport and local-console limits in
   this platform guide. Correct present-tense `0.2.0`/privacy-blocker wording
   in `RELEASE-CHECKS.md` and resolve obsolete handoff statements; retain dated
   evidence as dated evidence. Do not edit `macos/` or governance files.
3. Run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File
   .\windows\tests\run.ps1` on the final clean candidate and inspect all skips.
   Run relevant installer/version mutation checks if available; retain the
   already recorded mutation evidence for unchanged runtime code. Do not add
   tests that merely pin a version literal, weaken assertions, or repeat the
   manual account/profile/reboot/monitor matrix for a version-and-docs change.
4. Compare the candidate with the installed/physical evidence and report any
   genuinely affected check before taking an action on the live installation.
   No new monitor writes, profile creation, account changes or reboot are
   requested. Preserve the existing config, PATH, task and watcher state.
5. Commit and push the finished Windows change using the repository-local
   noreply identity. Record the exact candidate tested, PowerShell/OS version,
   commands, results/skips and fixture stamp verification; keep raw receipts
   private. If a documentation receipt creates a later commit, identify that
   separately. Return the final candidate commit for the matching Mac suite
   and CI/privacy checks. Do not tag, publish or change visibility.
