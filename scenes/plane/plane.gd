extends Node3D
## Semi-realistic fighter flight model.  The aircraft type (model, mass,
## thrust, gear, guns, fuel...) comes from aircraft_types.gd at spawn.
##
## All physics computed manually for full control and stability.
## Uses real aerodynamic principles: lift from AoA, drag polar, weathervane
## stability, and proper damping. Tuned for a War Thunder / IL-2 feel.

## How quickly the throttle lever moves
const THROTTLE_RESPONSE := 2.0

# -- Constants --
const GRAVITY: float = 9.81
const FlightModel := preload("res://scenes/plane/flight_model.gd")

const AircraftTypes := preload("res://scenes/plane/aircraft_types.gd")

## Aircraft type key in aircraft_types.gd (set before add_child, or taken
## from GameSettings.aircraft)
var aircraft_type := ""
var aircraft_name := ""

# Wheel contact points in local space (third point: tail or nose wheel)
var WHEEL_L : Vector3 = Vector3(-1.60, -1.50, -2.0)   # left main gear
var WHEEL_R : Vector3 = Vector3( 1.60, -1.50, -2.0)   # right main gear
var WHEEL_T : Vector3 = Vector3(  0.0, -1.20,  3.8)   # tail wheel

# Gun muzzle positions in local space (2 per wing, near leading edge)
var GUN_POSITIONS: Array = [
	Vector3(-4.5, 0.0, -0.8),   # left outer
	Vector3(-3.0, 0.0, -0.8),   # left inner
	Vector3( 3.0, 0.0, -0.8),   # right inner
	Vector3( 4.5, 0.0, -0.8),   # right outer
]
var BULLET_SPEED      := 800.0   # m/s — .303 Browning muzzle velocity
var FIRE_INTERVAL     := 0.02    # seconds between shots (750 RPM × 4 guns = 50 rds/s)
var GUN_AMMO_MAX      := 2000    # total .303 rounds across all four guns
const CONVERGENCE_DIST  := 400.0   # m — historical RAF ~250 yards (229 m) standard
const GUN_SPREAD        := 0.005   # rad — ~4 mil dispersion per shot

# Hispano Mk II 20 mm cannons — one per wing
var CANNON_POSITIONS : Array = [
	Vector3(-6.0, 0.0, -0.5),   # left wing cannon
	Vector3( 6.0, 0.0, -0.5),   # right wing cannon
]
var CANNON_SPEED    := 820.0          # m/s — 20 mm shell muzzle velocity
var CANNON_INTERVAL := 60.0 / 1400.0 # s between shots (700 RPM × 2 cannons)
const CANNON_DAMAGE   := 3             # HP deducted per shell hit
var CANNON_AMMO_MAX := 150            # total 20 mm rounds (75 per cannon)

# Fuel — 1200 units = ~20 minutes at full throttle
var MAX_FUEL        := 1200.0
var gun_label := ".303 MG"
var cannon_label := "20 MM"
var camera_distance := 20.0
var camera_height := 5.0
const BASE_FUEL_DRAIN := 1.0    # units/s at throttle 1.0
const FUEL_LEAK_RATE  := 3.0    # extra units/s when fuel tank fully destroyed

var _gun_index  : int   = 0
var _fire_timer : float = 0.0
var gun_ammo    : int   = GUN_AMMO_MAX

var _cannon_index : int   = 0
var _cannon_timer : float = 0.0
var cannon_ammo   : int   = CANNON_AMMO_MAX

var fuel : float = MAX_FUEL

const ParachuteScript := preload("res://scenes/fx/parachute.gd")

## Emitted when the pilot jumps, with the parachutist (the camera follows him)
signal bailed_out(chute: Node3D)
const BAIL_TIME := 1.6           # s holding the bail-out button
var bail_progress := 0.0         # 0..1 while the button is held (HUD bar)
var _dead := false               # no pilot aboard: the aircraft flies on, uncontrolled
var _derelict_age := 0.0

const SERVICE_TIME := 6.0        # s stopped on a friendly airfield to turn the aircraft round
const FLYOVER_SERVICE_ALT := 304.8   # m (1,000 ft) above a friendly field: a low pass services the aircraft
var _service_timer := 0.0
var _rumble_timer := 0.0

var _bullet_script = preload("res://scenes/plane/bullet.gd")
const Bullet := preload("res://scenes/plane/bullet.gd")
var _gun_tilt := 0.0             # guns angled up a touch to make up for the drop at convergence
var _cannon_tilt := 0.0
var _model : Node3D = null
var _profile : Dictionary = {}

# -- Physics: the shared flight model holds the state --
var fm := FlightModel.new()
var velocity: Vector3:
	get: return fm.velocity
	set(v): fm.velocity = v
var pitch_rate: float:        # rad/s, positive = nose up
	get: return fm.pitch_rate
	set(v): fm.pitch_rate = v
var roll_rate: float:         # rad/s, positive = roll right
	get: return fm.roll_rate
	set(v): fm.roll_rate = v
