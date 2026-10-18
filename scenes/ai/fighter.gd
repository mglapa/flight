extends Node3D
## AI fighter pilot, either side.  Flies the same aerodynamic model as the
## player, with the flight values of `fighter_type` from aircraft_types.gd.
##
## What it does each frame, in priority order:
##   parked / take-off roll  — scramble from an airfield (scramble_delay >= 0)
##   climb-out               — straight ahead and up until clear of the ground
##   attack `target`         — pursuit and gunnery (target set by the mission)
##   hold formation          — slot on `formation_leader` (escorts, wingmen)
##   head for `goal_world`   — patrol / intercept vector from the mission
## The mission director (scenes/mission/mission.gd) chooses targets.

const ParachuteScript := preload("res://scenes/fx/parachute.gd")
const CREW := 1                   ## crew who might bail out
const BAIL_CHANCE := 0.65
const AircraftTypes := preload("res://scenes/plane/aircraft_types.gd")
const AIR_DENSITY := 1.225
const GRAVITY     := 9.81
const CL_SLOPE    := 5.0
const CL_0        := 0.15
const OSWALD      := 0.78
const COMP_MAX    : int = 4

const PITCH_STABILITY := 1.5
const YAW_STABILITY   := 5.0
const DIHEDRAL_EFFECT := 2.0
const PITCH_DAMPING   := 3.5
const ROLL_DAMPING    := 4.0
const YAW_DAMPING     := 4.0

const TARGET_SPEED    := 82.0    # m/s cruise / combat speed
const MIN_AGL         := 280.0   # pull up below this (in combat)
const PURSUIT_DIST    := 400.0   # m behind the target to aim for when close
const FIRE_RANGE      := 520.0
const FIRE_CONE       := 0.09    # rad ≈ 5°
const FIRE_INTERVAL   := 0.06    # s between MG rounds (the AI fires slower than the player)
const CANNON_INTERVAL := 0.35
const CONVERGENCE_DIST := 300.0
const GUN_SPREAD      := 0.004
const BASE_FUEL_DRAIN := 1.0
const FUEL_LEAK_RATE  := 3.0
const CLIMB_OUT_AGL   := 220.0

enum State { PARKED, ROLLING, CLIMB_OUT, FLYING }

# ── Set before add_child ─────────────────────────────────────────────────────
var fighter_type := "bf109"
var side := "lw"
## "escort" (guard the bombers), "intercept" (go for bombers), "sweep" (hunt fighters)
var role := "escort"
var formation_leader : Node3D = null
var formation_offset := Vector3.ZERO
## Patrol / intercept destination in world coordinates (x, altitude, z)
var goal_world := Vector3.INF
## >= 0: start parked on the ground and begin the take-off roll after this long
var scramble_delay := -1.0

## Assigned by the mission director
var target : Node3D = null

# ── State ────────────────────────────────────────────────────────────────────
var state := State.FLYING
var on_ground := false            ## read by the model's undercarriage
var comp_hp : Dictionary = {"wing": 4, "elevator": 4, "rudder": 4, "engine": 4, "fuel_tank": 4}
var _on_fire := false
var _burn_timer := 0.0
var _dead := false
var _dead_vel := Vector3.ZERO
var _dead_age := 0.0
var _bail_times : Array = []       ## _dead_age at which each surviving crewman jumps
var _last_attacker : Node = null

var _p : Dictionary = {}
var _mass := 3000.0
var _wing_area := 20.0
var _thrust := 14000.0
var _cd0 := 0.025
var _stall := 0.279
var _pitch_power := 4.0
var _roll_power := 6.0
var _aspect := 6.0
var _guns : Array = []
var _cannons : Array = []

var _velocity := Vector3.ZERO
var _pitch_rate := 0.0
var _roll_rate := 0.0
var _yaw_rate := 0.0
var _throttle := 0.85
var _fuel := 1800.0

var _roll_speed := 0.0
var _rotate_speed := 50.0
var _park_pitch := 0.0
var _heading := Vector3.FORWARD

var _fire_cd := 0.0
var _cannon_cd := 0.0
var _gun_idx := 0
var _gun_ammo := 2000
var _cannon_ammo := 0

var _smoke_timer := 9999.0
var _smoke_interval := 9999.0
var _smoke_opacity := 0.0

var _hit_flash_script = preload("res://scenes/enemies/hit_flash.gd")
var _bullet_script = preload("res://scenes/plane/bullet.gd")
var _body_rid : RID
var _model : Node3D = null
var _world : Node = null
var _smoke : Node = null

