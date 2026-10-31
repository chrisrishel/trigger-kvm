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

## Secure dependency loading before the boot token is restricted

Kind:     defect report (P1; native confirmation required)
Spec:     specs/configure.md 8; root AGENTS.md, ordinary-user boot execution
Why:      a user-controlled module may execute with the original S4U token before the watcher restriction runs
Owed:     confirm or disprove the native loading path, then secure every dependency used before token restriction and test the boundary
Verified: source at 7a2a9a4; a bounded PowerShell 7.6.9 reproduction on macOS executed a substitute module before restriction with a user module directory first in PSModulePath; Windows PowerShell 5.1 and an elevated S4U task were not exercised by this review

`lib/user-launch.ps1:Get-BootTaskArguments` emits an unqualified `Add-Type`
before `[TkUserLaunch]::Run`; its catch also uses `Write-Error`. `-NoProfile`
does not disable module autoloading. Windows PowerShell's module search can
include user-writable locations before the system modules. Embedding the C#
source in a protected task therefore does not by itself establish that all
code executed before restriction is trusted.

Reproduce in a fresh native 5.1 child using the actual generated bootstrap.
Use an isolated temporary module tree with a substitute
`Microsoft.PowerShell.Utility` manifest exporting `Add-Type`; its function
should only write a fixture marker and throw. Set search paths only in the
fixture process, record the child's effective search order, and distinguish
normal startup from an explicitly supplied hostile path. Do not install a
module in a real profile or change persistent environment/policy. Avoid
preloading the trusted module in the child, which could hide the defect.

The macOS reproduction establishes the command-resolution hazard, not a native
privilege-escalation result. If native behavior disproves it, retain the exact
command, resolution evidence and conditions explaining why. Otherwise fix the
bootstrap so normal and error paths cannot consult user-controlled code before
restriction. Review the directly implicated compiler, assembly and temporary
file dependencies too; qualifying a command by module name alone does not pin
the module's trusted location. Compare a minimal secured bootstrap with a
protected launcher only if the existing design cannot enforce that boundary.

Keep the existing guarantees: intended owner/session, medium integrity, no
enabled administrator/power-user membership, only change-notify privilege,
failure without an unrestricted child or privileged user-log write, correct
quoting/exit codes and one detector. Add a native adversarial regression and
mutate the protection to prove the test detects its removal.

Sources: [module autoloading](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_modules?view=powershell-5.1),
[Windows PowerShell module-path construction](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_PSModulePath?view=powershell-5.1).

## Test elevation eligibility independently of administrator membership

Kind:     defect report (P2)
Spec:     specs/configure.md 8; Windows UAC eligibility in lib/host.ps1
Why:      the native suite fails for a supported standard account allowed to supply administrator credentials
Owed:     correct the policy-dependent expectation while retaining the independent native token-membership check
Verified: native-publication.tests.ps1:25 at 7a2a9a4 compares nativeAdmin to Test-CanElevate; the actual function with mocked standard-user claims and EnableLUA=1 / ConsentPromptBehaviorUser=3 returns true while nativeAdmin is false

Keep the `whoami` versus claims assertion. The following assertion must not
equate group membership with eligibility: `Test-CanElevate` also permits a
standard user's credential prompt and preserves uncertainty on query failure.
Cover administrator membership, permitted/denied standard-user prompts and
unavailable policy with focused native 5.1 fixtures. Use the existing elevation
tests and conventions; do not recreate disposable accounts merely to supply
policy inputs that can be isolated. Prove the regression with a mutation.
The owner has approved resolving this finding, including correction of this
erroneous expectation; that is not permission to skip or weaken the coverage.

## Reconcile the boot-validation wording with the recorded evidence

Kind:     defect report (P3)
Spec:     CONTRIBUTING.md, Preparing and publishing a release
Why:      the installation guide calls completed boot validation outstanding
Owed:     remove the stale claim and synchronize the Windows release-status wording
Verified: windows/README.md:82-83 at 7a2a9a4 says corrected boot paths still require installed validation; RELEASE-CHECKS.md and docs/measurements.md record completed 6a5afcf installed/reboot/restricted-session checks

Retain the actual limits: session-0 physical writes were after local sign-in,
not detector-triggered or pre-login writes. Completed evidence remains valid
for unchanged behavior. The open reports above, final coordinated candidate
checks and separate privacy work still block publication. Resolve the earlier
handoff's no-remaining-implementation-defect claim when processing this queue.

### Validation and coordination for these three reports

The owner prefers minimal additional manual interaction, with responsible
testing of the changed behavior. Start with bounded, automated native 5.1
fixtures, focused regressions and their mutations, then the full Windows suite
and CI. Preserve the completed profile, reboot and physical evidence rather
than repeating the whole release checklist. Do not recreate accounts, change
the live installation, reboot or switch monitors merely because a candidate
commit changed.

For a bootstrap fix, verify the actual child token and launch/failure behavior
in the affected context. Prefer a bounded session-0 fixture with harmless
children over a product reinstall or reboot. If elevation or an installed or
physical check is necessary, first finish the automated work, identify the
specific gap and why existing evidence cannot cover it, and coordinate the
smallest sufficient check in one batch. Preserve and restore the owner's
installation/state; all monitor and no-S3 rules remain in force. No new manual
matrix is required solely for the assertion or documentation correction.

Record commands, candidate identity, results, mutations and limits in the
existing measurement/release documents; update `TODO.md` and remove these
entries only when resolved. Push the finished fixes and inspect CI. Report
remaining manual work explicitly rather than counting an unrun check as a pass.

Privacy remains a separate task. The owner's policy is to retain public
authorship/name and GitHub handle while removing private email addresses,
device identifiers and personal machine/profile details from everything
published. This handoff authorizes neither history/author-metadata changes nor
publication, tags or visibility changes. Product/spec versions remain 0.2.0/15
unless an actual shared-contract change is separately required.
