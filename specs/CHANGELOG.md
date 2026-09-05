# specs — changelog

**Behaviour changes implementations must act on.** Newest first.

This is not a git duplicate. Git records every edit to `specs/`, including
rewording and typo fixes; this records only the changes that give an
implementation something to do. If an entry does not create work for a platform,
it does not belong here.

## How it is used

The **revision is the number of the newest entry below.** Each implementation
records the revision it is known to implement in its own `SPEC-REVISION` file,
and its own test suite fails while that is behind. So a platform learns it is out
of date from its own test run, with no one having to tell it — which is what
makes this scale to a third implementation for free.

**When you land a spec change:**

1. Add an entry here with the next number.
2. Implement it on the platform you are working on and bump that platform's
   `SPEC-REVISION`.
3. Leave every other platform's `SPEC-REVISION` alone. Their suites will now
   fail, which is the point, and they will read the entries between their number
   and this one to find out what they owe.

You do **not** append to every other platform's `HANDOFF.md` for a spec change.
That is fan-out: N−1 edits per change, worse with every platform added, and
silent if one is forgotten. A `HANDOFF.md` is for what the machinery *cannot*
tell a platform — chiefly a defect someone found in its code by reading it.

Fan out when the message is N different claims. Publish once when it is one fact.

## What an entry has to carry

**This file is the ONLY context channel for a spec change**, since none is fanned
out to the platforms. That is a fair trade only while an entry actually carries
the context a handoff would have. A thin entry — "§5 changed" — breaks the deal,
and the next person's instinct that they should have been written to directly
becomes correct.

So every entry carries, and the entries below are the worked examples:

- **What changed, in one bold line** a reader can match against a symptom.
- **`Sections:`** — the exact spec sections, linked. This is "where it is
  relevant"; the conformance failure gives strings, not places.
- **`Act on:`** — what an implementation must DO, as opposed to what the spec now
  says. Name a platform where they differ: revision 4 is macOS-only, revision 3
  named the file and function Windows had to change.
- **Why the old behaviour was wrong.** The reasoning does not survive in the spec
  — the spec describes what is true now, not what it replaced — so if it is not
  here it is nowhere, and someone re-proposes the old design in a year.

What does NOT go here: how a platform should implement it. That is the thing the
other platform is better placed to decide, and the thing you cannot check, since
you can neither run its tests nor see its hardware.

## Why this exists alongside the conformance check

The conformance check already tells every platform when the spec adds a string
it does not have. It is blind to two things, and this closes them:

- **Behavioural changes with no new wording** — "the cursor lands on the first
  check rather than Save" has nothing to grep for.
- **Removed or renamed strings** — the check tests presence only, so a platform
  keeps old wording forever and stays green.

---

## Revision 10 — 2026-09-04

**A Triggers row is identified by what the DEVICE IS, with its id beside it —
and the platform is asked for the best name it has, not the first.**

Sections: **new** [`configure.md`](configure.md) §7.1.

**Act on:**

1. **§7.1 — the row says what the device is; the vendor+product pair moves
   beside it rather than being the row.** An id alone is not a choice anybody can
   make. The pair stays visible because §7's own help text tells the reader to
   match the FULL pair, and that advice cannot be acted on against a name alone.

2. **Ask for the best name available, not the first one found.** Where your
   platform has more than one source for a device's name, take the most specific.
   Windows had a rule that ranked a device's nodes by how specific each one's
   device *class* was, as a proxy for how good its name would be — and the proxy
   is inverted, because the input-device nodes are exactly the ones named
   generically. It put `USB Input Device` on a row whose sibling node already
   said `G915 X LIGHTSPEED TKL`.

3. **Where the platform reports what a device presents itself as** — mouse,
   keyboard — put it on the row. Most recognisable thing there.

4. **Nothing new may become a filter.** Same rule as Bluetooth-on-paired: show
   what is true, let the person decide. "Looks internal" is a guess.

**Why.** The list existed to answer "which of these travels with the switch?",
and on the reference desk it answered it with `USB Input Device` three times over
— a wireless receiver carrying the keyboard and mouse, the motherboard's RGB
controller, and a CPU cooler. Two of those three can never travel. The one that
holds the peripherals was indistinguishable from the two that are soldered into
the case, which makes the menu actively misleading rather than merely terse.

