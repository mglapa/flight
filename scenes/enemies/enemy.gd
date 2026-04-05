extends Node3D
## Enemy aircraft.
## Orbit mode: circles a fixed point at constant altitude.
## Chase mode: same aerodynamic flight model as the player, driven by AI.

# ── Orbit constants ───────────────────────────────────────────────────────────
const SPEED      := 67.0
const MAX_HEALTH := 10

# ── Aerodynamic model (BF-109 class) ─────────────────────────────────────────
const AIRCRAFT_MASS  := 3200.0   # kg
const WING_AREA      := 16.2     # m²
const WING_SPAN      := 9.9      # m
const MAX_THRUST     := 13000.0  # N  (~1400 hp)
const AIR_DENSITY    := 1.225
const GRAVITY        := 9.81

const CL_SLOPE       := 5.0
const CL_0           := 0.15
const CD_0           := 0.025
const OSWALD         := 0.78
const STALL_ALPHA    := 0.279    # rad ≈ 16°

# ── Control authority (matches player) ────────────────────────────────────────
const PITCH_POWER     := 4.0
const ROLL_POWER      := 6.0
const YAW_POWER       := 1.5
const PITCH_STABILITY := 1.5
const YAW_STABILITY   := 5.0
const DIHEDRAL_EFFECT := 2.0
const PITCH_DAMPING   := 3.5
const ROLL_DAMPING    := 4.0
const YAW_DAMPING     := 4.0

# ── Chase AI parameters ───────────────────────────────────────────────────────
const TARGET_SPEED   := 82.0    # m/s desired airspeed
const MIN_AGL        := 280.0   # m — pull up below this
const PURSUIT_DIST   := 400.0   # m behind player to aim for when close
const FIRE_RANGE     := 520.0   # m
const FIRE_CONE      := 0.09    # rad ≈ 5°
const FIRE_INTERVAL  := 0.08    # s between rounds

const CHASE_GUNS : Array = [Vector3(-3.0, 0.0, -0.8), Vector3(3.0, 0.0, -0.8)]

# ── Orbit parameters (set before add_child) ───────────────────────────────────
var orbit_center   : Vector3 = Vector3.ZERO
var orbit_radius   : float   = 800.0
var orbit_altitude : float   = 200.0
var start_angle    : float   = -1.0

## Assign to activate pursuit.
var chase_target : Node3D = null

# ── Shared state ──────────────────────────────────────────────────────────────
var health : int = MAX_HEALTH
var _angle    : float = 0.0
var _dead     : bool  = false
var _dead_vel : Vector3 = Vector3.ZERO
var _dead_age : float   = 0.0

# ── Aerodynamic state ─────────────────────────────────────────────────────────
var _velocity   : Vector3 = Vector3.ZERO
var _pitch_rate : float   = 0.0
var _roll_rate  : float   = 0.0
var _yaw_rate   : float   = 0.0
var _throttle   : float   = 0.85
var _aspect_ratio : float = WING_SPAN * WING_SPAN / WING_AREA

var _fire_cd : float = 0.0
var _gun_idx : int   = 0

# ── Smoke ─────────────────────────────────────────────────────────────────────
var _smoke_timer    : float = 9999.0
var _smoke_interval : float = 9999.0

var _hit_flash_script  = preload("res://scenes/enemies/hit_flash.gd")
var _smoke_puff_script = preload("res://scenes/enemies/smoke_puff.gd")
var _bullet_script     = preload("res://scenes/plane/bullet.gd")
var _body_rid : RID

# ── Lifecycle ─────────────────────────────────────────────────────────────────

func _ready() -> void:
	add_to_group("enemies")
	_build_mesh()
	_build_collision()
	_angle = start_angle if start_angle >= 0.0 else randf() * TAU
	_apply_orbit()

func _process(delta: float) -> void:
	if _dead:
		_update_falling(delta)
		return

	if is_instance_valid(chase_target):
		_update_chase(delta)
	else:
		_angle += (SPEED / orbit_radius) * delta
		_apply_orbit()

	_smoke_timer -= delta
	if _smoke_timer <= 0.0:
		_smoke_timer = _smoke_interval
		_spawn_smoke_puff(false)

# ── Orbit ─────────────────────────────────────────────────────────────────────

