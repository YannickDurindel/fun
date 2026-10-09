# Fun Racer: what is missing from reality

A to-do list for making the game as realistic as possible. It is ordered by how much each
group changes what you feel or see when you play, not by effort.

How to read it: each item says what is wrong today and what to do. "Today" facts come from the
code and the track recipes (`tools/track/tracks/*.toml`), which record what was checked against
a source and what is an estimate.

One decision comes first, because half of this list depends on it:

- [ ] **Decide the driving model: Trackmania feel or simulation.** The car was built to feel
  like Trackmania: grip does not depend on tyre load, the body barely rolls, a drift is a
  button combination, and bots cannot touch you. "As realistic as possible" means replacing
  that with a simulation model (section 1). The two cannot share one set of physics; keep the
  arcade car as a selectable mode and add a simulation mode next to it.

## 1. Car physics

> **Status (October 2026).** A first version of everything in this section exists as the
> optional **Simulation** handling (Options → Gameplay): tyre model, suspension, aerodynamics
> with DRS and tow, power unit with ERS and 8 gears, brakes, tyre temperature / wear / compounds,
> fuel, driving aids, and an autopilot that measures the car. Arcade remains the default because
> the simulation car does not feel right yet. What is left: tune it by driving (the bench in
> `tools/sim_bench.sh` only proves the numbers; the autopilot laps the Red Bull Ring in about
> 1:14 against a real 1:04), reduce its understeer, and give it a steering assistance that suits
> a phone.

- [ ] **Tyre model.** Today: lateral grip is a fixed budget (3.3 g plus aero) that cancels
  sideways speed. Do: a real slip-angle and slip-ratio tyre model (Pacejka or brush), with
  grip that depends on load, so understeer, oversteer and the limit feel real.
- [ ] **Weight transfer and suspension.** Today: stiff springs with anti-roll and anti-pitch
  that keep the body flat. Do: real spring, damper and anti-roll-bar rates, pitch under
  braking, roll in corners, and load moving between the four tyres.
- [ ] **Aerodynamics.** Today: downforce is one coefficient times speed squared, capped. Do:
  front and rear downforce with ride-height sensitivity, drag, the tow (slipstream) behind
  another car, and DRS on the real DRS zones.
- [ ] **Power unit and gearbox.** Today: an acceleration table and an automatic 7-speed with a
  0.06 s torque dip. Do: a torque curve, 8 gears with real ratios per circuit, manual shifting
  with paddles, engine braking, hybrid deployment and harvesting (ERS), and a rev limiter.
- [ ] **Brakes.** Today: a constant 18 m/s² deceleration. Do: brake force from pressure and
  downforce (over 5 g at high speed, falling as speed drops), brake bias, lock-ups, and brake
  temperature.
- [ ] **Performance calibration.** Today: the autopilot laps the Red Bull Ring in 1:16.7; a
  real F1 lap is about 1:05. Do: tune grip, power and drag until lap times and corner speeds
  match real telemetry on a few reference circuits.
- [ ] **Tyre wear and temperature.** Compounds (soft, medium, hard, intermediate, wet), grip
  that builds with temperature and falls with wear, flat spots after a lock-up.
- [ ] **Fuel load.** Car mass and lap time change through a stint.
- [ ] **Damage.** Today: none. Do: front wing, suspension and puncture damage from contact,
  with their effect on handling.
- [ ] **Driving aids as options.** Traction control, ABS, automatic gears, steering assist and
  a racing line, each switchable, so the simulation mode stays playable on a keyboard.

## 2. Track accuracy

- [ ] **Elevation detail.** Today: 25–30 m elevation data, smoothed over 45 m or more along
  the lap, so short steep sections are too gentle. Spa's Raidillon peaks at 12.8 % against
  about 18 %. Do: use lidar ground models where countries publish them (done for Zandvoort and
  Monaco) and hand-correct signature climbs and crests.
