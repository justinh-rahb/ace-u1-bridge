# Commissioning Guide

Step-by-step bring-up sequence for the ace-u1-bridge integration.
Follow in order — each phase validates the next.

## Phase 1: Dumb Drybox (no firmware changes)

**Goal:** Confirm physical routing works. ACE Pro connected passively.

1. Place ACE Pro to the side or rear of the U1. Measure available space —
   the ACE is approximately 320mm wide × 170mm deep × 270mm tall.

2. Route 4x Bowden tubes from ACE outputs to U1 back panel entry points
   (one per toolhead). Use the existing 6mm OD quick-connect fittings on the
   U1 side. Confirm ACE output connectors are compatible — if not, print
   adapter couplings.

3. Load filament through ACE → U1 path for each lane. Verify:
   - Filament slides freely through full path length
   - No sharp bends that would resist ACE feed assist
   - U1's `AUTO_FEEDING LOAD=1` can pull filament from the ACE output
     position to the nozzle without the ACE motor needing to assist

4. Print a test model using all 4 toolheads. Confirm no extra friction,
   no feed failures. Measure actual Bowden path lengths and record in
   `docs/BOWDEN_ROUTING.md`.

5. If drybox mode is sufficient for your use case, stop here. The ACE will
   dry your filament passively even without firmware integration.

## Phase 2: ACE Klipper Instance

**Goal:** Stand up a second Klipper process that talks to the ACE Pro.

1. Run the install script to symlink ACE extras into Klipper:
   ```bash
   cd ~/ace-u1-bridge
   ./scripts/install.sh
   ```
   This symlinks the `ace/` package and `virtual_pins.py` from the ACEPRO
   submodule into `~/klipper/klippy/extras/`. Set `KLIPPER_DIR` env var if
   your Klipper checkout is not at `~/klipper`.

2. Find the ACE Pro USB serial path:
   ```bash
   ls /dev/serial/by-id/
   # Look for: usb-Anycubic_ACE_Pro_* or similar
   ```

3. Edit `config/klipper-ace/ace_instance.cfg` — uncomment the `serial_0:`
   line and set the correct path from step 2.

4. Ensure the host MCU is available (the ACE instance uses it as a
   placeholder since it has no physical MCU board):
   ```bash
   # If not already running:
   sudo systemctl start klipper-mcu
   ```

5. Start the ACE Klipper instance on a separate socket:
   ```bash
   ~/klippy-env/bin/python ~/klipper/klippy.py \
     ~/ace-u1-bridge/config/klipper-ace/printer.cfg \
     -a /tmp/klippy_ace_uds \
     -l /tmp/klippy_ace.log
   ```

6. Check the log for successful ACE Pro connection:
   ```
   ACE[0]:{'result': {'model': 'Anycubic Color Engine Pro', 'firmware': 'V1.3.xxx'}}
   ```

7. Test basic ACE commands via the Klipper console on the ACE instance:
   ```
   ACE_START_DRYING TEMP=45 DURATION=60
   ACE_STOP_DRYING
   ACE_FEED INDEX=0 LENGTH=100
   ACE_RETRACT INDEX=0 LENGTH=100
   ```

## Phase 3: Klipper Router

**Goal:** Connect U1 and ACE instances via the router.

1. The router is included as a submodule. No separate clone needed.
   If the U1 socket path differs from the default (`/tmp/klippy_uds`),
   edit `config/klipper-router/router.cfg` and update the `sock:` value
   under `[klippy u1]`.

2. Start the router pointing at the config:
   ```bash
   python3 ~/ace-u1-bridge/upstream/klipper-router/src/klipper_router.py \
     -c ~/ace-u1-bridge/config/klipper-router/router.cfg
   ```

3. Verify both instances connect. You should see in the U1 Klipper console:
   ```
   // Router connected to U1
   // ace_bridge: registering event handlers
   ```
   And in the ACE console:
   ```
   // Router connected to ACE instance
   // ace_events: registering event handlers
   ```

4. Test cross-instance gcode:
   From U1 console:
   ```
   ROUTER_GCODE_SCRIPT TARGET=ace SCRIPT="RESPOND MSG=hello_from_u1"
   ```
   Should appear in ACE log.

## Phase 4: Bridge Macros

**Goal:** Load the coordination macros and test the handoff.

1. Add to U1 Klipper config (in `extended/klipper/` or similar):
   ```ini
   [include /path/to/ace-u1-bridge/macros/ace_bridge.cfg]
   [include /path/to/ace-u1-bridge/upstream/klipper-router/includes/router_api.cfg]
   ```
   (router_api.cfg may already be included if you added it in Phase 3)

2. Restart U1 Klipper. Verify `_ACE_BRIDGE_STATE` variable shows
   `ace_ready: True` after router connects.

3. Test manual coordinated unload:
   ```
   ACE_BRIDGE_UNLOAD_LANE LANE=0 EXTRUDER=0 LENGTH=1200
   ```
   Watch U1 log: should show AUTO_FEEDING unload, then ACE retract.
   Watch ACE log: should show ACE_RETRACT command received and executed.

4. Test manual coordinated load:
   ```
   ACE_BRIDGE_LOAD_LANE LANE=0 EXTRUDER=0 LENGTH=1200
   ```
   Should show ACE feed, then U1 AUTO_FEEDING load completing.

## Phase 5: Distance Calibration

**Goal:** Dial in `parkposition_to_toolhead_length` and related constants.

1. With a lane loaded to the ACE park position (filament tip just inside
   the ACE output), run:
   ```
   ACE_FEED INDEX=0 LENGTH=1200
   ```
   Check where the filament tip ends up. It should reach the U1 extruder
   gears. If it falls short or overshoots, adjust `LENGTH` and record the
   correct value.

2. Update `parkposition_to_toolhead_length` in `ace_instance.cfg` with the
   calibrated value.

3. Repeat for `total_max_feeding_length` — full path from ACE output to
   nozzle. Feed with extruder cold, then measure extrusion distance at nozzle.

4. Commit calibrated values to the repo.

## Phase 6: Systemd Services (optional)

Set up the ACE Klipper instance and router as systemd services so they start
automatically with the printer.

1. Run the install script with the `--services` flag:
   ```bash
   ./scripts/install.sh --services
   ```
   This installs `klipper-ace.service` and `klipper-router.service` into
   `/etc/systemd/system/` with paths substituted for your environment.

2. Enable and start the services:
   ```bash
   sudo systemctl enable --now klipper-ace
   sudo systemctl enable --now klipper-router
   ```

3. Check status:
   ```bash
   sudo systemctl status klipper-ace klipper-router
   ```

4. View logs:
   ```bash
   journalctl -u klipper-ace -f
   journalctl -u klipper-router -f
   ```

The service templates are in `systemd/`. If you need to adjust paths or
startup ordering, edit the installed copies in `/etc/systemd/system/`.

## Connectivity Validation

At any point during commissioning, run the test script to check system state:

```bash
./scripts/test_connection.sh
```

This verifies Unix sockets, running processes, ACE hardware detection,
router event registration, and systemd service status.

## Bowden Path Length Measurements

Record your measurements here after Phase 1:

| Lane | ACE output → U1 back panel | Total ACE → nozzle | Notes |
|------|---------------------------|-------------------|-------|
| 0 (T0) | ___mm | ___mm | |
| 1 (T1) | ___mm | ___mm | |
| 2 (T2) | ___mm | ___mm | |
| 3 (T3) | ___mm | ___mm | |
