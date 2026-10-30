# Contributing

Two things first, because they shape everything else.

**This tool writes to monitors over a channel that can damage them.** One of
the two panels it was built for takes its input command on a manufacturer
service channel (I2C source address `0x50`). Sending unknown values there has
bricked LG monitors. So the rules in [`AGENTS.md`](AGENTS.md) are not style:
read its **Hard safety rules** before touching anything, and do not propose a
change that searches, sweeps or guesses a VCP code or value. Values come from
documentation, from [`displays.toml`](displays.toml), or from what a user types.

**Nobody can test hardware they do not own.** The project was developed against
exactly one LG 45GX950A, one ASUS PG42UQ, one Mac and one Windows PC. The
maintainers cannot verify a change on your monitor, and you cannot verify one on
theirs. A switch is only ever confirmed by a person looking at the screen; a
command returning success does not count, and neither does reading a value back
(both have lied here).

## How the repo is worked

`AGENTS.md` and the `CLAUDE.md` files are instructions for AI coding agents,
which do much of the implementation here under human direction. A change that
moves a monitor is confirmed on real hardware by a person before it is called
working; anything unwatched is said to be unwatched. Contributions from agents
are welcome and held to the same rules as contributions from people: the safety
rules, specs first, tests that can fail.

## Before you open a pull request

1. Read `AGENTS.md`, then the `AGENTS.md` of the platform you are changing
   (`macos/AGENTS.md` or `windows/AGENTS.md`).
2. If the change alters behaviour both platforms share, follow
   `specs/README.md`, "How a change flows". Do not edit the other platform's
   directory.
3. Run the suite. It needs no hardware and cannot move a monitor:
   - macOS: `cd macos && make test`
   - Windows: `cd windows\tests; .\run.ps1`
4. Add a test for what you changed, then break your change on purpose and
   confirm the test goes red (`make mutate` on macOS does this systematically).
5. Update the docs in the same commit: `README.md`, the platform README,
   `displays.toml` if a documented value changed, `docs/measurements.md` if a
   rule now rests on something you measured.
6. Conventional commits: `feat(macos): ...`, `fix(windows): ...`, `docs: ...`.

A `.context/` directory is gitignored; it is disposable per-session working
notes and nothing in it is part of the project.

## Versioning and releases

Both platforms ship as one product with one release version. A release is an
annotated Git tag, `vMAJOR.MINOR.PATCH`, pointing to the exact commit tested on
both platforms. Publishing the repository does not make it version 1.0.

### Choosing a version

Use [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html), with the
following project convention during initial development. Compare **all changes
since the previous release**, and take the largest applicable increase:

| Change | Before 1.0 | From 1.0 onward |
|---|---|---|
| Compatible bug or security fix, or an internal or documentation correction released on its own | Patch: `0.3.0` → `0.3.1` | Patch: `1.2.0` → `1.2.1` |
| Compatible feature or deprecation | Minor: `0.3.1` → `0.4.0` | Minor: `1.2.1` → `1.3.0` |
| Incompatible change to the public contract | Minor: `0.3.1` → `0.4.0` | Major: `1.2.1` → `2.0.0` |

The public contract is the documented commands, flags and exit codes;
configuration keys and their meaning; output explicitly documented for machine
consumption; and installation, upgrade, permission and platform requirements.
Human-readable layout and internal helpers are not parsing APIs, although
wording required by the specs remains binding on implementations. A fix that
restores the documented contract can be a patch; dropping a valid configuration
or documented workflow is an incompatible change, even if motivated by a bug.
Breaking changes require migration instructions, including before 1.0.

Commits do not each need a version increase or a release. A fix affecting only
one platform still uses the next shared product version when released. Version
1.0 marks a deliberate commitment to stable public contracts, supported upgrade
paths and a validated support matrix; it is not a deadline or a visibility
setting.

### Product version, specification revision and build identity

- **Product version:** the release number shown by an installed copy. The
  constants currently live in `macos/lib/common.sh` (`TK_VERSION`) and
  `windows/install.ps1` (`$VERSION`). Both must match the tag at release time.
  Each platform updates its own constant during release preparation.
