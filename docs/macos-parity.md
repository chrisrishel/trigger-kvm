# macOS parity — brief for whoever picks up the Mac side

**Status:** the Windows half was substantially rebuilt on 2026-08-30. macOS still
works, but it is now behind on naming, configuration, CLI shape, install tiers and
robustness. This is the catch-up brief.

Read [`../AGENTS.md`](../AGENTS.md) first — the hard safety rules are unchanged and
non-negotiable. Read [`../displays.toml`](../displays.toml) for the values. Nothing
below overrides either.

---

## 1. The rename happened

The project is **`trigger-kvm`**, renamed from `display-switch` because that name
collides exactly with [haimgel/display-switch](https://github.com/haimgel/display-switch)
(3,430 stars, actively maintained). The mechanical substitution across the macOS
files is already committed (`a5cd7eb`) but **has never been run on a Mac** — treat
it as edited-unverified and check it before trusting it:

| Was | Is |
|---|---|
| `macos/switch-displays.sh` | `macos/trigger-kvm.sh` |
| `com.chrisrishel.displayswitch` | `com.chrisrishel.trigger-kvm` |
| `~/Library/Logs/displayswitch.log` | `~/Library/Logs/trigger-kvm.log` |
| log prefix `display-switch:` | `trigger-kvm:` |

**`make install` must remove the pre-rename install**, or you get two LaunchAgents
and two watchers both firing on the same arrival. Windows does this in
`Remove-LegacyInstall`; mirror it: `launchctl bootout` the old label, delete the old
plist and binaries, and move the old log aside rather than deleting it. References
to `haimgel/display-switch` in prose are deliberately *not* renamed — they point at
the other project.

## 2. Adopt the config file

Machine-local facts no longer live in the scripts. Windows generates
`%LOCALAPPDATA%\trigger-kvm\config`; the macOS equivalent should be
`~/Library/Application Support/trigger-kvm/config` (or `~/.config/trigger-kvm/config`
— pick one and document it).

```
display.lg.vendor  = 0x1E6D     # EDID manufacturer id
display.lg.product = 0x9E9F     # NOTE: per-input on this panel. See below.
display.lg.name    = LG 45GX950A
display.lg.method  = lg-alt     # standard | lg-alt
display.lg.self    = 0xD1       # the input where THIS machine is. Required.

trigger.device   = 046d:0843,1235:820a
trigger.debounce = 3.0
trigger.settle   = 0.75

scene.windows.lg = 0xD0         # manual only -- the trigger never reads scenes
```

Flat `key = value`, `#` comments, deliberately not TOML/JSON — it is read on every
device arrival and must not need a parser. In shell that is one function:

```sh
cfg() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$CONFIG" | sed 's/[[:space:]]*#.*//;s/[[:space:]]*$//' | head -1; }
```

**Why the trigger keys are flat.** They were briefly nested under a transport and
reverted: nesting advertised a capability that does not exist, and a malformed id
already fails loudly, so nothing was failing silently for it to prevent. The one
structural rule that does matter: **`debounce` and `settle` must be global to
triggers**, never per-transport, because two independent debounce windows could not
dedupe against each other. Keep them at `trigger.*`.

Worth knowing before assuming the Mac watcher is inherently USB-bound: on Windows
the detection *query* turned out not to be — `Win32_PnPEntity` reaches Bluetooth,
PCI and Thunderbolt, and USB is only the ID pattern matched.

**But a generic query is not the same as a generic model,** and this is the trap.
The watcher assumes a node exists only while the device is attached, so presence ==
connected. That holds for USB and fails for Bluetooth: on Windows a *paired* device
keeps its node forever — AirPods last connected ten months ago and an iPhone three
years ago both still report `Present=True`. The edge would never fire and the
trigger would silently never work. Adding Bluetooth needs a different watcher using
connection-aware APIs, not a wider match pattern. Expect IOKit to have the same
distinction between paired and connected, and check it before assuming otherwise.

**The Mac's `self` values are different from the PC's, and that is the whole point.**
Each machine configures only its own inputs. On this desk the Mac sits on the LG's
USB-C (`0xD1`) and the ASUS's DisplayPort (`0x0F`); Windows sits on `0xD0` and `0x11`.
Neither machine records the other's — see §4.

**Trap, and it will bite here specifically:** the LG's EDID *product id is per-input*
— `0x9e9d` on DP (what Windows sees), `0x9e9f` on USB-C (what the Mac sees), `0x9ea0`
through the old KVM. So the Mac's config must carry **its own** measured value. Do
not copy `0x9e9d` from the Windows config; it will match nothing. The ASUS reports
`0x42e0` everywhere, which makes this trap easy to walk into.

## 3. Adopt the CLI shape

```
trigger-kvm.sh pull              # pull every configured monitor to THIS machine
trigger-kvm.sh to windows        # apply a saved scene
trigger-kvm.sh pull --only lg    # one monitor only
trigger-kvm.sh pull --dry-run    # resolve + print, send nothing  (= -WhatIf)
```

Replaces `trigger-kvm.sh mac|windows`. **`pull` is the only thing the trigger may
ever run.** Keep a dry-run mode — it is what makes the installer's guided discovery
safe, and it caught real mistakes on the Windows side before anything reached a
monitor.

## 4. The invariants — do not break these

- **Each machine knows only its own inputs.** `pull` reads only `self`. A scene is
  the one place a machine records another machine's inputs; scenes are local,
  optional, and **unreachable from the trigger path**. If the LaunchAgent can ever
  invoke a scene, a stale scene becomes able to cause an automatic switch to a dead
  input. Keep the verbs separate.
- **Fail closed on partial data.** Resolve every value before sending anything. A
  scene naming three displays with values for two moves none of them.
- **Never treat an unparsed value as zero.** In shell an empty `cfg` result is an
  empty string, and `$((0x))` or an unquoted expansion can quietly become `0` — a
  write aimed at the wrong input, or a match against vendor `0x0000`. Refuse.
- **The `0x50` sidechannel may only ever reach a GSM (`0x1e6d`) panel.** On Windows
  this is enforced *at the transport*: one function can emit `0x50`, the source byte
  is not a parameter, and it throws on a non-GSM target, so `method = lg-alt` in
  config grants nothing. Mirror that structure — do not enforce it at the call site.
- **The install tier is a property of the host.** All tier logic belongs in the
  Makefile/installer. Neither the watcher nor the switcher may branch on which tier
  it runs under.
- **Single instance must be machine-wide, not per-user-session**, for the same
  reason Windows moved from `Local\` to `Global\`: a login-time watcher and a
  boot-time watcher would each take their own lock and both fire, and the debounce
  is per-process.

## 5. Install tiers, and the pre-login problem

Windows now ships two tiers: a default needing no admin (logon task, covers
everything from login onward **including while locked**), and `-Tier s4u` needing
admin once to register, which runs at boot in session 0 and adds before-first-login
and after-logoff.

**macOS is genuinely harder, and the reason is not the same as it was on Windows.**
Windows' old blocker was `dxva2` needing an `HMONITOR`; that path is deleted, and
NVAPI was measured to both enumerate *and write* with no desktop. macOS's blocker is
that `m1ddc` links CoreGraphics and enumerates via `CGGetOnlineDisplayList`, which
needs a window server connection a LaunchDaemon does not have.

The known CoreGraphics-free path: enumerate `DCPAVServiceProxy` entries where
`Location = External` directly from IORegistry, then `IOAVServiceCreateWithService`
+ `IOAVServiceWriteI2C`. SimpleKVM confirms the sketch is right.

**The unsolved part is identity, not access.** SimpleKVM pairs displays *by
enumeration order*, and its own notes call EDID/location matching a known follow-up.
With two external monitors, order-based pairing can send the LG's `0xF4` packet to
the ASUS. That is a research problem and it is a hard blocker on a macOS pre-login
tier — **do not ship order-based pairing to work around it.** Better to have no
pre-login tier on macOS than one that can aim a service-channel write at the wrong
panel.

Before doing any of that, answer the cheap question first: **does the Mac already
switch correctly from the lock screen?** On Windows the answer was yes, which
narrowed the pre-login tier's value considerably — locking doesn't end the session,
so the watcher is still alive. If the same holds on macOS, a LaunchDaemon buys only
before-first-login and after-logout, and may not be worth the identity problem.

## 6. Robustness items Windows has and macOS does not

- **Log rotation.** `~/Library/Logs/trigger-kvm.log` is still unbounded. Windows
  rotates at watcher startup, past 1MB, keeping one `.1`. Placement matters:
  *after* the single-instance lock, so a redundant start does not rotate, and once
  per start rather than per write, so the switcher — a separate process appending to
  the same file — cannot race a rename mid-switch.
- **Log the no-edge branch.** Windows' watcher used to drop a device event yielding
  no arrival with a bare `continue`, so a quiet log could not distinguish "no event
  arrived" from "an event arrived and was correctly rejected". Same outcome,
  different claim. Check whether `usb-watch.c` has the same silent branch.
- **Worth knowing before you tune anything:** one physical USB plug produces
  **~32** device-change events on Windows, an unplug ~13. If IOKit behaves similarly,
  the debounce is load-bearing for ordinary operation, not just for flaky hardware.

## 7. The installer, once Windows has it

Windows is heading toward an interactive installer: display discovery by
enumeration, trigger discovery from a filtered list of currently-present removable
devices, guided input discovery, tier choice, and a re-runnable scene manager. Build
the macOS equivalent **after** the Windows one settles, and mirror its flow rather
than inventing a second one.

Two rules from that design that are already settled and apply to both platforms:

- **Guided input discovery is allowed only on standard DDC/CI** (`0x51`/`0x60`),
  using published MCCS values, offered as a labelled list the user picks from one at
  a time, each confirmed visually. Never auto-advance through values — that is a
  sweep. Never do guided discovery on a manufacturer sidechannel; those values come
  only from the known-monitor knowledge in `displays.toml`, or from a value the user
  types themselves.
- **Verify by switching away, holding ~8s, returning automatically, and asking
  afterwards.** The question then always arrives on a display that has already come
  back, so the installer never needs to know which monitor its own window is on, and
  a wrong guess costs eight seconds of black rather than a stranded session.

## 8. Suggested order

1. Verify the rename actually works on a Mac (`make`, `make plist`, `make install`).
2. Add legacy-install removal to `make install`.
3. Config file + `pull` / `to` verbs + dry-run.
4. Log rotation and the no-edge log line.
5. Answer the lock-screen question.
6. Interactive installer, mirroring Windows.
7. Pre-login, only if the identity problem is genuinely solved.

Steps 1–4 are mechanical parity. Step 5 is one experiment and may change how much
of 7 is worth doing.
