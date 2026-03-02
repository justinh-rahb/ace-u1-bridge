# ace-u1-bridge

Integrates the **Anycubic ACE Pro** multi-material unit with the **Snapmaker U1**
four-toolhead 3D printer using Klipper Router as a JSON-RPC bridge between two
independent Klipper instances.

## What This Is

The Snapmaker U1 already handles 4-material printing via its SnapSwap™ toolhead
system — each toolhead has its own dedicated extruder, filament path, and motorized
feed module. What it lacks is a smart upstream filament manager: active drying, lane
switching, and spool-end control.

The Anycubic ACE Pro fills that gap. It sits upstream of the U1's back-panel filament
entry points, keeps spools dry at up to 55°C while printing, and can switch between
lanes via a known serial protocol.

This project bridges the two systems so they cooperate:

- **U1 Klipper** owns the print — SnapSwap, extruders, bed, motion, all toolhead operations
- **ACE Klipper** owns the filament — drying, lane selection, feed/retract from spool to U1 entry point
- **Klipper Router** is the coordination layer — JSON-RPC bridge over Unix sockets

## Hardware Architecture

```
┌─────────────────────────────────────────────────────┐
│                 Anycubic ACE Pro                     │
│  [Slot 0] [Slot 1] [Slot 2] [Slot 3]                │
│   Dry @ 55°C  ·  RFID detect  ·  USB serial         │
└────────┬────────────┬───────────────────────────────┘
         │            │          (Bowden tubes)
         ▼            ▼
┌────────────────────────────────────────────────────┐
│              Snapmaker U1 Back Panel                │
│   Left feed module        Right feed module         │
│   (e0 + e1)               (e2 + e3)                 │
│   preload: ~950mm         preload: ~950mm            │
└──────┬──────┬──────────────┬──────┬────────────────┘
       │      │              │      │
       ▼      ▼              ▼      ▼
      [T0]  [T1]           [T2]  [T3]
   SnapSwap dock positions (Y=332.2mm)
```

### Deployment Modes

| Mode | ACE units | Description | Protocol |
|------|-----------|-------------|----------|
| **Dumb drybox** | 1 | ACE feeds passively into U1 entry points | No |
| **Lane-per-toolhead** | 1 | 1 ACE lane per toolhead, coordinated load/unload | Yes |
| **Per-feeder** | 2 | One ACE per feeder side (left: T0+T1 / right: T2+T3) | Yes |
| **2+2 split** | 1 or 2 | 2 ACE lanes per toolhead, switch during park dwell | Yes |

!!! tip "Start here"
    Begin with **dumb drybox** to validate physical Bowden routing before touching
    any firmware. The ACE will dry your filament passively even with no protocol
    integration. See [Commissioning](COMMISSIONING.md) for the full sequence.

## Software Architecture

```
┌─────────────────────┐     Unix socket      ┌─────────────────────┐
│   Klipper (u1)      │◄────────────────────►│  Klipper Router     │
│                     │                       │  klipper_router.py  │
│  - 4x extruders     │     Unix socket       │                     │
│  - SnapSwap macros  │◄────────────────────►│  JSON-RPC bridge    │
│  - filament_feed    │                       │                     │
│  - AFC lanes        │                       └──────────┬──────────┘
│  - router_api.cfg   │                                  │ Unix socket
└─────────────────────┘                       ┌──────────▼──────────┘
                                              │   Klipper (ace)     │
                                              │                     │
                                              │  - ace extra        │
                                              │  - dryer control    │
                                              │  - router_api.cfg   │
                                              └─────────────────────┘
```

### Key Design Decisions

**Why two Klipper instances?**
The U1 runs Snapmaker's proprietary Klipper fork with custom modules (`filament_feed`,
`park_detector`, etc.). Running `ace.py` as an extra on the U1 risks crashes affecting
live prints and breaks with OTA updates. A separate minimal Klipper process keeps failure
domains isolated — if the ACE instance crashes, the U1 keeps printing.