var yaw_rate: float:          # rad/s, positive = nose right
	get: return fm.yaw_rate
	set(v): fm.yaw_rate = v

# -- Exposed to HUD --
var throttle: float = 0.0
var current_speed: float = 0.0
var altitude: float = 0.0
var is_stalling: bool = false
var g_force: float = 1.0
var on_ground: bool = false
var airspeed_display: float = 0.0  # forward component only, for HUD

const COMP_MAX : int = 4
var comp_hp    : Dictionary = {"wing": 4, "elevator": 4, "rudder": 4, "engine": 4, "fuel_tank": 4}
var _on_fire   : bool  = false
var _burn_timer: float = 0.0

@onready var _hitbox_body : StaticBody3D = $Hitbox

# Smoke emission
var _smoke_timer    : float = 9999.0
var _smoke_interval : float = 9999.0
var _smoke_opacity  : float = 0.0
var _smoke_puff_script = preload("res://scenes/enemies/smoke_puff.gd")
var _hit_flash_script  = preload("res://scenes/enemies/hit_flash.gd")

# -- Audio --
# Engine — procedurally generated: a V12's firing pulses (each cylinder a
# little different, which gives the rumble), the propeller's beat and wind
const _ENG_RATE := 22050.0
var _eng_player   : AudioStreamPlayer
var _eng_playback : AudioStreamGeneratorPlayback
var _eng_jet := false
var _eng_rpm := 0.0
var _eng_fire_phase := 0.0
var _eng_prop_phase := 0.0
var _eng_cyl := 0
var _eng_cyl_gain : Array[float] = []
var _eng_since := 1.0          # seconds since the last firing pulse
var _eng_pulse := 0.0
var _eng_lp := 0.0
var _eng_lp2 := 0.0
var _eng_wind := 0.0
var _eng_misfire := 0.0        # chance a cylinder fails to fire (engine damage)
var _eng_running := true
var _eng_dmg := 0.0            # 0..1 engine damage: drives the rough running below
var _eng_dead : Array[bool] = []   # cylinders that no longer fire
var _eng_dead_n := 0
var _eng_low := 0.0            # exhaust resonance (state-variable filter)
var _eng_band := 0.0
var _eng_low2 := 0.0           # second, higher body resonance
var _eng_band2 := 0.0
var _eng_dc := 0.0             # DC blocker
var _eng_cycle := 0.0          # 720° of crank: the uneven beat of the firing order
var _eng_surge := 0.0          # slow rpm hunting when the engine is hurt
var _eng_knock := 1.0          # seconds since the last knock / backfire
var _eng_bang := 1.0

# Gun audio — procedurally generated
const _GUN_MIX_RATE     := 22050.0
const _SHOT_SAMPLES     := 1985    # 90 ms at 22050 Hz  — .303 MG
const _CANNON_SAMPLES   := 3308    # 150 ms at 22050 Hz — 20 mm cannon (longer boom)

var _gun_player   : AudioStreamPlayer
var _gun_playback : AudioStreamGeneratorPlayback
var _shot_ages        : Array[int] = []   # MG shots
var _cannon_shot_ages : Array[int] = []   # cannon shots (separate synthesis)

func _ready() -> void:
	add_to_group("player")
	add_to_group("aircraft")
	add_to_group("fighters")
	add_to_group("side_" + GameSettings.side)
	_apply_profile()
	throttle = 0.7
	# Start airborne at the type's cruising speed
	velocity = -global_transform.basis.z * float(_profile.get("start_speed", 80.0))
	# Put the hitbox on layer 2 so terrain/water raycasts (mask=1) never hit it
	_hitbox_body.collision_layer = 2
	_hitbox_body.collision_mask  = 2
	_setup_engine_audio()
	_setup_gun_audio()
	_load_model()

func _apply_profile() -> void:
	if aircraft_type == "":
		aircraft_type = GameSettings.aircraft
	if not AircraftTypes.TYPES.has(aircraft_type):
		aircraft_type = "spitfire"
	_profile = AircraftTypes.TYPES[aircraft_type]
	var p := _profile
	aircraft_name = p.name
	fm.setup(p)
	fm.auto_level = 0.35         # a centred stick drifts back toward wings level
	fm.pitch_hold = 1.0          # ...and holds the climb or dive it was let go in
	WHEEL_L = p.wheels[0]
	WHEEL_R = p.wheels[1]
	WHEEL_T = p.wheels[2]
	GUN_POSITIONS = p.guns
	FIRE_INTERVAL = p.gun_interval
	GUN_AMMO_MAX = p.gun_ammo
	BULLET_SPEED = p.gun_speed
	gun_label = p.gun_label
	CANNON_POSITIONS = p.cannons
	CANNON_INTERVAL = p.cannon_interval
	CANNON_AMMO_MAX = p.cannon_ammo
	CANNON_SPEED = p.cannon_speed
	cannon_label = p.cannon_label
	_gun_tilt = Bullet.harmonise(BULLET_SPEED, Bullet.DRAG_MG, CONVERGENCE_DIST)
	_cannon_tilt = Bullet.harmonise(CANNON_SPEED, Bullet.DRAG_CANNON, CONVERGENCE_DIST)
	MAX_FUEL = p.fuel
	gun_ammo = GUN_AMMO_MAX
	cannon_ammo = CANNON_AMMO_MAX
	fuel = MAX_FUEL
	camera_distance = p.camera[0]
	camera_height = p.camera[1]
	var shape := get_node_or_null("Hitbox/HitboxShape") as CollisionShape3D
	if shape and shape.shape is BoxShape3D:
		var box := (shape.shape as BoxShape3D).duplicate() as BoxShape3D
		box.size = p.hitbox
		shape.shape = box