# ── Lifecycle ─────────────────────────────────────────────────────────────────

func _ready() -> void:
	_apply_profile()
	add_to_group("aircraft")
	add_to_group("fighters")
	add_to_group("ai")
	add_to_group("side_" + side)
	add_to_group("allies" if side == GameSettings.side else "enemies")
	_world = get_tree().get_first_node_in_group("world")
	_smoke = get_tree().get_first_node_in_group("smoke_field")
	_build_mesh()
	_build_collision()
	_heading = -global_transform.basis.z
	_heading.y = 0.0
	_heading = _heading.normalized()
	if scramble_delay >= 0.0:
		state = State.PARKED
		on_ground = true
		_place_on_ground(_park_pitch)
	elif formation_leader != null and is_instance_valid(formation_leader):
		global_position = formation_leader.global_position + formation_leader.global_transform.basis * formation_offset
		global_transform.basis = formation_leader.global_transform.basis
		_velocity = _leader_velocity()
	else:
		_velocity = -global_transform.basis.z * TARGET_SPEED

func _apply_profile() -> void:
	if not AircraftTypes.TYPES.has(fighter_type):
		fighter_type = "bf109"
	_p = AircraftTypes.TYPES[fighter_type]
	_mass = _p.mass
	_wing_area = _p.wing_area
	_thrust = _p.thrust
	_cd0 = _p.cd0
	_stall = deg_to_rad(_p.stall_deg)
	_pitch_power = _p.pitch_power
	_roll_power = _p.roll_power
	_aspect = _p.span * _p.span / _wing_area
	_guns = _p.guns
	_cannons = _p.cannons
	_gun_ammo = int(_p.gun_ammo)
	_cannon_ammo = int(_p.cannon_ammo)
	_fuel = float(_p.fuel) * 1.5
	var cl_max := CL_0 + CL_SLOPE * _stall
	_rotate_speed = 1.3 * sqrt(2.0 * _mass * GRAVITY / (AIR_DENSITY * _wing_area * cl_max))
	# Three-point attitude: pitch that puts the main and tail wheels on the ground
	var m : Vector3 = _p.wheels[0]
	var t : Vector3 = _p.wheels[2]
	_park_pitch = atan((m.y - t.y) / (m.z - t.z)) if absf(m.z - t.z) > 0.01 else 0.0

func get_velocity() -> Vector3:
	return _velocity

func is_airborne() -> bool:
	return not _dead and (state == State.FLYING or state == State.CLIMB_OUT)

func _process(delta: float) -> void:
	if _dead:
		_update_falling(delta)
		return
	match state:
		State.PARKED, State.ROLLING:
			_ground_roll(delta)
		_:
			_fly(delta)
	if _dead:
		return
	_smoke_timer -= delta
	if _smoke_timer <= 0.0:
		_smoke_timer = _smoke_interval
		_puff(1 if _smoke_opacity > 0.6 else 0, 1.0 + _smoke_opacity, 2.5)
	if _on_fire:
		_burn_timer += delta
		if _burn_timer >= 1.0:
			_burn_timer -= 1.0
			var fc : String = comp_hp.keys().pick_random()
			comp_hp[fc] = maxi(comp_hp[fc] - 1, 0)
			if _total_hp() <= 0:
				_start_falling()
				return
			_smoke_opacity = 1.0
			_smoke_interval = 0.08
			_smoke_timer = minf(_smoke_timer, 0.08)

# ── Take-off ──────────────────────────────────────────────────────────────────

func _ground_y(p: Vector3) -> float:
	return _world.sample_height(p.x, p.z) if _world else 0.0

## Rests the main wheels on the ground at the given nose-up pitch
func _place_on_ground(pitch: float) -> void:
	var b := Basis.looking_at(_heading, Vector3.UP) * Basis(Vector3.RIGHT, pitch)
	var m : Vector3 = _p.wheels[0]
	global_transform.basis = b
	var drop := (b * m).y
	var p := global_position
	global_position = Vector3(p.x, _ground_y(p) - drop + 0.02, p.z)

