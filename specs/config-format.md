# The configuration file -- normative

One flat `key = value` file, written by `configure` and safe to edit by hand.
Both platforms read and write it. A reader that disagrees with the writer fails
silently, across machines, and presents as a hardware fault.

## Where it lives

| platform | path |
|---|---|
| Windows | `%LOCALAPPDATA%\trigger-kvm\config` |
| macOS | `~/Library/Application Support/trigger-kvm/config` |

Never inside the program directory, so uninstalling does not throw away a
configuration that represents real work.

## The line format

Not TOML or JSON: it is read on every device arrival and must not depend on a
parser being installed. The whole reader is one regular expression:

```
^\s*([A-Za-z0-9_.\-]+)\s*=\s*(.*?)\s*(?:#.*)?$
```

Every one of these is a way two readers could differ, so each is stated:

- **`\s` is whitespace in the regex's sense**, including the carriage return of
  a CRLF line, vertical tab and form feed. A UTF-8 byte-order mark at the start
  of the file is ignored.
- A key is `[A-Za-z0-9_.-]+` and is **lower-cased on read**.
- **Enumerated values are matched case-insensitively**: `Boot`, `LG-ALT` and
  `Standard` are `boot`, `lg-alt` and `standard`.
- Everything after the **first** `=` is the value; a value may contain `=`.
- The value is **cut at the first `#`**, then trimmed at both ends. There is no
  escape for a literal `#`.
- Values keep their case, verbatim.
- A line that does not match is **ignored**, not an error. A whole-line comment
  is simply a line that does not match.
- On a **duplicate key the LAST one wins**.
- A missing file reads as **empty**, not as an error.

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

### `trigger.device`

Comma-separated; each entry is trimmed. An entry is:

- `usb:VVVV:PPPP[@token[@where]]`: exactly four hex digits, colon, four,
  case-insensitive; then up to two optional suffixes, each `@` followed by
  `[a-z0-9-]+`. The suffixes are **lower case, and that is checked rather than
  normalised**: a suffix lower-cased on one platform and refused on another is
  exactly the disagreement this file exists to prevent. What they do is
  [`detector.md`](detector.md) 4.1.
- `bt:AAAAAAAAAAAA`: exactly twelve hex digits, no separators, case-insensitive.
- a bare `VVVV:PPPP`, which means `usb:`. A reader normalises the bare form so
  "currently a trigger" markers keep appearing.

Anything else is **refused by name** where the list is consumed
([`detector.md`](detector.md) 4), never prefixed into a `usb:` entry that can
match nothing. Every surface that shows an entry (`configure`, `discover`,
`status`) parses it with the same rule the watcher uses, so a malformed entry
never displays as valid.

`[a-z0-9-]` is the class computer and display names already follow, and the only
class that survives this format unchanged: no `#` to cut, no `,` to split, no
whitespace or case to normalise. A platform reduces whatever it uses to identify
a device into that class; a token is compared literally, never interpreted. Both
suffixes are derived, never asked: a person picks a device from a list.

### `trigger.debounce`, `trigger.settle`

Non-negative decimals: digits, or digits `.` digits. A malformed value is
refused by name, never read as zero.

## Value parsing

Two converters, and **both fail rather than guess or default**.

| kind | accepts | example |
|---|---|---|
| byte (an input value) | `0xNN`, `0XNN`, or 1-3 decimal digits <= 255 | `0x11`, `17` |
| word (an EDID id) | `0xNNNN` (1-4 hex digits), or 1-5 decimal digits <= 65535 | `0x1E6D` |

A leading zero is decimal, not octal: `010` is ten.

**A caller treats a parse failure as "refuse", never as zero.** A missing value
once became `0x00` on the wire, an input no monitor has, and every switch
silently did nothing. The property a test asserts is that **nothing is sent**,
not that a check ran.

## A writer must not write what it cannot read back

Whatever a writer puts in a file, reading it back MUST yield the same string. A
value that would not survive the round trip is transformed before it is
written, never written and silently altered on the next read.

| in a value | what the reader does |
|---|---|
| `#` | cuts the value there, and there is no escape |
| CR or LF | ends the line; the remainder becomes a separate line |
| leading or trailing whitespace | trimmed |