func get_velocity() -> Vector3:
	return velocity

## The mission treats an empty cockpit as out of the fight
func is_airborne() -> bool:
	return not _dead

## Puts the aircraft at its start: `at` is world space (for a ground start,
## `at.y` is the ground height and the wheels are set on it, tail down).
func spawn(at: Vector3, basis_: Basis, on_ground_: bool) -> void:
	var b := basis_
	if on_ground_:
		var pitch := 0.0
		if absf(WHEEL_L.z - WHEEL_T.z) > 0.01:
			pitch = atan((WHEEL_L.y - WHEEL_T.y) / (WHEEL_L.z - WHEEL_T.z))
		b = basis_ * Basis(Vector3.RIGHT, pitch)
		at.y -= (b * WHEEL_L).y - 0.02
		velocity = Vector3.ZERO
		throttle = 0.0
		on_ground = true
	else:
		velocity = -b.z * float(_profile.get("start_speed", 80.0))
	global_transform = Transform3D(b, WorldOrigin.to_scene(at))
	if _model and _model.has_method("set_gear_down"):
		_model.set_gear_down(on_ground_)

func _load_model() -> void:
	# Low-poly model built in code; offset so its wheels sit on WHEEL_L / WHEEL_R
	_model = Node3D.new()
	_model.name = _profile.short
	_model.set_script(load(_profile.model))
	_model.start_gear_up = true          # spawns airborne
	_model.position = _profile.model_offset
	add_child(_model)

func _setup_gun_audio() -> void:
	var gen := AudioStreamGenerator.new()
	gen.mix_rate      = _GUN_MIX_RATE
	gen.buffer_length = 0.05

	_gun_player = AudioStreamPlayer.new()
	_gun_player.stream    = gen
	_gun_player.volume_db = 4.0
	add_child(_gun_player)
	_gun_player.play()
	_gun_playback = _gun_player.get_stream_playback() as AudioStreamGeneratorPlayback

## Engine: synthesised on the fly (see _engine_sample), lo-fi but alive
func _setup_engine_audio() -> void:
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = _ENG_RATE
	gen.buffer_length = 0.08
	_eng_player = AudioStreamPlayer.new()
	_eng_player.stream = gen
	_eng_player.volume_db = -7.0
	add_child(_eng_player)
	_eng_player.play()
	_eng_playback = _eng_player.get_stream_playback() as AudioStreamGeneratorPlayback
	_eng_jet = aircraft_type == "f22"
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(aircraft_type)
	for i in range(12):
		_eng_cyl_gain.append(rng.randf_range(0.6, 1.25))
		_eng_dead.append(false)
	_eng_rpm = 0.0 if on_ground else _eng_rpm_target()

func _process(delta: float) -> void:
	# A damaged engine hunts: the revs wander up and down
	_eng_surge = clampf(_eng_surge + randf_range(-1.0, 1.0) * delta * 6.0 - _eng_surge * delta * 0.8, -1.0, 1.0)
	var target := _eng_rpm_target()
	if _eng_running:
		target += _eng_surge * _eng_dmg * 450.0
	_eng_rpm = lerpf(_eng_rpm, target, minf(1.0, 1.6 * delta))
	_push_engine_audio()
	_push_gun_audio()

	# Smoke emission — only when damaged
	if _smoke_interval < 9999.0:
		_smoke_timer -= delta
		if _smoke_timer <= 0.0:
			_smoke_timer = _smoke_interval
			_spawn_smoke_puff()

	# Fire — drains one random component HP per second until the plane is dead
	if _on_fire:
		_burn_timer += delta
		if _burn_timer >= 1.0:
			_burn_timer -= 1.0
			var fire_comps := ["wing", "elevator", "rudder", "engine", "fuel_tank"]
			var fc : String = fire_comps.pick_random()
			if comp_hp[fc] > 0:
				comp_hp[fc] -= 1
			_smoke_opacity  = 1.0
			_smoke_interval = 0.05
			_smoke_timer    = minf(_smoke_timer, 0.05)

