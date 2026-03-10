# Agent Task: implement the ACE overlay series for Snapmaker U1

## Goal

Implement ACE Pro support as a rebased overlay series against the current
ground truth in this repo:

- ACE research and prototype configs/macros live here
- `upstream/ACEPRO` is the pinned ACE driver source
- `upstream/klipper-router` is the pinned router source
- `upstream/SnapmakerU1-Extended-Firmware` on `develop` is the platform source

The implementation target is not a generic Linux host. It is the current U1
extended-firmware substrate.

---

## Current Ground Truth

### Pinned upstreams in this repo

- `upstream/ACEPRO` at `55ec2f7`
- `upstream/klipper-router` at `c350612`
- `upstream/SnapmakerU1-Extended-Firmware` at `f418d8f` on `develop`

### U1 platform facts already verified

From `upstream/SnapmakerU1-Extended-Firmware`:

- overlays live under `overlays/firmware-extended/NN-name/`
- extended config defaults are seeded from:
  - `/usr/local/share/firmware-config/extended/`
- persistent extended config lives under:
  - `/home/lava/printer_data/config/extended/`
- the main persistent config file is:
  - `/home/lava/printer_data/config/extended/extended2.cfg`
- firmware-config YAMLs live under:
  - `/usr/local/share/firmware-config/functions/`
- extended Klipper configs are auto-included from:
  - `extended/klipper/*.cfg`
- the default-materialization service is:
  - `overlays/firmware-extended/10-firmware-config/root/etc/init.d/S49extended-config`
- U1 init scripts use BusyBox `sh` and `start-stop-daemon`
- current dev tooling starts Klipper with:
  - `/usr/bin/python3 /home/lava/klipper/klippy/klippy.py ...`

### ACE facts already verified

From this repo and `upstream/ACEPRO`:

- the ACE driver is a package at `extras/ace/`, not `extras/ace.py`
- `extras/virtual_pins.py` is also required
- current prototype config uses:
  - `filament_runout_sensor_name_nozzle`
  - optional `filament_runout_sensor_name_rdm`
  - `parkposition_to_rdm_length`
  - `toolchange_load_length`
  - `feed_assist_active_after_ace_connect`
- current prototype event flow uses:
  - `ace_retract`
  - `ace_retract_done`
  - `ace_feed`
  - `ace_feed_done`
  - `ace_dry_start`
  - `ace_dry_stop`
  - `ace_runout`
- current prototype assumes a second Klipper instance with:
  - `kinematics: none`
  - host/process MCU via `/tmp/klipper_host_mcu`

### Important drift fact

`upstream/SnapmakerU1-Extended-Firmware` `develop` does not currently contain
`25-u1-router-led-events`.

PR 255 is therefore a roadmap only. It is useful as a pattern for router
integration, but it is not merged branch truth.

---

## Implementation Strategy

Implement this as two overlays:

1. `25-u1-router-core`
2. `26-u1-ace-instance`

Do not rebase the LED-specific parts of PR 255 into the ACE work. Bring
forward only the router substrate needed for ACE.

Reason:

- current `develop` has no router substrate at all
- ACE needs router services and a second-instance orchestrator first
- LED status events are unrelated to the ACE MVP

---

## Overlay 25: `25-u1-router-core`

### Purpose

Introduce the minimal router substrate required for any auxiliary Klipper
instance on the U1.

This overlay should be ACE-agnostic. It should not mention LEDs.

### Files to add

```text
overlays/firmware-extended/25-u1-router-core/
├── README.md
├── scripts/
│   └── 01-install-klipper-router.sh
└── root/
    ├── etc/init.d/
    │   ├── S98klipper-router-instances
    │   └── S99klipper-router
    └── usr/local/share/firmware-config/
        ├── extended/
        │   ├── klipper/
        │   │   └── 15_router_api.cfg
        │   └── router/
        │       └── klipper_router.cfg
        └── functions/
            └── 25_settings_router.yaml
```

### `scripts/01-install-klipper-router.sh`

Requirements:

- follow the build-script pattern already used by current extended overlays
- require `CREATE_FIRMWARE`
- use `cache_git.sh`
- clone from `https://github.com/justinh-rahb/klipper-router.git`
- pin to `c350612`
- install:
  - `/usr/local/sbin/klipper-routerd`
- also install reference router macros to:
  - `/usr/local/share/firmware-config/router/includes/router_api.cfg`

### `root/etc/init.d/S99klipper-router`

Base it on PR 255, but re-add it cleanly against current `develop`.

Requirements:

