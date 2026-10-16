extends RefCounted
## Playable aircraft: model, flight-model values, undercarriage contact
## points, armament, fuel and camera framing.  plane.gd applies one of these
## at spawn (GameSettings.aircraft picks which).
##
## The flight model uses sea-level air density throughout, so top speed is
## roughly sqrt(2 * thrust / (1.225 * wing_area * cd0)).

const TYPES := {
	"spitfire": {
		"name": "Supermarine Spitfire Mk I",
		"short": "Spitfire",
		"desc": "Agile and fast. The RAF's thoroughbred.",
		"model": "res://scenes/plane/spitfire/spitfire_model.gd",
		"model_offset": Vector3(0, 0, -0.9),
		"mass": 3000.0, "wing_area": 22.0, "span": 11.2, "thrust": 15000.0,
		"cd0": 0.025, "stall_deg": 16.0,
		"pitch_power": 4.0, "roll_power": 6.0, "yaw_power": 1.5,
		"wheels": [Vector3(-1.6, -1.5, -2.0), Vector3(1.6, -1.5, -2.0), Vector3(0.0, -1.2, 3.8)],
		"guns": [Vector3(-4.5, 0, -0.8), Vector3(-3.0, 0, -0.8), Vector3(3.0, 0, -0.8), Vector3(4.5, 0, -0.8)],
		"gun_interval": 0.02, "gun_ammo": 2000, "gun_speed": 800.0, "gun_label": ".303 MG",
		"cannons": [Vector3(-6.0, 0, -0.5), Vector3(6.0, 0, -0.5)],
		"cannon_interval": 60.0 / 1400.0, "cannon_ammo": 150, "cannon_speed": 820.0, "cannon_label": "20 MM",
		"fuel": 1200.0, "start_speed": 80.0,
		"camera": [20.0, 5.0], "hitbox": Vector3(12.0, 1.5, 10.0),
	},
	"hurricane": {
		"name": "Hawker Hurricane Mk I",
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
	"f22": {
		"name": "Lockheed Martin F-22 Raptor",
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

const ORDER := ["spitfire", "hurricane", "f22"]