func _ground_roll(delta: float) -> void:
	on_ground = true
	if _model:
		_model.set_controls(0.0, 0.0, 0.0, 0.25 if state == State.PARKED else 1.0)
	if state == State.PARKED:
		scramble_delay -= delta
		if scramble_delay <= 0.0:
			state = State.ROLLING
		return
	_roll_speed += (_thrust / _mass * 0.85 - 0.4) * delta
	global_position += _heading * _roll_speed * delta
	# The tail comes up as speed builds, then she flies herself off
	var f := smoothstep(0.35, 0.8, _roll_speed / _rotate_speed)
	_place_on_ground(lerpf(_park_pitch, 0.03, f))
	if _roll_speed >= _rotate_speed:
		state = State.CLIMB_OUT
		on_ground = false
		var fwd := -global_transform.basis.z
		_velocity = fwd * _roll_speed + Vector3.UP * 2.0

# ── Flight ───────────────────────────────────────────────────────────────────

## A leader worth following: alive and airborne (the player may still be
## taxiing, or down)
func _leader_flying() -> bool:
	if formation_leader == null or not is_instance_valid(formation_leader):
		return false
	if formation_leader.get("_dead") == true or formation_leader.get("on_ground") == true:
		return false
	var lp := formation_leader.global_position
	return lp.y - _ground_y(lp) > 60.0

func _leader_velocity() -> Vector3:
	if formation_leader != null and is_instance_valid(formation_leader) and formation_leader.has_method("get_velocity"):
		return formation_leader.get_velocity()
	return -global_transform.basis.z * TARGET_SPEED

func _total_hp() -> int:
	var t := 0
	for v in comp_hp.values():
		t += v
	return t

