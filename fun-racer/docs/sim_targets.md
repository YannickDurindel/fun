# Simulation targets: what a real Formula 1 car does

Reference numbers for calibrating the simulation car (`assets/car/specs/f1.tres`) with
`tools/sim_bench.sh`. The bench's `ref` column points at the row ids below (ACC1, BRK1...);
the bands themselves live in `TARGETS` in `tools/sim_bench.gd`. **Change a band in both places.**

The car is a 2022–2025 ground-effect car in qualifying trim: low fuel (the spec starts with
10 kg), new tyres, medium downforce, dry, sea level, flat ground.

## How far to trust each number

| Grade | Meaning |
|---|---|
| **A** | Official: FIA regulations and timing sheets, Formula1.com results, a team's own page, Brembo's braking data (read through press reprints of Brembo's releases, not from brembo.com). |
| **B** | An estimate from telemetry or reputable journalism. |
| **C** | Commonly repeated, with no primary source found. Treat as folklore. |
| **D** | Derived here from A/B numbers with simple physics. The arithmetic is shown. |
| **none** | No source at all: a design target, chosen so the car is drivable. |

Every URL below was opened and contained the figure, except where marked *snippet only*
(seen in a search result, page not opened). Researched on 2026-10-09.

**Honest summary.** The regulations, the speed traps, the Brembo braking zones, the pole
times and one team statement on downforce are solid. The acceleration times everyone quotes
(0–100 in 2.6 s and so on) have no primary source. Stopping distances to zero, cornering g
below 250 km/h, CdA and ClA, the understeer balance and all the transient targets are
derived or simply chosen. Do not calibrate to the third digit of anything.

## How the bench scores

A measurement inside the band is a `PASS`. Outside by less than half the band's width (and at
least 5 % of its centre) it is a `WARN`; further out a `FAIL`. `n/a` means the handling model
does not have the quantity, or the manoeuvre could not be done. The bench exits non-zero only
for a script error, a crash or a timeout.

## Mass and power

| Quantity | Value | Grade | Source |
|---|---|---|---|
| Minimum mass, no fuel, with driver | 798 kg (2022–2024), 800 kg (2025) | A | FIA 2024 Technical Regulations, Art. 4.1: "The mass of the car, without fuel, must not be less than 798kg" — <https://www.fia.com/sites/default/files/fia_2024_formula_1_technical_regulations_-_issue_8_-_2024-10-17.pdf>; 2025: <https://www.fia.com/news/formula-1-commission-meeting-23072024-media-statement> |
| Weight on the front axle | 44.6 % to 46.1 % | A | Same regulations, Art. 4.2: axle masses at least 0.446 and 0.539 of the minimum |
| Wheelbase | at most 3600 mm | A | Same regulations, Art. 3.4.2 |
| Electric motor (MGU-K) | 120 kW | A | Same regulations, Art. 5.3 |
| Fuel flow | at most 100 kg/h | A | Same regulations, Art. 5.2.3 |
| Total power | about 710–750 kW (950–1000 hp) | C / D | No official figure exists. "up to 950 hp (710 kW)": <https://en.wikipedia.org/wiki/Formula_One_car>. Derived bound: 100 kg/h of fuel at about 50 % efficiency and 43–44 MJ/kg is about 600 kW, plus 120 kW electric, about 720 kW |
| Race fuel load | about 110 kg | B | <https://www.gpfans.com/us/f1-news/1028253/f1-car-weight-explained/> |

The game's car is 3.6 m in wheelbase (`Car.WHEELBASE`) and 798 kg dry: both match.

## Acceleration (bench group `launch`)

