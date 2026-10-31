# Publication privacy

Public authorship is intentional: retain the copyright name, contributor names
and GitHub handles. Personal email addresses, device serials, Bluetooth
addresses, host-specific device-instance components, personal device labels
and account/profile paths are not publication data. Use consistent synthetic
values in fixtures and replacement labels in diagnostic examples. Preserve
model names, vendor/product IDs and documented input values: they explain the
hardware behavior and are not per-device identifiers.

## Sanitized development history

The owner authorized a history-preserving privacy rewrite on 2026-10-31.
All 251 existing commits retain their author and committer names, timestamps,
order and parent relationships. Identifying values in historical files and
messages are replaced consistently, and author/committer/tagger email uses the
maintainer's GitHub noreply identity. Commit references in text follow the
rewritten history. Hardware observations and safe DDC values are retained.

The annotated `v0.2.0` tag retains its name, tagger name, date and message and
points to the corresponding sanitized commit. Its object ID changes. This is
the owner's one-time pre-publication privacy exception to tag immutability;
ordinary releases still follow `CONTRIBUTING.md`. The cleanup did not create a
release or change the `0.2.0` product version; subsequent release preparation
is tracked in [TODO](../TODO.md#publication-readiness).

The original bundle, replacement inventory, commit mapping and Actions evidence
are retained privately outside tracked files. Affected Actions runs are removed
because their head-commit metadata contains the personal email. Historical CI
links therefore identify privately retained validation records instead of
linking to deleted runs. New validation belongs to the sanitized history.

Existing installed copies may still display their original source commit.
That stamp describes the installed copy; it need not be changed for this
cleanup. The remaining real serial in the Windows display-row test fixture is
synthetic in the sanitized history, with all assertions retained. Runtime
behavior, saved configuration and installed watchers are unchanged.

## Commit identity and future reports

For this maintainer's checkout on each machine:

```sh
git config --local user.email "54340943+chrisrishel@users.noreply.github.com"
```

Contributors should use their own GitHub noreply identity or an email address
they intentionally publish. Preserve human author names. GitHub's web email
privacy settings do not configure command-line Git; changing the setting for
future commits does not change earlier history.

Before sharing diagnostics, follow `CONTRIBUTING.md`: review config, logs,
screenshots and attachments for identifiers and use consistent replacements.
Keep private replacement maps and raw backups out of commits. Export tracked
files when producing an archive; do not zip a working directory containing
ignored research, audit material or installation backups.

## Refreshing the Windows checkout

Close tools that may write or push from the old checkout. Check for uncommitted
work and retain it privately before proceeding. Do not merge the old history
into the sanitized branch, and do not push from the old checkout.

Keep the old directory as a private archive and clone the repository into a new
directory. If the old directory is named `trigger-kvm`, these commands run from
its parent directory in PowerShell:

```powershell
Rename-Item -LiteralPath .\trigger-kvm -NewName trigger-kvm-private-before-privacy
git clone https://github.com/chrisrishel/trigger-kvm.git
Set-Location .\trigger-kvm
git config --local user.email "54340943+chrisrishel@users.noreply.github.com"
git status --short
git rev-parse --short HEAD
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\windows\tests\run.ps1
```

Use a different archive name if that directory already exists. Open the new
checkout in the Windows development tools. Any uncommitted work from the old
copy must be reviewed and copied as file edits, without importing its Git
history. A routine `git pull` in the old checkout is not this migration.
No reinstall, monitor switching, profile creation or reboot is needed solely
to refresh the checkout. Record the native suite outcome and any skips in the
Windows handoff; final release validation remains a separate gate.

## Audit limits

The publication check covers current tracked files, every commit and tag
reachable from published refs, commit messages and identity metadata, and
accessible GitHub artifacts. Automated secret patterns are supplemented with
exact comparisons against known historical identifiers and manual review.
They are not a proof that every possible identifier or secret is absent.

A rewrite does not guarantee deletion of cached or unadvertised GitHub objects
or outside copies. The owner accepts that residual risk for the identifiers
found here. GitHub secret scanning was disabled during the audit. The API could
not enumerate linked Projects; the owner confirmed on 2026-10-31 that there
are none. Repeat the accessible-surface checks for the final release candidate
and review any additional surfaces before making the repository public.

References: [GitHub email identities](https://docs.github.com/en/account-and-profile/concepts/email-addresses),
[history cleanup](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/removing-sensitive-data-from-a-repository),
and [repository visibility](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/managing-repository-settings/setting-repository-visibility).
