# The detector -- normative

The half of every implementation that answers "do I own the peripherals now?"
It is the only thing in this project that acts without a person watching. The
switcher it runs is `pull`, and only `pull` (`README.md`, "Why `pull` and `to`
are separate verbs"). The rules every session needs are in
[`../AGENTS.md`](../AGENTS.md); this is the contract those rules describe.

## 1. One process, N sources

The detector is one long-lived process holding one debounce and one lock.
Sources (USB presence, Bluetooth connection, anything added later) are event
sources inside it, never separate processes: two processes would each hold
their own debounce and both fire on the same arrival.

**Single instance is enforced by the process itself**, with a lock that
outlives whoever started it (a named mutex, a `flock`). A second start finds the
lock held, says so once, and exits **successfully**: a redundant start is a
no-op, because the supervisor restarts on failure. If the lock cannot be
established for any other reason, the watcher refuses to start; it never runs
unlocked.

**The log rotates at startup, after the lock, and nowhere else**, so a
redundant start never rotates a live watcher's log and the switcher, a separate
process appending to the same file, can never race it.

## 2. What fires

A **fire** is one run of `pull`. It happens on an **absent -> present edge** of
a watched device, and on nothing else.

- **A device already present when the watcher starts never fires.** The first
  sighting arms; only a later arrival is an edge.
- **The edge belongs to the device that arrived.** For an entry qualified by
  `@token` or `@where` (4.1), only the arrival of the device the entry resolves
  to is an edge; the arrival of another device sharing the id while the
  configured one is already present is not.
- **Debounce.** An arrival within `trigger.debounce` seconds of the last fire is
  ignored. Watched devices on one switch arrive together, so the first fires and
  the rest fall inside the window. One that arrives outside the window fires a
  second `pull` for the same flip: an idempotent re-assert, accepted rather than
  suppressed, because suppressing by device identity could miss a real flip back
  on which only that device re-enumerated.
- **Settle.** After an arrival, wait `trigger.settle` seconds, then fire only if
  **a device that arrived is still present**. Appear-then-vanish was a glitch.
  The test is on the arriving device, not on any watched device: with two
  devices that travel together, "is anything present?" is always yes.
- **Wake is not a trigger.** Nothing fires on sleep or wake.
- **Presence for Bluetooth means CONNECTED**, never paired.

## 3. The one-shot

`--test-trigger` (macOS) / `-TestTrigger` (Windows): print current presence for
the given devices, wait for **one** arrival edge up to a timeout, report it and
exit, **taking no lock and running nothing**. A real watcher may run alongside
it. The walkthrough decides whether to pull afterwards (`configure.md` 11).

## 4. What it is told

The detector is started with the device list and timings **from the config**,
by the launcher (`trigger-kvm watch`; the scheduled task's action). Nothing is
baked into the launch entry, so an edit takes effect on the next restart.

Its inputs are checked at startup and a bad one is **refused, loudly, naming
the entry**, never defaulted, never silently ignored. Refusing under a
supervisor means being restarted and refusing again, which is loud in the log.

- A device entry follows [`config-format.md`](config-format.md),
  `trigger.device`. Anything else is refused.
- `trigger.debounce` and `trigger.settle` are non-negative decimals: digits, or
  digits `.` digits. Anything else is refused.
- The listing modes that feed `configure` and `discover` (macOS `--list`,
  Windows `-ListUsb` / `-ListBluetooth`) need no config and refuse nothing: they
  must answer on a machine with no config at all.

### 4.1 A vendor:product pair can name more than one device

Two devices of the same model share one id; presence is per id; so where only
one of them travels with the switch, the id is permanently present, the edge
never happens, and the trigger never fires, silently. An entry may therefore
say which device: `usb:VVVV:PPPP[@token[@where]]`.

- **`token` identifies WHICH device** among those sharing the id. Its contents
  are the platform's (a product string, a serial, whatever stays with the
  device), reduced to `[a-z0-9-]`; no platform is required to produce one.
- **`where` is where the device was when it was configured** (a port, a
  location id), in the same class.
- **A writer chooses for uniqueness, not quality**, among the devices sharing
  the id at the time of writing: a token held by exactly one of them, written
  alone; where every candidate token is shared but the devices sit at different
  places, the shared token **plus** `where`; where nothing distinguishes them,
  the bare id, because a placeholder would match nothing and never fire, which
  is worse than matching all of them. A platform that cannot tell two such
  devices apart says so where the choice is made, never guesses.

**Matching, in order.** Among the present devices whose id matches:

| | result |
|---|---|
| no `token` given | every one of them |
| exactly one has the `token` | that one; `where` is not consulted, so a device moved to another socket still matches |
| none has the `token` | no match: absent, or renamed |
| several have it, one at `where` | that one, and **say that `where` decided it** |
| several have it, none at `where` | **AMBIGUOUS** |

**Ambiguous is a state, distinct from absent.** It is re-evaluated on every
presence sweep, never latched.

- An ambiguous entry does not fire and is reported: in the log once, and in
  `status`, which reports what the running watcher currently sees (through the
  watcher, not by re-deriving it). Every other entry keeps watching.
- **Leaving ambiguity is not an arrival.** When the devices become
  distinguishable again (one of them unplugged, or one moved to `where`), the
  entry's baseline becomes "present" without firing; only a later absent ->
  present edge of the resolved device fires.
- **Whenever `where` decides a match, say so** in the log and in `status`. A
  remembered location that has gone stale is dangerous only while it is silent.
- **If every configured entry is ambiguous when the watcher starts, refuse to
  start and say so.** A watcher that would run and never fire is the one case
  where refusing is the kinder answer. An entry that is merely absent is usable
  and does not count against this.
- **Never fall back to the whole id.** Firing on any device sharing the id is
  not what the config asked for: a visitor's identical dongle plugged in
  directly would pull the monitors over unbidden, the worst failure this system
  has. `status` and the log carry the ambiguity; no monitor moves to announce it.