func _fly(delta: float) -> void:
	var fwd   : Vector3 = -global_transform.basis.z
	var up    : Vector3 =  global_transform.basis.y
	var right : Vector3 =  global_transform.basis.x
	var speed : float   = maxf(_velocity.length(), 5.0)

	var vel_fwd   : float = _velocity.dot(fwd)
	var vel_up    : float = _velocity.dot(up)
	var vel_right : float = _velocity.dot(right)
	var alpha := 0.0
	var beta := 0.0
	if speed > 3.0:
		alpha = atan2(-vel_up, maxf(vel_fwd, 3.0))
		beta  = atan2(vel_right, maxf(vel_fwd, 3.0))

	var q  : float = 0.5 * AIR_DENSITY * speed * speed
	var qS : float = q * _wing_area
	var effectiveness : float = clampf(q / (0.5 * AIR_DENSITY * 80.0 * 80.0), 0.0, 1.5)

	var cl : float
	if absf(alpha) < _stall:
		cl = CL_0 + CL_SLOPE * alpha
	else:
		var cl_at_stall : float = CL_0 + CL_SLOPE * _stall * signf(alpha)
		cl = cl_at_stall * maxf(1.0 - (absf(alpha) - _stall) * 2.0, 0.2)
	var wing_dmg : float = float(COMP_MAX - comp_hp["wing"]) / float(COMP_MAX)
	var elev_dmg : float = float(COMP_MAX - comp_hp["elevator"]) / float(COMP_MAX)
	var rudd_dmg : float = float(COMP_MAX - comp_hp["rudder"]) / float(COMP_MAX)
	var eng_dmg  : float = float(COMP_MAX - comp_hp["engine"]) / float(COMP_MAX)
	var lift_force : Vector3 = up * qS * cl * (1.0 - wing_dmg * 0.9)
	var cd : float = _cd0 + (cl * cl) / (PI * _aspect * OSWALD)
	var drag_force : Vector3 = -_velocity.normalized() * qS * cd if speed > 1.0 else Vector3.ZERO
	var side_force : Vector3 = -right * qS * beta * 0.5

	# ── Where to go ───────────────────────────────────────────────────────────
	var pos := global_position
	var ground := _ground_y(pos)
	var agl := pos.y - ground
	var ahead := pos + fwd * (speed * 3.0)
	var agl_ahead := ahead.y - _ground_y(ahead)
	var has_target : bool = is_instance_valid(target) and state == State.FLYING and target.get("_dead") != true
	var floor_agl := MIN_AGL if has_target else CLIMB_OUT_AGL
	var sink := maxf(-_velocity.y, 0.0)          # dives need room to pull out
	var too_low := state == State.FLYING and (agl < floor_agl or agl_ahead < floor_agl * 0.6
		or agl - sink * 5.0 < floor_agl * 0.5)

	var goal : Vector3
	var want_speed := TARGET_SPEED
	var assist := Vector3.INF
	var shoot := false
	if state == State.CLIMB_OUT:
		goal = pos + _heading * 2500.0 + Vector3.UP * 500.0
		want_speed = TARGET_SPEED + 10.0
		if agl > CLIMB_OUT_AGL:
			state = State.FLYING
	elif has_target:
		var tp := target.global_position
		var tf := -target.global_transform.basis.z
		var dist := pos.distance_to(tp)
		if dist < 800.0:
			# Lead pursuit: point where the bullets will meet it
			var tv : Vector3 = target.get_velocity() if target.has_method("get_velocity") else Vector3.ZERO
			goal = tp + (tv - _velocity) * (dist / float(_p.gun_speed))
		else:
			goal = tp - tf * (PURSUIT_DIST * clampf(1.0 - dist / 1500.0, 0.0, 1.0))
		# Close in fast, then settle just above the target's speed at gun range
		var tspeed : float = target.get_velocity().length() if target.has_method("get_velocity") else TARGET_SPEED
		want_speed = maxf(tspeed, 60.0) + clampf((dist - 180.0) * 0.06, -5.0, 35.0)
		shoot = true
	elif _leader_flying():
		var lb := formation_leader.global_transform.basis
		var slot := formation_leader.global_position + lb * formation_offset
		slot.y = maxf(slot.y, _ground_y(slot) + 450.0)     # never follow a leader into the ground
		var lfwd := -lb.z
		var err := slot - pos
		goal = pos + lfwd * 250.0 + err.limit_length(220.0)
		var lv := _leader_velocity()
		want_speed = lv.length() + clampf(err.dot(lfwd) * 0.06, -14.0, 30.0)
		if err.length() < 400.0:
			assist = lv + err.limit_length(120.0) * 0.15
	else:
		if formation_leader != null and not is_instance_valid(formation_leader):
			formation_leader = null
		if goal_world != Vector3.INF:
			goal = WorldOrigin.to_scene(goal_world)
			if Vector2(goal.x - pos.x, goal.z - pos.z).length() < 1500.0:
				# Orbit the point until given something better to do
				goal = pos + right * 800.0 + fwd * 400.0
				goal.y = WorldOrigin.to_scene(goal_world).y
		else:
			goal = pos + Vector3(fwd.x, 0.0, fwd.z).normalized() * 1500.0

	var throttle_target := clampf(0.6 + (want_speed - speed) * 0.08, 0.0, 1.0)
	_throttle = clampf(lerpf(_throttle, throttle_target, 1.5 * delta), 0.0, 1.0)
	var fuel_tank_dmg : float = float(COMP_MAX - comp_hp["fuel_tank"]) / float(COMP_MAX)
	_fuel = maxf(_fuel - (BASE_FUEL_DRAIN * _throttle + FUEL_LEAK_RATE * fuel_tank_dmg) * delta, 0.0)
	var thrust_force : Vector3 = fwd * _thrust * _throttle * (1.0 - eng_dmg) * (1.0 if _fuel > 0.0 else 0.0)
	var weight : Vector3 = Vector3.DOWN * _mass * GRAVITY
	_velocity += ((lift_force + drag_force + side_force + thrust_force + weight) / _mass) * delta
	if assist != Vector3.INF:
		_velocity = _velocity.lerp(assist, clampf(delta * 0.6, 0.0, 1.0))      # formation-keeping help

	# ── Stick ─────────────────────────────────────────────────────────────────
	# Roll convention: ai_roll < 0 rolls right.  Bank angle: right wing down < 0.
	var bank := atan2(right.y, up.y)
	var pitch_now := asin(clampf(fwd.y, -1.0, 1.0))
	var ai_pitch := 0.0
	var ai_roll := 0.0
	if too_low:
		# Recover: wings level, then hold a steady climb (a full pull would stall)
		ai_roll = clampf(-bank * 1.5, -1.0, 1.0)
		if absf(bank) < 0.6:
			ai_pitch = clampf((deg_to_rad(20.0) - pitch_now) * 3.0, -0.4, 1.0)
		else:
			ai_pitch = 0.15 if up.y > 0.0 else 0.0     # roll upright before pulling
	elif shoot:
		# Pursuit: bank the target into the canopy and pull
		var goal_dir := (goal - pos).normalized()
		var behind := clampf(-goal_dir.dot(fwd), 0.0, 1.0)
		ai_roll = -clampf(goal_dir.dot(right) * 3.0, -1.0, 1.0)
		ai_pitch = clampf(goal_dir.dot(up) * 2.5 + behind * 0.8 + 0.05, -1.0, 1.0)
	else:
		# Flight director: coordinated turn toward the goal, gentle climb or descent
		var to := goal - pos
		var fwd_h := Vector3(fwd.x, 0.0, fwd.z).normalized()
		var right_h := Vector3(-fwd_h.z, 0.0, fwd_h.x)
		var to_h := Vector3(to.x, 0.0, to.z)
		var err := atan2(to_h.dot(right_h), to_h.dot(fwd_h))      # + = goal to the right
		var want_bank := -clampf(err * 1.4, -1.05, 1.05)
		ai_roll = clampf((want_bank - bank) * 2.0, -1.0, 1.0)
		var gamma := clampf(atan2(to.y, maxf(to_h.length(), 1.0)), -0.35, 0.35)
		ai_pitch = clampf((gamma - pitch_now) * 3.0 + absf(sin(bank)) * 0.6 + 0.05, -0.6, 1.0)
	var alpha_warn := _stall * 0.7
	if alpha > alpha_warn and ai_pitch > 0.0:
		ai_pitch *= maxf(0.0, 1.0 - (alpha - alpha_warn) / (_stall - alpha_warn))

	if _model:
		_model.set_controls(ai_pitch, -ai_roll, 0.0, _throttle)
	var pitch_accel : float = ai_pitch * _pitch_power * (1.0 - elev_dmg) * effectiveness
	var roll_accel  : float = -ai_roll * _roll_power * (1.0 - wing_dmg) * effectiveness
	var yaw_accel   : float = 0.0
	pitch_accel -= alpha * PITCH_STABILITY * (1.0 - elev_dmg) * effectiveness
	yaw_accel   += beta * YAW_STABILITY * (1.0 - rudd_dmg) * effectiveness
	roll_accel  -= beta * DIHEDRAL_EFFECT * effectiveness
	pitch_accel -= _pitch_rate * (PITCH_DAMPING * 0.5 + PITCH_DAMPING * 0.5 * effectiveness)
	roll_accel  -= _roll_rate * (ROLL_DAMPING * 0.5 + ROLL_DAMPING * 0.5 * effectiveness)
	yaw_accel   -= _yaw_rate * (YAW_DAMPING * 0.5 + YAW_DAMPING * 0.5 * effectiveness)
	_pitch_rate = clampf(_pitch_rate + pitch_accel * delta, -1.5, 1.5)
	_roll_rate  = clampf(_roll_rate + roll_accel * delta, -4.0, 4.0)
	_yaw_rate   = clampf(_yaw_rate + yaw_accel * delta, -0.6, 0.6)
	rotate_object_local(Vector3(1, 0, 0),  _pitch_rate * delta)
	rotate_object_local(Vector3(0, 0, 1), -_roll_rate * delta)
	rotate_object_local(Vector3(0, 1, 0), -_yaw_rate * delta)
	global_transform.basis = global_transform.basis.orthonormalized()

	global_position += _velocity * delta
	if global_position.y <= ground + 1.0 and state == State.FLYING:
		_start_falling()
		return

	# ── Guns ──────────────────────────────────────────────────────────────────
	_fire_cd -= delta
	_cannon_cd -= delta
	if shoot and not too_low:
		var to_tgt : Vector3 = target.global_position - global_position
		var cone := FIRE_CONE * (1.6 if target.is_in_group("bombers") else 1.0)
		var reach := FIRE_RANGE * (1.25 if target.is_in_group("bombers") else 1.0)
		if to_tgt.length() < reach and fwd.angle_to(to_tgt.normalized()) < cone:
			if _fire_cd <= 0.0 and _gun_ammo > 0:
				_fire(_guns[_gun_idx % _guns.size()], 1, float(_p.gun_speed))
				_gun_idx += 1
				_gun_ammo -= 1
				_fire_cd = FIRE_INTERVAL
			if _cannon_cd <= 0.0 and _cannon_ammo > 0 and not _cannons.is_empty():
				_fire(_cannons[_gun_idx % _cannons.size()], 3, float(_p.cannon_speed))
				_cannon_ammo -= 1
				_cannon_cd = CANNON_INTERVAL

