extends RefCounted
## Playable aircraft: model, flight-model values, undercarriage contact
## points, armament, fuel and camera framing.  plane.gd applies one of these
## at spawn (GameSettings.aircraft picks which).
##
## The flight model uses sea-level air density throughout, so top speed is
## roughly sqrt(2 * thrust / (1.225 * wing_area * cd0)).

const TYPES := {
	"spitfire": {
		"name": "Supermarine Spitfire Mk I", "side": "raf",
		"short": "Spitfire",
		"desc": "Agile and fast. The RAF's thoroughbred.",
		"model": "res://scenes/plane/spitfire/spitfire_model.gd",
		"model_offset": Vector3(0, 0, -0.9),
		"mass": 3000.0, "wing_area": 22.0, "span": 11.2, "thrust": 15000.0,
		"cd0": 0.025, "stall_deg": 16.0,
		"pitch_power": 4.0, "roll_power": 6.0, "yaw_power": 1.5,
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
		"mass": 3200.0, "wing_area": 23.9, "span": 12.2, "thrust": 14200.0,
		"cd0": 0.027, "stall_deg": 17.0,
		"pitch_power": 3.8, "roll_power": 5.0, "yaw_power": 1.6,
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
		"mass": 2600.0, "wing_area": 16.2, "span": 9.9, "thrust": 12500.0,
		"cd0": 0.026, "stall_deg": 16.0,
		"pitch_power": 3.8, "roll_power": 5.5, "yaw_power": 1.5,
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
		"mass": 27000.0, "wing_area": 78.0, "span": 13.6, "thrust": 440000.0,
		"cd0": 0.016, "stall_deg": 24.0,
		"pitch_power": 3.5, "roll_power": 8.0, "yaw_power": 1.2,
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
