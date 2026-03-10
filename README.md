# ace-u1-bridge

Integrates the Anycubic ACE Pro multi-material unit with the Snapmaker U1
four-toolhead 3D printer using Klipper Router as a JSON-RPC bridge between
two independent Klipper instances.

## What This Is

The Snapmaker U1 already handles 4-material printing via its SnapSwap™
toolhead system — each toolhead has its own dedicated extruder, filament path,
and motorized feed module. What it lacks is a smart upstream filament manager:
active drying, lane switching, and spool-end control.

The Anycubic ACE Pro fills that gap. It sits upstream of the U1's back-panel
filament entry points, keeps spools dry at up to 55°C while printing, and can
switch between lanes via a known serial protocol.

This project bridges the two systems so they cooperate:

- **U1 Klipper** owns the print — SnapSwap, extruders, bed, motion, all
  toolhead operations
- **ACE Klipper** owns the filament — drying, lane selection, feed/retract
  from spool to U1 entry point
- **Klipper Router** is the coordination layer — JSON-RPC bridge over Unix
  sockets, routes gcode events between the two instances

## Hardware Architecture

```
┌─────────────────────────────────────────────────────┐
│                 Anycubic ACE Pro                    │
│  [Slot 0] [Slot 1] [Slot 2] [Slot 3]                │
│   Dry @ 55°C  ·  RFID detect  ·  USB serial         │
└────────┬────────────┬───────────────────────────────┘
         │            │          (650mm Bowden each)
         ▼            ▼
┌─────────────────────────────────────────────────────┐
│              Snapmaker U1 Back Panel                │
│   Left feed module        Right feed module         │
│   (e0 + e1)               (e2 + e3)                 │
│   preload: ~950mm         preload: ~950mm           │
└──────┬──────┬──────────────┬──────┬─────────────────┘
       │      │              │      │
       ▼      ▼              ▼      ▼
      [T0]  [T1]           [T2]  [T3]
   SnapSwap dock positions (Y=332.2mm)
```

### Deployment Options

Integration modes, in order of increasing complexity:

| Mode | ACE units | Description | ACE protocol |
|------|-----------|-------------|-------------|
| **Dumb drybox** | 1 | ACE feeds passively into U1 entry points, no protocol | No |
| **Lane-per-toolhead** | 1 | 1 ACE lane per toolhead, coordinated load/unload | Yes |
| **Per-feeder** | 2 | One ACE per U1 feeder side (left: T0+T1 / right: T2+T3) | Yes |
| **2+2 split** | 1 or 2 | 2 ACE lanes per toolhead, lane switch during park dwell | Yes |

The U1 has two internal feed modules — left (T0+T1) and right (T2+T3). The
per-feeder mode matches this structure directly and enables each toolhead pair
to have its own dedicated ACE with 4 lanes to share.

Start with dumb drybox to validate Bowden routing and path lengths, then layer
in protocol integration. See [DESIGN.md](DESIGN.md) for full mode analysis.

## Software Architecture

```
┌─────────────────────┐     Unix socket      ┌─────────────────────┐
│   Klipper (u1)      │◄────────────────────►│  Klipper Router     │
│                     │                      │  klipper_router.py  │
│  - 4x extruders     │     Unix socket      │                     │
│  - SnapSwap macros  │◄────────────────────►│  JSON-RPC bridge    │
│  - filament_feed    │                      │                     │
│  - AFC lanes        │                      └──────────┬──────────┘
│  - router_api.cfg   │                                 │ Unix socket
└─────────────────────┘                      ┌──────────▼──────────┐
                                             │   Klipper (ace)     │
                                             │                     │
                                             │  - ace.py extra     │
                                             │  - filament sensors │
                                             │  - dryer control    │
                                             │  - router_api.cfg   │
                                             └─────────────────────┘
```

### Key Design Decisions

