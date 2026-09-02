# Handoff — work the Windows side owes

**This is an INBOX.** Anyone may append an entry; only the Windows side works
through it, and only the Windows side deletes from it.

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

## Measure whether a standard-DDC panel can be switched through dxva2 on the onboard Intel GPU

Kind:     measurement brief -- not a defect; work only this platform can do,
          and nothing to implement until the numbers are in
Spec:     n/a -- docs/decisions/001 names this as what would reopen it
Why:      the README turns away everyone without an NVIDIA GPU. Most monitors
          take the standard command, and this PC has an Intel UHD 770 that can
          drive one of the panels, so "any GPU, for standard monitors" can be
          measured here instead of hoped for
Owed:     a measurement, recorded in docs/measurements.md, then a decision
          record (003) -- NOT code. The machine and the panel are the
          instrument; keep every reading in the context it is a claim about
          (see the note at the top of docs/measurements.md).

          Setup (hard rule 4 throughout: the LG stays on the 4090 and stays on
          this PC, so there is always a screen to read):
          1. BIOS: Advanced -> System Agent Configuration -> iGPU Multi-Monitor
             = Enabled. Boot. Confirm "Intel(R) UHD Graphics 770" appears in
             Device Manager; install Intel's driver if Windows did not.
          2. Move ONLY the ASUS's PC cable (HDMI 1 today) from the 4090 to a
             motherboard output (HDMI or DisplayPort). Note which input on the
             ASUS it now occupies -- if it changed, the config's value for this
             computer on the ASUS changes with it; use the walkthrough, do not
             hand-edit.
          3. `trigger-kvm list` and `nvapi-probe.ps1`: NVAPI must now see ONE
             panel (the LG). Record what it says about the ASUS (expected:
             absent -- it is on another adapter). Record what
             `EnumDisplayMonitors` and `Get-CimInstance WmiMonitorID` report
             for both panels (EDID vendor/product for the ASUS from WMI is the
             identity a vendor-neutral transport would need).

          Measurements, each confirmed by looking at the ASUS:
          4. From a NORMAL session: `SetVCPFeature(0x60, 0x0F)` then `(0x60,
             <its new PC input value>)` on the ASUS's physical monitor handle
             (dxva2). The last working implementation of exactly this call is
             the parent of commit 70e5ed4 (`git show 70e5ed4^:windows/trigger-kvm.ps1`);
             lift the call, not the file. Both directions; from an inactive
             link too (switch the ASUS to the Mac first, then pull it back
             over the Intel output). Record: did it move, did it come back,
             how long.
          5. From SESSION 0 (an unelevated S4U on-demand task, the way the
             NVAPI probe was measured): what does `EnumDisplayMonitors`
             return with the ASUS on the Intel output -- the phantom, zero, or
             something new -- and can a physical monitor handle be obtained at
             all. Expected: no usable handle. This is the measurement that
             decides whether a dxva2 panel can ever be covered by the boot
             tier; the answer is probably no, and that goes in the decision
             as a stated limitation, never as a fallback.
          6. Is `WmiMonitorID` (or `Get-PnpDevice` display class) consistent
             with what NVAPI reports for the LG, so one identity key
             (EDID vendor+product) can serve both transports?

          Do NOT: send anything on I2C source 0x50 by any route other than
          `NvDdc.WriteLgInput`; do not attempt Intel's own I2C API (IGCL) --
          that is a third transport and a separate decision; do not sweep
          values -- 0x0F and the ASUS's HDMI value are the only two to send.

          Afterwards: put the ASUS cable back on the 4090 and re-run
          `configure` so the config matches the desk again. Then write
          decision 003 proposing per-panel transport selection at configure
          time (standard panels -> dxva2 where no vendor route exists, login
          tier only, the From boot row disabled with the reason per
          specs/configure.md 8), or recording why not.
Verified: nothing -- this is the brief for taking the measurement. Written on
          the Mac from the repo's own records (decision 001, windows/AGENTS.md
          session-0 findings, the deleted dxva2 code). The BIOS location and
          the iGPU model were reported by the owner from the machine.
