# Telling two identical devices apart

**Status:** exploratory. Nothing built. Two spellings drafted below for a
decision; the one chosen goes into `specs/` FIRST, then Windows, then a
changelog entry and revision 10.

The question this started from: the Triggers list showed one row reading
`G915 X LIGHTSPEED TKL  (mouse, keyboard)` where the desk actually has **two
Logitech receivers**, one for the keyboard and one for the mouse, plugged into
separate ports and both travelling through the USB switch. One row is not a
description of that hardware.

The principle behind the ask, in the owner's words: *every device that is
plugged in separately into a port, or connects separately over Bluetooth, should
be separately selectable.*

## What was measured, 2026-09-04

Both receivers report vendor `046D` product `C547`. Logitech reuses that pair
across LIGHTSPEED receivers, so it is not an identifier of a thing you can hold.

Everything the two have in common, byte for byte:

| | receiver A | receiver B |
|---|---|---|
| `HardwareIds` | `USB\VID_046D&PID_C547&REV_0402` | identical |
| HID hardware ids | `MI_00`, `MI_01&Col01..03`, `MI_02&Col01..02` | identical |
| serial number | **none** — the instance id is the port-derived `7&00aa0002&0&3` form | none |
| roles presented | mouse **and** keyboard | mouse **and** keyboard |

Only two things differ:

| | receiver A | receiver B |
|---|---|---|
| `LocationInfo` | `Port_#0003.Hub_#0005` | `Port_#0001.Hub_#0006` |
| bus-reported names in its tree | `G915 X LIGHTSPEED TKL`, `USB Receiver` | `LIGHTSPEED Receiver`, `USB Receiver` |

**The roles cannot separate them.** A LIGHTSPEED receiver enumerates a full HID
collection set -- keyboard, mouse, consumer control -- whatever is actually
paired to it. So both say "mouse, keyboard" and always will.

**The name sets differ in BOTH directions**, which is what makes a name usable as
a key: `G915 X LIGHTSPEED TKL` appears only in A's tree, `LIGHTSPEED Receiver`
only in B's.

## Why the name, and not the port

The obvious qualifier is the port, and it is the wrong one. `Port_#0003.Hub_#0005`
stops matching the moment somebody moves the dongle to another socket, and this
repo already has a rule against writing a mapping down and treating it as stable
(`AGENTS.md`, Conventions -- it is why displays are resolved by EDID and never by
index). A trigger that silently stops firing after a replug is the failure shape
the detector rules exist to prevent.

The name survives a replug, because it comes from the device rather than from
where it is plugged.

**But know where the string actually comes from.** `G915 X LIGHTSPEED TKL` is on
a LampArray (RGB lighting) child node, and it is the name of the **paired
keyboard**, surfaced through the receiver. Three consequences, none fatal, all
worth writing down before this is built:

1. **It selects a pairing, not a dongle.** Re-pair the G915 to the other
   receiver and the name follows the keyboard. For "trigger on whatever my
   keyboard is on" that is arguably right; it is still not the thing a reader
   would assume from the word "device".
2. **One of the two is identified by elimination.** B has no distinguishing name
   of its own -- `LIGHTSPEED Receiver` is generic, and it is only unique here
   because A happens to carry a better one. That is weaker than A's case and the
   asymmetry should be visible to whoever picks.
3. **A third Logitech receiver with a non-RGB device would report
   `LIGHTSPEED Receiver` too**, and the qualifier goes ambiguous. Rare, and
   detectable -- see Ambiguity below.

A serial number would beat all of this and there is not one: these receivers
report no `iSerialNumber`, which is exactly why Windows fell back to a
port-derived instance id.

## SUPERSEDED, 2026-09-04: the id should not be the key at all

Everything below this section treats "how do we qualify an id" as the question.
It is the wrong question, and the two spellings drafted for it are kept only as
the record of how that was worked out.

