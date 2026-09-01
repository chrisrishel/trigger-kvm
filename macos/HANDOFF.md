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

## Measure the Intel-Mac DDC route on the Intel MacBook Pro

Kind:     measurement brief -- not a defect; a reading only that machine can
          take, and nothing to implement until it is in
Spec:     n/a -- see the macOS row of README.md ("Apple Silicon") and
          macos/AGENTS.md
Why:      the README says Apple Silicon only, because m1ddc reaches monitors
          through IOAVService, which Intel Macs do not have. Intel Macs have a
          framebuffer I2C route instead (what ddcctl and ddc-macos use). An
          Intel MacBook Pro is available, so whether that route reaches THESE
          panels through THIS cabling can be measured rather than assumed.
Owed:     a measurement, recorded in docs/measurements.md under a new "Intel
          DDC route" heading, and then a decision record (004) -- NOT a
          transport. Every reading stays in the context it is a claim about
          (the note at the top of docs/measurements.md).

          The instrument is macos/intel-ddc-probe.c: `make intel-ddc-probe`.
          It is READ-ONLY. Without flags it enumerates and sends no I2C at all;
          with --i2c-read it sends one standard GetVCP 0x60 (source 0x51,
          hard-coded, nothing else expressible) per external display and
          prints the raw reply. It cannot write a value. The MacBook's own
          screen keeps the terminal, so hard rule 4 is satisfied throughout.

          1. On the MacBook: clone, `cd macos && make intel-ddc-probe`, run it
             with nothing attached. Record the arch line, the CoreGraphics
             list (the built-in panel) and the IOFramebuffer count.
          2. Attach it to a FREE input on one monitor -- the LG's HDMI or the
             ASUS's HDMI 2 -- with the most direct cable available first
             (USB-C to DisplayPort, or USB-C to HDMI). Run again. Record: does
             a framebuffer appear for it, does IODisplayCreateInfoDictionary
             carry the EDID (vendor/product/name must match what `trigger-kvm
             list` prints for that panel on the Mac Studio, apart from the
             LG's per-input product id), how many I2C buses and which
             transaction types (DDCci reply support matters).
          3. `./intel-ddc-probe --i2c-read`. Record the IOI2CSendRequest
             return, result, and the raw reply. A well-formed reply is
             evidence the I2C path reaches the panel; a non-answer is a
             measurement too (hard rule 2: these panels lie on reads -- the
             PG42UQ answers 0 to everything -- so an odd value is not a
             failure). Do this for BOTH panels if both have a free input.
          4. Repeat 2-3 through whatever adapter or hub would actually be used
             day to day. Adapters are where Intel-Mac DDC most often fails;
             that is the reading that decides whether this is worth building.
          5. Also `make test` on the MacBook: the suite has never run on an
             Intel Mac. Report what passes and what does not (the installer's
             arch preflight refusing is expected and correct).

          Do NOT: send anything on I2C source 0x50 by any route; do not write
          a VCP value from the MacBook -- a write is the next decision, taken
          after these readings, and the switch it would cause is exactly the
          thing hard rule 3 says a person has to watch for on purpose.

          Afterwards: docs/measurements.md entry; decision 004 proposing (or
          declining) an Intel transport under the existing ddc_send gate --
          m1ddc on arm64, an IOI2CSendRequest tool with the same `set input`
          / `set input-alt` surface on x86_64 -- and an Intel branch of
          display-probe.c for identity. Nothing is written into the tree
          before the decision.
Verified: the probe compiles clean under -Wall -Wextra on the Apple Silicon
          Mac and, run there, reports zero IOFramebuffer services -- the
          expected answer on that hardware. It has not yet run on an Intel
          Mac; that is the point of this entry.
