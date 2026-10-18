extends Node3D
## Semi-realistic fighter flight model.  The aircraft type (model, mass,
## thrust, gear, guns, fuel...) comes from aircraft_types.gd at spawn.
##
## All physics computed manually for full control and stability.
## Uses real aerodynamic principles: lift from AoA, drag polar, weathervane
## stability, and proper damping. Tuned for a War Thunder / IL-2 feel.

# -- Aircraft specs --
@export_group("Aircraft")
## Aircraft mass in kg (Spitfire Mk V loaded)
@export var aircraft_mass: float = 3000.0
## Wing area in m²
@export var wing_area: float = 22.0
## Wing span in m (used for aspect ratio)
@export var wing_span: float = 11.2
## Max engine thrust in Newtons (~1,200 hp Merlin engine)
@export var max_thrust: float = 15000.0
## How quickly throttle responds
@export var throttle_response: float = 2.0

@export_group("Control Sensitivity")
## Pitch rate authority (rad/s² at cruise speed)
@export var pitch_power: float = 4.0
## Roll rate authority
@export var roll_power: float = 6.0
## Yaw rate authority (rudder is weaker than ailerons)
@export var yaw_power: float = 1.5

@export_group("Stability & Damping")
## Pitch stability — tail pushes nose toward velocity (reduces AoA)
@export var pitch_stability: float = 1.0
## Yaw stability — vertical tail fin keeps nose aligned with velocity
@export var yaw_stability: float = 5.0
## Dihedral effect — sideslip causes corrective roll
@export var dihedral_effect: float = 2.0
## Pitch angular damping
@export var pitch_damping: float = 3.5
## Roll angular damping
@export var roll_damping: float = 4.0
## Yaw angular damping
@export var yaw_damping: float = 4.0
## Auto-level strength (gently rolls toward wings-level with no input)
@export var auto_level: float = 0.5

# -- Constants --
const AIR_DENSITY: float = 1.225  # kg/m³ at sea level
const GRAVITY: float = 9.81

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
var _service_timer := 0.0

var _bullet_script = preload("res://scenes/plane/bullet.gd")
var _model : Node3D = null
var _profile : Dictionary = {}

# -- Aero coefficients --
## Lift curve slope per radian (typical finite wing)
var cl_slope: float = 5.0
## Lift coefficient at zero angle of attack (cambered airfoil)
var cl_0: float = 0.15
## Parasitic drag coefficient (clean WW2 fighter)
var cd_0: float = 0.025
## Oswald span efficiency factor
var oswald: float = 0.78
## Wing aspect ratio (computed in _ready)
var aspect_ratio: float
## Critical angle of attack in degrees
var stall_alpha_deg: float = 16.0

# -- Physics state --
var velocity: Vector3 = Vector3.ZERO
var pitch_rate: float = 0.0   # rad/s, positive = nose up
var roll_rate: float = 0.0    # rad/s, positive = roll right (clockwise from behind)
var yaw_rate: float = 0.0     # rad/s, positive = nose right

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
	aspect_ratio = wing_span * wing_span / wing_area
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
	aircraft_mass = p.mass
	wing_area = p.wing_area
	wing_span = p.span
	max_thrust = p.thrust
	cd_0 = p.cd0
	stall_alpha_deg = p.stall_deg
	pitch_power = p.pitch_power
	roll_power = p.roll_power
	yaw_power = p.yaw_power
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
		_eng_cyl_gain.append(rng.randf_range(0.7, 1.15))
	_eng_rpm = 0.0 if on_ground else _eng_rpm_target()