- gate startup on `[router] enabled` in `extended2.cfg`
- runtime config path:
  - `/home/lava/printer_data/config/extended/router/klipper_router.cfg`
- generated runtime config path:
  - `/home/lava/printer_data/config/extended/router/klipper_router.runtime.cfg`
- instance directory:
  - `/home/lava/printer_data/config/extended/router/instances`
- PID file:
  - `/var/run/klipper-router.pid`
- log file:
  - `/home/lava/printer_data/logs/klipper-router.log`
- run as `lava`
- start with:
  - `/usr/bin/python3 -- /usr/local/sbin/klipper-routerd -c <runtime_cfg>`
- append missing `[klippy <name>]` blocks for discovered instances

Default base config should only include `main`, not `led`.

### `root/etc/init.d/S98klipper-router-instances`

This is the key ACE prerequisite.

Base it on PR 255, but add two capabilities from the start:

1. per-instance `klippy_path` override
2. per-instance enable gating

Requirements:

- global gate:
  - do nothing unless `[router] enabled` is `true`
- default Klippy path:
  - `/home/lava/klipper/klippy/klippy.py`
- per-instance config path:
  - `/home/lava/printer_data/config/extended/router/instances/<name>/printer.cfg`
- per-instance socket path:
  - `/home/lava/printer_data/comms/klippy-router-<name>.sock`
- per-instance serial path:
  - `/home/lava/printer_data/comms/klippy-router-<name>.serial`
- per-instance log path:
  - `/home/lava/printer_data/logs/klippy-router-<name>.log`
- per-instance pid path:
  - `/var/run/klippy-router-<name>.pid`
- start via:
  - `/usr/bin/python3 -- "$KLIPPY" "$cfg" -I "$serial" -a "$sock" -l "$log" -u lava`
- validate pidfiles by checking `/proc/<pid>/cmdline` contains:
  - the expected klippy path
  - the expected config path
  - the expected socket path

#### Per-instance `klippy_path`

If this file exists:

```text
/home/lava/printer_data/config/extended/router/instances/<name>/klippy_path
```

use its content as the Klippy executable path for that instance.

This allows ACE to select a separate derived runtime instead of the stock
instance managed by `/home/lava/klipper/klippy/klippy.py`.

#### Per-instance enable gating

If this file exists:

```text
/home/lava/printer_data/config/extended/router/instances/<name>/enabled_config
```

its content must be interpreted as:

```text
<section> <key> <default>
```

Example for ACE:

```text
ace enabled false
```

The instance manager should then evaluate:

```sh
/usr/local/bin/extended-config.py get "$EXTENDED_CFG" <section> <key> <default>
```

and only start the instance when the result is `true`.

If `enabled_config` is missing, default to enabled.

### `root/usr/local/share/firmware-config/extended/router/klipper_router.cfg`

Ship a minimal default router config:

```ini
[klippy main]
sock: /home/lava/printer_data/comms/klippy.sock
on_connect: M118 Router connected to main
```

Do not bake ACE or LED blocks into this base config. Let `S99klipper-router`
append discovered instances dynamically.

### `root/usr/local/share/firmware-config/extended/klipper/15_router_api.cfg`

Install the extended router macro API into the main persistent Klipper include
set so it is auto-included by the existing `extended/klipper/*.cfg` mechanism.

This file should be based on the PR 255 macro layer, not the bare upstream
include, because the main instance needs easy G-code wrappers such as:

- `ROUTER_GCODE_SCRIPT`
- `ROUTER_EVENT_SUBSCRIBE`
- `ROUTER_EVENT_TRIGGER`
- `ROUTER_OBJECTS_LIST`
- `ROUTER_OBJECTS_QUERY`
- `ROUTER_OBJECTS_SUBSCRIBE`
- `ROUTER_ON_READY`
- `ROUTER_ON_CONNECTED`
- `ROUTER_ON_DISCONNECTED`

No LED-specific reconnect hook belongs here in the ACE plan.

### `root/usr/local/share/firmware-config/functions/25_settings_router.yaml`

Add firmware-config status and enable/disable control for router mode.

Requirements:

- status:
  - router service running/stopped
  - count of `klippy-router-*.pid`
  - router log path
- setting:
  - `[router] enabled: true|false`
- enable action:
  - write `[router] enabled true`
  - restart `S98klipper-router-instances`
  - restart `S99klipper-router`
- disable action:
  - write `[router] enabled false`
  - stop `S99klipper-router`
  - stop `S98klipper-router-instances`

### Non-goals for Overlay 25