| Id | Quantity | Real figure | Band | Grade | Source |
|---|---|---|---|---|---|
| ACC1 | 0–100 km/h | about 2.6 s | 2.3–2.9 s | C | <https://motorsportexplained.com/f1-accelerate-decelerate/>, <https://racingnews365.com/speed-trap-f1> (both unsourced) |
| ACC2 | 0–200 km/h | 4.5 s; other sites say 5.0–5.5 s | 4.3–5.5 s | C | Same pages. The figures conflict |
| ACC3 | 0–300 km/h | about 10.6 s | 8.5–11.5 s | C, weak | One low-quality page, *snippet only*. **Not sourced**: the band is wide on purpose |
| ACC4 | Peak acceleration off the line | — | 1.3–2.0 g | D | Not published. 0–100 in 2.6 s is 1.09 g on average; the tyres allow more once the downforce builds, so the peak comes near 120–160 km/h |

Wikipedia's "0–60 mph in 1.8 s" contradicts ACC1 and is not used. No F1.com or team figure
for any of these was found. The launch is traction-limited to about 150 km/h, then
power-limited: ACC1 mostly tests the tyres and the traction control, ACC3 the power and drag.

## Top speed (bench group `top_speed`)

FIA "Qualifying Session Maximum Speeds" sheets, 2024 season (A). Cars run with the DRS open
at the speed trap in qualifying.

| Circuit (wing level) | Speed trap, fastest / slowest car | Source |
|---|---|---|
| Monza (lowest downforce) | 353.5 / 346.8 km/h | <https://www.fia.com/sites/default/files/2024_16_ita_f1_q0_timing_qualifyingsessionmaximumspeeds_v01.pdf> |
| Silverstone (medium-high) | 332.7 (probably towed); most cars 320–325 km/h | <https://www.fia.com/sites/default/files/2024_12_gbr_f1_q0_timing_qualifyingsessionmaximumspeeds_v01.pdf> |
| Red Bull Ring (medium) | 321.4 / 314.5 km/h; 324.4 at the first intermediate | <https://www.fia.com/sites/default/files/2024_11_aut_f1_q0_timing_qualifyingsessionmaximumspeeds_v01.pdf> |
| Monaco (maximum) | 285.7 / 279.7 km/h | <https://www.fia.com/sites/default/files/2024_08_mon_f1_q0_timing_qualifyingsessionmaximumspeeds_v01.pdf> |