**If a device id can name two devices, it has no business being an identity.**
The qualifier designs are both workarounds for keying on something that is not
unique, and the config already contains the answer -- it is what DISPLAYS do:

```
display.lg.vendor  = 0x1E6D        <- identity lives in FIELDS
display.lg.product = 0x9E9D
display.lg.method  = lg-alt
```

`lg` is a handle the person picks. The EDID pair is the identity and it sits
INSIDE the record, precisely because two panels can share a product id -- which
this project already learned about monitors and wrote into `AGENTS.md`. Triggers
are the only thing in the config whose identity IS its key, and that is the
defect.

### The shape

```
trigger.device = kbd, mouse, clarett
trigger.device.kbd.id      = usb:046d:c547
trigger.device.kbd.match   = G915 X LIGHTSPEED TKL
trigger.device.mouse.id    = usb:046d:c547
trigger.device.mouse.match = LIGHTSPEED Receiver
trigger.device.clarett.id  = usb:1235:820a
```

- **`id` is a field, not a key**, so two devices may share one and stay separate
  entries. That is the whole point.
- **`match` is optional and its contents are the PLATFORM's**, exactly as
  `transport` is in revision 9: a shared key, per-platform vocabulary, nobody
  required to have one. Windows would put a bus-reported name; if macOS finds
  serial numbers where Windows finds none, it puts a serial. Configs are
  machine-local and never copied between hosts, so the two never have to agree
  on contents -- which is also why the field is `match` and not `name`, since
  `name` presupposes the answer.
- **The label is a handle the person picks**, the same as a monitor's, and the
  same rule (`configure.md` §5.1) can name it.
- The reader pattern is `^trigger\.device\.([^.]+)\.`, which mirrors
  `^display\.([^.]+)\.` -- machinery both platforms already have.

It also closes the gap spelling A could not: *"these two out of three"* is just
two entries.

### Clearing a prior rejection, on the record

`RENAMED_KEYS` shows this repo already went `trigger.usb.device` ->
`trigger.device.usb` -> back to flat, and `install.ps1` says why: the detour was
*"future-proofing against a second transport -- the same speculative generality
this project refuses elsewhere"*, and **"a malformed device id already throws
loudly ... so nothing was failing silently for the extra nesting to prevent."**

That last clause is the bar, and it is now cleared. Something IS failing
silently: an id that names two devices, with no way to say which, and a menu
that pooled both receivers' names and labelled the pair after whichever won. The
nesting is no longer speculative -- it is the minimum shape that can express a
measured fact about the reference desk.

### What it costs

- `specs/detector.md` §4 and `specs/config-format.md`, both platforms, plus
  cases in `specs/config-fixture`.
- **Old configs must keep working.** `trigger.device = usb:046d:0843,
  usb:1235:820a` reads as entries with an `id` and no `match`, and `configure`
  rewrites into the new shape on Save -- the warn-honour-rewrite path
  `RENAMED_KEYS` already established.
- **A constraint that cannot be checked from Windows:** `config.ps1` says *"if
  this grows past what sed can mirror, the format has drifted"*. Enumerating
  `trigger.device.<label>.*` is more work in `sed` than splitting a comma list.
  macOS already does the identical thing for `display.<label>.*`, so the
  machinery exists -- but that side should confirm rather than this side assume.

---

# Kept for the record: the qualifier designs this replaced

## First, what the SHARED READER does to each spelling

Both spellings were run through the real `config.ps1` before being written up,
because `specs/config-format.md` makes the line regex normative -- it is *the*
definition, pinned by `specs/config-fixture` and mirrored on macOS in `sed`:

```
^\s*([A-Za-z0-9_.\-]+)\s*=\s*(.*?)\s*(?:#.*)?$
```

Measured 2026-09-04, feeding three candidate lines to `Read-Config`:

| line | what came back |
|---|---|
| `trigger.device = usb:046d:c547#G915 X LIGHTSPEED TKL` | `usb:046d:c547` -- **the name is silently gone** |
| `trigger.device.usb:046d:c547.name = ...` | **nothing. The line is dropped entirely** |
| `trigger.device.046d-c547.name = ...` | `G915 X LIGHTSPEED TKL` -- parses clean |

