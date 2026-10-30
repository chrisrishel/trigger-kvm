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
