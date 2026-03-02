# Bowden Routing Notes

Physical routing measurements and notes for the ACE Pro → Snapmaker U1 filament path.

## ACE Pro Placement

- **Position:** _(describe: left/right/rear of U1, shelf, enclosure, etc.)_
- **ACE dimensions:** ~320mm W × 170mm D × 270mm H
- **Distance to U1 back panel:** ___mm

## Bowden Tube Specs

| Property | Value |
|----------|-------|
| Outer diameter | ___mm |
| Inner diameter | ___mm |
| Material | PTFE / Capricorn / other |
| Connector type (ACE side) | ___ |
| Connector type (U1 side) | 6mm OD quick-connect |
| Adapter needed? | Yes / No |

## Path Length Measurements

Record after Phase 1 (dumb drybox validation). Feed filament through and
measure at each segment.

| Lane | ACE Slot | U1 Toolhead | ACE Output → U1 Back Panel | U1 Back Panel → Extruder | Total ACE → Nozzle | Notes |
|------|----------|-------------|---------------------------|-------------------------|-------------------|-------|
| 0 | Slot 0 | T0 (e0) | ___mm | ~950mm | ___mm | |
| 1 | Slot 1 | T1 (e1) | ___mm | ~950mm | ___mm | |
| 2 | Slot 2 | T2 (e2) | ___mm | ~950mm | ___mm | |
| 3 | Slot 3 | T3 (e3) | ___mm | ~950mm | ___mm | |

## Routing Diagram

Sketch your physical routing here. Note any bends, clip points, or areas
where tubes cross.

```
     ACE Pro
  ┌────────────┐
  │ S0 S1 S2 S3│
  └─┬──┬──┬──┬─┘
    │  │  │  │   ← Bowden tubes (___mm each)
    │  │  │  │
  ┌─┴──┴──┴──┴─┐
  │  U1 Back    │
  │  Panel      │
  │ L0 L1 R0 R1│  ← Left feed (e0,e1) / Right feed (e2,e3)
  └─────────────┘
```

## Friction Check

After routing, pull filament through by hand. Note any sticking points.

| Lane | Slides freely? | Friction points | Action taken |
|------|---------------|-----------------|-------------|
| 0 | | | |
| 1 | | | |
| 2 | | | |
| 3 | | | |

## Calibrated Values

After Phase 5 calibration, record the final values used in `ace_instance.cfg`:

```ini
parkposition_to_toolhead_length: ___   # ACE park → U1 extruder gears
parkposition_to_rdm_length: 0          # no RDM sensor
total_max_feeding_length: ___          # ACE park → nozzle tip
```