func _fire(gun_local: Vector3, damage: int, muzzle_speed: float) -> void:
	var muzzle : Vector3 = global_transform * gun_local
	var aim_local := Vector3(-gun_local.x, 0.0, -CONVERGENCE_DIST).normalized()
	var aim : Vector3 = global_transform.basis * aim_local
	aim = (aim + global_transform.basis.x * randf_range(-GUN_SPREAD, GUN_SPREAD)
		+ global_transform.basis.y * randf_range(-GUN_SPREAD, GUN_SPREAD)).normalized()
	var bullet := Node3D.new()
	bullet.set_script(_bullet_script)
	bullet.velocity = _velocity + aim * muzzle_speed
	bullet.damage = damage
	bullet.shooter = self
	bullet.exclude_rids = [_body_rid]
	get_parent().add_child(bullet)
	bullet.global_position = muzzle

# ── Damage ────────────────────────────────────────────────────────────────────

func take_hit(hit_pos: Vector3, damage: int = 1, source: Node = null) -> void:
	if _dead:
		return
	if source != null:
		_last_attacker = source
	var flash := Node3D.new()
	flash.set_script(_hit_flash_script)
	flash.size = float(damage)
	get_parent().add_child(flash)
	flash.global_position = hit_pos
	var c : String = comp_hp.keys().pick_random()
	comp_hp[c] = maxi(comp_hp[c] - damage, 0)
	if c == "fuel_tank" and not _on_fire and randf() < 0.01:
		_on_fire = true
	var total := _total_hp()
	if total <= 0:
		_start_falling()
		return
	var ratio := 1.0 - float(total) / float(COMP_MAX * 5)
	_smoke_opacity = ratio
	_smoke_interval = lerpf(1.2, 0.1, ratio)
	_smoke_timer = minf(_smoke_timer, _smoke_interval)