## Crankshaft rpm the engine is heading for (windmilling when it has stopped)
func _eng_rpm_target() -> float:
	var eng_ok : bool = comp_hp["engine"] > 0 and fuel > 0.0 and not _dead
	_eng_running = eng_ok
	_eng_dmg = float(COMP_MAX - comp_hp["engine"]) / float(COMP_MAX)
	_eng_misfire = _eng_dmg * 0.22
	# Each hit kills another cylinder or two: the beat goes lumpy
	var dead_n := int(round(_eng_dmg * 5.0))
	if dead_n != _eng_dead_n:
		_eng_dead_n = dead_n
		var order := [3, 9, 6, 0, 10, 4, 1, 7, 11, 2, 5, 8]
		for i in range(12):
			_eng_dead[order[i]] = i < dead_n
	if not eng_ok:
		return clampf(airspeed_display * 12.0, 0.0, 1400.0)
	return lerpf(950.0, 3000.0, throttle) + clampf(airspeed_display - 60.0, 0.0, 120.0) * 2.0

## Piston engine: twelve exhaust pulses per two turns of the crank, each
## ringing a low exhaust resonance; the cylinders' uneven strength gives the
## deep, lumpy beat under the drone.  Damage kills cylinders, adds misfires,
## knocking and backfires.  The F-22 gets a turbofan roar instead.
func _push_engine_audio() -> void:
	if not _eng_playback:
		return
	var frames := _eng_playback.get_frames_available()
	if frames <= 0:
		return
	var dt := 1.0 / _ENG_RATE
	var crank := _eng_rpm / 60.0                     # rev/s
	var fire_rate := crank * 6.0 if _eng_running else 0.0   # 12 cylinders, 4-stroke
	var blade_rate := crank * 0.477 * 3.0            # reduction gear, three blades
	var load := 0.35 + 0.65 * throttle
	var a1 := 1.0 - exp(-TAU * lerpf(240.0, 650.0, throttle) * dt)
	var a2 := 1.0 - exp(-TAU * 140.0 * dt)
	# Exhaust resonance, a little higher with the revs
	var rev := clampf(_eng_rpm / 3000.0, 0.0, 1.2)
	var f_res := 2.0 * sin(PI * (70.0 + 50.0 * rev) * dt)
	var f_res2 := 2.0 * sin(PI * (170.0 + 90.0 * rev) * dt)
	var q_res := 0.45
	var a_dc := 1.0 - exp(-TAU * 25.0 * dt)
	var wind_amt := clampf(airspeed_display / 160.0, 0.0, 1.0)
	wind_amt *= wind_amt
	var prop_amt := clampf(_eng_rpm / 3000.0, 0.0, 1.0)
	var d := _eng_dmg if _eng_running else 0.0
	# Backfires: rare at first, frequent when the engine is badly hurt
	if _eng_running and randf() < d * d * 1.6 * frames * dt:
		_eng_bang = 0.0
	for _i in range(frames):
		var n := randf() * 2.0 - 1.0
		var x := 0.0
		if _eng_jet:
			# Turbofan: a deep roar with a faint whine
			_eng_lp += a1 * (n - _eng_lp)
			_eng_lp2 += a2 * (_eng_lp - _eng_lp2)
			_eng_prop_phase = fmod(_eng_prop_phase + crank * 1.4 * dt, 1.0)
			x = (_eng_lp * 1.4 + _eng_lp2 * 3.0) * load + sin(TAU * _eng_prop_phase) * 0.05 * prop_amt
		else:
			_eng_fire_phase += fire_rate * dt
			if _eng_fire_phase >= 1.0:
				_eng_fire_phase -= 1.0
				_eng_cyl = (_eng_cyl + 1) % 12
				_eng_since = 0.0
				var fires := not _eng_dead[_eng_cyl] and randf() >= _eng_misfire
				_eng_pulse = _eng_cyl_gain[_eng_cyl] if fires else 0.0
				if fires and randf() < d * 0.5:
					_eng_knock = 0.0
			_eng_since += dt
			_eng_cycle = fmod(_eng_cycle + crank * 0.5 * dt, 1.0)
			# Exhaust pulse: a soft ~6 ms thump that rings the resonance
			var env := exp(-_eng_since * 170.0) * _eng_pulse
			var exc := env * (0.65 + 0.35 * n)
			var hi := exc - _eng_low - q_res * _eng_band
			_eng_band += f_res * hi
			_eng_low += f_res * _eng_band
			var hi2 := exc - _eng_low2 - 0.6 * _eng_band2
			_eng_band2 += f_res2 * hi2
			_eng_low2 += f_res2 * _eng_band2
			_eng_lp += a1 * (exc - _eng_lp)
			var body := _eng_low * 2.2 + _eng_band * 0.9 + _eng_band2 * 1.3 + _eng_lp * 0.9
			# Firing-order beat under the drone
			var beat := sin(TAU * _eng_cycle) * 0.22 + sin(TAU * _eng_cycle * 2.0 + 0.6) * 0.14
			x = (body * 3.0 + beat * (0.4 + 0.6 * prop_amt)) * load
			# Propeller: air chopped by the blades
			_eng_prop_phase = fmod(_eng_prop_phase + blade_rate * dt, 1.0)
			var chop := 0.5 + 0.5 * sin(TAU * _eng_prop_phase)
			_eng_lp2 += a2 * (n - _eng_lp2)
			x += _eng_lp2 * chop * chop * 1.6 * prop_amt
			# Damage: rattle, knocking, backfires
			if d > 0.0:
				x += _eng_lp2 * d * 0.35 * (0.5 + 0.5 * sin(TAU * _eng_cycle * 6.0))
				_eng_knock += dt
				x += sin(TAU * 1450.0 * _eng_knock) * exp(-_eng_knock * 500.0) * 0.9 * d
			if _eng_bang < 0.12:
				_eng_bang += dt
				var be := exp(-_eng_bang * 35.0)
				x += (n * 0.9 + sin(TAU * 55.0 * _eng_bang) * 1.4) * be * 1.6
		# Wind over the airframe rises with speed
		_eng_wind += 0.08 * (n - _eng_wind)
		x += _eng_wind * wind_amt * 0.5
		_eng_dc += a_dc * (x - _eng_dc)
		x -= _eng_dc
		x = x / (1.0 + absf(x))                       # soft clip
		_eng_playback.push_frame(Vector2(x, x) * 0.85)

