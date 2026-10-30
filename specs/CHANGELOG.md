# specs -- changelog

Behaviour changes implementations must act on, newest first. **The revision is
the largest `## Revision N` below.** Each implementation records the revision it
implements in its own `SPEC-REVISION`; its suite fails while that is behind and
names the entries in between. When you land a spec change: add the next entry,
implement it on your platform, bump your platform's `SPEC-REVISION` only, push
(`README.md`, "How a change flows").

An entry carries what changed, the sections, and what an implementation must
do; where platforms differ, it says which. Not how to implement it. Entries
older than both platforms' revisions are kept as one line each; git holds the
rest.

---

## Revision 15 -- 2026-10-29

**Status resolves the saved configuration, and menu overflow preserves text.**

Sections: [`status.md`](status.md) 4.1; [`detector.md`](detector.md) 4.1;
[`configure.md`](configure.md) 3.1. No new normative strings.

**Act on (both platforms):** label trigger resolution as the current saved
configuration, show each entry's current result using the watcher resolver,
and remind the user that trigger edits require `trigger-kvm restart`. Do not
imply that this reads the running watcher's loaded configuration. Preserve
unbreakable menu text, including in narrow terminals, and account for folded
and leftover rows during redraw; the width is a wrapping target, not a reason
to truncate identifiers.

## Revision 14 -- 2026-09-07

**Ambiguity is a state, a pass is bound to what it checked, absent panels and
remembered ports survive Save, "no autostart" means this session, and the
listing modes need no config.**

Sections: [`detector.md`](detector.md) 1, 2, 4, 4.1; [`configure.md`](configure.md)
6, 6.1, 7, 7.1, 8, 10.1, 10.2, 10.7, 10.8, 11, 12; [`config-format.md`](config-format.md)
"trigger.device", "Ordering", "Hand edits survive"; [`status.md`](status.md)
3.1, 4.1. No normative string changes; nothing new for the conformance check.

**Act on (both platforms):**

1. `detector.md` 2: the arrival edge belongs to the device that arrived. A
   qualified entry fires only when the device it resolves to arrives, never
   when another device sharing the id does while the configured one is present.
   (macOS `device_appeared` re-counted present devices; Windows compares
   presence maps and is affected only through item 2.)
2. `detector.md` 4.1: AMBIGUOUS is a state distinct from absent, re-evaluated
   every sweep, never latched; leaving ambiguity re-baselines and never fires;
   a watcher whose every entry is ambiguous at start refuses; `status` 4.1
   reports the watcher's verdict per entry, from the watcher's own code.
   (Windows: an ambiguous entry reads as absent, so one twin being unplugged
   fires; an all-ambiguous list still arms; macOS: latched until restart while
   `status` shows fine.)
3. `detector.md` 4.1 writer rule, settled: token alone where unique; shared
   token plus `where` where the places differ; bare id where nothing
   distinguishes. `where` is never written without a token.
4. `detector.md` 1: a lock that cannot be established for a reason other than
   "held" refuses to start. (macOS continued unlocked.)
5. `detector.md` 4: the listing modes need no config and refuse nothing.
   (Windows `event-watch.ps1` refuses `-ListUsb`/`-ListBluetooth` when the
   config lacks `trigger.device`, so a fresh machine's walkthrough lists no
   triggers.)
6. `configure.md` 6: a configured panel that is not attached is shown, keeps
   every key on Save, and is not checked. (Both platforms built answers from
   attached panels only and dropped the rest on Save.)
7. `configure.md` 7.1: nothing is filtered by name, hubs included. (Both
   platforms hide `hub`, `host controller`, `root complex`, and both suites pin
   the filter; delete the filter and those tests.)
8. `configure.md` 7 and 11: a saved entry's `where` survives a re-save while the
   device is away, and the one-shot is given the entries as they will be saved.
9. `configure.md` 8: "No" starts the watcher now for this session only and
   leaves nothing that returns at login. (macOS wrote a `RunAtLoad` plist into
   `~/Library/LaunchAgents`.)
10. `configure.md` 10.2 and 10.7: every path that moves a panel goes through the
    round preamble, including the no-other-computer transport check and a
    single-panel retry. (Both platforms sent immediately on that path.)
11. `configure.md` 10.8 and 11: a pass is bound to scope, method, transport and
    map; any edit to those invalidates it; the trigger check pulls for real only
    with a current pass on every managed attached panel. (Both cleared the
    result text but not the pass flag on a map edit; both let a one-panel pass
    authorise a full pull.)
12. `configure.md` 11: the trigger check restores the watcher to its prior
    state on every way out, cancel and EOF included.
13. `configure.md` 12: the closing words claim only what was reached; a tier
    that failed to load says so.
14. `config-format.md` "trigger.device": every surface parses an entry with the
    watcher's rule (trim per entry; suffix case checked, not normalised).
    (Windows lower-cased and stripped whitespace at three UI sites.)
15. `config-format.md` "Ordering": a reader returns computers in file order.
    (Both sorted keys, so `status` showed hex order.)
16. `config-format.md` "The line format": `\s` includes VT and FF. (macOS
    trimmed space, tab and CR only.)

## Older revisions

Revisions through 13 are condensed below; each platform's `SPEC-REVISION`
records its current implementation.

- **13** (2026-09-05): two attached panels with one EDID id are shown, refused
  in the walkthrough, and reported by `status` (`configure.md` 6.4, `status.md` 5).
- **12** (2026-09-04): `usb:VVVV:PPPP[@token[@where]]`; ambiguous entry
  disabled, watcher not; never fall back to the whole id (`detector.md` 4.1).
- **11** (2026-09-04): a writer removes `#`, CR, LF and trims; refuses an
  identifier it cannot represent (`config-format.md`).
- **10** (2026-09-04): a Triggers row says what the device is, best name, role,
  nothing filtered (`configure.md` 7.1).
- **9** (2026-09-04): `transport` is a config key separate from `method`;
  unrecognised refused by name; no platform must have two (`config-format.md`,
  `configure.md` 6.3, 8, `status.md` 4).
- **8** (2026-09-02): `status` shows the input map and says nothing can verify
  it; answers "running" from the lock (`status.md`).
- **7** (2026-09-01): the detector contract; settle tests the arriving device;
  startup refuses bad entries by name; the shared config fixture; checker
  trims before measuring and takes the maximum revision.
- **6** (2026-09-01): the service-channel consequence named at the method
  chooser and the typed-value prompt; a panel is one submenu; unique short name;
  collision by value; declined elevation falls back to login; trigger check
  stands the watcher down.
- **5** (2026-08-31): enter never destroys; `Remove a computer` is a row;
  unmanaging confirms and names what it forgets.
- **4** (2026-08-31): macOS offers the boot tier (LaunchDaemon with `UserName`).
- **3** (2026-08-31): a multi-select obeys the layout rules; erase to end of
  line, never pad.
- **2** (2026-08-31): the manufacturer method is offered up front; esc on the
  top menu moves to Cancel.
- **1** (2026-08-31): the initial corpus.
