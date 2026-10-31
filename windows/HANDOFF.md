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
Why:      native installation evidence does not establish restricted session-0 display writes or finish the release/privacy gates
Owed:     finish the owner reboot/device checks and remaining evidence collection in RELEASE-CHECKS.md
Verified: 2026-10-30, native PowerShell 5.1 suite: 21 files without skips; 6a5afcf standard-user credential Cancel/success, restricted installed boot watcher, pre-login startup after a real reboot, installed Save/Cancel, login/manual sign-out/sign-in, fresh-product UAC-decline fallback and source-unavailable uninstalls; original owner upgraded/restored to 6a5afcf with unchanged config/PATH and one enabled/running restricted boot watcher

Remaining work:

- Verify the restored original-owner installation after a real reboot, including
  its process token, single watcher and startup before interactive login.
- Validate required device access through the restricted session-0 path. Use the
  installed switcher, one panel at a time, and require visual confirmation in
  both directions. Prior local-console ASUS dxva2 (2026-10-29) and both-panel
  NVAPI (2026-10-30) observations remain valid for those tested contexts; they do
  not establish this new execution path. Never test S3 standby.
- Complete the separate administrator-PATH comparison. Its profile hive was
  unloaded and the private copied-hive reader failed; this is explicitly
  unverified. The standard account received only the expected batch-logon right,
  which remains after successful installation/uninstall by design. Coordinate
  disposable-account cleanup separately; no accounts have been deleted.
- Run both native platforms' suites at the coordinated release commit, inspect
  CI, and complete the separately requested privacy review. Publication remains
  blocked by the owner's 2026-10-30 decision about historical identifiers and
  author metadata. Driver-update/port-move checks retain their TODO triggers.

The standard-profile program directory was owned by Administrators; the config
was owned by the intended standard user. That user successfully configured and
uninstalled through the installed shim. Uninstall preserved all original PATH
entries/order, removing a trailing semicolon; do not claim byte-identical PATH.
The exact archive candidate is established by provenance and installed source
hashes; its stamp correctly says it is not a Git checkout.

The owner's original boot/enabled/running state and temporary Switch user policy
have been restored. Dated evidence and earlier administrator-profile/Ctrl+C
results are in `../docs/measurements.md`; do not repeat completed profile work.
Product version remains 0.2.0, specification revision 15; 0.3.0 is the next
coordinated release target.

## Validate the restricted boot path's device access

Kind:     defect report
Spec:     configure.md section 8; root AGENTS.md, host-owned startup tier
Why:      S4U / RunLevel Limited alone did not restrict the native administrator control
Owed:     confirm required device access and physical switching through the protected bootstrap's restricted session-0 child
Verified: clean 6a5afcf native bootstrap fixture passed, missing-integrity mutation refused before launch; actual installed standard-user watcher and post-reboot watcher had the intended owner, session 0, medium integrity, no administrator/power-user membership and only change-notify privilege; restored original-owner watcher passed the same token checks

All bounded diagnostic tasks were removed. Token/launch and installed startup
evidence are complete for the observed cases. Physical switching through this
restricted session-0 execution path remains unverified.