Two facts fall out of that, and both are decisive:

- **A key may not contain `:`.** The grammar is `[A-Za-z0-9_.-]+`, so the obvious
  `trigger.device.usb:046d:c547.name` does not merely read oddly, it vanishes --
  and a dropped line is the worst possible failure for a config, because nothing
  is malformed enough to complain about.
- **A value is cut at the first `#`,** by the reader, before any consumer sees
  it. So an inline `#` separator is not a delimiter this format has available.

## Spelling A -- a separate qualifier key

```
trigger.device = usb:046d:c547, usb:1235:820a

# Which one, where an id covers more than one physical device.
# Note the key spells the id with a dash: a key may not contain a colon.
trigger.device.046d-c547.name = G915 X LIGHTSPEED TKL
```

- **No escaping, ever.** The value is the rest of the line, so a product name
  containing a comma or a space needs no rule. (A name containing `#` is still
  cut by the reader -- that is true of every value in this format and is not
  something this feature can or should change.)
- `trigger.device` keeps its existing grammar exactly, so every config written
  before this keeps working and the detector's list parser is untouched.
- The qualifier is **optional and additive**: absent, the id means what it means
  today.
- Costs a second key, and the relationship between the two lines is positional
  rather than obvious -- a reader has to notice the id repeated, re-spelled with
  a dash, inside the key name. That re-spelling is a genuine wart and a thing to
  get wrong by hand.
- Two devices of the same id, both wanted separately, need two qualifier lines
  while the list still holds the id once. `trigger.device` is a set of *ids* and
  this wants a set of *devices*; the mismatch shows here.

## Spelling B -- inline, after a separator

```
trigger.device = usb:046d:c547#G915 X LIGHTSPEED TKL, usb:1235:820a
```

- One field. A device is one token, so two receivers are two entries and the
  "set of devices" reading works, with no id re-spelled anywhere.
- **But `#` is measured above to be unavailable**, so this needs some other
  separator, and the candidates are poor: `:` is already inside the id, `,`
  separates the list, `=` is the key/value split. Something like `@` or `|`
  could work and neither is currently reserved.
- **The comma problem stays whatever separator is chosen.** The list separator
  is a comma and product names contain them -- `Focusrite Audio Engineering,
  Ltd.` is a real string on this desk. A device called `Acme Receiver, Mk II`
  splits in half and each half is refused as malformed. Any fix -- quoting,
  escaping, "split on the comma only outside a qualifier" -- is a rule BOTH
  platforms implement identically, and `specs/config-fixture` needs a case for
  each.

**CHOSEN: A, 2026-09-04.**

The measurement argues for it -- B's cost lands squarely in the shared
line-parsing rules, the one definition both implementations and the fixture pin
exactly and that macOS mirrors in a `sed` expression small enough to hold in the
head. A needs one naming convention and no change to that regex; B needs a new
reserved character and a list-splitting rule that survives commas in names.

**But the deciding argument is architectural, and it is the better one:
platform-specific device-identification conventions belong in a VALUE, not in
the key schema.** macOS identifies USB devices by `locationID` and IOKit
properties, Linux by sysfs paths; none of those look like `VID:PID`, and a third
implementation should not have to fit its notion of "which device" into a key
shape Windows' notion suggested. A value can hold whatever a platform reports.
A key is schema, and schema is the part that has to mean the same thing
everywhere.

### The gap A leaves, stated plainly

`trigger.device` holds each id **once**, so spelling A can express:

- **all devices with this id** -- the unqualified entry, exactly today's meaning
- **exactly one of them** -- the entry plus a `.name` qualifier

It cannot express *"these two specific ones out of three."* On this desk that
costs nothing, because both receivers travel and the unqualified id already
covers both. It is still a real gap against the stated principle that every
separately-plugged device should be separately selectable, and it is here in
writing rather than waiting to be discovered.

