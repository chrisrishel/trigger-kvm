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
- A `usb:` entry may carry up to two **optional suffixes**, each introduced by
  `@` and each `[a-z0-9-]+`: `usb:VVVV:PPPP[@token[@where]]`. Absent, an entry
  means exactly what it has always meant. §4.1 says what they do.

### 4.1 A vendor:product pair can name more than one device

**Two devices of the same model share one id.** The reference desk has two
wireless receivers, one carrying a keyboard and one a mouse, both reporting
`046D:C547`. So `usb:046d:c547` names two things and, without more, a person
cannot pick one and the detector cannot tell them apart.

That is not only a naming problem. **Presence is per id**: if a device is present
whenever anything matching the id is present, then two devices sharing an id
where only one travels with the switch means the id is permanently present, the
absent→present edge never happens, and **the trigger never fires, silently.**

- **`token` identifies WHICH device**, among those sharing the id. Its contents
  are the platform's — a product string, a serial, whatever that platform can
  read that stays with the device — and no platform is required to produce one.
  Same rule as `transport` in `config-format.md`: shared key, per-platform
  vocabulary. A platform that cannot tell two such devices apart says so where
  the choice is made rather than guessing.
- **`token` must be chosen for UNIQUENESS, not merely taken.** The best name for
  a device is not necessarily one that distinguishes it: measured on the
  reference desk, both receivers report `usb-receiver` and only one reports
  `g915-x-lightspeed-tkl`. A writer picks a value held by exactly one of the
  devices sharing that id, and where none exists, writes no token.
- **`where` is a TIEBREAK ONLY**, consulted when and only when `token` still
  matches more than one present device. It records where the device was when it
  was configured. It must never be consulted while `token` resolves to exactly
  one device, because then a device moved to another socket would stop matching
  — and a trigger that silently stops firing after a replug is the failure this
  section exists to prevent.
- **Whenever `where` decides a match, say so** — in `status`, naming it. A
  remembered location that has gone stale is only dangerous while it is silent:
  two indistinguishable devices physically swapped between sockets will resolve
  to the wrong one, and the only defence is that the reader can see it happened.

**Matching, in order.** Among the present devices whose id matches:

| | result |
|---|---|
| no `token` given | every one of them, as today |
| exactly one has the `token` | that one; `where` is not consulted |
| none has the `token` | no match — absent, or renamed |
| several have it, one at `where` | that one, and **say that `where` decided it** |
| several have it, none at `where` | ambiguous — see below |

**An ambiguous entry is disabled; the watcher is not.** Log it, keep watching
every other trigger, and say so in `status`. This is deliberately NOT the
treatment a malformed entry gets: a malformed entry can never match, so a watcher
carrying one runs and never fires, while an ambiguous one has all its devices
present and only "which" unresolved. Refusing to start over the latter turns a
cosmetic uncertainty into total non-operation, which a person meets as "it just
stopped working" with no visible cause.

**Unless nothing usable is left.** If disabling the ambiguous entries leaves no
trigger that could ever fire, refuse to start and say so — that is the one case
where the watcher would run and never fire, and refusing is the kinder answer.

**Never fall back to the whole id.** Firing on any device sharing the id is not
what the config asked for, and the cost is concrete: a visitor's identical dongle
plugged into this machine would produce an arrival edge and pull the monitors
over unbidden. Displays that move on their own are the worst failure this system
has (`../AGENTS.md`). Salience does not require moving somebody's screens;
`status` and the log carry it.
- `trigger.debounce` and `trigger.settle` are non-negative decimals: digits, or
  digits `.` digits. Anything else is refused.

Refusing at startup under a supervisor means being restarted and refusing again;
that is loud in the log, which is the point.