- no LED instance
- no LED event subscriptions
- no runtime migration script for LED reconnect hooks

---

## Overlay 26: `26-u1-ace-instance`

### Purpose

Add the ACE-specific second Klipper instance and bridge macros on top of the
router substrate from Overlay 25.

### Dependencies

- `25-u1-router-core`
- existing extended-firmware include mechanism already present on `develop`

### Files to add

```text
overlays/firmware-extended/26-u1-ace-instance/
├── README.md
├── scripts/
│   └── 01-install-ace-klipper-payload.sh
└── root/
    └── usr/local/share/firmware-config/
        ├── extended/
        │   ├── klipper/
        │   │   └── 16_router_ace_bridge.cfg
        │   └── router/
        │       └── instances/
        │           └── ace/
        │               ├── enabled_config
        │               ├── klippy_path
        │               ├── printer.cfg
        │               └── klipper/
        │                   ├── 10_ace_instance.cfg
        │                   └── 20_ace_events.cfg
        └── functions/
            └── 26_settings_ace.yaml
```

### `scripts/01-install-ace-klipper-payload.sh`

Requirements:

- require `CREATE_FIRMWARE`
- use `cache_git.sh`
- copy ACEPRO payload from:
  - `https://github.com/justinh-rahb/ACEPRO.git`
- pin to:
  - `55ec2f7`
- install payload to:
  - `/home/lava/klipper-ace/klippy/extras/ace/`
  - `/home/lava/klipper-ace/klippy/extras/virtual_pins.py`
- copy the stock Klipper tree from the extracted rootfs to:
  - `/home/lava/klipper-ace`
- set ownership to `lava:lava`

#### Python dependency check

The build work must explicitly verify that the Python used for Klippy on the U1
has the runtime dependencies ACEPRO needs:

- `pyserial`
- `jinja2`

`jinja2` is likely already present because Klipper uses it. `pyserial` must be
verified, not assumed.

If `pyserial` is missing from the image, add a build-time installation step in
this overlay rather than relying on runtime `pip install`.

### `root/usr/local/share/firmware-config/extended/router/instances/ace/klippy_path`

Contents:

```text
/home/lava/klipper-ace/klippy/klippy.py
```

This is consumed by the new per-instance `klippy_path` support in Overlay 25.
`/home/lava/klipper-ace` is copied from the stock `/home/lava/klipper` tree on
ACE enable and then augmented with the ACE payload.

### `root/usr/local/share/firmware-config/extended/router/instances/ace/enabled_config`

Contents:

```text
ace enabled false
```

This is consumed by the new per-instance enable gating in Overlay 25.

### `root/usr/local/share/firmware-config/extended/router/instances/ace/printer.cfg`

Base this on `config/klipper-ace/printer.cfg`, but adapt paths for U1 runtime.

Required shape:

```ini
[mcu]
serial: /tmp/klipper_host_mcu

[printer]
kinematics: none
max_velocity: 1
max_accel: 1

[respond]
[virtual_pins]

[save_variables]
filename: /home/lava/printer_data/config/extended/router/instances/ace/ace_saved_variables.cfg

[include /usr/local/share/firmware-config/router/includes/router_api.cfg]
[include klipper/*.cfg]
```

Notes:

- use the host/process MCU pattern already reflected in this repo and other
  headless Klipper test configs in the firmware repo
- keep the router API include explicit here so the ACE-side macros can override
  `ROUTER_ON_READY` / `ROUTER_ON_CONNECTED` / `ROUTER_ON_DISCONNECTED`

### `10_ace_instance.cfg`

Base this on `config/klipper-ace/ace_instance.cfg`.

Requirements:

- preserve current ACEPRO config vocabulary:
  - `filament_runout_sensor_name_nozzle`
  - optional `filament_runout_sensor_name_rdm`
  - `parkposition_to_toolhead_length`
  - `parkposition_to_rdm_length`
  - `total_max_feeding_length`
  - `toolchange_load_length`
  - `feed_assist_active_after_ace_connect`
- preserve current ACEPRO install shape:
  - `[output_pin ACE_Pro]`
  - virtual nozzle sensor wiring
- use ACE auto-discovery, not a hardcoded `serial:` path
- keep hardware-dependent distances as clearly marked TODO defaults
- disable Moonraker lane sync by default on the ACE instance

Initial ACE config should stay close to the research repo:

- `ace_count: 1`
- `feed_assist_active_after_ace_connect: True`
- `parkposition_to_toolhead_length: 1200`
- `parkposition_to_rdm_length: 0`
- `total_max_feeding_length: 3000`
- `toolchange_load_length: 2000`
- `moonraker_lane_sync_enabled: False`