**Why Klipper Router?**
[Klipper Router](https://github.com/justinh-rahb/klipper-router) is a small async Python
bridge that connects multiple Klipper instances over Unix sockets. It handles reconnection,
ready-state tracking, and async event delivery via `router/event/trigger` —
exactly what's needed for the load/unload handoff.

**The handoff boundary**
`AUTO_FEEDING UNLOAD=1` retracts filament clear of the U1 extruder but not all the way
back to the spool. The ACE handles everything from that point. The coordination distance
is calibrated via `parkposition_to_toolhead_length` in `ace_instance.cfg`.

## Event Protocol

Events flow through Klipper Router using `ROUTER_EVENT_TRIGGER` / `ROUTER_EVENT_SUBSCRIBE`.
Both instances register handlers at startup via `ROUTER_ON_READY`.

=== "Unload (U1 → ACE)"

    ```gcode
    AUTO_FEEDING EXTRUDER=n UNLOAD=1       # retracts to extruder exit
    ROUTER_EVENT_TRIGGER EVENT=ace_retract CONTEXT={lane:n,length:xxx}
    # ACE: ACE_RETRACT INDEX=n LENGTH=xxx
    # ACE: ROUTER_EVENT_TRIGGER EVENT=ace_retract_done CONTEXT={lane:n}
    ```

=== "Load (ACE → U1)"

    ```gcode
    ROUTER_EVENT_TRIGGER EVENT=ace_feed CONTEXT={lane:n,length:xxx}
    # ACE: ACE_FEED INDEX=n LENGTH=xxx
    # ACE: ROUTER_EVENT_TRIGGER EVENT=ace_feed_done CONTEXT={lane:n}
    AUTO_FEEDING EXTRUDER=n LOAD=1         # pulls remaining path to nozzle
    ```

=== "Dryer control (U1 → ACE)"

    ```gcode
    ROUTER_EVENT_TRIGGER EVENT=ace_dry_start CONTEXT={temp:45,duration:240}
    # ACE: ACE_START_DRYING TEMP=45 DURATION=240
    ```

!!! note "Disconnect fallback"
    When the ACE instance goes offline, `ROUTER_ON_DISCONNECTED` fires on the U1.
    The U1 falls back to dumb-drybox mode — filament stays in the Bowden, the U1
    feeds normally, ACE drying stops.

## Filament Path Reference

| Segment | Length | Notes |
|---------|--------|-------|
| ACE output → U1 back panel | TBD | Depends on ACE placement |
| U1 back panel → extruder | ~950mm | U1 internal `preload_length` |
| Total ACE → nozzle | ~950mm + offset | Measure after placement |

`total_max_feeding_length` must be ≥ total path length. The default 3000mm is
generous for most placements.

## Quick Start

```bash
# Clone with submodules
git clone --recurse-submodules https://github.com/justinh-rahb/ace-u1-bridge.git
cd ace-u1-bridge

# Symlink ACE extras into Klipper
./scripts/install.sh

# Verify ACE Pro is detected on USB
python3 -m serial.tools.list_ports --verbose | grep -i ace

# Start the ACE Klipper instance
~/klippy-env/bin/python ~/klipper/klippy.py \
  config/klipper-ace/printer.cfg \
  -a /tmp/klippy_ace_uds \
  -l /tmp/klippy_ace.log

# Start the router
python3 upstream/klipper-router/src/klipper_router.py \
  -c config/klipper-router/router.cfg

# Validate everything is connected
./scripts/test_connection.sh
```

See [Commissioning](COMMISSIONING.md) for the full phase-by-phase bring-up sequence.

## Upstream Dependencies

| Repo | Role |
|------|------|
| [justinh-rahb/klipper-router](https://github.com/justinh-rahb/klipper-router) | JSON-RPC bridge daemon |
| [Kobra-S1/ACEPRO](https://github.com/Kobra-S1/ACEPRO) | ACE Pro Klipper driver |
| [ANYCUBIC-3D/klipper-go](https://github.com/ANYCUBIC-3D/klipper-go) | Reference: ACE protocol internals |
| [jbatonnet/Rinkhals](https://github.com/jbatonnet/Rinkhals) | Reference: community CFW for Kobra 3 V2 |

---

[![Buy Me A Coffee](https://www.buymeacoffee.com/assets/img/custom_images/orange_img.png)](https://www.buymeacoffee.com/wildtang3nt)

Licensed under the [GNU General Public License v3.0](https://github.com/justinh-rahb/ace-u1-bridge/blob/main/LICENSE).