**Windows-specific, for context rather than for copying:** the second name source
is `DEVPKEY_Device_BusReportedDeviceDesc`, the USB `iProduct` string the device
reports about itself, and roles come from the classes of a device's `HID\`
children. Read it through `cfgmgr32` and not `Get-PnpDeviceProperty` — same
property, 0.14 ms against ~200 ms per call, which is 70 seconds for one desk.
Your platform's sources will be its own; what you owe is the shape, not the API.

**Note for whoever implements this next:** an id can cover MORE THAN ONE physical
device — two wireless receivers of the same model share one vendor+product pair,
and the reference desk has exactly that. Saying so on the row is within this
revision. **Selecting between them is not**, and is being designed separately in
[`../ideas/telling-two-identical-devices-apart.md`](../ideas/telling-two-identical-devices-apart.md);
it will need a config-format change and will arrive as its own revision.

## Revision 9 — 2026-09-04

**`transport` is a new config key, and a separate axis from `method`. Refuse an
unrecognised one BY NAME; you are not required to have a second transport.**

Sections: [`config-format.md`](config-format.md) "`transport` and `method` are
different questions"; [`configure.md`](configure.md) §6.3 (new) and §8;
[`status.md`](status.md) §4 (new).

**Nothing here is normative, so the conformance check will not name any of it.**
That is deliberate and it is why this entry is long: a platform with one
transport must not owe strings for menus it never draws. The whole change
travels on the revision.

**Act on (macOS) — the short version: one rule, and it is a refusal.**

1. **Read `display.<label>.transport`, and REFUSE a value you do not recognise,
   naming it.** Never default it to the transport you have. This is the one
   thing every platform owes, and the rule that makes a shared key with
   per-platform vocabulary safe: a config naming `nvapi` is a config for a
   different machine, and saying so is the honest answer. Defaulting instead
   would send the write down a path nobody ever confirmed by eye — and a
   transport, like an input value, is verified exactly once by a human looking
   at the panel (`../AGENTS.md` hard rule 3).

2. **Absent means your platform's original transport.** Every config written
   before this key existed keeps working, unrewritten. macOS has one transport,
   so in practice: absent, or the name of that one, is accepted; anything else
   is refused.

3. **You are NOT required to invent a second transport, and must not.** The key
   is shared; the vocabulary is each platform's, named after the API that
   carries it. macOS having exactly one name is the expected shape, not a gap.
   §6.3 says a platform with one transport asks nothing — so no new menu, and
   `configure.md` §6.3, `configure.md` §8's transport case and `status.md` §4
   are all unreachable for you and owe you no work beyond point 1.

**What Windows did, for context rather than for copying.** It gained `dxva2`
(Windows' own DDC/CI stack, any adapter) beside `nvapi` (aimed raw I2C, NVIDIA
only). That makes a 2×2 with one impossible cell — `dxva2` cannot express an I2C
source byte at all, so it cannot carry a manufacturer dialect — and the pair is
refused with the reason named rather than quietly downgraded to the standard
command. `configure` asks §6.3 only where a panel enumerated on more than one
transport, before the §6.2 method question, because the transport decides which
dialects exist. Because `dxva2` needs a desktop, the `From boot` row is drawn
disabled naming the panel, an already-chosen boot tier falls back to login and
says so, and `status` §4 says which panel a transport strands.

**Why `method` was not enough.** It conflated WHAT is sent with HOW it gets
there. Those were one key only because every platform had exactly one transport,
and the moment one has two, a single key cannot say that a panel takes the
standard dialect *and* which API carries it — the values on offer would change
meaning with the route. Splitting them is what lets a platform add a transport
without any dialect changing meaning on any other platform.

**Why the refusal, and not a fallback.** Nothing tries one transport and falls
through to another at switch time (`docs/decisions/003`). A silent fallback
would mean the packet that moved the panel on the day somebody watched it is not
the packet sent afterwards — which is the one property this project cannot give
up, because a human eye is the only verification the hardware permits.

**One thing to check rather than assume**, since §6.3 draws a line that could
otherwise blur hard rule 1b: **enumerating is not probing.** Listing this
computer's own adapters and reading the EDID each reports sends nothing to any
monitor. What 1b forbids is discovering a MONITOR's behaviour by experiment.
Building an offer from what enumerated is not that, and the spec now says so
explicitly so nobody has to re-derive it.

## Revision 8 — 2026-09-02

**`status` must show the input map and say that nothing can verify it.**

Sections: **new [`status.md`](status.md)**; [`README.md`](README.md) "Knowing you
are behind".

