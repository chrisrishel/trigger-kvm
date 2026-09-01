# 002 -- Instruction files that both Claude Code and Codex load in full

**Date:** 2026-08-31
**Status:** accepted

## Context

Two agents work this repo. Claude Code loads `CLAUDE.md` (and whatever it
`@`-imports) at every session start; it does not read `AGENTS.md` on its own.
Codex loads the `AGENTS.md` chain from the git root down to its working
directory, concatenated, and does not read `CLAUDE.md`.

On 2026-08-31 the root `AGENTS.md` was 53,390 bytes and `CLAUDE.md` was three
lines of prose saying "see AGENTS.md". Codex was reading the first 32,768 bytes
and dropping the rest -- which happened to be `DO NOT CHANGE ANYTHING IN THE
OTHER PLATFORM'S DIRECTORY`, the HANDOFF rules, both platforms' build and test
sections, and every convention including *do not hardcode display indices*,
whose failure mode is a service-channel write landing on the wrong panel. The
hard safety rules survived only because they come first.

## What was measured

Codex CLI 0.149.0-alpha.4.3 (bundled with the ChatGPT desktop app), verified
against its source at the same date:

- `codex-rs/config/defaults.toml`: `project_doc_max_bytes = 32768`. The schema
  describes it as "Maximum total bytes of project instruction content across all
  selected environments" -- one budget for the whole chain, not per file.
- `codex-rs/core/src/agents_md.rs`, `read_agents_md`: files are read root-first,
  `AGENTS.override.md` before `AGENTS.md` at each level, and `data.truncate(
  remaining)` once the budget is spent -- mid-line. The only signal is a
  `tracing::warn!` in the internal log. Issues openai/codex#7138 (closed, not
  planned) and #13386 ask for a visible warning; there is none.
- `load_project_instructions`: the global `~/.codex/AGENTS.md` is attached as
  host-provided user instructions and is NOT deducted from the budget.

Sentinel test, `codex exec` asked to quote the last line of a synthetic
`AGENTS.md` from context only: 19,755 B seen; 28,170 B seen (with a 6,909 B
global file alongside, so the global file does not count); 44,505 B not seen;
138,956 B not seen -- the last two with identical token counts, the signature of
a fixed cut.

Claude Code (docs, same date): loads a `CLAUDE.md` of up to 4 MiB in full; `@`
imports resolve relative to the importing file, four hops deep; subdirectory
`CLAUDE.md` files load on demand when files there are read; guidance is "target
under 200 lines per file -- longer files consume more context and reduce
adherence".

## Decision

Restructure rather than raise the cap.

- **Root `AGENTS.md`** holds what every session on either platform needs: the
  hard safety rules, the shared rules, the docs/specs workflow, the commands.
  Target 16 KB, hard cap 20 KB.
- **`macos/AGENTS.md` and `windows/AGENTS.md`** hold that platform's hazards and
  toolchain notes, 10 KB each. Codex loads one of them when its working directory
  is inside that platform; Claude Code loads the `CLAUDE.md` beside it on first
  read of a file there. Any root-plus-platform chain stays under 30 KB, leaving
  headroom under 32,768.
- **`docs/measurements.md`** holds the dated observations. A rule stays one
  paragraph; its evidence moves.
- **Every `CLAUDE.md` is `@AGENTS.md` plus Claude-specific additions only.** One
  source; two copies would drift.
- **Enforced** in `macos/tests/conventions.tests.sh`: each chain's byte total
  against the budget, and the import-only shape of every `CLAUDE.md`. Windows'
  suite is asked to mirror it.

## Why not raise `project_doc_max_bytes`

It is per-machine configuration, so a fresh checkout or a colleague's machine
silently regresses; and the length problem is real on both tools regardless of
the cap -- both vendors document that adherence falls as these files grow. A
budget that fails a test is the only version of this that survives the next
50 KB.

## Consequences

Adding a rule now means finding the file it belongs in and moving evidence out to
make room, not appending. The old sentence "every hardware-learned hazard stays in
THIS file" is gone; its purpose -- one home per fact -- is kept by the placement
rule instead.