Other figures: 359 km/h in the 2023 Monza race with a tow (A, <https://www.mercedesamgf1.com/races/italian-grand-prix-2024>);
372.5 km/h, Bottas, Mexico 2016, at 2200 m altitude (A, team:
<https://www.williamsf1.com/posts/253b1dc5-aee9-4d3b-b720-8e30f3a83093/how-fast-can-an-f1-car-go>;
the "378 km/h" on the same page is a team claim, not a speed-trap reading).

| Id | Quantity | Band | Grade | Why |
|---|---|---|---|---|
| TOP1 | Top speed, DRS closed, medium downforce | 310–335 km/h | D | A real trap is at the end of a finite straight; the bench runs until the speed stops rising, which is a little higher. Taken as the medium-downforce traps (315–325, DRS open) less a DRS gain of about 10–12 km/h, plus up to 10 km/h for the endless straight |
| TOP2 | Top speed, DRS open | 322–348 km/h | D | The same traps plus the endless straight |

The DRS gain itself is poorly sourced: 10–12 km/h (attributed to the FIA) and 4–5 km/h
(Racecar Engineering), both *snippet only*. To calibrate a low-downforce setup use the Monza
row instead (347–354 km/h with DRS).

## Braking (bench group `braking`)

Brembo's data for single braking zones (A, through press reprints):

| Corner | Speeds | Distance | Time | Peak | Source |
|---|---|---|---|---|---|
| Red Bull Ring T3, 2024 | 313 → 81 km/h | 114 m | 2.52 s | 4.6 g | <https://www.motorbox.com/auto/sport/f1/gran-premi/formula-1-gp-austria-2024-orari-meteo-e-segreti-del-circuito> |
| Red Bull Ring T1, 2022 | 312 → 139 km/h | 102 m | 1.78 s | 4.7 g | <https://www.motorbox.com/auto/sport/f1/news/gp-austria-2022-i-segreti-del-cricuito-di-spielberg-con-brembo> |
| Monza T1, 2023 | 334 → 89 km/h | 122 m | 2.57 s | 5.2 g | <https://www.motorbox.com/auto/sport/f1/news/gp-italia-2023-i-segreti-del-circuito-di-monza-con-brembo> |
| Monza T1, 2019 | 349 → 87 km/h | 137 m | 2.74 s | 5.6 g | <https://f1grandprix.motorionline.com/en/formula-1-gp-italia-brembo-analizza-limpegno-dei-sistemi-frenanti-sul-tracciato-di-monza/> |
| Monza T4, 2019 | 334 → 119 km/h | 117 m | 2.09 s | 4.9 g | Same page |

| Id | Quantity | Band | Grade | Why |
|---|---|---|---|---|
| BRK1 | 313 → 81 km/h: distance, time, peak | 103–125 m, 2.2–2.8 s, 4.2–5.3 g | A | Red Bull Ring T3 above, ±10 %; the peak band reaches 5.3 g because the 2020 figure for the same corner was 5.3 g from 331 km/h (*snippet only*) |
| BRK2 | 300 → 0 km/h | 108–135 m, 3.1–3.9 s, peak 4.2–5.4 g | D | See below |
| BRK3 | 200 → 0 km/h | 60–75 m, 2.4–3.0 s, peak 2.7–3.6 g | D | See below |
| BRK4 | 100 → 0 km/h | 17–23.5 m, 1.3–1.75 s, peak 1.8–2.6 g | D | See below |
| BRK5 | Time with a wheel locked | at most 0.10 s | none | With the anti-lock aid on, the bench car should not lock |

**BRK1 is the only braking target with a real measurement behind it.** A driver builds the
pedal pressure over a tenth or two and bleeds it off as the downforce goes; the bench stamps
on the pedal at once, so expect the bench to be a few metres and tenths *better* than Brembo
for the same car.

BRK2–4 are derived. No source was found for the usual "200–0 in 65 m and 2.9 s" or "300–0
in under 4 s" (and 65 m with 2.9 s is not possible at a constant deceleration: that takes
80 m). They come from a deceleration that grows with the square of the speed, like the
downforce and the drag: `a(v) = a0 + (a1 − a0)·(v / 313 km/h)²`, with `a0` = 1.6–1.8 g at a
crawl and `a1` = 4.6–4.8 g at 313 km/h. That model reproduces the Brembo zones (313 → 81 in
112–120 m and 2.25–2.4 s; 312 → 139 in 89–95 m) and gives 300–0 in 119–129 m and 3.4–3.7 s,
200–0 in 67–73 m and 2.6–2.9 s, 100–0 in 20–22.5 m and 1.5–1.7 s. The bands are those,
widened. The folklore "100–0 in 15 m" (C: <https://motorsportexplained.com/f1-accelerate-decelerate/>)
needs 2.6 g on mechanical grip alone and is below the band.

Brake discs reach about 1000–1200 °C (A: <https://www.formula1.com/en/latest/article.watch-the-drivers-rely-heavily-on-their-brakes-at-high-speed-monza-so-how-do.3SBdVFYO9vIr1XM9nLVs1S.html>).

## Cornering (bench group `cornering`)

| Published figure | Grade | Source |
|---|---|---|
| Silverstone Maggotts–Becketts, 2024: "up to 5G", "an expected maximum of 5g at Turn 11" | A (team) | <https://www.mercedesamgf1.com/races/british-grand-prix-2024> |
| Maggotts–Becketts: entered at about 308 km/h, minimum 228 km/h; 5.3 g (2020 broadcast graphic); 4–5 g in the race | B / C | <https://oversteer48.com/maggots-and-becketts/> |
| Copse, 2020 Mercedes: 276 km/h, 4.5 g in the race | B | <https://es.motorsport.com/f1/news/carga-aerodinamica-formula1-record-comparativa/5171817/> |
| Mugello 2020, Savelli: "over 5.2G" | B | <https://africa.espn.com/f1/story/_/id/29869082/why-drivers-relishing-challenge-crazy-mugello-circuit> |
| "4 to 6.5 g" in general | C | <https://en.wikipedia.org/wiki/Formula_One_car> |

| Id | Speed | Band | Grade | Why |
|---|---|---|---|---|
| LAT1 | 80 km/h | 1.8–2.5 g | D | **No published figure for slow corners.** Tyre friction of about 1.7–1.9 plus a little downforce |
| LAT1 | 120 km/h | 2.2–3.1 g | D | Same, with more downforce |
| LAT2 | 160 km/h | 2.8–3.8 g | D | Interpolated between LAT1 and LAT3 |
| LAT2 | 200 km/h | 3.4–4.6 g | D | Interpolated; the Red Bull Ring's Turns 6 and 7 are taken at about 185–200 km/h (below) |
| LAT3 | 250 km/h | 4.3–5.5 g | B | The 4.5–5.3 g figures above are for 230–300 km/h |
| LAT3 | 300 km/h | 4.8–6.3 g | B / C | Peaks of 5–6 g are published; sustained values at 300 km/h are not |

The bench holds the speed and winds the steering on slowly; the figure is the best 0.25 s
mean, so it is a *sustained* limit and reads lower than a broadcast peak. Published g figures
are 2020–2024 cars; Pirelli's own "g" figures are tyre-energy averages and read lower still
(they are not used here). If a row's note says `FULL LOCK`, the steering ran out before the
tyres did, and the number is not the grip limit.

## Downforce (bench group `ride`)

| Id | Statement | Band (wheel load ÷ weight) | Grade | Source |
|---|---|---|---|---|
| AER1 | "At around 150 km/h, the car generates as much downforce as it weighs" | 1.6–2.2 at 150 km/h (and 0.97–1.03 at rest) | A (team, about 2022) | <https://www.mercedesamgf1.com/news/feature-downforce-in-formula-one-explained> |
| AER2 | At the end of the straight "probably three or four times the weight of the car" (same page); about 3000 kg at 276 km/h through Copse in 2020 | 4.0–5.5 at 300 km/h | A / B | Same page; <https://es.motorsport.com/f1/news/carga-aerodinamica-formula1-record-comparativa/5171817/> |

Derived (D): downforce equal to 795 kg at 150 km/h is a ClA of about 7.4 m² (air at
1.2 kg/m³); 3000 kg at 276 km/h is about 8.3 m² for the 2020 cars, the highest-downforce
era. The two statements on the Mercedes page do not agree with each other exactly (a pure
square law from 150 km/h gives 4 times the weight at 300 km/h, 4.8 times at 330), hence the
wide bands. Wikipedia's "twice its weight at 190 km/h" (C) implies even more. **CdA, the
lift-to-drag ratio and the front/rear aero balance are not sourced**; set the drag from the
top speed (TOP1) once the power is fixed.

The ride-height rows are for information: no real figure was sourced.

## Balance and transients (bench groups `cornering`, `step_steer`, `lift_off`)

**None of these has a source.** They are design targets for a car that is quick but can be
driven with a phone.

| Id | Quantity | Band | Why |
|---|---|---|---|
| DYN1 | Front minus rear tyre slip angle at the limit | −0.5 to +3.0° | Mild understeer at the limit at every speed: the front gives up first. Negative is oversteer |
| DYN2 | Step steer to half the limit: yaw-rate rise time to 90 %, and overshoot | 0.08–0.25 s; at most 20 % | Racing cars answer in about 0.1–0.2 s; a large overshoot means too little yaw damping |
| DYN3 | Lift-off at 85 % of the limit: peak body slip; spin | at most 8°; no spin | The car should tuck in, not spin, when the driver lifts |

Steering ratio and the slip angle of peak grip for an F1 slick were not sourced (the usual
engineering figures are 6–8° for peak lateral grip and 8–12 % slip ratio; grade C).

## Tyres

Working ranges for Pirelli's 2019 compounds (A, 13-inch tyres; **not found for the 18-inch
tyres used since 2022**): C1 110–140 °C, C2 110–135 °C, C3 105–135 °C, C4 90–120 °C,
C5 85–115 °C. <https://press.pirelli.com/whats-new-with-pirellis-2019-formula-1-tyres/>

## Lap times (bench option `--lap <track>`)

The band is from 1 % under the pole to 4 % over: a lap much quicker than reality is as wrong
as a slow one. The lap is the autopilot's flying lap from `tools/lap_check.sh`, so it tests
the autopilot as much as the car.

| Id | Circuit | Pole used (2025) | Grade | Source | Other years |
|---|---|---|---|---|---|
| LAP1 | Red Bull Ring | 1:03.971, Norris | A | <https://www.formula1.com/en/results/2025/races/1264/austria/qualifying> | 2024 1:04.314 (A: <https://www.formula1.com/en/results/2024/races/1239/austria/qualifying>); 2023 1:04.391, 2022 1:04.984, 2021 1:03.720 (B, Wikipedia race pages); outright record 1:02.939, Bottas, 2020 (B: <https://en.wikipedia.org/wiki/2020_Austrian_Grand_Prix>) |
| LAP2 | Monza | 1:18.792, Verstappen (264.7 km/h average) | B | <https://en.wikipedia.org/wiki/2025_Italian_Grand_Prix> | 2020 1:18.887 |
| LAP3 | Silverstone | 1:24.892, Verstappen | B | <https://en.wikipedia.org/wiki/2025_British_Grand_Prix> | 2024 1:25.819 (A: <https://www.mercedesamgf1.com/races/british-grand-prix-2024>) |
| LAP4 | Monaco | 1:09.954, Norris | B | <https://en.wikipedia.org/wiki/2025_Monaco_Grand_Prix> | |

### Corner speeds

No complete, telemetry-based table of apex speeds was found in text form for any circuit.
What there is:

| Corner | Speed | Grade | Source |
|---|---|---|---|
| Red Bull Ring T1 (Niki Lauda) | 139 km/h minimum, braking from 312 | A | Brembo 2022 (link above) |
| Red Bull Ring T3 (Remus) | 81 km/h minimum, braking from 313 (2024) | A | Brembo 2024 (link above) |
| Red Bull Ring T4 (Schlossgold) | third gear; no speed | B | <https://redbullring.com/en/events-tickets/formula-1/formula-1-circuit> |
| Red Bull Ring T6–T7 | 185 km/h minimum (2018 cars); "about 200 km/h" for T6 to T10 | B | <https://www.grandprix247.com/formula-1-news/austrian-grand-prix-facts-stats-info>; Brembo 2022 |
| Red Bull Ring T9 (Rindt) | about 240–250 km/h | B | Same two pages |
| Red Bull Ring T10 | **not sourced** | | |
| Red Bull Ring, before T3 | 313–324 km/h | A | Brembo 2024; FIA sheet above |
| Monza T1 / T4 | 87–89 / 119 km/h | A | Brembo (links above) |
| Silverstone Copse | 276 km/h (2020); about 290 km/h (unsourced) | B / C | Motorsport.com link above; <https://oversteer48.com/silverstone-copse-corner/> |
| Monaco hairpin | 45–50 km/h | A (team) | <https://www.mercedesamgf1.com/races/monaco-grand-prix-2024> |

Lesmo, Ascari and Parabolica at Monza were not sourced. For a proper table, pull one
qualifying lap from the FastF1 timing archive and read the speed trace; that was not done.