**FIRST: add `status.md` to your conformance loop.** Each suite loops over a list
of spec names it holds itself, so a new spec file is checked by NOBODY until it
is added — the revision is what tells you it exists, and this entry is the only
place that can name it. Windows added it to `windows/tests/spec.tests.ps1`. Do
the equivalent before reading the rest of this entry, or you will bump your
revision with the strings unchecked.

**Act on (macOS):**

1. **`status.md` §3 — `status` shows the configured input map, and says in words
   that the tool cannot verify it.** Four normative fragments: `inputs   :`,
   `asserted, never verified`, `switches that panel to a dead input`, and
   `Fix: trigger-kvm configure`. Every configured panel, each of its input values
   and the computer that value names, with `computer.this` marked as this one.

2. **`status.md` §3.1 — order each panel's inputs BY COMPUTER, not by input
   value.** Sorting on the hex puts the same two computers in opposite orders on
   two panels, purely by which socket each happened to be plugged into. This is
   the rule `config-format.md` "Ordering" already applies when writing the file;
   it now applies to showing it, so the block and the `computers` line agree.

3. **`status.md` §3.1 — with no display configured, print the label with your
   usual "none configured" answer and OMIT the warning.** An empty map asserts
   nothing, so the warning would be noise.

4. **`status.md` §2 — answer "is a watcher running" from the LOCK, not by
   counting processes.** A lock that exists but cannot be OPENED by the caller is
   a RUNNING watcher, not an absent one. On Windows this was live: an unelevated
   caller reads `Win32_Process.CommandLine` as empty across the session boundary,
   so `status` reported no watcher while a session-0 one was running and firing.
   macOS should check whether its own answer holds for a LaunchDaemon watcher
   seen from a user session; if it already does, nothing to do but say so.

**Why.** The input map is an assertion about physical cabling. When a cable moves
to a different input **on the monitor**, a panel whose EDID product id is stable
across its inputs still resolves perfectly, `pull` sends the old value, and the
panel switches to an input with nothing on it — **black, silently, with a success
in the log.** Detection is barred rather than unimplemented: reading the value
back is forbidden by hard rule 2 and answers the wrong question anyway, a success
code proves nothing under hard rule 3, and no protocol command means "switch to
whoever is talking" (`../ideas/knowing-which-input-you-are-on.md`). So the only
remedy available is legibility, which makes this wording a behaviour rather than
a nicety — and therefore something both implementations must have.

## Revision 7 — 2026-09-01

**The detector has a contract; the config reader has a shared fixture; the
checkers agree with each other.**

Sections: new [`detector.md`](detector.md); [`config-format.md`](config-format.md)
"The line format", "Value parsing", `trigger.device`, "Hand edits survive", "The
shared fixture"; [`README.md`](README.md) "Normative wording".

**Act on (both platforms):**

1. **`detector.md` §2 — settle tests the ARRIVING device**, not any watched
   device. Windows already does (`$arrived`); macOS checked `any` and the
   protection was inert with two devices that travel together. The same-flip
   second `pull` is accepted, not suppressed — recorded so nobody adds a
   device-identity window that could miss a real flip back.

2. **`detector.md` §4 — startup refuses a bad device entry or timing by name.**
   `usb:VVVV:PPPP` is exactly 4+4 hex; `bt:` exactly 12 hex, no separators; a
   bare 4+4 pair is `usb:`; anything else is refused, never prefixed into a
   `usb:` entry that matches nothing. Timings are `digits` or `digits.digits`;
   `three` is refused, not `0`. macOS `atof`'d to zero (both protections off);
   Windows threw before arming, silently, and was restarted every minute.

3. **`config-format.md` — whitespace includes CR; a BOM is ignored; enumerations
   are case-insensitive; a word is ≤ 65535.** macOS kept the CR (rev 6 fixed the
   reader; this makes it the rule) and was case-sensitive on the tier; both
   accepted words up to 99999.

4. **`config-format.md` "Hand edits survive" — EVERY key the walkthrough does not
   write is carried across**, unknown keys included. Both carried exactly two.

5. **`config-format.md` "The shared fixture"** — parse `config-fixture/input.conf`
   with your reader and reproduce `expected.tsv`; run your converters over
   `values.tsv`. Until now "conforms to config-format.md" passed vacuously on
   both platforms, because that file has no normative strings — and three
   reader disagreements were found by hand that this would have caught.

6. **`README.md` — the checker trims before measuring; the changelog head is
   the maximum revision.** macOS measured then trimmed and took the first
   heading; Windows trimmed then measured and took the maximum. Two specs were
   constructed that one flagged and the other did not.

