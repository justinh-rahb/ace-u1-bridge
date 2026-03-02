# Design & Architecture

Design rationale, open questions, and architectural decisions made during development.

## Origin & Context

This project started from the question: *"what if we made the ACE Pro work with the
Snapmaker U1 instead of the Kobra 3 V2 it was sold with?"*

The ACE Pro communicates over USB serial using a JSON-RPC protocol that has been fully
reverse-engineered by the community (`ACEResearch` → `DuckACE` → `ACEPROSV08` →
`Kobra-S1/ACEPRO`). It does not care what printer it is attached to. The `ace` Klipper
extra is the key artifact — it speaks the protocol and exposes gcode commands.

The Snapmaker U1 is a 4-toolhead tool-changer running a heavily modified Klipper fork.
It already solves multi-material printing differently from filament-switcher systems like
AMS/MMU — each toolhead has its own extruder and filament path, so "color switching" is
just a physical toolhead swap with no purging required. What it lacks is upstream filament
management: active drying, smart spool handling, and optional lane switching.

## The U1 Filament Feed System

!!! important
    This is the most important thing to understand before touching anything.

The U1 has two internal `[filament_feed]` modules (`left` and `right`), each controlling
2 channels:

- **left:** e0 (extruder) + e1 (extruder1) → T0, T1
- **right:** e2 (extruder2) + e3 (extruder3) → T2, T3

Each module has its own DC motor, wheel tachos, port sensors, and pushes filament
approximately **950mm** from the back panel entry to the extruder gears (the
`preload_length` parameter). This is Snapmaker's own internal motorized Bowden assist —
effectively a mini-AMS already built into the frame.

The `SM_PRINT_AUTO_FEED` / `AUTO_FEEDING` gcode commands drive this system. The
load/unload tip-forming sequence is compiled into Snapmaker's Klipper fork, not exposed
as editable gcode macros. This means:

- We **cannot** directly edit tip-forming parameters as gcode
- We **can** wrap `AUTO_FEEDING` calls with pre/post ACE coordination
- The U1 unloads filament clear of the extruder but **not** back to the spool

## Integration Mode Analysis

### Mode 1: Dumb Drybox (no protocol)

ACE Pro sits at the spool end, keeps filament dry at 45–55°C, feeds passively into the
U1's back panel entry. No USB connection to any Klipper instance. U1's own feed motors
handle the 950mm path as normal.

| | |
|---|---|
| **Pros** | Zero firmware risk, immediate value, works today |
| **Cons** | No lane switching, no dryer control from printer, no runout handoff |
| **Start here** | Validates Bowden routing before any firmware changes |

---

### Mode 2: Lane-per-Toolhead (1:1 mapping)

One ACE lane feeds one U1 toolhead. 4 lanes → 4 toolheads. ACE connected to ACE Klipper
instance. U1 triggers ACE retract after unload, ACE triggers U1 load on feed complete.
Dryer control from U1 side via router events.

| | |
|---|---|
| **Pros** | Clean 1:1 mapping, simple routing table, ACE handles drying |
| **Cons** | No lane switching within a toolhead (still 4 colors max, same as stock) |
| **Gain** | Active drying, endless spool potential, spool management |

---

### Mode 3: One ACE Per Feeder (dual-ACE)

The U1 has two internal feed modules: left (e0+e1 → T0+T1) and right (e2+e3 → T2+T3).
Running one ACE unit per feeder mirrors this structure exactly and halves the Bowden length
to each toolhead pair.

**Configuration:** `ace_count: 2` in a single ACE Klipper instance. The driver auto-discovers
both units by USB topology; the unit plugged into the lower-numbered root port becomes
instance 0 (left feeder). Global INDEX numbering: ACE 0 → INDEX 0–3, ACE 1 → INDEX 4–7.

**Lane mapping in `_ACE_LANE_MAP`:**

| Tool | ACE instance | Slot | Global INDEX |
|------|-------------|------|-------------|
| T0 primary | ACE 0 | 0 | 0 |
| T1 primary | ACE 0 | 2 | 2 |
| T2 primary | ACE 1 | 0 | 4 |
| T3 primary | ACE 1 | 2 | 6 |

| | |
|---|---|
| **Pros** | Shorter Bowden runs; feeder-matched fault isolation; 4 slots per toolhead pair |
| **Cons** | Hardware cost of a second ACE unit; needs two USB ports on host |
| **Gain** | Each toolhead pair can independently switch between 2 materials |

---

### Mode 4: 2+2 Split (lane switching within a toolhead)

With a single ACE: lanes 0+1 → T0, lanes 2+3 → T1 (T2/T3 single material).
With dual ACE: all 4 toolheads can each have 2 lanes — full 2+2 across the board.

Each ACE-equipped toolhead switches between 2 colors during the SnapSwap park dwell period
(~70°C standby). The slicer must plan which color each toolhead carries for a given layer
range.

Set `t*_alt_lane` values in `_ACE_LANE_MAP` to enable 2+2 for any toolhead:

```gcode
[gcode_macro _ACE_LANE_MAP]
variable_t0_lane: 0
variable_t0_alt_lane: 1   # enables 2+2 for T0
variable_t1_lane: 2
variable_t1_alt_lane: 3   # enables 2+2 for T1
```

