extends RefCounted
## Playable aircraft: model, flight-model values, undercarriage contact
## points, armament, fuel and camera framing.  plane.gd applies one of these
## at spawn (GameSettings.aircraft picks which).
##
## Flight values feed flight_model.gd: mass (kg), wing area (m²), span (m),
## zero-lift drag cd0, clean cl_max and stall angle, engine power (W) at its
## rated altitude (m), roll rate (rad/s) and the G limit.  Fighters of a
## class share the model; these numbers are what tells them apart.

## Engine power is scaled up (and drag with it, so top speeds stay put) to
## get the fighters to the raid's height in about three minutes rather than
## the real six or seven
const CLIMB_BOOST := 1.5

const TYPES := {
	"spitfire": {
		"name": "Supermarine Spitfire Mk I", "side": "raf",
		"short": "Spitfire",
		"desc": "Agile and fast. The RAF's thoroughbred.",
		"model": "res://scenes/plane/spitfire/spitfire_model.gd",
		"model_offset": Vector3(0, 0, -0.9),
		# Merlin III, 1,030 hp at 16,250 ft: ~470 km/h at sea level, ~575 km/h at 5.5 km
		"mass": 2700.0, "wing_area": 22.5, "span": 11.2, "cd0": 0.0195,
		"cl_max": 1.40, "stall_deg": 16.0,
		"power": 790000.0, "rated_alt": 5000.0, "roll_max": 2.1, "climb_boost": CLIMB_BOOST,
		"wheels": [Vector3(-1.6, -1.5, -2.0), Vector3(1.6, -1.5, -2.0), Vector3(0.0, -0.27, 3.8)],
		"guns": [Vector3(-4.5, 0, -0.8), Vector3(-3.0, 0, -0.8), Vector3(3.0, 0, -0.8), Vector3(4.5, 0, -0.8)],
		"gun_interval": 0.02, "gun_ammo": 2000, "gun_speed": 800.0, "gun_label": ".303 MG",
		"cannons": [Vector3(-6.0, 0, -0.5), Vector3(6.0, 0, -0.5)],
		"cannon_interval": 60.0 / 1400.0, "cannon_ammo": 150, "cannon_speed": 820.0, "cannon_label": "20 MM",
		"fuel": 1200.0, "start_speed": 80.0,
		"camera": [20.0, 5.0], "hitbox": Vector3(12.0, 1.5, 10.0),
	},
	"hurricane": {
		"name": "Hawker Hurricane Mk I", "side": "raf",
		"short": "Hurricane",
		"desc": "Rugged, steady gun platform. Eight Brownings.",
		"model": "res://scenes/plane/hurricane/hurricane_model.gd",
		"model_offset": Vector3.ZERO,
		# Same Merlin, a thicker wing and more weight: slower, but turns as tightly
		"mass": 3000.0, "wing_area": 23.9, "span": 12.2, "cd0": 0.0235,
		"cl_max": 1.45, "stall_deg": 17.0,
		"power": 790000.0, "rated_alt": 5000.0, "roll_max": 1.85, "climb_boost": CLIMB_BOOST,
		"wheels": [Vector3(-1.2, -1.62, -0.75), Vector3(1.2, -1.62, -0.75), Vector3(0.0, -1.0, 5.15)],
		"guns": [Vector3(-3.15, -0.4, -1.1), Vector3(-2.9, -0.4, -1.1), Vector3(-2.65, -0.4, -1.1), Vector3(-2.4, -0.4, -1.1),
			Vector3(2.4, -0.4, -1.1), Vector3(2.65, -0.4, -1.1), Vector3(2.9, -0.4, -1.1), Vector3(3.15, -0.4, -1.1)],
		"gun_interval": 0.0125, "gun_ammo": 2400, "gun_speed": 800.0, "gun_label": ".303 MG ×8",
		"cannons": [], "cannon_interval": 1.0, "cannon_ammo": 0, "cannon_speed": 820.0, "cannon_label": "",
		"fuel": 1100.0, "start_speed": 78.0,
		"camera": [21.0, 5.5], "hitbox": Vector3(12.5, 1.8, 10.0),
	},
	"bf109": {
		"name": "Messerschmitt Bf 109 E-4", "side": "lw",
		"short": "Bf 109",
		"desc": "Fast climber with hard-hitting 20 mm cannon.",
		"model": "res://scenes/enemies/bf109/bf109_model.gd",
		"model_offset": Vector3.ZERO,
		# DB 601A: more power on a small, heavily loaded wing (slats help the stall)
		"mass": 2600.0, "wing_area": 16.2, "span": 9.9, "cd0": 0.0235,
		"cl_max": 1.48, "stall_deg": 17.0,
		"power": 800000.0, "rated_alt": 4500.0, "roll_max": 2.0, "climb_boost": CLIMB_BOOST,
		"wheels": [Vector3(-1.0, -1.6, -0.55), Vector3(1.0, -1.6, -0.55), Vector3(0.0, -0.58, 3.95)],
		"guns": [Vector3(-0.15, 0.45, -2.6), Vector3(0.15, 0.45, -2.6)],
		"gun_interval": 0.025, "gun_ammo": 1000, "gun_speed": 790.0, "gun_label": "7.92 MM MG",
		"cannons": [Vector3(-2.5, -0.3, -0.5), Vector3(2.5, -0.3, -0.5)],
		"cannon_interval": 60.0 / 1040.0, "cannon_ammo": 120, "cannon_speed": 600.0, "cannon_label": "MG FF 20 MM",
		"fuel": 1000.0, "start_speed": 80.0,
		"camera": [18.0, 4.5], "hitbox": Vector3(10.0, 1.5, 9.0),
	},
	"f22": {
		"name": "Lockheed Martin F-22 Raptor", "side": "any", "free_flight_only": true,
		"short": "F-22",
		"desc": "Mach 2 scenery scout with a bottomless tank.",
		"model": "res://scenes/plane/f22/f22_model.gd",
		"model_offset": Vector3.ZERO,
		"mass": 27000.0, "wing_area": 78.0, "span": 13.6, "cd0": 0.016,
		"cl_max": 1.6, "stall_deg": 24.0,
		"engine": "jet", "thrust": 440000.0, "mcrit": 0.95,
		"g_max": 9.0, "g_tol": 7.0, "roll_max": 4.0, "pitch_auth": 10.0,
		"wheels": [Vector3(-1.7, -2.25, 1.0), Vector3(1.7, -2.25, 1.0), Vector3(0.0, -2.25, -5.6)],
		"guns": [Vector3(1.6, 0.25, -3.0)],
		"gun_interval": 0.01, "gun_ammo": 480, "gun_speed": 1050.0, "gun_label": "M61 20 MM",
		"cannons": [], "cannon_interval": 1.0, "cannon_ammo": 0, "cannon_speed": 820.0, "cannon_label": "",
		"fuel": 30000.0, "start_speed": 250.0,
		"camera": [34.0, 8.0], "hitbox": Vector3(14.0, 3.0, 19.0),
	},
}

const ORDER := ["spitfire", "hurricane", "bf109", "f22"]

## Aircraft a pilot of `side` ("raf" / "lw") may fly (the F-22 only in Free Flight)
static func for_side(side: String, free_flight := false) -> Array:
	var out : Array = []
	for k in ORDER:
		if TYPES[k].get("free_flight_only", false) and not free_flight:
			continue
		if TYPES[k].side == side or TYPES[k].side == "any":
			out.append(k)
	return out