**Why.** The detector is the one component that acts with nobody watching, and
it had no contract: its rules lived in `AGENTS.md` as things not to "fix on
sight", which tells a session what not to touch but not what a second
implementation must do. The reader had a contract that nothing enforced. Both
gaps were found by a review comparing the two implementations line by line —
which is exactly the reading the machinery exists to make unnecessary.

## Revision 6 — 2026-09-01

**Name the consequence at the service channel; a panel is one submenu; the
walkthrough refuses what the switcher would refuse later.**

Sections: [`configure.md`](configure.md) §4.2, §6, §6.1, §6.2, §8, §11.

**Act on (both platforms):**

1. **§6.2 — three lines in the method chooser** say what the manufacturer method
   is (a service channel), what is sent to it (only the recorded values) and
   what has happened on it (monitors made unusable). **§6.1 — two lines before
   the typed-value prompt** when the method is a manufacturer channel. Both are
   normative wording.

2. **§6 — a panel's questions are one submenu.** Esc at any menu in it returns
   to the Monitors list with the panel unchanged. Windows already does this;
   macOS advanced to the input questions instead.

3. **§6 — the short name is unique and follows §5.1's character rule**,
   suggested and asked. A duplicate is refused: `There is already a monitor
   called`. Windows strips underscores where the rule turns them into dashes.

4. **§6.1 — typed-value collision is by value**, and a typed value is stored as
   canonical `0xNN`. `17` and `0x11` were accepted as two sockets on both
   platforms.

5. **§8 — a declined prompt is "cannot be obtained"**: fall back to login, say
   `falling back to starting at login`, record login. macOS did; Windows exited
   with the config still saying boot and the watcher not restarted. And where
   the account is not an administrator, the `From boot` row is drawn disabled
   with `needs an administrator account` — on Windows this is the row that sent
   a standard account into a different account's UAC prompt.

6. **§11 — the trigger check stands the installed watcher down** where that
   needs no elevation and restores it after; otherwise it says `The running
   watcher will also fire, using the saved configuration.` before the flip.

7. **§4.2 — backing out of a check is not a failure**; the cursor does not go
   to Monitors.

**Why.** The review before publication found the bricking hazard stated only in
`AGENTS.md`, a file a user never opens, while the two moments a person actually
commits to the service channel said nothing. §2 already required naming the
consequence; this applies it. The rest are places where the two implementations
had quietly diverged (esc in the panel flow, the label rule, the declined
prompt) or where both accepted an answer the switcher would refuse later
(duplicate labels, `17` vs `0x11`) — the walkthrough exists to refuse those
while the person can still say what they meant.

## Revision 5 — 2026-08-31

**Enter must never destroy. Removing a computer becomes a row, and unmanaging a
monitor states what it forgets.**

Sections: [`configure.md`](configure.md) §5, §5.0, §5.3, §6.

**Act on (both platforms):**

1. **§5.0 — the rename prompt keeps the name on a blank answer**, pre-filled with
   the current name like every other prompt. It used to REMOVE the computer.

2. **§5.3 — a `Remove a computer` row**, between `Add another computer` and
   `Done`, opening a list that excludes `computer.this`, names the panels each
   computer is on in the detail column, and confirms with a default of no.

3. **§6 — answering no to `Manage this monitor?` confirms** when the panel has
   assignments, naming what is forgotten. A panel with none is not asked twice.

**Why.** Blank-means-remove made the most innocuous keypress available the
destructive one — the same failure as accepting an empty multi-select, which §3
already exists to prevent, for the same reason: enter is what people press.

It was visible in the code as a workaround before it was visible in use. The
prompt had to withhold its own default, because supplying one would have made
removal unreachable; the comment saying so was still there. A question that has
to opt out of the tool's own convention is the wrong question.

**Why a row and not a delete key.** A keypress has no typed-fallback equivalent,
and §3.5 makes that fallback load-bearing — it is how each platform's suite drives
`configure` end to end, so a key-only action is one no suite can reach. It also
breaks the rule the whole UI rests on, that enter does what the highlighted row
says; a hidden second verb per row is what that rule exists to prevent. A row is
visible, typed-fallback-native, and has a detail column to state the cost in.

**Why the monitor keeps a question rather than gaining a `Remove` row.** A monitor
is bolted to the desk; only its assignments can be removed. The symmetry worth
having between the two menus is not a shared keystroke but a shared rule:
anything that discards configuration says what it discards and asks.

## Revision 4 — 2026-08-31