Those values are starting defaults, not calibration truth.

### `20_ace_events.cfg`

Base this on `macros/ace_events.cfg`.

Keep these ACE-side event handlers in the first implementation:

- `ROUTER_ON_READY`
- `ROUTER_ON_CONNECTED`
- `ROUTER_ON_DISCONNECTED`
- `ON_ACE_RETRACT_CMD`
- `ON_ACE_FEED_CMD`
- `ON_ACE_DRY_START_CMD`
- `ON_ACE_DRY_STOP_CMD`
- `ACE_RUNOUT_NOTIFY`

The ACE-side handlers should continue to call real ACEPRO commands:

- `ACE_FEED`
- `ACE_RETRACT`
- `ACE_START_DRYING`
- `ACE_STOP_DRYING`

### `16_router_ace_bridge.cfg`

Base this on `macros/ace_bridge.cfg`, but keep scope disciplined.

For the initial overlay series, this file should provide:

- ACE bridge state macro
- event subscriptions for:
  - `ace_retract_done`
  - `ace_feed_done`
  - `ace_runout`
- manual/testable bridge commands:
  - `ACE_BRIDGE_RETRACT`
  - `ACE_BRIDGE_FEED`
  - `ACE_BRIDGE_DRY_START`
  - `ACE_BRIDGE_DRY_STOP`
  - `ACE_BRIDGE_LOAD_LANE`
  - `ACE_BRIDGE_UNLOAD_LANE`
  - `_ACE_LANE_MAP`
  - `ACE_BRIDGE_LOAD_TOOL`
  - `ACE_BRIDGE_UNLOAD_TOOL`

Keep the researched handoff:

1. main instance tells ACE to feed/retract over router events
2. ACE instance performs `ACE_FEED` / `ACE_RETRACT`
3. ACE instance returns `ace_feed_done` / `ace_retract_done`
4. main instance finishes the last leg with `AUTO_FEEDING`

#### Initial non-goal

Do not auto-patch unknown proprietary U1 toolchange macros in this first ACE
overlay series.

Deliver the bridge layer as explicit macros first. Auto-hooking into the
proprietary Snapmaker toolchange/unload flow should be a follow-up once the
exact on-device macro names and call order are verified.

### `26_settings_ace.yaml`

Add firmware-config visibility and enable/disable control for ACE mode.

Requirements:

- status:
  - ACE instance pid status via `/var/run/klippy-router-ace.pid`
  - ACE log path via `/home/lava/printer_data/logs/klippy-router-ace.log`
  - ACE socket presence via `/home/lava/printer_data/comms/klippy-router-ace.sock`
  - ACE runtime presence via `/home/lava/klipper-ace/klippy/klippy.py`
- setting:
  - `[ace] enabled: true|false`
- enable action:
  - write `[ace] enabled true`
  - ensure `[router] enabled true`
  - restart `S98klipper-router-instances`
  - restart `S99klipper-router`
  - restart `S60klipper`
- disable action:
  - write `[ace] enabled false`
  - restart `S98klipper-router-instances`
  - restart `S99klipper-router`
  - restart `S60klipper`

### README

Document:

- dependency on Overlay 25
- installed paths
- ACE enable flow
- current manual bridge macros
- calibration TODOs
- explicit statement that auto-hooking U1 proprietary toolchange flow is not in
  the first cut unless separately verified during implementation

---

## Explicit Non-Goals for the First Implementation

Do not claim or implement these in the initial ACE overlay series unless they
are verified during development:

- full automatic integration with proprietary Snapmaker toolchange macros
- lane switching during park dwell as a completed production feature
- dual-ACE production support beyond config-level groundwork
- Moonraker-backed ACE UI on the auxiliary instance
- direct integration into the proprietary `/home/lava/klipper` tree

---

## Commit Plan

Make this work as a small series, not one large commit.

Recommended commit structure:

1. `[done] chore: rebase upstreams and align ace overlay tasking`
   - `.gitmodules`
   - submodule updates
   - `task.md`

2. `[done] feat: add u1 router core overlay substrate`
   - Overlay 25 files

3. `[done] feat: add ace instance overlay scaffold`
   - Overlay 26 install/config files

4. `[done] feat: add u1 ace bridge macros and settings`
   - main-side bridge macros
   - ACE firmware-config YAML

5. `[done] docs: document u1 ace overlay series`
   - overlay READMEs

## Progress Log