**Why two Klipper instances?**
The U1 runs a heavily modified Klipper fork (Snapmaker's own build). The ACE
Pro driver (`ace.py`) speaks serial JSON-RPC to the ACE hardware. Running it
in a separate Klipper process keeps the U1 firmware untouched and lets the ACE
instance run from a derived copy of the stock Klipper tree.

**Why Klipper Router?**
Klipper Router (see `upstream/klipper-router`) is a small async Python bridge
that connects multiple Klipper instances over their Unix sockets and lets them
call each other's gcode macros via `router/event/trigger` and
`router/gcode/script`. It handles reconnection, ready-state tracking, and
async event delivery — exactly what's needed for the load/unload handoff.

**The handoff boundary**
The U1's `AUTO_FEEDING UNLOAD=1` retracts filament clear of the extruder but
not all the way back to the spool. The ACE Pro handles everything from that
point back to the unit. The coordination point is somewhere in the 650mm
Bowden tube between the U1 back panel and the ACE output — calibrated via
`parkposition_to_toolhead_length` in `ace.cfg`.

## Filament Path & Distance Reference

| Segment | Length | Notes |
|---------|--------|-------|
| ACE output → U1 back panel | TBD | Depends on ACE placement |
| U1 back panel → extruder | ~950mm | U1 `preload_length` |
| Total ACE → nozzle | ~950mm + offset | Measure after placement |

The ACE `ace.cfg` parameter `total_max_feeding_length` must be >= total path
length. Default in the upstream driver is 3000mm — well within range.

## Load/Unload Event Protocol

Events flow through Klipper Router using `ROUTER_EVENT_TRIGGER` /
`ROUTER_EVENT_SUBSCRIBE`. The U1 instance and ACE instance register handlers
at startup via `ROUTER_ON_READY`.

### Unload sequence (U1 → ACE)

```
U1:  AUTO_FEEDING EXTRUDER=n UNLOAD=1       # retracts to extruder exit
U1:  ROUTER_EVENT_TRIGGER EVENT=ace_retract CONTEXT={lane:n,length:xxx}
ACE: ACE_RETRACT INDEX=n LENGTH=xxx         # retracts rest of way to unit
ACE: ROUTER_EVENT_TRIGGER EVENT=ace_retract_done CONTEXT={lane:n}
U1:  [continues with SnapSwap or next operation]
```

### Load sequence (ACE → U1)

```
U1:  ROUTER_EVENT_TRIGGER EVENT=ace_feed CONTEXT={lane:n,length:xxx}
ACE: ACE_FEED INDEX=n LENGTH=xxx            # pushes to U1 entry point
ACE: ROUTER_EVENT_TRIGGER EVENT=ace_feed_done CONTEXT={lane:n}
U1:  AUTO_FEEDING EXTRUDER=n LOAD=1         # pulls remaining path to nozzle
```

### Dryer control (U1 → ACE)

```
U1:  ROUTER_EVENT_TRIGGER EVENT=ace_dry_start CONTEXT={temp:45,duration:240}
ACE: ACE_START_DRYING TEMP=45 DURATION=240
```

### ACE disconnect fallback

When the ACE Klipper instance goes offline, `ROUTER_ON_DISCONNECTED` fires on
the U1 instance. The U1 should fall back gracefully to dumb-drybox mode —
filament is still physically present in the Bowden, U1 feeds normally, ACE
drying just stops.

## Repository Structure

```
ace-u1-bridge/
├── README.md                   # this file
├── DESIGN.md                   # detailed design notes & open questions
├── config/
│   ├── klipper-ace/
│   │   ├── printer.cfg         # minimal Klipper config for ACE host
│   │   └── ace_instance.cfg    # ace.py config + sensor definitions
│   └── klipper-router/
│       └── router.cfg          # router config: u1 + ace sockets
├── macros/
│   ├── ace_bridge.cfg          # U1-side event handlers & handoff macros
│   └── ace_events.cfg          # ACE-side event handlers
├── scripts/
│   ├── install.sh              # symlink ACE extras, install services
│   └── test_connection.sh      # validate connectivity between instances
├── systemd/
│   ├── klipper-ace.service     # ACE Klipper instance service template
│   └── klipper-router.service  # router daemon service template
├── docs/
│   ├── BOWDEN_ROUTING.md       # physical routing notes, path length measurements
│   └── COMMISSIONING.md        # step-by-step bring-up guide
└── upstream/                   # git submodules (read-only)
    ├── klipper-router          # github.com/paxx12/klipper-router
    └── ACEPRO                  # github.com/Kobra-S1/ACEPRO
```

## Upstream Dependencies

| Repo | Role |
|------|------|
| [paxx12/klipper-router](https://github.com/paxx12/klipper-router) | JSON-RPC bridge daemon |
| [Kobra-S1/ACEPRO](https://github.com/Kobra-S1/ACEPRO) | ACE Pro Klipper driver (`ace.py`) |
| [ANYCUBIC-3D/klipper-go](https://github.com/ANYCUBIC-3D/klipper-go) | Reference: Anycubic's own Golang Klipper port |
| [jbatonnet/Rinkhals](https://github.com/jbatonnet/Rinkhals) | Reference: community CFW for Kobra 3 V2 |

## Quick Start

```bash
# Clone with submodules
git clone --recurse-submodules https://github.com/justinh-rahb/ace-u1-bridge.git
cd ace-u1-bridge

# Install ACE extras into Klipper
./scripts/install.sh

# Verify the ACE Pro is detected on USB (auto-discovered, no config needed)
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

For the full bring-up procedure, see [docs/COMMISSIONING.md](docs/COMMISSIONING.md).

## Getting Started

See [docs/COMMISSIONING.md](docs/COMMISSIONING.md) for the full bring-up
sequence. The recommended order is:

1. Validate dumb drybox routing (no firmware changes)
2. Run `./scripts/install.sh` to symlink ACE extras into Klipper
3. Configure `config/klipper-ace/ace_instance.cfg` with your USB serial path
4. Stand up ACE Klipper instance, verify `ace.py` communicates with hardware
5. Deploy Klipper Router, verify U1 ↔ ACE connection
6. Load `ace_bridge.cfg` on U1, `ace_events.cfg` on ACE instance
7. Test manual load/unload event flow
8. Dial in Bowden path length constants (record in [docs/BOWDEN_ROUTING.md](docs/BOWDEN_ROUTING.md))
9. Optionally install systemd services: `./scripts/install.sh --services`

---

[![Buy Me A Coffee](https://www.buymeacoffee.com/assets/img/custom_images/orange_img.png)](https://www.buymeacoffee.com/wildtang3nt)

## License

Licensed under the [GNU General Public License v3.0](LICENSE).