**macOS can offer the boot tier after all — the row stops being disabled.**

Sections: [`configure.md`](configure.md) §8.

**Act on (macOS only):** enable the `From boot` row and install a LaunchDaemon
in `/Library/LaunchDaemons` with `UserName` set to the installing user. Windows
already has this tier and is unaffected.

**Why the row was disabled, and why that was wrong.** It read "not available on
macOS — needs root", on the reasoning that a LaunchDaemon runs as root and the
switcher must never run as root to obtain a tier. Both halves of that were
measured wrong:

- A LaunchDaemon with `UserName` runs **as that user, unelevated**. Root is
  needed to *install* it into the system domain, not to run it — exactly the
  Windows property, where admin registers the task and nothing elevated runs on
  the switch path.
- The supporting claim that "reading the displays needs a logged-in session" was
  also wrong. Measured from a LaunchDaemon: IOKit display identity works with no
  session and no CoreGraphics, `m1ddc display list` works, and a full
  `trigger-kvm pull` works as uid 501 with no session, both writes sent.

So the tier costs one plist and a single sudo at install. No root on the switch
path, no second root-owned config, no replacement transport.

## Revision 3 — 2026-08-31

**A multi-select must obey the same layout rules as every other menu.**

Sections: [`configure.md`](configure.md) §3.1, §3.4.

**Act on:** `Select-Many` / `select_many` must lay its rows out the way
`Select-One` does — the item column, and the detail wrapped at `", "` onto
aligned continuation lines. Both implementations concatenated instead, which is
fine until the content is long, and Bluetooth device names are.

Reported from a real 80-column terminal: the trigger list overflowed, wrapped,
and the redraw corrupted — stale text from the previous frame showing at the
right edge, and the help block repeated down the screen.

Two distinct defects, one cause:

- a wrapped line's tail is **not cleared** by the next frame, so what was there
  before shows through
- a line landing exactly on the terminal's fold occupies **two** rows while the
  naive count says one, so the frame stacks downward

Also: redraw by **erasing each line to its end**, not by padding it to the
width. Padding must measure the line, and `printf`'s field width counts bytes
while a terminal column is a character — so a name containing a typographic
apostrophe (macOS puts one in every "Terry’s iPhone") pads two columns short and
leaves the previous frame showing.

Windows has the same concatenation in `Select-Many` and the same padding in
`Write-MenuFrame`; it is at revision 0 and owes this along with revisions 1–2.

## Revision 2 — 2026-08-31

**Offer a manufacturer's alternative method up front, and make esc on the top
menu move to Cancel.**

Sections: [`configure.md`](configure.md) §3.3, §6, §6.2, §10.5.
Also amends [`../AGENTS.md`](../AGENTS.md) hard rule 1b.

**Act on:**

1. **§6.2 — a new question.** When the chosen panel's EDID vendor has a
   documented alternative method, ask which method to use, immediately after the
   short name and before any input question, because the values on offer depend
   on the answer. Standard stays the default and stays the cursor's start.
   Previously the alternative was reachable only by failing the check first.

2. **§10.5 — the escalation becomes symmetric.** A panel already on the
   manufacturer method that answers nothing must be offered *standard*. Before
   this it was told "no manufacturer values are known here", which is now
   reachable, false, and a dead end.

3. **§3.3 — esc on the top menu moves the cursor to `Cancel`** rather than doing
   nothing. It must not activate it: a setup still cannot be discarded by one
   keypress.

**Why:** forcing a known-alt-mode user to fail first cost more than it bought,
and someone who saw the standard method fail without being told the alternative
existed could reasonably give up before the check offered it. The "never probed"
half of hard rule 1b is untouched — values still come only from the documented
table or from the user, and the transport gate is unchanged.

## Revision 1 — 2026-08-31

The initial corpus: [`README.md`](README.md), [`config-format.md`](config-format.md)
and [`configure.md`](configure.md), written from the finished Windows
implementation and the macOS one built to match it, and superseding
`docs/macos-parity.md`.

**Act on:** conform to every `normative` block, and to the behaviour described in
the prose around them.

- **macOS** conformed at the time this was written.
- **Windows** did not, and still does not. Two of its gaps are wording —
  §2 requires "computer", never "machine", in anything the user sees — and one
  is behaviour: §3.5 requires `configure` to accept a scripted answer stream on
  stdin, which is what makes the walkthrough testable end to end.

Run the conformance checker for the current list rather than working from one
written down here; this entry is dated and that list is not.