func _process(delta: float) -> void:
	_eng_rpm = lerpf(_eng_rpm, _eng_rpm_target(), minf(1.0, 1.6 * delta))
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
	_eng_misfire = float(COMP_MAX - comp_hp["engine"]) / float(COMP_MAX) * 0.35
	if not eng_ok:
		return clampf(airspeed_display * 12.0, 0.0, 1400.0)
	return lerpf(950.0, 3000.0, throttle) + clampf(airspeed_display - 60.0, 0.0, 120.0) * 2.0

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
	var cutoff := lerpf(420.0, 1500.0, throttle)
	var a1 := 1.0 - exp(-TAU * cutoff * dt)
	var a2 := 1.0 - exp(-TAU * 160.0 * dt)
	var wind_amt := clampf(airspeed_display / 160.0, 0.0, 1.0)
	wind_amt *= wind_amt
	var prop_amt := clampf(_eng_rpm / 3000.0, 0.0, 1.0)
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
				_eng_pulse = 0.0 if randf() < _eng_misfire else _eng_cyl_gain[_eng_cyl]
			_eng_since += dt
			# Each firing: a sharp exhaust bark that dies away in ~2 ms
			var env := exp(-_eng_since * 520.0) * _eng_pulse
			var bark := env * (0.75 + 0.6 * n)
			_eng_lp += a1 * (bark * 2.4 - _eng_lp)
			# Propeller: air chopped by the blades
			_eng_prop_phase = fmod(_eng_prop_phase + blade_rate * dt, 1.0)
			var chop := 0.5 + 0.5 * sin(TAU * _eng_prop_phase)
			_eng_lp2 += a2 * (n - _eng_lp2)
			x = _eng_lp * load + _eng_lp2 * chop * chop * 2.2 * prop_amt
		# Wind over the airframe rises with speed
		_eng_wind += 0.08 * (n - _eng_wind)
		x += _eng_wind * wind_amt * 0.5
		x = x / (1.0 + absf(x))                       # soft clip
		_eng_playback.push_frame(Vector2(x, x) * 0.8)

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
	var stick_sensitivity: float = 0.5
	var pitch_input := Input.get_axis("pitch_up", "pitch_down") * stick_sensitivity
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

	throttle = clampf(throttle + (throttle_up - throttle_down) * throttle_response * delta, 0.0, 1.0)
	if _model:
		# roll_input is inverted (see ROLL below): -roll_input = roll right
		_model.set_controls(pitch_input / stick_sensitivity, -roll_input, yaw_input, throttle)

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
	# AIRCRAFT AXES
	# ========================
	var fwd: Vector3 = -global_transform.basis.z   # nose direction
	var up: Vector3 = global_transform.basis.y      # wing top direction
	var right: Vector3 = global_transform.basis.x   # right wing direction

	# ========================
	# AIRSPEED & ALTITUDE
	# ========================
	current_speed = velocity.length()
	airspeed_display = maxf(velocity.dot(fwd), 0.0)
	altitude = global_position.y

	# Velocity decomposed into aircraft body frame
	var vel_fwd: float = velocity.dot(fwd)
	var vel_up: float = velocity.dot(up)
	var vel_right: float = velocity.dot(right)

	# ========================
	# ANGLE OF ATTACK & SIDESLIP
	# ========================
	var alpha: float = 0.0   # angle of attack (positive = nose above velocity)
	var beta: float = 0.0    # sideslip angle

	if current_speed > 3.0:
		alpha = atan2(-vel_up, maxf(vel_fwd, 3.0))
		beta = atan2(vel_right, maxf(vel_fwd, 3.0))

	# ========================
	# DYNAMIC PRESSURE
	# ========================
	var q: float = 0.5 * AIR_DENSITY * current_speed * current_speed
	var qS: float = q * wing_area

	# Control effectiveness scales with airspeed (normalized to ~290 km/h cruise)
	var q_ref: float = 0.5 * AIR_DENSITY * 80.0 * 80.0
	var effectiveness: float = clampf(q / q_ref, 0.0, 1.5)

	# ========================
	# LIFT
	# ========================
	var stall_alpha: float = deg_to_rad(stall_alpha_deg)
	var cl: float

	if absf(alpha) < stall_alpha:
		# Normal flight: lift increases linearly with AoA
		cl = cl_0 + cl_slope * alpha
	else:
		# Post-stall: lift drops gradually (not a cliff — more forgiving)
		var cl_at_stall: float = cl_0 + cl_slope * stall_alpha * signf(alpha)
		var excess: float = absf(alpha) - stall_alpha
		cl = cl_at_stall * maxf(1.0 - excess * 2.0, 0.2)

	is_stalling = absf(alpha) > stall_alpha and current_speed > 5.0

	# Per-component damage factors (0.0 = healthy, 1.0 = destroyed)
	var wing_dmg  : float = float(COMP_MAX - comp_hp["wing"])     / float(COMP_MAX)
	var elev_dmg  : float = float(COMP_MAX - comp_hp["elevator"]) / float(COMP_MAX)
	var rudd_dmg  : float = float(COMP_MAX - comp_hp["rudder"])   / float(COMP_MAX)
	var eng_dmg   : float = float(COMP_MAX - comp_hp["engine"])   / float(COMP_MAX)
	var lift_mult     : float = 1.0 - wing_dmg * 0.90    # wing: 10 % lift remains at 0 HP
	var thrust_factor : float = 1.0 - eng_dmg            # engine: thrust → 0 when gone
	var lift_force: Vector3 = up * qS * cl * lift_mult

	# ========================
	# DRAG (parasitic + induced)
	# ========================
	var cd: float = cd_0 + (cl * cl) / (PI * aspect_ratio * oswald)
	# Post-stall: separated flow produces flat-plate drag far beyond polar prediction
	if absf(alpha) > stall_alpha:
		cd += (absf(alpha) - stall_alpha) * 1.8
	var drag_force: Vector3 = Vector3.ZERO
	if current_speed > 1.0:
		drag_force = -velocity.normalized() * qS * cd

	# ========================
	# SIDE FORCE (fuselage resists sideways motion)
	# ========================
	var side_force: Vector3 = -right * qS * beta * 0.5

	# ========================
	# FUEL
	# ========================
	var fuel_tank_dmg : float = float(COMP_MAX - comp_hp["fuel_tank"]) / float(COMP_MAX)
	fuel = maxf(fuel - (BASE_FUEL_DRAIN * throttle + FUEL_LEAK_RATE * fuel_tank_dmg) * delta, 0.0)

	# ========================
	# THRUST
	# ========================
	var fuel_factor   : float = 1.0 if fuel > 0.0 else 0.0
	var thrust_force: Vector3 = fwd * max_thrust * throttle * thrust_factor * fuel_factor

	# ========================
	# GRAVITY
	# ========================
	var weight: Vector3 = Vector3.DOWN * aircraft_mass * GRAVITY

	# ========================
	# TOTAL FORCE → VELOCITY
	# ========================
	var total_force: Vector3 = lift_force + drag_force + side_force + thrust_force + weight
	var accel: Vector3 = total_force / aircraft_mass
	velocity += accel * delta

	# ========================
	# G-FORCE (for HUD)
	# ========================
	g_force = (accel + Vector3.UP * GRAVITY).dot(up) / GRAVITY

	# ========================
	# ANGULAR ACCELERATIONS
	# ========================

	# Damage-scaled control authority
	var eff_pitch_power     := pitch_power     * (1.0 - elev_dmg)
	var eff_pitch_stability := pitch_stability * (1.0 - elev_dmg)
	var eff_roll_power      := roll_power      * (1.0 - wing_dmg)
	var eff_yaw_power       := yaw_power       * (1.0 - rudd_dmg)
	var eff_yaw_stability   := yaw_stability   * (1.0 - rudd_dmg)

	# --- Pilot control inputs ---
	# pitch_input: +1 = S key / stick back = nose UP
	var pitch_accel: float = pitch_input * eff_pitch_power * effectiveness
	# roll_input: user-swapped axis, -roll_input gives correct direction
	var roll_accel: float = -roll_input * eff_roll_power * effectiveness
	# yaw_input: +1 = E key / stick right = nose RIGHT
	var yaw_accel: float = yaw_input * eff_yaw_power * effectiveness

	# --- Aerodynamic stability ---
	# Horizontal stabilizer: reduces angle of attack (nose toward velocity)
	pitch_accel -= alpha * eff_pitch_stability * effectiveness
	# Vertical stabilizer (weathervane): reduces sideslip
	yaw_accel += beta * eff_yaw_stability * effectiveness
	# Dihedral effect: sideslip causes corrective roll
	roll_accel -= beta * dihedral_effect * effectiveness

	# --- Angular damping (resists rotation) ---
	# Uses fixed + speed-dependent damping so the plane is always damped,
	# but more so at high speed (like real aircraft)
	pitch_accel -= pitch_rate * (pitch_damping * 0.5 + pitch_damping * 0.5 * effectiveness)
	roll_accel -= roll_rate * (roll_damping * 0.5 + roll_damping * 0.5 * effectiveness)
	yaw_accel -= yaw_rate * (yaw_damping * 0.5 + yaw_damping * 0.5 * effectiveness)

	# --- Auto-level (gentle, only when no roll input) ---
	if absf(roll_input) < 0.1 and not is_stalling:
		var bank_angle: float = right.dot(Vector3.UP)
		roll_accel -= bank_angle * auto_level * effectiveness

	# --- Stall aerodynamics ---
	# Four coupled effects that make a stall feel like a real departure:
	if is_stalling:
		var stall_over : float = clampf((absf(alpha) - stall_alpha) / stall_alpha, 0.0, 1.5)

		# 1. Elevator authority bleeds away — separated flow over the tailplane
		#    means the pilot can no longer hold the nose up.
		pitch_accel -= (pitch_input * eff_pitch_power * effectiveness) \
					   * clampf(stall_over * 0.75, 0.0, 0.75)

		# 2. Nose-break: aerodynamic centre moves forward past stall,
		#    creating a strong pitch-down moment even at low airspeed.
		#    maxf(effectiveness, 0.35) ensures it fires when nearly stopped.
		pitch_accel -= signf(alpha) * stall_over \
					   * eff_pitch_stability * 5.0 * maxf(effectiveness, 0.35)

		# 3. Autorotation: any pre-existing roll rate amplifies (spin entry).
		#    A wings-level symmetric stall just pitches down; a stall in a
		#    bank or turn will depart and roll hard.
		roll_accel += roll_rate * stall_over * 3.5

		# 4. Aileron authority also degrades — surfaces in separated flow.
		roll_accel -= (-roll_input * eff_roll_power * effectiveness) \
					  * clampf(stall_over * 0.70, 0.0, 0.70)

		# 5. Small airframe asymmetry: prevents a perfectly symmetric stall
		#    from being infinitely holdable; gives a natural wing-drop bias
		#    that varies with position so it isn't the same every time.
		roll_accel += sin(global_position.x * 0.01 + global_position.z * 0.007) \
					  * 0.25 * stall_over

		# 6. Adverse yaw from roll rate in stall — couples into spin entry.
		yaw_accel -= roll_rate * stall_over * 1.5

	# ========================
	# UPDATE ROTATION RATES
	# ========================
	pitch_rate += pitch_accel * delta
	roll_rate += roll_accel * delta
	yaw_rate += yaw_accel * delta

	# Clamp to realistic maximums
	pitch_rate = clampf(pitch_rate, -1.5, 1.5)   # ~85°/s
	roll_rate = clampf(roll_rate, -4.0, 4.0)      # ~230°/s (fighters roll fast)
	yaw_rate = clampf(yaw_rate, -0.6, 0.6)        # ~35°/s

	# ========================
	# APPLY ROTATION (local axes)
	# ========================
	# Godot local axis conventions (right-hand rule):
	#   +X rotation = pitch UP
	#   +Z rotation = roll LEFT, so negate for roll RIGHT
	#   +Y rotation = yaw LEFT, so negate for yaw RIGHT
	rotate_object_local(Vector3(1, 0, 0), pitch_rate * delta)
	rotate_object_local(Vector3(0, 0, 1), -roll_rate * delta)
	rotate_object_local(Vector3(0, 1, 0), -yaw_rate * delta)

	# Prevent floating-point drift in the basis
	global_transform.basis = global_transform.basis.orthonormalized()

	# ========================
	# UPDATE POSITION
	# ========================
	global_position += velocity * delta

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
## refuelled and rearmed after a short turnaround.
func _service(delta: float) -> void:
	if _dead:
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
	_say("Aircraft serviced - ready for take-off")