func _push_gun_audio() -> void:
	if not _gun_playback:
		return
	var to_fill := _gun_playback.get_frames_available()
	for _i in range(to_fill):
		var sample := 0.0

		# .303 MG — high crack, short decay
		for j in range(_shot_ages.size() - 1, -1, -1):
			var t : float = float(_shot_ages[j]) / _GUN_MIX_RATE
			sample += (randf() * 2.0 - 1.0) * exp(-t * 500.0) * 4.0   # muzzle crack
			sample += sin(TAU * 90.0  * t) * exp(-t * 33.0)  * 3.0    # 90 Hz boom
			sample += sin(TAU * 500.0 * t) * exp(-t * 100.0) * 1.2    # 500 Hz ring
			_shot_ages[j] += 1
			if _shot_ages[j] >= _SHOT_SAMPLES:
				_shot_ages.remove_at(j)

		# 20 mm cannon — deep boom, longer decay
		for j in range(_cannon_shot_ages.size() - 1, -1, -1):
			var t : float = float(_cannon_shot_ages[j]) / _GUN_MIX_RATE
			sample += (randf() * 2.0 - 1.0) * exp(-t * 180.0) * 6.0   # heavy crack
			sample += sin(TAU * 42.0  * t) * exp(-t * 10.0)  * 6.0    # 42 Hz deep thump
			sample += sin(TAU * 180.0 * t) * exp(-t * 40.0)  * 2.5    # 180 Hz mid ring
			_cannon_shot_ages[j] += 1
			if _cannon_shot_ages[j] >= _CANNON_SAMPLES:
				_cannon_shot_ages.remove_at(j)

		_gun_playback.push_frame(Vector2(clampf(sample * 0.3, -1.0, 1.0),
										 clampf(sample * 0.3, -1.0, 1.0)))

func take_hit(hit_pos: Vector3, damage: int = 1, _source: Node = null) -> void:
	var flash := Node3D.new()
	flash.set_script(_hit_flash_script)
	flash.size = float(damage)
	get_parent().add_child(flash)
	flash.global_position = hit_pos

	var comps := ["wing", "elevator", "rudder", "engine", "fuel_tank"]
	var c : String = comps.pick_random()
	comp_hp[c] = maxi(comp_hp[c] - damage, 0)

	if c == "fuel_tank" and not _on_fire and randf() < 0.01:
		_on_fire = true

	var total_hp := 0
	for v in comp_hp.values():
		total_hp += v
	var damage_ratio := 1.0 - float(total_hp) / float(COMP_MAX * 5)
	_smoke_opacity  = damage_ratio
	_smoke_interval = lerpf(2.0, 0.08, damage_ratio)
	_smoke_timer    = minf(_smoke_timer, _smoke_interval)

func _spawn_smoke_puff() -> void:
	var puff := Node3D.new()
	puff.set_script(_smoke_puff_script)
	puff.dark    = true
	puff.opacity = _smoke_opacity
	get_parent().add_child(puff)
	puff.global_position = global_position + Vector3(0.0, -0.5, 0.0)

