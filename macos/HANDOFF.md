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
             The MacBook is a 2019 model with four USB-C/Thunderbolt 3 ports
             and no HDMI. Record WHICH 2019 model: the 13" drives external
             displays from the Intel GPU, the 15"/16" from an AMD Radeon Pro,
             and they are different framebuffer drivers (the probe prints the
             class). Both monitors' DisplayPort inputs are taken (the LG's by
             the PC, the ASUS's by the Mac Studio); the free inputs are HDMI
             on both. So there are two readings, and they answer different
             questions -- take them in this order:
          2. THE ROUTE: a USB-C to DisplayPort cable, direct. DP Alt Mode is
             plain DisplayPort and the DDC channel rides along natively, so
             this is the cleanest test of whether the framebuffer I2C route
             works on this Mac at all. It needs a DP input: unplug the PC's DP
             cable from the LG and plug the MacBook's in for the duration (the
             Mac Studio keeps both monitors on its own inputs throughout, so
             hard rule 4 holds; the PC loses the LG until the cable goes
             back). Run the probe. Record: does a framebuffer appear, does
             IODisplayCreateInfoDictionary carry the EDID (vendor/product/
             name must match what `trigger-kvm list` prints on the Mac Studio
             apart from the LG's per-input product id -- note the product id
             this input reports, it will be a fourth value), how many I2C
             buses, which transaction types (DDCci reply support matters).
          3. `./intel-ddc-probe --i2c-read`. Record the IOI2CSendRequest
             return, result, and the raw reply. A well-formed reply is
             evidence the I2C path reaches the panel; a non-answer is a
             measurement too (hard rule 2: these panels lie on reads -- the
             PG42UQ answers 0 to everything -- so an odd value is not a
             failure). Then put the PC's DP cable back.
          4. THE ADAPTER: Apple's USB-C to HDMI adapter onto a FREE HDMI input
             -- the LG's HDMI 1 or the ASUS's HDMI 2, and both if time allows.
             This is how an Intel Mac would actually live on this desk, and
             Apple's adapter has a DP-to-HDMI protocol converter inside;
             whether it passes DDC/CI is the unknown that decides whether an
             Intel transport is worth building. Repeat 2-3. If the route
             worked in step 2 and not here, the finding is "adapter", and it
             is worth naming the adapter model in the measurement.
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

## Count a SKIP separately from a PASS, and print it

Kind:     defect report
Spec:     n/a -- the same property specs/README.md asks of the conformance
          check: a check that cannot fail is decoration
Why:      `tests/run.sh` reports "all N test files passed" on a machine where
          some of them did not run, and does not say which
Owed:     run.sh:85-95 captures a file's output into `$out` and prints it only
          on FAIL (or under TK_TEST_VERBOSE), so a `SKIP` line written to
          stderr is SWALLOWED, and exit 0 is counted as PASS in `n`. Three
          places reach that:

          - `keys.tests.sh:17-20` exits 0 with no python3. That file is the only
            one that drives the real key-driven menus through a pty, so on such a
            machine the entire interactive half of the walkthrough goes untested
            and the run says all green.
          - `watcher.tests.sh:41` (`skip_no_present`, used at :261, :356, :379)
            skips the cases that need a present USB device -- which are the arm
            and fire cases -- and the file still exits 0.
          - `discover.tests.sh:117` skips its live-rows case when event-watch is
            not built, and run.sh does not build.

          Suggested shape, which is what windows/tests now does: a distinct exit
          code for "did not run" (2 there), rendered as `SKIP` with its reason
          ALWAYS printed, counted separately, and named in the summary -- "1 did
          NOT run on this machine and proved nothing". A skip should not raise
          the exit code: it is a fact about the machine, not a failure. Case-level
          skips need the count carried out of the file rather than an exit code;
          `finish` already tallies, so a `skipped` counter beside it is the
          natural place.

          The reason this is worth doing rather than tolerating: the Windows side
          had the identical shape and it hid the ONLY tests of the byte-exact
          packets and of every fail-closed refusal on any machine but the
          reference desk, for as long as those tests have existed.
Verified: read on Windows against commit 592c382; run.sh:85-95 and the three call
          sites quoted from source. NOT executed -- there is no macOS here, and
          the claim that the SKIP line is swallowed rests on reading the capture,
          not on watching it. Windows' equivalent fix is in commit 5febeec if the
          shape is useful.