func _needs_service() -> bool:
	if fuel < MAX_FUEL - 1.0 or gun_ammo < GUN_AMMO_MAX or cannon_ammo < CANNON_AMMO_MAX or _on_fire:
		return true
	for v in comp_hp.values():
		if v < COMP_MAX:
			return true
	return false

func _at_friendly_field() -> bool:
	var m := get_tree().get_first_node_in_group("mission")
	if m == null or m.get("geo") == null:
		return false
	var id : int = m.geo.airfield_at(WorldOrigin.world_x(global_position.x), WorldOrigin.world_z(global_position.z))
	return id >= 0 and m.geo.airfields[id][1] == GameSettings.side

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

	var aim_local : Vector3 = Vector3(-gun_local.x, 0.0, -CONVERGENCE_DIST).normalized()
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

	var aim_local : Vector3 = Vector3(-gun_local.x, 0.0, -CONVERGENCE_DIST).normalized()
	var aim_world : Vector3 = global_transform.basis * aim_local
	aim_world = (aim_world
		+ global_transform.basis.x * randf_range(-GUN_SPREAD, GUN_SPREAD)
		+ global_transform.basis.y * randf_range(-GUN_SPREAD, GUN_SPREAD)).normalized()

	var bullet := Node3D.new()
	bullet.set_script(_bullet_script)
	bullet.damage       = CANNON_DAMAGE
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
