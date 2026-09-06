# Handoff — work the macOS side owes

**This is an INBOX.** Anyone may append an entry; only the macOS side works
through it, and only the macOS side deletes from it.

Read this first when you start work here. It is a **queue, not a log** — delete
an entry once it has landed, because git already keeps the history. Nothing
below the format section means the two platforms are in step.

## The rule it lives under

You never *change* anything in the other platform's directory: not its code, not
its tests, not its docs. You cannot run its tests or see its hardware, and a
half-made change there is worse than none.

**Appending an entry to its `HANDOFF.md` is the one exception**, and it is a
different verb from editing — prose cannot break their build. That is how work
crosses the boundary.

## Entry format

```markdown
## A short title, in the imperative

Kind:     spec change | defect report
Spec:     specs/configure.md §4.2          (or: n/a)
Why:      the one-line reason, in the terms the user would use
Owed:     what this platform has to do
Verified: what the author could and could not check from where they were

Anything longer goes underneath.
```

`Kind` matters because the two have different standing:

- A **spec change** is required. The conformance check already fails here until
  it lands.
- A **defect report** is a reading, often by someone who could not run this
  platform's code. `Verified` says how far they got. Disagree with it if you
  have better evidence — you can run it and they could not.

---

## Measure what `ioreg` can actually tell you about a USB device's name

Kind:     defect report
Spec:     configure.md §7.1 (revision 10) — and it feeds a design not yet written
Why:      the trigger list is only as good as the names the platform can give it,
          and nobody here knows what yours are
Owed:     a measurement, written into docs/measurements.md, dated
Verified: nothing. This was taken on Windows only. The author cannot run macOS
          and is not guessing at what IOKit reports.

Revision 10 asks for "the best name the platform has, not the first". On Windows
that turned out to matter enormously: three separate rows read `USB Input Device`
— a wireless receiver holding the keyboard and mouse, the motherboard RGB
controller, and a CPU cooler — and the fix was a SECOND name source, the USB
`iProduct` string the device reports about itself, which named all three.

**The question for this side: does `ioreg` give you one useful name, two, or only
generic ones?** Specifically worth reading off a few real devices:

- `kUSBProductString` / `USB Product Name` — the device's own iProduct string,
  the equivalent of what Windows calls the bus-reported name
- `kUSBVendorString`
- whether IOKit surfaces anything like a role (mouse / keyboard) without opening
  the device
- `kUSBSerialNumberString` — see below, this one may make the harder problem easy

If the names are already good, revision 10 may be nearly free here and the note
below is moot. If they are as generic as Windows' `FriendlyName`, say so — that
is the finding, and it means the second source matters here too.

### The reason this is more than curiosity

A follow-on design needs it: **two devices can share one vendor+product pair.**
The reference desk has two Logitech LIGHTSPEED receivers, one for the keyboard
and one for the mouse, both `046D:C547`, both travelling through the switch. So
`trigger.device = usb:046d:c547` names two things, and there is no way to pick
one.

On Windows the ONLY port-independent discriminator turned out to be the
bus-reported name: one receiver's node tree carries `G915 X LIGHTSPEED TKL` and
the other's only `LIGHTSPEED Receiver`. Hardware ids, HID collections and
revisions are byte-identical, and **neither reports a USB serial number**, which
is why Windows falls back to a port-derived instance id.

**If macOS DOES see a serial number where Windows sees none** — and IOKit does
surface `kUSBSerialNumberString` when a device has one — that is a materially
better key than a product string, and it would change the design before it is
written. Worth checking explicitly rather than assuming the device reports the
same thing to both operating systems.

The design, its measurements and the two candidate config spellings are in
`ideas/telling-two-identical-devices-apart.md`. **Nothing is built and no spec
has changed for it**; a finding from this side is wanted BEFORE the format is
settled, because a format is the hardest thing here to change afterwards.

### Amendment: this SHIPPED as revision 12, and not in the shape described above

Two corrections to what is written above, both of which happened after it was
appended and before this side had read it.

**It is no longer a question of "before the format is settled".** The format is
settled and published: `specs/detector.md` §4.1 and revision 12. So this
measurement no longer holds anything up -- it decides what macOS PUTS IN the
field, not what the field is. Take it when convenient.

**And the shape is NOT the labelled record this entry first described.** That
design -- `trigger.device.<label>.id` plus a `.match` key -- was drafted here and
then dropped, because a label has to be worth its ceremony: a display is labelled
because you TYPE the label (`pull --only asus`), while a trigger is never
referenced by name anywhere, so naming one would exist only to give the config
something to key on. What shipped instead is a suffix on the existing list entry,
which adds no key at all:

```
trigger.device = usb:046d:c547@g915-x-lightspeed-tkl@0003-0005, usb:1235:820a
```

`usb:VVVV:PPPP[@token[@where]]`, both optional, both `[a-z0-9-]` and **checked
lower-case rather than normalised**. Absent -- every config written so far --
an entry means exactly what it always meant, so **there is nothing to migrate and
a platform that only refuses malformed suffixes is already conformant for every
existing desk.**

`token` carries a platform-defined string, exactly as `transport` does in
revision 9: shared key, per-platform vocabulary, nobody required to produce one.
It is `token` and not `name` deliberately -- `name` would presuppose that a
product string is the right discriminator, which is precisely what this entry is
asking. **If serial numbers turn out to be readable here where Windows has none,
a token holds a slugified serial and nothing else about the format changes.**

Read the changelog entry rather than this note for what is actually owed; this
one exists to stop the superseded design above being implemented by mistake.
