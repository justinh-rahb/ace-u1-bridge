# Design Notes

This document captures the design rationale, open questions, and architectural
decisions made during initial planning. Intended as context for Claude Code
sessions and future contributors.

## Origin & Context

This project started from the question: "what if we made the ACE Pro work with
the Snapmaker U1 instead of the Kobra 3 V2 it was sold with?"

The ACE Pro communicates over USB serial using a JSON-RPC protocol that has
been fully reverse-engineered by the community (see `ACEResearch` →
`DuckACE` → `ACEPROSV08` → `Kobra-S1/ACEPRO` lineage). It does not care what
printer it is attached to. The `ace.py` Klipper extra is the key artifact —
it speaks the protocol and exposes gcode commands.

The Snapmaker U1 is a 4-toolhead tool-changer running a heavily modified
Klipper fork. It already solves multi-material printing differently from
filament-switcher systems like AMS/MMU — each toolhead has its own extruder
and filament path, so "color switching" is just a physical toolhead swap with
no purging required. What it lacks is upstream filament management: active
drying, smart spool handling, and optional lane switching.

## The U1 Filament Feed System

This is the most important thing to understand before touching anything.

The U1 has two internal `[filament_feed]` modules (`left` and `right`), each
controlling 2 channels:
- `left`: e0 (extruder) + e1 (extruder1)
- `right`: e2 (extruder2) + e3 (extruder3)

Each module has its own DC motor, wheel tachos, port sensors, and pushes
filament approximately **950mm** from the back panel entry to the extruder
gears (the `preload_length` parameter). This is Snapmaker's own internal
motorized Bowden assist — effectively a mini-AMS already built into the frame.

The `SM_PRINT_AUTO_FEED` / `AUTO_FEEDING` gcode commands drive this system.
The load/unload tip-forming sequence is compiled into Snapmaker's Klipper
fork, not exposed as editable gcode macros. This means:
- We cannot directly edit tip-forming parameters as gcode
- We CAN wrap `AUTO_FEEDING` calls with pre/post ACE coordination
- The U1 unloads filament clear of the extruder but NOT back to the spool

## Integration Mode Analysis

### Mode 1: Dumb Drybox (no protocol)

ACE Pro sits at the spool end, keeps filament dry at 45-55°C, feeds passively
into the U1's back panel entry. No USB connection to any Klipper instance.
U1's own feed motors handle the 950mm path as normal.

**Pros:** Zero firmware risk, immediate value, works today  
**Cons:** No lane switching, no dryer control from printer, no runout handoff  
**Validation:** This is the first thing to do. Confirms Bowden routing works.

### Mode 2: Lane-per-Toolhead (1:1 mapping)

One ACE lane feeds one U1 toolhead. 4 lanes → 4 toolheads. ACE connected to
ACE Klipper instance. U1 triggers ACE retract after unload, ACE triggers U1
load on feed complete. Dryer control from U1 side via router events.

**Pros:** Clean 1:1 mapping, simple routing table, ACE handles drying  
**Cons:** No lane switching within a toolhead (still 4 colors max, same as stock)  
**Gain:** Active drying, endless spool potential, spool management

### Mode 3: 2+2 Split (lane switching per toolhead pair)

ACE lanes 0+1 → T0, lanes 2+3 → T1 (or any split). Each ACE-equipped
toolhead can switch between 2 colors. During SnapSwap dwell time (toolhead
parked, ~70°C standby), ACE performs the lane switch. The slicer must be
aware of which toolhead has multiple lanes.

**Pros:** 6+ effective colors (2 singles + 2 dual-lane heads), unique capability  
**Cons:** Complex routing table in macros, lane switch must complete in park dwell window  
**Open question:** Is park dwell time long enough for a full ACE lane switch cycle?

### Mode 4: Full 4-lane on one toolhead

All 4 ACE lanes → 1 toolhead via a 4-in-1 passive splitter. Other 3 toolheads
unchanged. Maximum color count on one head, but requires splitter hardware
and significantly more complex tip-forming tuning.

**Not recommended as starting point.** The U1's integrated-nozzle design
(heat sink + heat break + block + nozzle as one unit, no individual
replacement) makes hotend modifications risky.

## The Two-Klipper Architecture

### Why not run ace.py on the U1 Klipper directly?

The U1 runs Snapmaker's proprietary Klipper fork. It has custom modules
(`filament_feed`, `park_detector`, `filament_entangle_detect`,
`inductance_coil`, `fm175xx_reader`, etc.) that don't exist in vanilla
Klipper. Adding `ace.py` as an extra *might* work, but:

1. Snapmaker OTA updates would need to preserve the extra
2. If `ace.py` crashes, it takes the main printer process with it
3. The ACE USB reconnect issue (known in the driver) is especially bad if it
   can crash a live print
4. It complicates the codebase unnecessarily