func _apply_orbit() -> void:
	global_position = Vector3(
		orbit_center.x + cos(_angle) * orbit_radius,
		orbit_altitude,
		orbit_center.z + sin(_angle) * orbit_radius)
	var ahead := Vector3(
		orbit_center.x + cos(_angle + 0.05) * orbit_radius,
		orbit_altitude,
		orbit_center.z + sin(_angle + 0.05) * orbit_radius)
	look_at(ahead, Vector3.UP)

# ── Chase AI with aerodynamic flight model ────────────────────────────────────

func _update_chase(delta: float) -> void:
	# Seed velocity from orbit tangent on first chase frame
	if _velocity == Vector3.ZERO:
		_velocity = Vector3(-sin(_angle), 0.0, cos(_angle)) * TARGET_SPEED

	var fwd   : Vector3 = -global_transform.basis.z
	var up    : Vector3 =  global_transform.basis.y
	var right : Vector3 =  global_transform.basis.x
	var speed : float   = maxf(_velocity.length(), 5.0)

	# ── Velocity decomposed in body frame ─────────────────────────────────────
	var vel_fwd   : float = _velocity.dot(fwd)
	var vel_up    : float = _velocity.dot(up)
	var vel_right : float = _velocity.dot(right)

	# ── Angle of attack & sideslip ────────────────────────────────────────────
	var alpha : float = 0.0
	var beta  : float = 0.0
	if speed > 3.0:
		alpha = atan2(-vel_up, maxf(vel_fwd, 3.0))
		beta  = atan2(vel_right, maxf(vel_fwd, 3.0))

	# ── Dynamic pressure ──────────────────────────────────────────────────────
	var q  : float = 0.5 * AIR_DENSITY * speed * speed
	var qS : float = q * WING_AREA
	var q_ref         : float = 0.5 * AIR_DENSITY * 80.0 * 80.0
	var effectiveness : float = clampf(q / q_ref, 0.0, 1.5)

	# ── Lift ──────────────────────────────────────────────────────────────────
	var cl : float
	if absf(alpha) < STALL_ALPHA:
		cl = CL_0 + CL_SLOPE * alpha
	else:
		var cl_at_stall : float = CL_0 + CL_SLOPE * STALL_ALPHA * signf(alpha)
		var excess : float = absf(alpha) - STALL_ALPHA
		cl = cl_at_stall * maxf(1.0 - excess * 2.0, 0.2)
	var lift_force : Vector3 = up * qS * cl

	# ── Drag ──────────────────────────────────────────────────────────────────
	var cd : float = CD_0 + (cl * cl) / (PI * _aspect_ratio * OSWALD)
	var drag_force : Vector3 = Vector3.ZERO
	if speed > 1.0:
		drag_force = -_velocity.normalized() * qS * cd

	# ── Side force ────────────────────────────────────────────────────────────
	var side_force : Vector3 = -right * qS * beta * 0.5

	# ── Auto-throttle: push hard when slow, ease back when fast ───────────────
	var throttle_target := 1.0 if speed < TARGET_SPEED else 0.65
	_throttle = clampf(lerpf(_throttle, throttle_target, 1.5 * delta), 0.0, 1.0)
	var thrust_force : Vector3 = fwd * MAX_THRUST * _throttle

	# ── Gravity ───────────────────────────────────────────────────────────────
	var weight : Vector3 = Vector3.DOWN * AIRCRAFT_MASS * GRAVITY

	# ── Integrate forces → velocity ───────────────────────────────────────────
	var total_force : Vector3 = lift_force + drag_force + side_force + thrust_force + weight
	_velocity += (total_force / AIRCRAFT_MASS) * delta

	# ── Terrain look-ahead ────────────────────────────────────────────────────
	var ground_y  : float   = _terrain_y(global_position)
	var agl       : float   = global_position.y - ground_y
	var ahead_pos : Vector3 = global_position + fwd * (speed * 3.0)
	var agl_ahead : float   = ahead_pos.y - _terrain_y(ahead_pos)
	var too_low   : bool    = agl < MIN_AGL or agl_ahead < MIN_AGL * 0.6

	# ── AI: generate pitch / roll inputs (same convention as player inputs) ────
	# pitch_input convention: +1 = pull back = nose UP
	# roll_input convention : -1 = roll right (as in player get_axis)
	var ai_pitch : float = 0.0
	var ai_roll  : float = 0.0

	if too_low:
		# Pull up hard, level wings
		ai_pitch =  1.0
		ai_roll  =  0.0
	else:
		var target_pos : Vector3 = chase_target.global_position
		var target_fwd : Vector3 = -chase_target.global_transform.basis.z
		var dist       : float   = (target_pos - global_position).length()

		# Pure pursuit when far; blend to offset pursuit when close
		var t_offset : float   = clampf(1.0 - dist / 1500.0, 0.0, 1.0)
		var goal     : Vector3 = target_pos - target_fwd * (PURSUIT_DIST * t_offset)
		var goal_dir : Vector3 = (goal - global_position).normalized()

		var goal_right : float = goal_dir.dot(right)   # +ve → goal to our right
		var goal_up    : float = goal_dir.dot(up)       # +ve → goal above us
		var goal_fwd_d : float = goal_dir.dot(fwd)      # +ve → goal ahead

		# Roll to bank toward goal (brings goal into the "above" hemisphere).
		# Negative roll_input → roll right (same sign as player model).
		ai_roll = -clampf(goal_right * 3.0, -1.0, 1.0)

		# Pull toward goal. Extra pull when goal is behind to loop around.
		var behind : float = clampf(-goal_fwd_d, 0.0, 1.0)
		ai_pitch = clampf(goal_up * 2.5 + behind * 0.8, -1.0, 1.0)

		# Trim: small constant pitch-up to compensate aerodynamic trim offset.
		# Also suppresses unwanted sink from stability term at cruise.
		ai_pitch = clampf(ai_pitch + 0.05, -1.0, 1.0)

	# ── Stall limiter: back off pull input when alpha approaches stall ─────────
	var alpha_warn : float = STALL_ALPHA * 0.70
	if alpha > alpha_warn and ai_pitch > 0.0:
		var over : float = (alpha - alpha_warn) / (STALL_ALPHA - alpha_warn)
		ai_pitch *= maxf(0.0, 1.0 - over)

	# ── Angular accelerations — identical to player ───────────────────────────
	var pitch_accel : float =  ai_pitch * PITCH_POWER * effectiveness
	var roll_accel  : float = -ai_roll  * ROLL_POWER  * effectiveness
	var yaw_accel   : float = 0.0

	# Aerodynamic stability (same as player)
	pitch_accel -= alpha * PITCH_STABILITY * effectiveness
	yaw_accel   += beta  * YAW_STABILITY   * effectiveness
	roll_accel  -= beta  * DIHEDRAL_EFFECT * effectiveness

	# Angular damping (same as player)
	pitch_accel -= _pitch_rate * (PITCH_DAMPING * 0.5 + PITCH_DAMPING * 0.5 * effectiveness)
	roll_accel  -= _roll_rate  * (ROLL_DAMPING  * 0.5 + ROLL_DAMPING  * 0.5 * effectiveness)
	yaw_accel   -= _yaw_rate   * (YAW_DAMPING   * 0.5 + YAW_DAMPING   * 0.5 * effectiveness)

	_pitch_rate += pitch_accel * delta
	_roll_rate  += roll_accel  * delta
	_yaw_rate   += yaw_accel   * delta

	_pitch_rate = clampf(_pitch_rate, -1.5, 1.5)
	_roll_rate  = clampf(_roll_rate,  -4.0, 4.0)
	_yaw_rate   = clampf(_yaw_rate,   -0.6, 0.6)

	# Apply rotation — identical axis/sign convention to player
	rotate_object_local(Vector3(1, 0, 0),  _pitch_rate * delta)
	rotate_object_local(Vector3(0, 0, 1), -_roll_rate  * delta)
	rotate_object_local(Vector3(0, 1, 0), -_yaw_rate   * delta)
	global_transform.basis = global_transform.basis.orthonormalized()

	# ── Move ─────────────────────────────────────────────────────────────────
	global_position += _velocity * delta

	# Crash if descended into terrain
	if global_position.y <= _terrain_y(global_position) + 1.0:
		_start_falling()
		return

	# ── Shoot ────────────────────────────────────────────────────────────────
	_fire_cd -= delta
	if _fire_cd <= 0.0 and not too_low:
		var to_tgt   : Vector3 = chase_target.global_position - global_position
		var angle_to : float   = fwd.angle_to(to_tgt.normalized())
		if to_tgt.length() < FIRE_RANGE and angle_to < FIRE_CONE:
			_fire_enemy_gun()
			_fire_cd = FIRE_INTERVAL