- [ ] **Banking.** Today: capped at 1.7°. Zandvoort (18°) and Jeddah turn 13 (12°) are nearly
  flat. Do: lift the cap, tilt the terrain and verges with the road, and check the car and
  autopilot on banked corners.
- [ ] **Road width and camber.** Today: pipeline defaults (12–15 m, light camber) except on
  the Red Bull Ring and the street circuits, and even those are estimates. Do: measure widths
  per section from aerial imagery and set them in the recipes.
- [ ] **Corner geometry on street circuits.** Today: where the map has one sharp point at a
  junction, the recipe invents a radius. Las Vegas has no turn 15 bend and takes turn 14 too
  fast. Do: trace the real racing surface for those corners.
- [ ] **Kerbs, run-off and barriers.** Today: permanent circuits get an automatic layout with
  barriers at least 10 m from the road. Do: a hand-made layout per circuit (as the Red Bull
  Ring has): real kerb types and positions, gravel or tarmac run-off, wall positions.
- [ ] **Start line, grid and sectors.** Today: several start lines are placed from the race
  distance or from a building outline, and sectors are thirds of the lap. Do: set the real
  timing line, grid slots and the two real sector points per circuit.
- [ ] **Turn numbering.** Today: several turn tables come from memory of the official maps.
  Do: check every circuit against the official circuit map, including the Red Bull Ring's T2,
  T5 and T10.
- [ ] **Pit lane.** Today: no circuit has one. Do: pit entry, pit lane with a speed limit, pit
  boxes and pit exit, built from the map data that the pipeline currently drops.
- [ ] **Bridges, tunnels and overpasses.** Today: only Suzuka's crossover exists. Monaco's
  tunnel, Miami's overpasses, Yas Marina's hotel and Singapore's bridges are open air. Do:
  roof and deck geometry.
- [ ] **Surface detail.** Bumps, patches, painted lines that are slippery in the wet, drain
  covers on street circuits, rubber build-up on the racing line and marbles off it.

## 3. Scenery

The runtime for the first five items exists (`scripts/track/scenery.gd`,
`scripts/track/track_environment.gd`, README "Scenery and time of day"): it shows whatever
scenery files a track folder has. What is open per track is the data: the baked files and a
hand-written `environment.json` and `landmarks.json`.

Known gaps of the runtime: floodlights are one shared light plus glowing lamp heads, so there
are no pools of light or several shadows per car; trees are opaque low-poly shapes; water has
no shoreline foam or reflections of buildings; grandstand crowds are a speckle; a time of day
is fixed per track (no session clock); an exported build must ship `landcover*.png` as plain
files, because they are read as class ids, not as textures.

- [ ] **Buildings and grandstands.** Today: none anywhere; street circuits run between walls
  on grass. Do: building blocks from the map data's footprints and heights, grandstands, pit
  buildings, and landmark models (Monaco's casino and harbour, the Las Vegas Sphere, the
  Suzuka wheel).