func _physics_process(delta: float) -> void:
	# ========================
	# INPUT
	# ========================
	var pitch_input := Input.get_axis("pitch_up", "pitch_down")
	var roll_input := Input.get_axis("roll_right", "roll_left")
	var yaw_input := Input.get_axis("yaw_left", "yaw_right")
	var throttle_up := Input.get_action_strength("throttle_up")
	var throttle_down := Input.get_action_strength("throttle_down")
	if _dead:
		# Abandoned: the engine winds down and she drops into a slow spiral
		pitch_input = -0.06
		roll_input = 0.3
		yaw_input = 0.0
		throttle_up = 0.0
		throttle_down = 0.0
		throttle = maxf(throttle - 0.5 * delta, 0.0)
		_derelict_age += delta
		if _derelict_age > 120.0:
			queue_free()
			return
	else:
		_update_bail(delta)

	throttle = clampf(throttle + (throttle_up - throttle_down) * THROTTLE_RESPONSE * delta, 0.0, 1.0)
	if _model:
		# roll_input is inverted (see ROLL below): -roll_input = roll right
		_model.set_controls(pitch_input, -roll_input, yaw_input, throttle)

	# ========================
	# GUNS & CANNON
	# ========================
	_fire_timer = maxf(_fire_timer - delta, 0.0)
	if not _dead and Input.is_action_pressed("fire") and _fire_timer == 0.0 and gun_ammo > 0:
		_fire_next_gun()
		_fire_timer = FIRE_INTERVAL

	_cannon_timer = maxf(_cannon_timer - delta, 0.0)
	if not _dead and Input.is_action_pressed("fire_cannon") and _cannon_timer == 0.0 and cannon_ammo > 0:
		_fire_cannon()
		_cannon_timer = CANNON_INTERVAL

	# ========================
	# FLIGHT MODEL
	# ========================
	var wing_dmg  : float = float(COMP_MAX - comp_hp["wing"])     / float(COMP_MAX)
	var elev_dmg  : float = float(COMP_MAX - comp_hp["elevator"]) / float(COMP_MAX)
	var rudd_dmg  : float = float(COMP_MAX - comp_hp["rudder"])   / float(COMP_MAX)
	var eng_dmg   : float = float(COMP_MAX - comp_hp["engine"])   / float(COMP_MAX)
	var fuel_tank_dmg : float = float(COMP_MAX - comp_hp["fuel_tank"]) / float(COMP_MAX)
	fuel = maxf(fuel - (BASE_FUEL_DRAIN * throttle + FUEL_LEAK_RATE * fuel_tank_dmg) * delta, 0.0)
	fm.dmg_wing = wing_dmg
	fm.dmg_elev = elev_dmg
	fm.dmg_rudder = rudd_dmg
	fm.power_scale = (1.0 - eng_dmg) * (1.0 if fuel > 0.0 else 0.0)
	# roll_input is inverted (user-swapped axis): -roll_input = roll right
	fm.step(self, delta, pitch_input, -roll_input, yaw_input, throttle, NAN, on_ground)

	current_speed = fm.tas
	airspeed_display = maxf(velocity.dot(-global_transform.basis.z), 0.0) * sqrt(fm.rho / FlightModel.RHO0)
	altitude = global_position.y
	is_stalling = fm.is_stalling
	g_force = fm.g_force
	var right: Vector3 = global_transform.basis.x
	_feedback(delta)

	# ========================
	# GROUND / GEAR
	# ========================
	# The frame the floating origin moves, the physics server still has the
	# old collision positions: skip ground contact rather than hit stale terrain
	if WorldOrigin.last_shift_frame == Engine.get_physics_frames():
		return
	var wl := global_transform * WHEEL_L
	var wr := global_transform * WHEEL_R
	var wt := global_transform * WHEEL_T

	# Terrain height directly below each wheel via physics raycast
	var space := get_world_3d().direct_space_state
	var gnd_l := _terrain_y(wl, space)
	var gnd_r := _terrain_y(wr, space)
	var gnd_t := _terrain_y(wt, space)

	# Penetration depth: positive means the wheel is below the terrain surface
	var pen_l := gnd_l - wl.y
	var pen_r := gnd_r - wr.y
	var pen_t := gnd_t - wt.y
	var max_pen := maxf(pen_l, maxf(pen_r, pen_t))

	on_ground = max_pen > -0.05

	if on_ground:
		# Push the plane up by the deepest penetration
		if max_pen > 0.0:
			# 15 mph ≈ 6.7 m/s downward — high-speed ground impact is fatal
			if velocity.y < -6.7:
				_crash()
				return
			global_position.y += max_pen
			if velocity.y < 0.0:
				velocity.y = 0.0
			# Recompute after push
			wl = global_transform * WHEEL_L
			wr = global_transform * WHEEL_R
			wt = global_transform * WHEEL_T
			gnd_l = _terrain_y(wl, space)
			gnd_r = _terrain_y(wr, space)
			gnd_t = _terrain_y(wt, space)
			pen_l = gnd_l - wl.y
			pen_r = gnd_r - wr.y
			pen_t = gnd_t - wt.y

		# ---- Roll spring ----
		# Compare each main wheel's height above its local terrain.
		var roll_err := (wl.y - gnd_l) - (wr.y - gnd_r)
		roll_rate += -roll_err * 25.0 * delta

		# ---- Pitch spring ----
		var main_above := ((wl.y - gnd_l) + (wr.y - gnd_r)) * 0.5
		var tail_above := wt.y - gnd_t
		var pitch_err  := main_above - tail_above
		# The third wheel may be a tail wheel (behind) or a nose wheel (ahead)
		pitch_rate += -pitch_err * 8.0 * delta * signf(WHEEL_T.z)

		# Heavy angular damping on the ground (landing gear absorbs oscillation)
		roll_rate  *= maxf(0.0, 1.0 - 12.0 * delta)
		pitch_rate *= maxf(0.0, 1.0 -  6.0 * delta)
		yaw_rate   *= maxf(0.0, 1.0 -  8.0 * delta)

		# ---- Tail (or nose) wheel steering ----
		# The rudder pedals turn the wheel while it's on the ground.  Turn rate
		# follows speed (a ~10 m turning circle), with a little help from prop
		# wash and brakes at a crawl.  It fades out as the tail lifts and the
		# rudder takes over aerodynamically.
		var spd := velocity.length()
		var wheel_down := pen_t > -0.15
		var steer_w := (1.0 - smoothstep(25.0, 45.0, spd)) * (1.0 if wheel_down else 0.0)
		if steer_w > 0.0:
			var crawl := maxf(spd, throttle * 4.0)
			var steer := yaw_input * minf(crawl / 10.0, 0.6) * (1.0 - rudd_dmg * 0.5)
			yaw_rate = lerpf(yaw_rate, steer, minf(1.0, 10.0 * delta) * steer_w)

		# Wheels constrain sideways sliding: the tyres turn the velocity with
		# the nose rather than scrubbing it away, so a taxiing turn keeps its speed
		var lat_vel := velocity.dot(right)
		var hspeed := Vector2(velocity.x, velocity.z).length()
		velocity -= right * lat_vel * minf(1.0, 15.0 * delta)
		var hnew := Vector2(velocity.x, velocity.z).length()
		if hnew > 0.01 and absf(lat_vel) < hspeed * 0.5:
			velocity.x *= hspeed / hnew
			velocity.z *= hspeed / hnew

		# Rolling resistance + wheel brakes.
		# Holding throttle_down on the ground applies brakes (μ up to ~0.5).
		var brake_mu := lerpf(0.03, 0.5, throttle_down)
		var friction_decel := GRAVITY * brake_mu * delta
		if velocity.length() > friction_decel:
			velocity -= velocity.normalized() * friction_decel
		else:
			velocity = Vector3.ZERO
	_service(delta)

