# Simulation handling: how the parts fit

The car has two handling models. `arcade` is the Trackmania-style model inside
`scripts/car/car.gd`. `simulation` is the force-based model in `scripts/car/sim/`, owned by
the `Car` as `car.sim` (`SimHandling`). Choose with the `gameplay/handling` setting, the
`--handling=arcade|simulation` flag, or `car.handling` set before the car enters the tree.

## One tick (240 Hz), in `sim_handling.gd`

1. Driver input is copied into `SimState.in_*`; **`SimAids.step`** writes the demands
   (`throttle`, `brake`, `steer_angle`, `shift_request`, `drs_request`).
2. Each wheel is ray-cast: `contact`, `compression` (0 = design ride height),
   `compression_vel`, `surface_mu`, `surface_drag`.
3. **`SimSuspension.step`** writes `load[i]` (N). **`SimAero.step`** writes
   `downforce_front`, `downforce_rear`, `drag`, `drs_open`.
4. **`SimPowertrain.step`** writes `drive_torque[i]`, `gear`, `rpm`, `shifting`,
   `ers_energy`. **`SimBrakes.step`** writes `brake_torque[i]`, `brake_temp[i]`.
5. Per wheel, in 4 sub-steps: slip ratio and slip angle, then
   **`SimTyreModel.forces(state, spec, i, dt)`** returns `Vector2(fx, fy)` in the wheel frame,
   then the wheel's rotation is integrated (semi-implicit, using
   `SimTyreModel.long_stiffness`).
6. Gravity, aero and tyre forces are summed on the body and its velocities integrated.
7. **`SimTyreCondition.step`** updates `grip_factor`, `tyre_temp`, `tyre_wear`, `fuel`,
   `mass`. The `Car` contract is published (`speed_kmh`, `rpm`, `gear`, `wheels[i]`...).

## Rules for a part

- A part is a `RefCounted` class with `setup(spec)`, `reset(state, spec)` and its step
  function. Keep those signatures: the loop calls them.
- A part writes only the `SimState` fields listed as its own in `sim_state.gd`. It may read
  any field. Values it reads from parts that run later are from the previous tick.
- Every number lives in `CarSpec` (`scripts/car/sim/car_spec.gd`, values in
  `assets/car/specs/f1.tres`). Add `@export` fields in your part's group; do not rename or
  remove existing ones. Do not put tuning constants in the part.
- No allocations per tick (no new arrays or dictionaries in `step`).
- Deterministic: no randomness, no wall-clock time.
- Units are SI. Frames: car forward = -Z, up = +Y, right = +X. Wheels: FL, FR, RL, RR.
  Tyre frame: x = along the wheel (+ pushes the car forward), y = to the wheel's right.
  A positive slip angle (patch moving right) gives a negative y force.

## Testing

`tests/sim_rig.gd` (`SimRig`) gives a flat pad and manoeuvres that return measurements:
`spawn`, `drive`, `set_speed`, `launch`, `brake_from`, `max_lateral_g`, `top_speed`.
`tests/test_sim_basics.gd` shows their use. Name part tests `tests/test_sim_<part>.gd`.
A part can also be tested without physics by building a `SimState` and a `CarSpec` by hand
and calling its step function.

`tools/lap_check.sh <track> --handling=simulation` drives full laps with the autopilot.

## Reference numbers (a 2020s F1 car, to be confirmed against sources by the bench unit)

| Quantity | Value |
|---|---|
| Mass with driver, no fuel | 798 kg |
| Power | about 750 kW (620 kW engine + 120 kW electric) |
| 0–100 km/h | about 2.6 s (traction limited) |
| 0–200 km/h | about 4.5–5 s |
| 0–300 km/h | about 10–11 s |
| Top speed | 330–350 km/h depending on wing level |
| Braking | about 5 g peak at high speed; 200–0 km/h in about 55–65 m |
| Cornering | about 1.7–2 g at low speed, rising to 4–5 g above 250 km/h |
| Downforce | about equal to the car's weight near 150–160 km/h |

With the placeholder parts the car does 0–100 in 2.75 s, 0–300 in 9.5 s, 200–0 in 59 m and
2.5 g at 150 km/h.