# ── Damage ────────────────────────────────────────────────────────────────────

func take_hit(hit_pos: Vector3) -> void:
	if _dead:
		return
	health -= 1

	var flash := Node3D.new()
	flash.set_script(_hit_flash_script)
	get_parent().add_child(flash)
	flash.global_position = hit_pos

	if health <= 3:
		_smoke_interval = 0.12
	elif health <= 6:
		_smoke_interval = 0.40

	if health <= 0:
		_start_falling()

func _start_falling() -> void:
	_dead = true
	_dead_vel = _velocity if _velocity.length() > 1.0 else -global_transform.basis.z * SPEED
	chase_target = null

func _update_falling(delta: float) -> void:
	_dead_age += delta
	_dead_vel.y -= 20.0 * delta
	global_position += _dead_vel * delta
	rotate_object_local(Vector3(1, 0, 0),  2.2 * delta)
	rotate_object_local(Vector3(0, 0, 1),  1.0 * delta)

	_smoke_timer -= delta
	if _smoke_timer <= 0.0:
		_smoke_timer = 0.07
		_spawn_smoke_puff(true)

	if global_position.y <= _terrain_y(global_position) or _dead_age > 14.0:
		queue_free()

# ── Helpers ───────────────────────────────────────────────────────────────────

func _fire_enemy_gun() -> void:
	var muzzle : Vector3 = global_transform * CHASE_GUNS[_gun_idx]
	_gun_idx = (_gun_idx + 1) % CHASE_GUNS.size()
	var bullet := Node3D.new()
	bullet.set_script(_bullet_script)
	bullet.velocity = _velocity + (-global_transform.basis.z) * 800.0
	get_parent().add_child(bullet)
	bullet.global_position = muzzle