So a writer removes `#`, CR and LF, and trims. Nothing is escaped; this format
has no escape. `=` needs no treatment. EDID descriptor strings are LF-terminated
by the standard, so a panel's reported name is the value this bites first.

The same rule covers values a writer passes through from an existing file: they
were already cut at `#` on read, and a writer cannot restore what it never had.

Where a value's meaning depends on being exact (an identifier something is
matched on, rather than a label somebody reads), a writer that cannot represent
it faithfully **refuses to write it and says so**, rather than storing a
near-miss that matches nothing.

## `transport` and `method` are different questions

**`method` is WHAT is sent**: which VCP dialect, and therefore which values are
legal. **`transport` is HOW it gets there**: which driver API carries the bytes.

- **`transport` absent means the platform's original transport**, so a config
  written before the key existed keeps working, unrewritten.
- **The key is shared; the vocabulary is each platform's**, named after the API
  that carries it (Windows: `nvapi`, `dxva2`; macOS: `ioavservice`). No
  platform is required to have two.
- **An unrecognised transport is REFUSED BY NAME, never defaulted.** A config
  naming a transport this platform does not have is a config for a different
  machine. Defaulting would send the write down a path nobody confirmed by eye.
- **The transport decides which dialects are available.** A transport that
  cannot address an I2C source byte cannot carry a manufacturer sidechannel;
  asking for one is refused naming the reason, never silently downgraded. The
  refusal belongs at the transport, with the rest of the source-byte gating
  (`../AGENTS.md` hard rule 5).
- **A transport is never a fallback.** Nothing tries one and falls through to
  another at switch time.

## `display.<label>.input.<value> = <computer>` is the whole map

There is no second table. `pull` looks up `computer.this`; `to mac` looks up
`mac`. Same lookup, same code path, one name apart. Rules the reader enforces:

- A value that does not parse as a byte is dropped, not zeroed.
- Two inputs naming the same computer on one panel is a **refusal**, not a coin
  toss.
- A computer named on no input of a panel means that panel cannot go there, and
  a `to` naming it moves **nothing at all**, not the panels that could. Every
  value is resolved before any is sent.

## A config is machine-local

Never copy one between hosts, and never seed one from another desk.
`computer.this` differs, and some panels report a different EDID product id per
input (`../displays.toml`), so a copied id matches nothing. The label (`lg`,
`asus`) is a local name someone chose.

## Ordering

Displays are written in the order the walkthrough holds them. Within one panel,
the input map is written **in the order the computers were listed**, not by
input value, and a reader **returns them in file order**: sorting on the hex
puts the same two computers in opposite orders on two panels, purely by which
socket each was plugged into. The order someone listed their computers in is
the one they will look for, in `status` and on a re-run of `configure`.

## Hand edits survive

`configure` rewrites this file from its answers. Every key the walkthrough does
not write is carried across from the existing file, unknown keys included; an
unknown key is someone's hand edit or a newer version's setting. A key the
walkthrough *does* write is dropped only when the answer says so: a panel
explicitly unmanaged, a computer removed. **A configured panel that is not
attached right now keeps every key**; not being enumerated is not an answer
([`configure.md`](configure.md) 6). Comments are not carried; the file is
rewritten with its own.

## The shared fixture

Two readers written independently drift in the details above, so the
adversarial cases live once, here, and both suites parse them with their own
reader:

| file | what |
|---|---|
| [`config-fixture/input.conf`](config-fixture/input.conf) | a config exercising every rule above, including CRLF lines and a byte-order mark |
| [`config-fixture/expected.tsv`](config-fixture/expected.tsv) | what a reader must produce: `key<TAB>value`, one per surviving key, in file order, last duplicate winning |
| [`config-fixture/values.tsv`](config-fixture/values.tsv) | the byte and word converters: `kind<TAB>input<TAB>decimal-or-REFUSE` |

Each suite asserts its reader reproduces `expected.tsv` exactly and its
converters agree with every row of `values.tsv`. `input.conf` is marked binary
in `.gitattributes` so no checkout normalises its line endings away.
