# The configuration file — normative

One flat `key = value` file, written by `configure` and safe to edit by hand.
Both platforms read and write it. **This is the sharpest drift risk in the
project**: a reader that disagrees with the writer fails silently, across
machines, and presents as a hardware fault.

## Where it lives

| platform | path |
|---|---|
| Windows | `%LOCALAPPDATA%\trigger-kvm\config` |
| macOS | `~/Library/Application Support/trigger-kvm/config` |

It sits beside the log, **never** inside the program directory, so uninstalling
does not throw away a configuration that represents real work.

## The line format

Deliberately not TOML or JSON: it is read on every device arrival and must not
depend on a parser being installed. The whole reader is one regular expression.

```
^\s*([A-Za-z0-9_.\-]+)\s*=\s*(.*?)\s*(?:#.*)?$
```

That is the definition. Everything below follows from it, and every one of these
is a way two readers could differ, so each is stated:

- A key is `[A-Za-z0-9_.-]+` and is **lower-cased on read**.
- Everything after the **first** `=` is the value — so a value may contain `=`
  and it is not a second separator.
- The value is **cut at the first `#`**, then trimmed at both ends. There is no
  escape for a literal `#`.
- Values keep their case, **verbatim**.
- A line that does not match is **ignored**, not an error. A whole-line comment
  is simply a line that does not match.
- On a **duplicate key the LAST one wins**, because assigning into a hash table
  does.
- A missing file reads as **empty**, not as an error. "No config yet" is a normal
  state that every caller already handles, and failing here would break `status`
  and `configure` on exactly the machine that needs them.

## Value parsing

Two converters, and **both fail rather than guess or default**.

| kind | accepts | example |
|---|---|---|
| byte (an input value) | `0xNN`, `0XNN`, or 1–3 decimal digits ≤ 255 | `0x11`, `17` |
| word (an EDID id) | `0xNNNN` (1–4 hex digits), or 1–5 decimal digits | `0x1E6D` |

A leading zero is **decimal, not octal**: `010` is ten. Shells read it as eight
by default, which would be a silent cross-platform disagreement about which
input to select.

**A caller must treat a parse failure as "refuse", never as zero.** This is the
one that has already cost this project: a missing value became `0x00` on the
wire, an input no monitor has, so every switch silently did nothing and said
nothing. The null check was present and did not fire.

So the property to assert in a test is that **nothing is sent** — not that a
check ran.

## The keys

```
install.autostart = boot          # boot | login | no

computer.this = mac               # what THIS computer is called below

display.lg.vendor  = 0x1E6D       # EDID manufacturer id
display.lg.product = 0x9E9D       # EDID product id
display.lg.name    = LG ULTRAGEAR+
display.lg.method  = lg-alt       # standard | lg-alt
display.lg.input.0xD0 = pc        # which computer is on which input
display.lg.input.0xD1 = mac

trigger.device   = usb:046d:0843, bt:0011223344ff
trigger.debounce = 3.0
trigger.settle   = 0.75
```

`trigger.device` is comma-separated. An entry is `usb:VVVV:PPPP`,
`bt:AAAAAAAAAAAA`, or a bare `VVVV:PPPP` — **bare means usb**, so configs written
before Bluetooth existed keep working unchanged. A reader must normalise the bare
form, or every "currently a trigger" marker silently stops appearing, which reads
as "none of these are configured" and is worse than no marker at all.

## `display.<label>.input.<value> = <computer>` is the whole map

There is no second table. `pull` looks up `computer.this` in it; `to mac` looks
up `mac`. **The same lookup, the same code path, one name apart** — so the two
can never disagree about where a computer is.

Windows previously had `display.<label>.self` *and* `scene.<name>.<label>`, which
were two shapes for one fact ("computer C is on input V of display D"). They
could drift, and did. **Do not reintroduce a second table.**

Rules the reader must enforce:

- A value that does not parse as a byte is **dropped, not zeroed**.
- Two inputs naming the same computer on one panel is a **refusal**, not a coin
  toss: it means the file was edited wrongly, and picking one would switch to an
  input nobody meant on a desk this machine cannot see.
- A computer named on no input of a panel means that panel cannot go there — and
  a `to` naming it must move **nothing at all**, not the panels that could. A
  half-applied arrangement leaves the desk in a state nobody configured, and you
  have to work out which half landed.

## A config is machine-local

Never copy one between hosts, and never seed one from another desk.
`computer.this` differs, and the LG 45GX950A reports a **different EDID product
id per input** — `0x9E9D` on one host's DisplayPort, `0x9E9F` on another's USB-C.
A copied id matches nothing. See `../displays.toml` for the measurements.

The label (`lg`, `asus`) is a local name someone chose. Nothing outside that
machine's config refers to it.

## Ordering

Displays are written in the order the walkthrough holds them; a reader may
return them in any order, because every value is resolved before any of them is
sent.

Within one panel, the input map is written **in the order the computers were
listed**, not by input value. Reading the file sorts by key, which is the hex —
so the same two computers came out `mac, pc` on one panel and `pc, mac` on the
next, purely because of which socket they happened to be plugged into. The order
someone listed their computers in is the one they will look for.

## Hand edits survive

`configure` rewrites this file from its answers. Any key the walkthrough does not
ask about — `trigger.debounce` and `trigger.settle` today — must be **carried
across from the existing file** rather than reset to a default.