### A name that cannot be stored

`config-format.md` is explicit that a value is cut at the first `#` and **there
is no escape for a literal `#`** -- deliberate, because an escaping rule is
exactly what two readers drift on, and macOS's is a `sed` expression.

The answer is at the WRITER, not in the format: the walkthrough offers a name
qualifier only where the name is storable and unique. A device whose
distinguishing name contains `#` is not separately selectable, and the list says
so rather than writing a value that reads back truncated. Nothing about the
shared rule changes.

## Ambiguity: what happens when a qualifier matches 2, or 0

**Decided by discussion 2026-09-04, and it overrides the first proposal.** The
first suggestion here was to refuse to start the watcher, matching the existing
rule that a malformed `trigger.device` entry is refused by name. That was wrong,
and the objection is a good one: refusing converts a cosmetic uncertainty into
total non-operation, which the user meets as "the KVM just stopped working" with
no visible cause and a log they may not know exists.

**The two cases are not the same failure.** A malformed entry can NEVER match, so
a watcher that starts with one runs and never fires -- the shape
`specs/detector.md` refuses for good reason. An ambiguous qualifier is different:
the devices are all present, and only "which one" is unresolved.

So:

1. **An ambiguous or unmatched qualifier disables THAT ENTRY, not the watcher.**
   Log it, keep watching every other trigger. A desk with redundant triggers --
   this one has a webcam and an audio interface -- keeps working, which is the
   whole point of having more than one.
2. **`status` says so, in words.** This is what makes it discoverable without
   knowing the log exists, and `status` already names the configured triggers.
3. **If that leaves NO usable trigger at all, refuse to start, loudly.** A
   watcher running with nothing that can ever fire is precisely the worst shape,
   and the only case where refusing is the kinder answer.

**Why not fall back to the whole id** (fire on either receiver), which was the
other candidate: it does something the config did not ask for. It is the same
shape as the transport rule already settled in `config-format.md` -- *"an
unrecognised transport is REFUSED BY NAME, never defaulted, because defaulting
sends the write down a path nobody verified"*. Concretely: a visitor's Logitech
dongle plugged into this machine would produce an arrival edge and pull the
monitors over unbidden, and `AGENTS.md` names displays that steal themselves at
random as the worst failure this system can have. The argument for falling back
was that the resulting weirdness is salient enough to prompt a reconfigure --
but salience does not require moving somebody's monitors. `status` and the log
carry it without that.

## Also worth fixing while here, and NOT dependent on any of the above

**Presence is per vendor:product, so a stationary twin masks a travelling one.**
`Test-UsbPresent` matches `DeviceID LIKE 'USB\VID_x&PID_y%'` and returns true if
any node matches, and the trigger fires on an absent -> present edge. If two
devices share an id and only one travels with the switch, the id is permanently
present, the edge never happens, and the trigger never fires -- silently. Not
biting this desk (both receivers travel, and the configured triggers are the
webcam and the Clarett), but it is a property worth a warning where the choice is
made, and it is Windows-local prose, not a format change.

## What macOS would owe

One rule, and the shape is already familiar from revision 9's transport key: read
the qualifier, and where it is absent behave exactly as today. `ioreg` exposes a
USB product string per device, so the mechanism exists there; the vocabulary and
the property name are its own. It is **not** required to find the same string
Windows finds -- a qualifier is machine-local, like an input value, and configs
are never copied between hosts.

## Rejected while drafting

**A live "press a key and watch the row light up" indicator**, to tell the
keyboard's receiver from the mouse's. Windows opens keyboard and mouse HID
top-level collections exclusively for the class driver, so reading input reports
directly is access-denied by design; the supported route is RawInput, which needs
a window and a message loop -- a real chunk of native plumbing inside a
PowerShell installer, for a disambiguation the names may already solve. Worth
reconsidering only if, after the names are shown, real ambiguity remains.
