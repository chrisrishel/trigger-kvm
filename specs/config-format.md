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

- **`\s` is whitespace in the regex's sense**, which includes the carriage
  return of a CRLF line. A reader that trims only space and tab keeps the CR on
  every value: `lg-alt<CR>` is an unknown method and every switch refuses with a
  message that looks right. A UTF-8 byte-order mark at the start of the file is
  ignored; left in, it hides the first key.
- A key is `[A-Za-z0-9_.-]+` and is **lower-cased on read**.
- **Enumerated values are matched case-insensitively**: `Boot`, `LG-ALT` and
  `Standard` are `boot`, `lg-alt` and `standard`. Refusing `Boot` while
  accepting `boot` is a disagreement with whichever platform does not.
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

## A writer must not write what it cannot read back

Everything above defines what a READER does. This is the other half, and it was
missing: both implementations wrote values straight through and both were wrong
the same way, which is the argument for it being here rather than in either.

**Whatever a writer puts in a file, reading that file back MUST yield the same
string.** A value that would not survive the round trip is transformed before it
is written, never written and left to be silently altered on the next read.

Three characters break the round trip, and they follow from the rules above:

| in a value | what the reader does |
|---|---|
| `#` | cuts the value there, and **there is no escape** |
| CR or LF | ends the line, so the remainder becomes a separate line |
| leading or trailing whitespace | trimmed |

So a writer **removes `#`, CR and LF, and trims**. Nothing is escaped, because
this format has no escape and giving it one is a rule two readers could differ
on. `=` needs no treatment: a value may contain it.

**This is not hypothetical.** A monitor's name is written verbatim from what the
panel reports, and EDID descriptor strings are LF-terminated by the standard. A
panel calling itself `ACME #1 Display` is written intact and reads back as
`ACME`, on both platforms, today.

**The same rule covers values a writer merely passes through.** Content read from
an existing file has already been cut at `#`, so writing it back unchanged
silently rewrites somebody's hand edit. Preserving hand edits (below) means
preserving what the reader could see; a writer cannot restore what it never had,
and must not pretend to.

**Where a value's meaning depends on being exact** — an identifier something is
matched on, rather than a label somebody reads — a writer that cannot represent
it faithfully must **refuse to write it and say so**, rather than store a
transformed version that matches nothing. Silently storing a near-miss is the
failure this whole section exists to prevent.

## Value parsing

Two converters, and **both fail rather than guess or default**.

| kind | accepts | example |
|---|---|---|
| byte (an input value) | `0xNN`, `0XNN`, or 1–3 decimal digits ≤ 255 | `0x11`, `17` |
| word (an EDID id) | `0xNNNN` (1–4 hex digits), or 1–5 decimal digits ≤ 65535 | `0x1E6D` |

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

display.lg.vendor    = 0x1E6D     # EDID manufacturer id
display.lg.product   = 0x9E9D     # EDID product id
display.lg.name      = LG ULTRAGEAR+
display.lg.transport = nvapi      # HOW the bytes get there. Platform vocabulary
display.lg.method    = lg-alt     # WHAT is sent: standard | lg-alt
display.lg.input.0xD0 = pc        # which computer is on which input
display.lg.input.0xD1 = mac

trigger.device   = usb:046d:0843, bt:0011223344ff
trigger.debounce = 3.0
trigger.settle   = 0.75
```

`trigger.device` is comma-separated. An entry is `usb:VVVV:PPPP` (exactly four
hex digits, colon, four), `bt:AAAAAAAAAAAA` (exactly twelve hex digits, no
separators), or a bare `VVVV:PPPP` — **bare means usb**, so configs written
before Bluetooth existed keep working unchanged. Case does not matter; the
normalised form is lower-case. A reader must normalise the bare form, or every
"currently a trigger" marker silently stops appearing, which reads as "none of
these are configured" and is worse than no marker at all. **Anything else is
refused by name** where the list is consumed ([`detector.md`](detector.md) §4)
— never prefixed into a `usb:` entry that can match nothing.

`trigger.debounce` and `trigger.settle` are non-negative decimals — digits, or
digits `.` digits. A malformed value is refused by name, never read as zero: a
debounce of zero fires on every event in a plug's burst.

## `transport` and `method` are different questions

**`method` is WHAT is sent** — which VCP dialect, and therefore which values are
legal. **`transport` is HOW it gets there** — which driver API carries the bytes.
They were one key while every platform had exactly one transport, and separating
them is what lets a platform have two without the values on offer changing
meaning.

**`transport` absent means the platform's original transport**, so a config
written before this key existed keeps working untouched and unrewritten.

**The key is shared; the vocabulary is each platform's.** Transports are named
after the API that carries them — Windows has `nvapi` and `dxva2` — and a
platform with one transport has one name. **No platform is required to have
two.** A config is machine-local and never copied between hosts
(below), so a name that means nothing on another platform can never arrive there
by a supported route.

**An unrecognised transport is REFUSED BY NAME, never defaulted.** This is the
rule that makes the shared key safe. Defaulting to the platform's usual
transport would send the write down a path nobody verified — and a transport,
like an input value, is confirmed exactly once by a human looking at the panel
(`../AGENTS.md` hard rule 3). A config naming a transport this platform does not
have is a config for a different machine, and the honest answer is to say so.

**Not every dialect is available on every transport, and the transport decides.**
A transport that cannot address an I2C source byte cannot carry a manufacturer
sidechannel at all; asking for one is refused, naming the reason rather than
silently sending the standard command instead. The refusal belongs at the
transport, with the rest of the source-byte gating (`../AGENTS.md` hard rule 5).

**A transport is never a fallback.** Nothing tries one and falls through to
another at switch time. Which transport a panel uses is configuration, chosen
once and verified once; a silent fallback would mean the packet that moved the
panel on the day it was checked is not the packet sent afterwards.

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

`configure` rewrites this file from its answers. **Every key the walkthrough does
not write must be carried across from the existing file** — `trigger.debounce`
and `trigger.settle`, and any key the reader has never heard of. An unknown key
is someone's hand edit or a newer version's setting; dropping it on Save is a
silent loss with no way to notice. (A key the walkthrough *does* write — a panel
unmanaged, a computer removed — is dropped on purpose; that is the answer being
applied.) Comments are not carried; the file is rewritten with its own.

## The shared fixture

Two readers written independently drift in the details above, and each
platform's own tests only ever mirror what its author remembered. So the
adversarial cases live **once**, here, and both suites parse them with their own
reader:

| file | what |
|---|---|
| [`config-fixture/input.conf`](config-fixture/input.conf) | a config exercising every rule above, including CRLF lines and a byte-order mark |
| [`config-fixture/expected.tsv`](config-fixture/expected.tsv) | what a reader must produce from it: `key<TAB>value`, one per surviving key, in file order, last duplicate winning |
| [`config-fixture/values.tsv`](config-fixture/values.tsv) | the byte and word converters: `kind<TAB>input<TAB>decimal-or-REFUSE` |

Each suite must assert its reader reproduces `expected.tsv` exactly and its
converters agree with every row of `values.tsv`. `input.conf` is marked binary
in `.gitattributes` so no checkout normalises its line endings away.