- **Specification revision:** each platform's `SPEC-REVISION` records the shared
  contract it implements. Follow [the specification workflow](specs/README.md#how-a-change-flows)
  for behaviour changes. Several revisions may land in one product release;
  a release need not change the revision. Release numbering and this policy do
  not themselves require a new specification revision.
- **Build identity:** `trigger-kvm status` includes the install stamp, with the
  source commit when available. A checkout between tags is a development build,
  even when its product version still matches the previous release. Only a
  clean checkout of a release tag, or its unmodified source archive, identifies
  that release. Record the commit when testing development builds; for an
  archive without Git metadata, retain the tag and download provenance.

### Preparing and publishing a release

1. Resolve the release blockers in [publication readiness](TODO.md#publication-readiness),
   including the Windows handoff and privacy review. For public distribution,
   review all refs and GitHub surfaces that will become public, not just the
   current files. Decisions about author metadata and any history rewrite need
   separate approval.
2. Choose the version and have each platform update its constant. Both
   `SPEC-REVISION` files must equal the latest revision in
   [`specs/CHANGELOG.md`](specs/CHANGELOG.md). Update installation and usage docs
   to match the candidate. Do not tag an intermediate cross-platform state.
3. Test clean checkouts of the same final candidate commit on both native
   platforms: `cd macos && make test`, and `cd windows\tests; .\run.ps1`
   under Windows PowerShell 5.1. Run relevant mutation tests and require CI to
   pass. Record commands, environments, results and skips; a skipped check is
   never a pass. A changed candidate needs validation again in proportion to
   the change, on both platforms where affected.
4. Verify fresh installation, upgrade with configuration preserved, and the
   supported autostart tiers. Confirm physical switching by eye on the claimed
   reference hardware and retain dated evidence in `docs/measurements.md`.
   State unverified hardware paths as limitations; do not broaden compatibility
   claims from fixture tests or successful writes. All hardware checks follow
   the safety rules in `AGENTS.md`.
5. Prepare user-facing release notes covering changes since the previous tag,
   installation and upgrade instructions, migrations, tested platforms and
   known limitations. Publish these with the release; the specification
   changelog is an implementation ledger, not a substitute for release notes.
6. Obtain explicit maintainer approval to tag and publish the reviewed
   candidate. Approval to commit or push ordinary work does not authorize a
   release or a repository visibility change. Create the annotated tag at that
   tested commit; any distributed assets must come from it.

Released tags and assets are immutable. Corrections get a new version; never
move a release tag or replace its contents. An optional release candidate uses
`vX.Y.Z-rc.N`, with matching product constants and its limitations stated in the
notes. It still requires safety and privacy review and approval to publish;
failed automated checks must be resolved before tagging. Each revised candidate
gets a new tag. A final release must pass the full release checklist.

## Reporting a monitor that is not one of the two

This is the most useful thing an outside contributor can do, and it needs
facts, not guesses. Open a **New monitor report** issue and include:

- Make and model, and the EDID vendor and product ids exactly as
  `trigger-kvm list` prints them.
- The output of `trigger-kvm list`, with personal identifiers redacted as below.
- Which method worked: **standard** DDC/CI (VCP `0x60`), or a manufacturer
  method the walkthrough offered. Say which input values you confirmed, and
  confirm each one **visually**, in both directions.
- Which OSD setting you turned off to stop the monitor choosing its own input
  (the name differs per vendor), and whether it stayed put while the other
  computer slept.
- Which platform and GPU, and the driver version on Windows.

Do not report a value you found by trying codes or values that are not
documented somewhere. If your monitor answers neither standard DDC/CI nor a
method the walkthrough already knows, say so; that is a useful report on its
own, and the answer may be that it cannot be helped.

## Reporting a bug

Include the platform, `trigger-kvm status`, the relevant lines of
`trigger-kvm logs`, and what you saw on the screens. A log line saying a switch
was sent is not evidence it happened; what the monitor showed is.

Before posting diagnostic output, remove device serials, Bluetooth addresses,
usernames, personal paths and device names, and USB/PnP instance identifiers.
Use consistent labels such as `<device-a>` where identity relationships matter.
Keep model names, EDID vendor/product ids, input values and error messages;
those explain the behavior without identifying your devices. Review screenshots
and attachments too. Never attach credentials or an unreviewed configuration.