Running a second minimal Klipper instance (vanilla) just for the ACE keeps
failure domains isolated. If the ACE instance crashes, the U1 keeps printing.

### The ACE Klipper instance

Minimal config needed:
- `[mcu]` or just host MCU (ACE talks USB serial, not SPI/UART to a board)
- `[ace]` section from `ace.cfg` with correct serial path
- Two `[filament_switch_sensor]` sections (RMS + toolhead sensors per the
  ACEPRO driver requirements)
- `[include router_api.cfg]`
- Event handler macros from `macros/ace_events.cfg`

Can run on the same SBC as the U1 — just a second `klippy.py` process on a
different Unix socket path.

### Klipper Router role

The router (`klipper_router.py`) connects to both Unix sockets and registers
`router/*` remote methods on each. This lets either instance call the other's
gcode macros asynchronously.

Key router features used in this project:
- `router/event/trigger` + `router/event/subscribe` — async handoff signals
- `router/objects/subscribe` — U1 watches ACE slot status, drying state
- `ROUTER_ON_CONNECTED` / `ROUTER_ON_DISCONNECTED` — fallback handling
- Auto-reconnect — ACE USB instability is a known issue; router handles it

## Handoff Distance Constants

These need to be measured after physical installation and will vary by ACE
placement relative to the printer.

```
# In ace.cfg on the ACE Klipper instance:
parkposition_to_toolhead_length: ???    # distance from park pos to U1 extruder
parkposition_to_rms_sensor_length: ???  # distance from park pos to RMS sensor
total_max_feeding_length: ???           # total ACE → nozzle path length

# The U1 preload_length (in printer.cfg filament_feed sections) is ~950mm.
# Total path = ACE placement offset + 950mm.
```

## AFC Integration

The U1 config already has an AFC (Automated Filament Changer) framework in
`afc.cfg` — it maps E0-E3 lanes with toolhead sensors. This was added in
anticipation of exactly this kind of integration. The `[AFC_lane]` sections
map extruders to channels and already reference the `filament_motion_sensor`
entries.

The ACE bridge macros should eventually integrate with AFC lane state so that
Mainsail/Fluidd can display which ACE slot is loaded in which lane.

## Open Questions

- [ ] What is the park dwell window for a SnapSwap cycle? Is it long enough
      for a full ACE lane switch (retract + switch + feed)?
- [ ] Where exactly does `AUTO_FEEDING UNLOAD=1` leave the filament tip?
      (In the Bowden tube? At the back panel entry? Needs physical test.)
- [ ] Can the ACE Klipper instance run on the U1's embedded SBC, or does it
      need a separate host? (U1 uses RK3568 SoC — likely enough headroom.)
- [ ] Does the U1's 6mm OD / 4.6mm ID Bowden tube accept standard ACE output
      connectors, or does an adapter fitting need to be printed/sourced?
- [ ] For 2+2 mode: does the lane switch need a dedicated 2-in-1 passive
      splitter at the toolhead entry, or can the ACE output directly?
- [ ] Endless spool: the ACEPRO driver lists this as TODO — is it far enough
      along to be useful, or should that be a separate contribution?

## Related Projects & Reference

| Project | Relevance |
|---------|-----------|
| [Kobra-S1/ACEPRO](https://github.com/Kobra-S1/ACEPRO) | The ace.py driver we're using. S1-specific macros need replacing with U1 equivalents |
| [ANYCUBIC-3D/klipper-go](https://github.com/ANYCUBIC-3D/klipper-go) | Anycubic's own Golang Klipper port — useful for understanding ACE protocol internals |
| [printers-for-people/ACEResearch](https://github.com/printers-for-people/ACEResearch) | Original protocol reverse engineering |
| [utkabobr/DuckACE](https://github.com/utkabobr/DuckACE) | Base driver implementation upstream of ACEPRO |
| [jbatonnet/Rinkhals](https://github.com/jbatonnet/Rinkhals) | Community CFW for Kobra 3 V2 — reference for Klipper + ACE integration on the source hardware |
| [BunnyACE](https://github.com/BlackFrogKok/BunnyACE) | Referenced by klipper-go ACE module — another ACE protocol implementation |

## Session Context for Claude Code

When continuing this work in Claude Code, provide this context:

> This project integrates an Anycubic ACE Pro multi-material unit with a
> Snapmaker U1 4-toolhead printer. The U1 runs a proprietary Klipper fork
> with custom modules. We are running a second minimal vanilla Klipper instance
> for the ACE Pro, and using klipper-router (a JSON-RPC bridge over Unix
> sockets) to coordinate between them. The U1 handles all print operations;
> ACE handles filament from spool to U1 back panel entry. The handoff is
> event-driven via router/event/trigger. Read README.md, DESIGN.md, and all
> files in macros/ and config/ before making changes. The upstream submodules
> in upstream/ are read-only references.
