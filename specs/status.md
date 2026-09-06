# `trigger-kvm status` — normative

What the command reports, and the one thing it must say that nothing else can.

Read [`README.md`](README.md) first for how this corpus is enforced. The rules
every session needs are in [`../AGENTS.md`](../AGENTS.md); measured values are in
[`../displays.toml`](../displays.toml). This file points at those and does not
restate them.

---

## 1. What it is for

`status` answers "what does this computer think is set up, and what does that
cover?" — for someone who is either checking a fresh install or working out why
a switch did not happen.

**It says everything it can, whether or not autostart is installed.** A computer
with no watcher registered is exactly where "what does this think is configured?"
is the question being asked, so nothing may exit early on that.

**It never sends a packet and never reads a VCP value.** It reports configuration
and process state only. Reads lie on this hardware (`../AGENTS.md` hard rule 2),
and a status command that moved a monitor would be its own hazard.

## 2. Reporting the watcher

Whether a watcher is running is answered **from the single-instance lock**, never
by counting processes.

An implementation whose watcher can run in a different session from the caller
cannot see that process reliably — on Windows an unelevated caller reads
`Win32_Process.CommandLine` as empty across the session boundary, so counting
reported none while a watcher was running and firing
(`../docs/measurements.md`). The lock is also what makes a second watcher
impossible, so it is the authority on both halves of the question.

A lock that **exists but cannot be opened** by this caller is a **running**
watcher, not an absent one. That is what a watcher in another session looks like
from here, and reading it as absent is the failure this rule exists to prevent.

Because the lock permits only one, this is a state and not a count.

## 3. The input map, and the claim it cannot make

`status` MUST show the configured input map — which computer each panel's inputs
are asserted to belong to — and MUST say, in words, that the tool cannot verify
it.

**Why this is not optional.** The map is an assertion about physical cabling.
If a computer's cable is moved to a different input **on the monitor**, a panel
whose EDID product id is stable across its inputs still resolves perfectly, so
`pull` sends the old value, the panel switches to an input with nothing on it,
and **it goes black — silently, with a success in the log.** A panel whose
product id differs per input fails safe instead, by refusing to resolve.

**Detection is barred, not merely unimplemented.** Reading the value back is
forbidden (`../AGENTS.md` hard rule 2) and would answer the wrong question
anyway; a success code proves nothing (hard rule 3). No protocol command means
"switch to whoever is talking" — see `../ideas/knowing-which-input-you-are-on.md`
for the research, including why even a perfect one would be refused on the same
grounds auto-input is.

So the only move available is making the failure **legible and cheap to
recover**, and that is this section's entire purpose. The user must be able to
learn, without reading the config file, what the tool believes and that the
belief is unchecked.

The map itself lives in exactly one place, `display.<label>.input.<value> =
<computer>` (see [`config-format.md`](config-format.md)). `status` READS that
map. It does not keep, cache or derive a second representation of it.

### 3.1 What it must say

Layout, ordering and separators are each platform's own. These fragments are
binding:

```normative
inputs   :
asserted, never verified
switches that panel to a dead input
Fix: trigger-kvm configure
```

The label ends in a colon and lines up with the other keys the implementation
prints. Every configured panel appears, with each of its input values and the
computer that value names, and the computer matching `computer.this` is marked
as this one — the same marking the `computers` line already uses.

**Within a panel, order by the computer, not by the input value.** Sorting on the
hex puts the same two computers in opposite orders on two panels, purely by which
socket each happened to be plugged into — the reason
[`config-format.md`](config-format.md) ("Ordering") writes the file that way too.
Ordered by computer, this block and the `computers` line agree, and the order a
person listed their computers in is the one they will look for.

**When no display is configured**, the map has nothing to assert and the warning
would be noise. Print the `inputs` label with the same "none configured" answer
the implementation gives elsewhere, and omit the warning.

### 3.2 What it must not say

- It must not claim the map is correct, or hedge the warning into a maybe.
  There is no signal behind such a claim.
- It must not offer to check the map. Nothing can.
- It must not suggest reading the current input back as a way to confirm it.

## 4. Coverage a transport takes away

Where a panel's configured transport cannot switch it under the installed
autostart tier, `status` MUST say so, naming the panel.

§2 already requires `status` to state what the tier covers. That statement is
about the *tier*, and a transport can make it untrue for one panel while it
stays true for the others — a machine can be installed from boot, correctly
report that it covers the login screen, and still have one monitor that will not
move until someone logs in. Reporting only the tier would be accurate and
misleading at once.

This is the same fact `configure` names when the transport is chosen
([`configure.md`](configure.md) §6.3 and §8); `status` is where someone looks
afterwards, when they have forgotten choosing it, or inherited the machine.

**Nothing is normative here**, for the reason §6.3 gives: a platform with one
transport has no panel this can be true of, and must not owe wording for a case
it cannot reach.

## 5. An identity that names more than one attached panel

Where a configured panel's identity currently matches **more than one attached
panel**, `status` MUST say so, naming the label it is configured as.

**The switch has already been refused by the time anyone looks here.** Resolution
is by EDID vendor:product and refuses on more than one match, so the panel simply
stops following, and the reason goes to the log — which is not where anyone looks,
because the symptom is a monitor that used to work and now does not. That is the
same shape as §3: something the tool can see perfectly well and does not say out
loud.

This is the same fact `configure` names when the identity is met in the Monitors
list ([`configure.md`](configure.md) §6.4). `status` is where the person looks
who did not run `configure` today — who plugged a second identical panel in weeks
ago and has no reason to connect the two events.

**Enumerating is permitted here.** §1 bars sending a packet and reading a VCP
value; asking the platform what displays are attached is neither, and `status`
already has to look at real hardware to report what the watcher is waiting for.

### 5.1 What it must say

Layout is each platform's own, as in §3.1. These fragments are binding:

```normative
more than one attached monitor matches
the switch refuses rather than guessing
```

**Name the count where the platform has it.** "More than one" is the least the
resolver knows; a number is better, and nothing above stops an implementation
printing one.

### 5.2 What it must not say

- **It must not offer a fix it does not have.** `configure` cannot resolve this
  and must not be suggested as though it could — the opposite of §3.1, where
  `configure` is exactly the fix.
- **It must not name one of the panels as the one that will be used.** Nothing
  chooses, and a line implying something did is worse than the silence this
  section replaces.
- It must not report the condition for a configured panel that is merely
  **absent**. Zero matches and two matches are different states with different
  remedies, and only the second is this section.