## The buffet (stall, spin, compressibility) through the pad's motors
func _feedback(delta: float) -> void:
	_rumble_timer -= delta
	if _rumble_timer > 0.0:
		return
	_rumble_timer = 0.1
	var b := 0.0 if _dead else fm.buffet
	if b > 0.05 and not Input.get_connected_joypads().is_empty():
		Input.start_joy_vibration(0, b * 0.5, b * 0.3, 0.15)

## Hit the ground too hard: a fireball where she went in
func _crash() -> void:
	var smoke := get_tree().get_first_node_in_group("smoke_field")
	if smoke:
		var w := WorldOrigin.to_world(global_position)
		smoke.explosion(global_position, 0.7, w.y < 2.0)
	queue_free()

## Holding the bail-out button fills a bar; letting go early cancels
func _update_bail(delta: float) -> void:
	if not Input.is_action_pressed("bail_out"):
		bail_progress = 0.0
		return
	bail_progress = minf(bail_progress + delta / BAIL_TIME, 1.0)
	if bail_progress >= 1.0:
		_bail_out()

func _bail_out() -> void:
	_dead = true
	bail_progress = 0.0
	_service_timer = 0.0
	for g in ["player", "fighters", "side_" + GameSettings.side]:
		remove_from_group(g)
	var b := global_transform.basis
	var chute := Node3D.new()
	chute.set_script(ParachuteScript)
	chute.suit = Color(0.36, 0.40, 0.46) if GameSettings.side == "raf" else Color(0.42, 0.40, 0.34)
	# Out over the side, thrown up and back by the slipstream
	chute.velocity = velocity * 0.55 + b.y * 4.0 + b.x * 2.0
	get_parent().add_child(chute)
	chute.global_position = global_position + b.y * 1.6 + b.x * 0.8
	chute.rotation.y = rotation.y
	_say("You bailed out.")
	get_tree().call_group("mission", "on_player_bailed", chute)
	bailed_out.emit(chute)

## Ground crew: stopped on a friendly airfield, the aircraft is repaired,
## refuelled and rearmed after a short turnaround.  A low pass over the field
## (under 1,000 ft) does the same instantly, so a damaged pilot can get back
## into the fight before the raid is over.
func _service(delta: float) -> void:
	if _dead:
		return
	if not on_ground and _needs_service():
		var field := _friendly_field()
		if field >= 0:
			var m := get_tree().get_first_node_in_group("mission")
			if global_position.y - float(m.geo.airfields[field][3]) < FLYOVER_SERVICE_ALT:
				_restore()
				_say("Low pass over %s - repaired, refuelled and rearmed" % m.geo.airfields[field][0])
		return
	var stopped := on_ground and velocity.length() < 0.5
	if not stopped or not _needs_service():
		if _service_timer > 0.0 and not stopped:
			_say("Ground crew: servicing abandoned")
		_service_timer = 0.0
		return
	if _service_timer == 0.0:
		if not _at_friendly_field():
			return
		_say("Ground crew: repairing, refuelling and rearming")
	_service_timer += delta
	if _service_timer < SERVICE_TIME:
		return
	_service_timer = 0.0
	_restore()
	_say("Aircraft serviced - ready for take-off")

