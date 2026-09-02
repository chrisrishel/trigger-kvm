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

## Decide whether to build the Intel transport -- the readings are in

Kind:     decision owed -- the measurement half of the old brief is DONE and
          this is what is left of it
Spec:     n/a -- see the macOS row of README.md ("Apple Silicon") and
          macos/AGENTS.md
Why:      the readings the previous brief asked for were taken on 2026-09-01 on
          a MacBook Pro 16" and are recorded in docs/measurements.md under
          "Intel DDC route". The route WORKS: the AMD framebuffer I2C path
          returned well-formed DDC/CI from both panels, over USB-C DP Alt Mode
          direct AND through an old Apple USB-C Digital AV Multiport Adapter,
          including from the ASUS on an input it was not displaying. So the
          question is no longer "is it possible" but "is it worth building",
          and that is a decision, not a reading.
Owed:     decision record 004, proposing or declining an Intel transport --
          NOT a transport. Read the measurement first; it is the evidence.

          If it is built, these are what the readings say it costs, and each
          is measured, not guessed:
          - a second transport under the existing `ddc_send` gate: m1ddc on
            arm64, an IOI2CSendRequest tool with the same `set input` /
            `set input-alt` surface on x86_64. Hard rule 5 must survive it --
            exactly ONE function may emit source 0x50, the source stays out of
            the parameter list, and conventions.tests.sh must still find one
            door.
          - an Intel branch of display-probe.c. On Intel it silently returns
            an EMPTY name and connector: it looks for a registry property
            named `EDID`, and this Mac has zero of those and two
            `IODisplayEDID` instead. displays.toml matches panels by
            edid_name, so identity is broken on Intel until this is fixed.
          - the installer's arch preflight would have to stop refusing, and
            install.tests.sh cannot run on Intel until it does -- all 26 of
            its assertions fail there today, correctly.
          - reachability checks cannot use enumeration. A vacant framebuffer
            still advertises DDCci, IODisplayCreateInfoDictionary still
            returns a non-NULL dictionary, and the built-in panel still
            returns result=0 -- with garbage. Only the `6E 88` reply framing
            separates an answer from a non-answer.
          - resolve by EDID, never by framebuffer: the gMux migrates a display
            between the Intel and AMD framebuffers on hotplug.

          - conventions.tests.sh must be extended FIRST. It scans lib/ and
            trigger-kvm -- shell only -- and keys on the string `input-alt`.
            C code emitting the source byte numerically contains no such
            string, so the scan would count one door and pass while a second
            existed. That is a precondition, not a follow-up.

          The STANDARD channel is now measured end to end: a SetVCP 0x60 framed
          by intel-ddc-probe and sent over IOI2CSendRequest moved the ASUS in
          both directions, watched, and its bytes match displays.toml exactly.
          So the route writes and the framing is right.

          The gating unknown is now ONLY the LG: whether it accepts 0xF4 on
          source 0x50 over this route is untested, and its standard 0x60 is
          stubbed in the panel, so the sidechannel is the only way to move it.
          Standard-DDC success does not substitute -- a machine that switched
          the ASUS and not the LG is the half-switching setup that presents as
          a hardware fault. Taking that reading means sending on the service
          channel, with a person watching (hard rule 3), and is its own
          decision -- not a by-product of building.
Verified: all of the above was run on the Intel Mac, the ASUS write visually
          confirmed in both directions by the user. Nothing was ever sent on
          source 0x50. The 13" 2019 model drives externals from the Intel GPU
          rather than the AMD one and was not tested at all.