| | |
|---|---|
| **Pros** | Doubles effective color count (up to 8 colors with dual ACE) |
| **Cons** | Lane switch must complete within park dwell window; slicer awareness required |
| **Open question** | Is park dwell time long enough for a full ACE lane switch cycle? |

---

### Mode 5: Full 4-lane on one toolhead

All 4 ACE lanes → 1 toolhead via a 4-in-1 passive splitter. Other 3 toolheads unchanged.
Maximum color count on one head, but requires splitter hardware and significantly more
complex tip-forming tuning.

!!! warning "Not recommended"
    The U1's integrated-nozzle design (heat sink + heat break + block + nozzle as one unit,
    no individual replacement) makes hotend modifications risky.

## The Two-Klipper Architecture

### Why not run ace.py on the U1 Klipper directly?

The U1 runs Snapmaker's proprietary Klipper fork with custom modules (`filament_feed`,
`park_detector`, `filament_entangle_detect`, `inductance_coil`, `fm175xx_reader`, etc.)
that don't exist in vanilla Klipper. Adding `ace.py` as an extra *might* work, but:

1. Snapmaker OTA updates would need to preserve the extra
2. If `ace.py` crashes, it takes the main printer process with it
3. The ACE USB reconnect issue (known in the driver) is especially bad if it can crash a live print
4. It complicates the codebase unnecessarily

Running a second minimal Klipper instance (vanilla) just for the ACE keeps failure domains
isolated. If the ACE instance crashes, the U1 keeps printing.

### The ACE Klipper instance

Minimal config needed:

- `[mcu]` using the host Linux process (no physical MCU board — ACE talks USB serial internally)
- `[ace]` section from `ace_instance.cfg` with distance calibration
- `[filament_switch_sensor]` sections (required by driver even without physical sensors)
- `[include router_api.cfg]` from `upstream/klipper-router/includes/`
- `[include ace_events.cfg]` from `macros/`

Can run on the same SBC as the U1 — just a second `klippy.py` process on a different
Unix socket path. The U1 uses an RK3568 SoC which has sufficient headroom.

### Klipper Router role

The router (`klipper_router.py`) connects to both Unix sockets and registers `router/*`
remote methods on each. This lets either instance call the other's gcode macros asynchronously.

Key router features used:

| Feature | Use |
|---------|-----|
| `router/event/trigger` + `router/event/subscribe` | Async load/unload handoff signals |
| `router/objects/subscribe` | U1 watches ACE slot status and drying state |
| `ROUTER_ON_CONNECTED` / `ROUTER_ON_DISCONNECTED` | Fallback mode handling |
| Auto-reconnect | Handles ACE USB instability without printer impact |

## Handoff Distance Constants

These must be measured after physical installation and vary by ACE placement.

```ini
# In config/klipper-ace/ace_instance.cfg:
parkposition_to_toolhead_length: ???    # ACE park pos → U1 extruder gears
parkposition_to_rdm_length: 0          # no RDM sensor in U1 path
total_max_feeding_length: 3000         # ACE park → nozzle tip (safe default)
```

The U1 `preload_length` (back panel → extruder gears) is ~950mm. Total path =
Bowden tube length (ACE → back panel) + 950mm.

## AFC Integration

The U1 config already has an AFC (Automated Filament Changer) framework in `afc.cfg` —
it maps E0–E3 lanes with toolhead sensors. The ACE bridge macros should eventually
integrate with AFC lane state so that Mainsail/Fluidd can display which ACE slot is
loaded in which lane.

## Open Questions

- [ ] What is the park dwell window for a SnapSwap cycle? Is it long enough for a full ACE lane switch (retract + switch + feed)?
- [ ] Where exactly does `AUTO_FEEDING UNLOAD=1` leave the filament tip? (In the Bowden tube? At the back panel entry? Needs physical test.)
- [ ] Can the ACE Klipper instance run on the U1's embedded SBC, or does it need a separate host? (U1 uses RK3568 SoC — likely enough headroom.)
- [ ] Does the U1's 6mm OD / 4.6mm ID Bowden tube accept standard ACE output connectors, or does an adapter fitting need to be printed/sourced?
- [ ] For 2+2 mode: does the lane switch need a dedicated 2-in-1 passive splitter at the toolhead entry, or can the ACE output directly?
- [ ] Endless spool: the ACEPRO driver lists this as TODO — is it far enough along to be useful, or should that be a separate contribution?

## Related Projects

| Project | Relevance |
|---------|-----------|
| [Kobra-S1/ACEPRO](https://github.com/Kobra-S1/ACEPRO) | The ace driver we're using. S1-specific macros replaced with U1 equivalents |
| [ANYCUBIC-3D/klipper-go](https://github.com/ANYCUBIC-3D/klipper-go) | Anycubic's own Golang Klipper port — useful for ACE protocol internals |
| [printers-for-people/ACEResearch](https://github.com/printers-for-people/ACEResearch) | Original protocol reverse engineering |
| [utkabobr/DuckACE](https://github.com/utkabobr/DuckACE) | Base driver implementation upstream of ACEPRO |
| [jbatonnet/Rinkhals](https://github.com/jbatonnet/Rinkhals) | Community CFW for Kobra 3 V2 — reference for Klipper + ACE on source hardware |
| [BlackFrogKok/BunnyACE](https://github.com/BlackFrogKok/BunnyACE) | Another ACE protocol implementation |