## Back to a fresh aircraft: undamaged, fire out, full tanks and magazines
func _restore() -> void:
	for c in comp_hp:
		comp_hp[c] = COMP_MAX
	_on_fire = false
	_burn_timer = 0.0
	_smoke_opacity = 0.0
	_smoke_interval = 9999.0
	_smoke_timer = 9999.0
	fuel = MAX_FUEL
	gun_ammo = GUN_AMMO_MAX
	cannon_ammo = CANNON_AMMO_MAX

## Direction the guns point (the boresight, tilted up for harmonisation)
func gun_axis() -> Vector3:
	return global_transform.basis * Vector3(0.0, sin(_gun_tilt), -cos(_gun_tilt))

func _needs_service() -> bool:
	if fuel < MAX_FUEL - 1.0 or gun_ammo < GUN_AMMO_MAX or cannon_ammo < CANNON_AMMO_MAX or _on_fire:
		return true
	for v in comp_hp.values():
		if v < COMP_MAX:
			return true
	return false

func _at_friendly_field() -> bool:
	return _friendly_field() >= 0

## Index of the friendly airfield below the aircraft, or -1
func _friendly_field() -> int:
	var m := get_tree().get_first_node_in_group("mission")
	if m == null or m.get("geo") == null:
		return -1
	var id : int = m.geo.airfield_at(WorldOrigin.world_x(global_position.x), WorldOrigin.world_z(global_position.z))
	return id if id >= 0 and m.geo.airfields[id][1] == GameSettings.side else -1

func _say(text: String) -> void:
	var m := get_tree().get_first_node_in_group("mission")
	if m and m.has_method("_say"):
		m._say(text)

## Spawns one tracer from the next gun in the rotation and advances the index.
func _fire_next_gun() -> void:
	var gun_local    : Vector3 = GUN_POSITIONS[_gun_index]
	var muzzle_world : Vector3 = global_transform * gun_local
	_gun_index = (_gun_index + 1) % GUN_POSITIONS.size()
	gun_ammo -= 1

	var aim_local : Vector3 = Vector3(-gun_local.x, 0.0, -CONVERGENCE_DIST).normalized().rotated(Vector3.RIGHT, _gun_tilt)
	var aim_world : Vector3 = global_transform.basis * aim_local
	aim_world = (aim_world
		+ global_transform.basis.x * randf_range(-GUN_SPREAD, GUN_SPREAD)
		+ global_transform.basis.y * randf_range(-GUN_SPREAD, GUN_SPREAD)).normalized()

	var bullet := Node3D.new()
	bullet.set_script(_bullet_script)
	bullet.velocity     = velocity + aim_world * BULLET_SPEED
	bullet.shooter      = self
	bullet.exclude_rids = [_hitbox_body.get_rid()]
	get_parent().add_child(bullet)
	bullet.global_position = muzzle_world

	if _gun_playback:
		_shot_ages.append(0)

## Fires one 20 mm cannon shell from the next cannon in the rotation.
func _fire_cannon() -> void:
	var gun_local    : Vector3 = CANNON_POSITIONS[_cannon_index]
	var muzzle_world : Vector3 = global_transform * gun_local
	_cannon_index = (_cannon_index + 1) % CANNON_POSITIONS.size()
	cannon_ammo -= 1

	var aim_local : Vector3 = Vector3(-gun_local.x, 0.0, -CONVERGENCE_DIST).normalized().rotated(Vector3.RIGHT, _cannon_tilt)
	var aim_world : Vector3 = global_transform.basis * aim_local
	aim_world = (aim_world
		+ global_transform.basis.x * randf_range(-GUN_SPREAD, GUN_SPREAD)
		+ global_transform.basis.y * randf_range(-GUN_SPREAD, GUN_SPREAD)).normalized()

	var bullet := Node3D.new()
	bullet.set_script(_bullet_script)
	bullet.damage       = CANNON_DAMAGE
	bullet.drag_k       = Bullet.DRAG_CANNON
	bullet.shooter      = self
	bullet.velocity     = velocity + aim_world * CANNON_SPEED
	bullet.exclude_rids = [_hitbox_body.get_rid()]
	get_parent().add_child(bullet)
	bullet.global_position = muzzle_world

	if _gun_playback:
		_cannon_shot_ages.append(0)

## Returns the terrain height directly below world_pos using a downward raycast.
## Falls back to 0 if nothing is hit (e.g. outside the terrain bounds).
func _terrain_y(world_pos: Vector3, space: PhysicsDirectSpaceState3D) -> float:
	var query := PhysicsRayQueryParameters3D.create(
		Vector3(world_pos.x, 2000.0, world_pos.z),
		Vector3(world_pos.x,  -50.0, world_pos.z))
	query.collision_mask = 1  # terrain and water only — never hits plane hitboxes (layer 2)
	var hit := space.intersect_ray(query)
	return hit.position.y if hit else 0.0