func _start_falling() -> void:
	if _dead:
		return
	_dead = true
	_plan_bail_out()
	on_ground = false
	_dead_vel = _velocity if _velocity.length() > 1.0 else -global_transform.basis.z * TARGET_SPEED
	target = null
	get_tree().call_group("mission", "on_aircraft_down", self, _last_attacker if is_instance_valid(_last_attacker) else null)

func _update_falling(delta: float) -> void:
	_dead_age += delta
	if not _bail_times.is_empty() and _dead_age >= _bail_times[0]:
		_bail_times.pop_front()
		if global_position.y - _ground_y(global_position) > 120.0:
			_jump()
	_dead_vel.y -= 20.0 * delta
	global_position += _dead_vel * delta
	rotate_object_local(Vector3(1, 0, 0), 2.2 * delta)
	rotate_object_local(Vector3(0, 0, 1), 1.0 * delta)
	_smoke_timer -= delta
	if _smoke_timer <= 0.0:
		_smoke_timer = 0.1
		_puff(1, 2.2, 6.0)
	var g := _ground_y(global_position)
	if global_position.y <= g or _dead_age > 20.0:
		if global_position.y <= g + 5.0 and _smoke:
			_smoke.explosion(Vector3(global_position.x, g, global_position.z), 0.6)
		queue_free()

## Who gets out: each of the crew has a fair chance, one after another
func _plan_bail_out() -> void:
	var t := randf_range(0.8, 2.5)
	for i in range(CREW):
		if randf() < BAIL_CHANCE:
			_bail_times.append(t)
		t += randf_range(0.7, 1.6)

func _jump() -> void:
	var chute := Node3D.new()
	chute.set_script(ParachuteScript)
	chute.suit = Color(0.36, 0.40, 0.46) if side == "raf" else Color(0.42, 0.40, 0.34)
	var b := global_transform.basis
	chute.velocity = _dead_vel * 0.5 + Vector3.UP * 3.0
	get_parent().add_child(chute)
	chute.global_position = global_position + b.y * 1.5 + b.x * randf_range(-2.0, 2.0)
	chute.rotation.y = randf() * TAU

func _puff(kind: int, radius: float, life: float) -> void:
	if _smoke:
		_smoke.emit(global_position + global_transform.basis.z * 2.0, kind, radius, life, 1.5)

# ── Build ─────────────────────────────────────────────────────────────────────

func set_cloud_alpha(alpha: float) -> void:
	if _model:
		_model.set_cloud_alpha(alpha)

func _build_mesh() -> void:
	_model = Node3D.new()
	_model.name = _p.short
	_model.set_script(load(_p.model))
	_model.start_gear_up = scramble_delay < 0.0
	_model.position = _p.model_offset
	add_child(_model)

func _build_collision() -> void:
	var body := StaticBody3D.new()
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = _p.hitbox
	col.shape = box
	body.add_child(col)
	# Layer 2: bullets (mask 3) hit it; terrain rays (mask 1) do not
	body.collision_layer = 2
	body.collision_mask = 2
	add_child(body)
	_body_rid = body.get_rid()