- 2026-03-06: Commit 1 landed in the superproject.
- 2026-03-06: Commit 2 landed in the firmware submodule and was recorded in the superproject.
- 2026-03-06: Overlay `26-u1-ace-instance` scaffold added in the firmware submodule.
- 2026-03-06: Firmware submodule commit `321cbb4` landed with:
  - ACE payload install script
  - ACEPRO payload install wiring
  - seeded ACE router instance files
  - main-side ACE bridge include
  - ACE firmware-config settings
  - overlay README
- 2026-03-06: Validation completed:
  - router target naming checked against seeded router config: base instance name is `main`
  - `26-u1-ace-instance/scripts/01-install-ace-klipper-payload.sh` passes `bash -n`
  - `26_settings_ace.yaml` parses successfully via Ruby YAML
- 2026-03-07: Build failure root cause identified:
  - `ACEPRO_GIT_SHA` in `01-install-ace-klipper-payload.sh` was pinned to a non-existent commit
  - corrected to local/upstream pinned ACEPRO commit `55ec2f783410aadacb0776cf9649cad7694455cf`
- 2026-03-07: Dependency verification adjusted:
  - retained explicit `jinja2` and `pyserial` verification per task requirements
  - widened the module search to the full extracted rootfs because limiting it to `usr/lib` and `usr/local/lib` can miss the existing Klipper runtime environment
- 2026-03-07: Follow-up on dependency verification:
  - broadened module path matching beyond `site-packages` and `dist-packages`
  - reason: embedded Python installs may place `jinja2` and `serial` directly under `pythonX.Y/`
- 2026-03-07: Live-printer inspection results:
  - `/usr/bin/python3` imports both `jinja2` and `serial` successfully on-device
  - modules resolve to `/usr/lib/python3.11/site-packages/.../__init__.pyc`
  - verifier updated to accept `__init__.pyc` as well as `__init__.py`
- 2026-03-09: Deployment model changed:
  - dropped the separate fetched Klipper tree entirely
  - ACE now runs from `/home/lava/klipper-ace`, copied from the on-device `/home/lava/klipper`
  - build now prepares `/home/lava/klipper-ace` in the firmware image
  - enable flow only toggles config and restarts services
- 2026-03-09: ACE toggle hardening:
  - seeded `[ace] enabled: false` in the shipped default `extended2.cfg`
  - changed ACE firmware-config restart order to restart `S60klipper` before `S98` and `S99`
- 2026-03-10: Firmware-config root cause identified:
  - ACE and router toggles both used the same item id `enabled`
  - `firmware-config.py` resolves settings by id globally, so the ACE toggle could execute the router command
  - fixed by giving the toggles unique ids: `ace_enabled` and `router_enabled`
- 2026-03-10: ACE runtime config compatibility:
  - stock U1-derived Klipper requires `max_logical_extruder_num` in `[printer]`
  - ACE instance `printer.cfg` now sets `max_logical_extruder_num: 32` to match existing firmware test configs
- 2026-03-06: Next commit target:
  - run build-level validation when the firmware build environment is available

---

## Acceptance Criteria

This task is complete when all of the following are true:

- Overlay 25 exists and provides a generic router substrate on current
  `upstream/SnapmakerU1-Extended-Firmware` `develop`
- Overlay 25 supports both:
  - per-instance `klippy_path`
  - per-instance `enabled_config`
- Overlay 26 installs the ACEPRO package layout actually used by
  `upstream/ACEPRO`
- Overlay 26 derives an ACE runtime from the on-device `/home/lava/klipper`
  tree without modifying the stock tree in place
- Overlay 26 seeds an ACE instance under the persistent router-instance layout
- main-side bridge macros are auto-included through the existing extended
  Klipper include mechanism
- ACE enable/disable is controllable through firmware-config
- no incorrect ACEPRO file names, sensor names, or config keys are introduced
- any remaining hardware-sensitive values are clearly marked as TODOs instead of
  being faked as known

---

## References

ACE research in this repo:

- `config/klipper-ace/printer.cfg`
- `config/klipper-ace/ace_instance.cfg`
- `config/klipper-router/router.cfg`
- `macros/ace_bridge.cfg`
- `macros/ace_events.cfg`
- `design.md`
- `docs/DESIGN.md`
- `docs/COMMISSIONING.md`

Pinned upstream sources:

- `upstream/ACEPRO`
- `upstream/klipper-router`
- `upstream/SnapmakerU1-Extended-Firmware`

Historical pattern only:

- PR 255 against `SnapmakerU1-Extended-Firmware`
