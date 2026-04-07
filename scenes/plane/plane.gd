extends Node3D
## Semi-realistic WW2 fighter flight model (Spitfire Mk V class).
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

# Wheel contact points in local space — must match plane.tscn geometry
const WHEEL_L = Vector3(-1.60, -1.50, -2.0)   # left main gear
const WHEEL_R = Vector3( 1.60, -1.50, -2.0)   # right main gear
const WHEEL_T = Vector3(  0.0, -1.20,  3.8)   # tail wheel

# Gun muzzle positions in local space (2 per wing, near leading edge)
const GUN_POSITIONS: Array = [
	Vector3(-4.5, 0.0, -0.8),   # left outer
	Vector3(-3.0, 0.0, -0.8),   # left inner
	Vector3( 3.0, 0.0, -0.8),   # right inner
	Vector3( 4.5, 0.0, -0.8),   # right outer
]
const BULLET_SPEED      := 800.0   # m/s — .303 Browning muzzle velocity
const FIRE_INTERVAL     := 0.02    # seconds between shots (750 RPM × 4 guns = 50 rds/s)
const GUN_AMMO_MAX      := 2000    # total .303 rounds across all four guns
const CONVERGENCE_DIST  := 300.0   # m — historical RAF ~250 yards (229 m) standard
const GUN_SPREAD        := 0.004   # rad — ~4 mil dispersion per shot

# Hispano Mk II 20 mm cannons — one per wing
const CANNON_POSITIONS : Array = [
	Vector3(-6.0, 0.0, -0.5),   # left wing cannon
	Vector3( 6.0, 0.0, -0.5),   # right wing cannon
]
const CANNON_SPEED    := 820.0          # m/s — 20 mm shell muzzle velocity
const CANNON_INTERVAL := 60.0 / 1400.0 # s between shots (700 RPM × 2 cannons)
const CANNON_DAMAGE   := 3             # HP deducted per shell hit
const CANNON_AMMO_MAX := 150            # total 20 mm rounds (75 per cannon)

# Fuel — 600 units = ~10 minutes at full throttle
const MAX_FUEL        := 600.0
const BASE_FUEL_DRAIN := 1.0    # units/s at throttle 1.0
const FUEL_LEAK_RATE  := 3.0    # extra units/s when fuel tank fully destroyed

var _gun_index  : int   = 0
var _fire_timer : float = 0.0
var gun_ammo    : int   = GUN_AMMO_MAX

var _cannon_index : int   = 0
var _cannon_timer : float = 0.0
var cannon_ammo   : int   = CANNON_AMMO_MAX

var fuel : float = MAX_FUEL

var _bullet_script = preload("res://scenes/plane/bullet.gd")

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
## Drag a looping engine .wav/.ogg onto this in the Inspector
@export var engine_sound : AudioStream

var _audio_player : AudioStreamPlayer

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
	aspect_ratio = wing_span * wing_span / wing_area
	throttle = 0.7
	# Start at ~290 km/h, airborne
	velocity = -global_transform.basis.z * 80.0
	# Put the hitbox on layer 2 so terrain/water raycasts (mask=1) never hit it
	_hitbox_body.collision_layer = 2
	_hitbox_body.collision_mask  = 2
	_setup_engine_audio()
	_setup_gun_audio()

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

func _setup_engine_audio() -> void:
	if not engine_sound:
		return
	_audio_player = AudioStreamPlayer.new()
	_audio_player.stream    = engine_sound
	_audio_player.volume_db = -10.0
	add_child(_audio_player)
	_audio_player.play()

func _process(delta: float) -> void:
	if _audio_player:
		_audio_player.pitch_scale = lerpf(0.5, 1.8, throttle)
		_audio_player.volume_db   = lerpf(-18.0, -6.0, throttle)
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

func take_hit(hit_pos: Vector3, damage: int = 1) -> void:
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

	throttle = clampf(throttle + (throttle_up - throttle_down) * throttle_response * delta, 0.0, 1.0)

	# ========================
	# GUNS & CANNON
	# ========================
	_fire_timer = maxf(_fire_timer - delta, 0.0)
	if Input.is_action_pressed("fire") and _fire_timer == 0.0 and gun_ammo > 0:
		_fire_next_gun()
		_fire_timer = FIRE_INTERVAL

	_cannon_timer = maxf(_cannon_timer - delta, 0.0)
	if Input.is_action_pressed("fire_cannon") and _cannon_timer == 0.0 and cannon_ammo > 0:
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
				queue_free()
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
		pitch_rate += -pitch_err * 8.0 * delta

		# Heavy angular damping on the ground (landing gear absorbs oscillation)
		roll_rate  *= maxf(0.0, 1.0 - 12.0 * delta)
		pitch_rate *= maxf(0.0, 1.0 -  6.0 * delta)
		yaw_rate   *= maxf(0.0, 1.0 -  8.0 * delta)

		# Wheels constrain sideways sliding
		var lat_vel := velocity.dot(right)
		velocity -= right * lat_vel * minf(1.0, 15.0 * delta)

		# Rolling resistance + wheel brakes.
		# Holding throttle_down on the ground applies brakes (μ up to ~0.5).
		var brake_mu := lerpf(0.03, 0.5, throttle_down)
		var friction_decel := GRAVITY * brake_mu * delta
		if velocity.length() > friction_decel:
			velocity -= velocity.normalized() * friction_decel
		else:
			velocity = Vector3.ZERO

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
