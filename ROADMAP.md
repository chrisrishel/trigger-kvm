# Roadmap

Milestones and trajectory only. Tasks live in [`TODO.md`](TODO.md); evidence in
[`docs/measurements.md`](docs/measurements.md); reasoning in
[`docs/decisions/`](docs/decisions/); exploration in [`ideas/`](ideas/);
contracts in [`specs/`](specs/README.md).

## Built

- **Pull-to-self on both platforms**, USB and Bluetooth triggers, the walkthrough
  with visual checks, one config format, one verb surface.
- **A boot tier that runs unelevated** on both platforms: Windows S4U task in
  session 0 (measured firing at an empty logon screen and between a logoff and
  the next logon), macOS LaunchDaemon with `UserName`.
- **Aimed writes.** The LG's service channel reaches exactly one output, gated
  at the transport by EDID vendor, on both platforms.
- **Two Windows transports**, `nvapi` and `dxva2`, chosen per panel at configure
  time, never a fallback (decision 003). The shipped `dxva2` path has not yet
  been watched moving a panel; every run so far was `-WhatIf`.
- **Identity the tool cannot resolve is made visible**: two panels with one EDID
  id are refused and named in `list`, `configure` and `status`; two USB devices
  with one vendor:product can be told apart by `@token@where`; `status` shows the
  input map and says nothing can verify it.
- **Specs with enforcement**: normative strings checked by each suite, a
  revision ledger each platform tracks, a shared config fixture.

## Next

- **Watch a panel move over the shipped `dxva2` path** (`TODO.md`).
- **A tiebreak for two identical monitors**, designed and unbuilt
  ([`ideas/telling-two-identical-monitors-apart.md`](ideas/telling-two-identical-monitors-apart.md)).
  The measurement it waited on (NVAPI ids survive reboots and a driver update)
  has been taken.
- **Behavioural conformance fixtures** for the walkthrough and the detector,
  replacing string presence as the proof that the two implementations agree.

## Open

- **An AMD transport (ADL).** A raw I2C route that may reach the LG's
  sidechannel and may work in session 0. No AMD hardware here to measure.
- **A watcher handover** for a machine whose configured transport needs a
  desktop: run in session 0 before login, hand over after. Whether it earns its
  complexity is undecided; the alternative is the disabled `From boot` row that
  `specs/configure.md` 8 already provides.

## Deliberately not built

| | record |
|---|---|
| Intel-Mac DDC (proven, not built) | [`004`](docs/decisions/004-intel-mac-ddc-proven-not-built.md) |
| IGCL as an Intel transport (every write needs admin) | [`005`](docs/decisions/005-igcl-ruled-out-by-its-elevation-requirement.md) |
| Autologin as a pre-login tier | [`ideas/rejected/autologin-tier.md`](ideas/rejected/autologin-tier.md) |
| A capabilities read (`0xF3`/`0xE3`) | waits for a third-party standard-DDC monitor in the room; [`ideas/unknown-monitor-discovery.md`](ideas/unknown-monitor-discovery.md) |

## Accepted limitations

- **Wake is not a trigger.** Drift while a computer is awake strands you until
  the switch next moves.
- **A switch is confirmed only by a human looking at the screen.** No read-back,
  no retry loop.
- **The input map is an assertion about cabling the tool cannot check**; `status`
  makes that legible and nothing can make it detectable.
- **The LG needs raw I2C whatever the GPU**, so no vendor-neutral tier covers
  this desk.
- **A `dxva2` panel is login-tier only.**
- **A USB switch mode that hands the peripherals to both computers is
  unsupported**: both watchers would fire.