- [ ] **Ground types.** Today: grass verges and grass terrain everywhere. Do: sand for Bahrain,
  Lusail and Jeddah, tarmac for city blocks, water for harbours, lakes and the sea (today
  Monaco's harbour is flat green ground).
- [ ] **Trees and vegetation.** Forests at Spa, Monza and Suzuka, dunes at Zandvoort.
- [ ] **Trackside objects.** Advertising boards, marshal posts, fences with catch posts, brake
  marker boards (300, 200, 100 m), start lights gantry, light panels.
- [ ] **Sky, time of day and night races.** Today: one bright daytime sky. Do: time of day per
  session and floodlit night races for Bahrain, Jeddah, Singapore, Las Vegas, Lusail and Yas
  Marina.
- [ ] **Weather.** Rain, a drying line, puddles, spray behind cars, wet grip.
- [ ] **Crowds and atmosphere.** Spectators, flags, smoke, a pit crew.

## 4. Racing

- [ ] **Car-to-car collisions.** Today: bots are ghosts you drive through. Do: real contact
  between cars, with the bots trained to avoid it.
- [ ] **Bot racecraft.** Today: each bot follows its own line at a pace set by the difficulty.
  Do: overtaking, defending, slipstreaming, braking for the car ahead, mistakes under
  pressure, and 19 opponents instead of 7.
- [ ] **Race weekend.** Practice, qualifying (three knockout parts) and the race, with a grid
  set by qualifying.
- [ ] **Start procedure.** Formation lap, five red lights with a random delay, jump-start
  detection. Today: a 3-2-1-GO countdown.
- [ ] **Rules.** Track limits with lap deletion and time penalties, blue and yellow flags,
  safety car and virtual safety car, pit-lane speed limit, mandatory tyre change.
- [ ] **Pit stops and strategy.** Tyre choice, fuel, repairs, and bots that follow strategies.
- [ ] **Teams, drivers and a championship.** A season over the 24 circuits with points.
  Real team and driver names and liveries are trademarks: use invented ones, or get a licence.
- [ ] **Race distance.** Full, half and quarter race lengths based on each circuit's real lap
  count.

## 5. Sound

- [ ] **Engine.** Today: a synthesised V12-style tone that nobody has tuned by ear. Do: a
  turbo-hybrid V6 character: lower revs (15,000 rpm limit, about 11,000–12,000 in use), turbo
  whistle, energy-recovery whine, gear-shift cracks, lift-off burble.
- [ ] **Tyres, wind and impacts.** Scrub that rises with slip, kerb rumble, gravel, wall
  hits, bottoming.
- [ ] **Other cars and the world.** Opponents' engines with distance and Doppler shift,
  echoes off walls and under bridges, crowd, tannoy.
- [ ] **Team radio.** Lap times, gaps, flags and pit calls spoken by an engineer.

## 6. Cockpit, cameras and display

- [ ] **Steering wheel and dashboard.** A modelled wheel with a display (gear, speed, delta,
  ERS), shift lights, working mirrors, the halo in the cockpit view.
- [ ] **Driver.** Animated hands and helmet movement.
- [ ] **Broadcast cameras.** TV camera positions per circuit for replays, an onboard T-cam, a
  replay system with rewind.
- [ ] **Timing screens.** A timing tower with gaps and tyre compounds, sector colours for
  every car, a track map with car positions.
- [ ] **Graphics quality.** Reflections on the car, heat haze, tyre smoke and rubber marks
  that persist, better shadows, motion blur. Keep a low preset for integrated graphics.

## 7. Input devices

- [ ] **Steering wheels and pedals.** Detect wheels, map axes with calibration and a
  configurable steering range, and force feedback driven by the tyre model.
- [ ] **Gamepad.** Rumble for kerbs, lock-ups and wheelspin; adjustable trigger curves.
- [ ] **Phone as a controller.** See the next section.

## 8. Phone as a game controller: steer, accelerate and brake

> **Status (October 2026).** Done and tried on an Android phone: the game serves the page, pairs
> with a 4-digit code and QR code, tilt steering (Chrome, over the `https` address; Brave blocks
> the sensors), on/off gas and brake, AUTO GAS, CAM, shift, DRS, respawn and pause. Not tried:
> iPhone. Left to do: a steering assistance like Real Racing 3 (help towards the racing line and
> automatic braking), and vibration tuning.

Goal: hold the phone like a steering wheel. Tilt it to steer; press the right side of the
screen to accelerate and the left side to brake. No app to install: the phone opens a web page
that the game serves over the local Wi-Fi.

How it works: the game runs a small web server. The phone loads a controller page from it and
sends its tilt and touch state back over a WebSocket about 60 times a second. The game treats
those values as an analog input device, like a gamepad.

- [ ] **Step 1: the server in the game.** Add a `PhoneController` autoload using Godot's
  `TCPServer` and `WebSocketPeer`: serve one HTML page on a port (for example 8080) and accept
  one WebSocket connection. Start it only when the option is turned on.
- [ ] **Step 2: the controller page.** One self-contained HTML file in `assets/phone/`:
  - steering from `DeviceOrientationEvent` (tilt in landscape), with a touch slider as a
    fallback when motion sensors are unavailable;
  - two large touch zones: right for throttle, left for brake, analog by how far up the zone
    the thumb is;
  - buttons for respawn, pause and camera;
  - a wake lock so the screen stays on, and fullscreen landscape.
- [ ] **Step 3: the message format.** A small JSON or binary message: `steer` (−1..1),
  `throttle` (0..1), `brake` (0..1), buttons, and a sequence number. If no message arrives for
  0.3 s, the game releases all inputs so a dropped connection cannot leave the throttle on.
- [ ] **Step 4: feed the game.** Read the values in `Bootstrap.get_steer()`, `get_throttle()`
  and `get_brake()` (`scripts/bootstrap.gd`) as an analog source. `is_steer_digital()` must
  return false for it, so the car does not apply the keyboard steering ramp.
- [ ] **Step 5: pairing screen.** In Options → Controls add "Phone controller": an on/off
  switch, the address to open (`http://<this computer's IP>:8080`) and a QR code of it, a
  connection status light, and a 4-digit code shown on the PC that the phone must enter, so
  nobody else on the network can drive the car.
- [ ] **Step 6: calibration and tuning.** A "hold the phone level and press Centre" button,
  and sliders for steering angle (how many degrees of tilt give full lock, default 40°), dead
  zone and smoothing. Save them in `Settings` under `controls`.
- [ ] **Step 7: iPhone support.** iOS only gives motion data to pages served over HTTPS and
  after a tap that calls `DeviceMotionEvent.requestPermission()`. Either serve HTTPS with a
  self-signed certificate (the user accepts a browser warning once), or ship the touch-slider
  fallback for iPhones. Android Chrome works over plain HTTP on a local address.
- [ ] **Step 8: feedback on the phone.** Vibrate on kerbs, impacts and gear shifts
  (`navigator.vibrate`, Android only), and show speed and gear on the page.
- [ ] **Step 9: firewall and network.** Document opening the port on the PC's firewall
  (on Fedora: `firewall-cmd --add-port=8080/tcp`), and that phone and PC must be on the same
  Wi-Fi network. Show a clear message in the game when the port cannot be opened.
- [ ] **Step 10: test it.** A headless test that connects a fake phone client, sends tilt and
  touch values, and checks the car's inputs follow them and return to neutral when the
  connection drops. Measure the delay from phone to car; aim for under 50 ms.

## 9. Known gaps in what exists today

Smaller things to finish before or alongside the list above.

- [ ] **Play-test the handling.** The steering ramp, grip and drift rules were tuned from
  numbers; confirm them by hand and adjust the sliders in Options → Controls.
- [ ] **Listen to the sound.** Engine, tyre, wind and menu sounds were checked by signal
  measurements only.
- [ ] **Measure performance.** Frame rate and loading time per circuit on the Intel HD 520,
  with and without 7 bots. Spa (7 km) and the street circuits with close walls are the ones
  to watch.
- [ ] **Test display options on a real window.** Fullscreen, resolution changes and vsync.
- [ ] **Spa, La Source exit.** The autopilot comes within 7 cm of the road edge there.
- [ ] **Monaco.** A steep grass bank stands in front of a retaining wall before the chicane;
  one verge sample has a gap with no wall; the harbour is green ground.
- [ ] **Remus kerb, Red Bull Ring.** The sawtooth kerb inside the hairpin is about 10 cm
  high, above the 5 cm intended.
- [ ] **Hand-made trackside for the 17 permanent circuits.** They use the automatic layout.
- [ ] **Repository size.** Track assets are about 90 MB; consider Git LFS before adding more.
