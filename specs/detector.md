# The detector — normative

The half of every implementation that answers "do I own the peripherals now?"
It is the only thing in this project that acts without a person watching, so
what it must and must not do is written down here. The switcher it runs is
`pull`, and only `pull` (`README.md`, "Why `pull` and `to` are separate verbs").

Read [`README.md`](README.md) first for how this corpus is enforced. The rules
every session needs are in [`../AGENTS.md`](../AGENTS.md); this file is the
contract those rules describe, and it does not restate the reasoning behind
them.

---

## 1. One process, N sources

The detector is one long-lived process holding one debounce and one lock.
Sources — USB presence, Bluetooth connection, anything added later — are event
sources inside it, never separate processes. Two processes would each hold their
own debounce and both fire on the same arrival.

**Single instance is enforced by the process itself**, with a lock that outlives
whoever started it (a named mutex, a `flock`). A second start finds the lock
held, says so once, and exits **successfully**: a redundant start is a no-op, not
a crash, because the supervisor restarts on failure.

**The log rotates at startup, after the lock, and nowhere else**, so a redundant
start never rotates a live watcher's log and the switcher, a separate process
appending to the same file, can never race it.

## 2. What fires

A **fire** is one run of `pull`. It happens on an **absent → present edge** of a
watched device, and on nothing else.

- **A device already present when the watcher starts never fires.** The first
  sighting arms; only a later arrival is an edge.
- **Debounce.** An arrival within `trigger.debounce` seconds of the last fire is
  ignored. Watched devices on one switch arrive together, so the first fires and
  the rest fall inside the window. One that arrives *outside* the window fires a
  second `pull` for the same flip: an idempotent re-assert, accepted rather than
  suppressed, because suppressing by device identity could miss a real flip back
  on which only that device re-enumerated.
- **Settle.** After an arrival, wait `trigger.settle` seconds, then fire only if
  **a device that arrived is still present**. Appear-then-vanish was a glitch,
  not a switch. The test is on the *arriving* device, not on any watched device:
  with two devices that travel together, "is anything present?" is always yes,
  and the protection is inert.
- **Wake is not a trigger.** Nothing fires on sleep or wake; a panel that moves
  during sleep is the monitor's auto-input setting, not the detector's business.
- **Presence for Bluetooth means CONNECTED**, never paired. A paired device
  keeps its record for years while away, so pairing would never produce an edge.

## 3. The one-shot

`--test-trigger` (macOS) / `-TestTrigger` (Windows): print current presence for
the given devices, wait for **one** arrival edge up to a timeout, report it and
exit — **taking no lock and running nothing**. It is a question about the
devices, not a second watcher, so a real watcher may run alongside it. The
walkthrough decides whether to pull afterwards (`configure.md` §11).

## 4. What it is told

The detector is started with the device list and timings **from the config**,
by the launcher (`trigger-kvm watch`; the scheduled task's action). Nothing is
baked into the launch entry, so an edit takes effect on the next restart.

Its inputs are checked at startup and a bad one is **refused, loudly, naming the
entry** — never defaulted, never silently ignored. A watcher that starts with a
wrong device list, or with a debounce of zero because `three` parsed as `0`,
runs and never does the right thing, which is the worst failure shape available.

- A device is `usb:VVVV:PPPP` (exactly four hex digits, colon, four hex digits;
  case-insensitive) or `bt:AAAAAAAAAAAA` (exactly twelve hex digits, no
  separators). A bare `VVVV:PPPP` means `usb:`. Anything else is refused.
- `trigger.debounce` and `trigger.settle` are non-negative decimals: digits, or
  digits `.` digits. Anything else is refused.

Refusing at startup under a supervisor means being restarted and refusing again;
that is loud in the log, which is the point.