func _terrain_y(world_pos: Vector3) -> float:
	var space := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(
		Vector3(world_pos.x, 2000.0, world_pos.z),
		Vector3(world_pos.x,  -50.0, world_pos.z))
	if _body_rid.is_valid():
		query.exclude = [_body_rid]
	var hit := space.intersect_ray(query)
	return hit.position.y if hit else 0.0

func _spawn_smoke_puff(is_dark: bool) -> void:
	var puff := Node3D.new()
	puff.set_script(_smoke_puff_script)
	puff.dark = is_dark
	get_parent().add_child(puff)
	puff.global_position = global_position + Vector3(0, 0.4, 0)

# ── Build ─────────────────────────────────────────────────────────────────────

func _build_mesh() -> void:
	var fus_mat := StandardMaterial3D.new()
	fus_mat.albedo_color = Color(0.45, 0.35, 0.25)
	fus_mat.roughness    = 0.8

	var wing_mat := StandardMaterial3D.new()
	wing_mat.albedo_color = Color(0.40, 0.30, 0.22)
	wing_mat.roughness    = 0.8

	var fuselage := MeshInstance3D.new()
	var fm := BoxMesh.new(); fm.size = Vector3(1.0, 1.2, 9.8)
	fuselage.mesh = fm; fuselage.material_override = fus_mat
	add_child(fuselage)

	var wings := MeshInstance3D.new()
	var wm := BoxMesh.new(); wm.size = Vector3(11.3, 0.15, 1.7)
	wings.mesh = wm; wings.material_override = wing_mat
	add_child(wings)

	var tail := MeshInstance3D.new()
	var tm := BoxMesh.new(); tm.size = Vector3(4.0, 0.12, 1.1)
	tail.mesh = tm; tail.position = Vector3(0, 0.4, 4.0)
	tail.material_override = wing_mat
	add_child(tail)

	var fin := MeshInstance3D.new()
	var fm2 := BoxMesh.new(); fm2.size = Vector3(0.15, 1.5, 1.5)
	fin.mesh = fm2; fin.position = Vector3(0, 1.3, 4.0)
	fin.material_override = fus_mat
	add_child(fin)

func _build_collision() -> void:
	var body := StaticBody3D.new()
	var col  := CollisionShape3D.new()
	var box  := BoxShape3D.new()
	box.size = Vector3(12.0, 1.5, 10.0)
	col.shape = box
	body.add_child(col)
	add_child(body)
	_body_rid = body.get_rid()
