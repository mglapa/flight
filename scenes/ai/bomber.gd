extends Node3D
## AI medium bomber, either side: He 111 (Luftwaffe) or Wellington (RAF).
##
## The formation leader flies `route` (world-space waypoints: in, over the
## target, out and home); wingmen hold their slot on it.  Every bomber
## times its own release: once the predicted fall of a bomb lands inside
## the target area it lays a stick of bombs.  Defensive gunners engage
## enemy fighters inside their arc.  The mission director promotes a new
## leader when one is lost.

const COMP_MAX        : int   = 8      # bombers are tough — 8 HP per component
const BASE_FUEL_DRAIN : float = 1.0
const FUEL_LEAK_RATE  : float = 3.0
const AIR_DENSITY := 1.225
const GRAVITY     := 9.81
const CL_SLOPE    := 5.0
const CL_0        := 0.15
const OSWALD      := 0.75
const STALL_ALPHA := 0.279

const PITCH_POWER     := 1.5           # slow, heavy control response
const ROLL_POWER      := 1.0
const PITCH_STABILITY := 1.0
const YAW_STABILITY   := 4.0
const DIHEDRAL_EFFECT := 1.5
const PITCH_DAMPING   := 3.0
const ROLL_DAMPING    := 3.0
const YAW_DAMPING     := 3.5

const CRUISE        := 75.0            # m/s (~270 km/h)
const FIRE_RANGE    := 500.0
const FIRE_INTERVAL := 0.3             # per gunner
const GUN_SPREAD    := 0.03              # hand-held guns in a slipstream
const STICK_GAP     := 0.35            # s between bombs in a stick
const WP_RADIUS     := 1500.0

const PROFILES := {
	"he111": {
		"name": "He 111", "model": "res://scenes/enemies/he111/he111_model.gd",
		"mass": 14000.0, "wing_area": 86.5, "span": 22.6, "thrust": 26000.0, "cd0": 0.030,
		"bullet_speed": 750.0, "bay": Vector3(0.0, -0.9, -0.8), "bombs": 8,
		"hitbox": Vector3(24.0, 3.0, 18.0),
		# Gunner muzzles and the hemisphere each covers: nose, dorsal, ventral, tail
		"gunners": [[Vector3(0.08, 0.12, -8.5), Vector3(0, 0, -1)], [Vector3(0.0, 1.35, 3.3), Vector3(0, 1, 0)],
			[Vector3(-0.15, -1.2, 3.5), Vector3(0, -1, 0)], [Vector3(0.0, 0.4, 8.4), Vector3(0, 0, 1)]],
	},
	"wellington": {
		"name": "Wellington", "model": "res://scenes/enemies/wellington/wellington_model.gd",
		"mass": 12500.0, "wing_area": 78.0, "span": 26.3, "thrust": 24000.0, "cd0": 0.030,
		"bullet_speed": 745.0, "bay": Vector3(0.0, -1.15, -1.2), "bombs": 9,
		"hitbox": Vector3(26.0, 3.5, 19.0),
		# Nose turret, tail turret, port and starboard beam guns
		"gunners": [[Vector3(0.0, 0.0, -10.0), Vector3(0, 0, -1)], [Vector3(0.0, 0.42, 10.1), Vector3(0, 0, 1)],
			[Vector3(-1.0, 0.35, 2.6), Vector3(-1, 0, 0)], [Vector3(1.0, 0.35, 2.6), Vector3(1, 0, 0)]],
	},
}

# ── Set before add_child ─────────────────────────────────────────────────────
var bomber_type := "he111"
var side := "lw"
## World-space waypoints (x, altitude, z) for the leader
var route : Array = []
var wp := 0
## Formation: when set, hold `formation_offset` (leader's local frame) on it
var formation_leader : Node3D = null
var formation_offset := Vector3.ZERO
## Aiming point (world x, z) and radius of the target area
var bomb_target := Vector2.INF
var target_radius := 2000.0

# ── State ────────────────────────────────────────────────────────────────────
var comp_hp : Dictionary = {"wing": 8, "elevator": 8, "rudder": 8, "engine": 8, "fuel_tank": 8}
var bombs_left := 8
var bombed := false            ## released its load over the target
var _releasing := false
var _release_clock := 0.0
var _on_fire := false
var _burn_timer := 0.0
var _dead := false
var _dead_vel := Vector3.ZERO
var _dead_age := 0.0
var _last_attacker : Node = null

var _p : Dictionary
var _velocity := Vector3.ZERO
var _pitch_rate := 0.0
var _roll_rate := 0.0
var _yaw_rate := 0.0
var _throttle := 0.85
var _fuel := 4000.0
var _aspect := 6.0

var _gun_cds : Array[float] = [0.0, 0.0, 0.0, 0.0]
var _hostiles : Array = []
var _hostile_clock := 0.0

var _smoke_timer := 9999.0
var _smoke_interval := 9999.0
var _smoke_opacity := 0.0

var _hit_flash_script = preload("res://scenes/enemies/hit_flash.gd")
var _bullet_script = preload("res://scenes/plane/bullet.gd")
var _bomb_script = preload("res://scenes/fx/bomb.gd")
var _body_rid : RID
var _model : Node3D = null
var _world : Node = null
var _smoke : Node = null

# ── Lifecycle ─────────────────────────────────────────────────────────────────

func _ready() -> void:
	if not PROFILES.has(bomber_type):
		bomber_type = "he111"
	_p = PROFILES[bomber_type]
	_aspect = _p.span * _p.span / _p.wing_area
	bombs_left = int(_p.bombs)
	add_to_group("aircraft")
	add_to_group("bombers")
	add_to_group("ai")
	add_to_group("side_" + side)
	add_to_group("allies" if side == GameSettings.side else "enemies")
	_world = get_tree().get_first_node_in_group("world")
	_smoke = get_tree().get_first_node_in_group("smoke_field")
	_build_mesh()
	_build_collision()
	if formation_leader != null and is_instance_valid(formation_leader):
		global_position = formation_leader.global_position + formation_leader.global_transform.basis * formation_offset
		global_transform.basis = formation_leader.global_transform.basis
		_velocity = formation_leader.get_velocity()
	else:
		_velocity = -global_transform.basis.z * CRUISE

func get_velocity() -> Vector3:
	return _velocity

func is_airborne() -> bool:
	return not _dead

## Becomes the formation leader (the old one was lost): fly the route from here
func take_lead(route_: Array, wp_: int) -> void:
	route = route_
	wp = wp_
	formation_leader = null

func _process(delta: float) -> void:
	if _dead:
		_update_falling(delta)
		return
	_update_flight(delta)
	if _dead:
		return
	_update_bombing(delta)
	_update_gunners(delta)
	_smoke_timer -= delta
	if _smoke_timer <= 0.0:
		_smoke_timer = _smoke_interval
		_puff(1 if _smoke_opacity > 0.6 else 0, 2.0 + _smoke_opacity * 2.0, 3.0)
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

func _total_hp() -> int:
	var t := 0
	for v in comp_hp.values():
		t += v
	return t

func _ground_y(p: Vector3) -> float:
	return _world.sample_height(p.x, p.z) if _world else 0.0

# ── Flight model + autopilot ──────────────────────────────────────────────────

func _update_flight(delta: float) -> void:
	var fwd   : Vector3 = -global_transform.basis.z
	var up    : Vector3 =  global_transform.basis.y
	var right : Vector3 =  global_transform.basis.x
	var speed : float   = maxf(_velocity.length(), 5.0)
	var vel_fwd : float = _velocity.dot(fwd)
	var alpha := 0.0
	var beta := 0.0
	if speed > 3.0:
		alpha = atan2(-_velocity.dot(up), maxf(vel_fwd, 3.0))
		beta  = atan2(_velocity.dot(right), maxf(vel_fwd, 3.0))
	var q  : float = 0.5 * AIR_DENSITY * speed * speed
	var qS : float = q * _p.wing_area
	var effectiveness : float = clampf(q / (0.5 * AIR_DENSITY * CRUISE * CRUISE), 0.0, 1.5)
	var cl : float
	if absf(alpha) < STALL_ALPHA:
		cl = CL_0 + CL_SLOPE * alpha
	else:
		cl = (CL_0 + CL_SLOPE * STALL_ALPHA * signf(alpha)) * maxf(1.0 - (absf(alpha) - STALL_ALPHA) * 2.0, 0.2)
	var wing_dmg : float = float(COMP_MAX - comp_hp["wing"]) / float(COMP_MAX)
	var elev_dmg : float = float(COMP_MAX - comp_hp["elevator"]) / float(COMP_MAX)
	var rudd_dmg : float = float(COMP_MAX - comp_hp["rudder"]) / float(COMP_MAX)
	var eng_dmg  : float = float(COMP_MAX - comp_hp["engine"]) / float(COMP_MAX)
	var lift_force : Vector3 = up * qS * cl * (1.0 - wing_dmg * 0.9)
	var cd : float = _p.cd0 + (cl * cl) / (PI * _aspect * OSWALD)
	var drag_force : Vector3 = -_velocity.normalized() * qS * cd if speed > 1.0 else Vector3.ZERO
	var side_force : Vector3 = -right * qS * beta * 0.5

	# ── Autopilot: hold the slot, or fly the route ────────────────────────────
	var tgt : Vector3
	var want := CRUISE
	var assist := Vector3.INF
	if formation_leader != null and is_instance_valid(formation_leader) and not formation_leader.get("_dead"):
		var lb := formation_leader.global_transform.basis
		var slot := formation_leader.global_position + lb * formation_offset
		var err := slot - global_position
		# Fly the leader's heading plus a bounded correction toward the slot
		tgt = global_position - lb.z * 350.0 + err.limit_length(250.0)
		var lv : Vector3 = formation_leader.get_velocity()
		want = lv.length() + clampf(err.dot(-lb.z) * 0.05, -10.0, 15.0)
		assist = lv + err.limit_length(120.0) * 0.12
		wp = formation_leader.wp
	else:
		formation_leader = null
		if wp < route.size():
			var w : Vector3 = WorldOrigin.to_scene(route[wp])
			var flat := Vector2(w.x - global_position.x, w.z - global_position.z)
			if flat.length() < WP_RADIUS:
				wp += 1
				if wp >= route.size():
					get_tree().call_group("mission", "on_bomber_home", self)
					queue_free()
					return
			tgt = Vector3(w.x, w.y, w.z)
			# Hold altitude on the way, steer by heading
			var d := Vector3(flat.x, 0.0, flat.y).normalized()
			tgt = global_position + d * 600.0
			tgt.y = w.y
		else:
			tgt = global_position + fwd * 600.0
	var agl := global_position.y - _ground_y(global_position)
	if agl < 400.0:
		tgt = global_position + Vector3(fwd.x, 0.0, fwd.z).normalized() * 600.0 + Vector3.UP * 250.0
	var goal_dir := (tgt - global_position).normalized()
	var ai_roll := -clampf(goal_dir.dot(right) * 2.0, -0.5, 0.5)
	# Height hold: climb or sink at a rate proportional to the height error
	var vs_want := clampf((tgt.y - global_position.y) * 0.08, -6.0, 6.0)
	if speed < CRUISE - 8.0:
		vs_want = minf(vs_want, (speed - (CRUISE - 8.0)) * 0.5)     # slow: trade height for speed
	var ai_pitch := clampf((vs_want - _velocity.y) * 0.12 + 0.04 - _pitch_rate * 0.6, -0.4, 0.5)
	# Stall protection: ease off as the angle of attack nears the stall, push if past it
	var a_warn := STALL_ALPHA * 0.6
	if alpha > a_warn:
		ai_pitch = minf(ai_pitch, lerpf(0.2, -0.4, clampf((alpha - a_warn) / (STALL_ALPHA - a_warn), 0.0, 1.0)))

	var throttle_target := clampf(0.6 + (want - speed) * 0.06, 0.0, 1.0)
	_throttle = clampf(lerpf(_throttle, throttle_target, 1.5 * delta), 0.0, 1.0)
	var fuel_tank_dmg : float = float(COMP_MAX - comp_hp["fuel_tank"]) / float(COMP_MAX)
	_fuel = maxf(_fuel - (BASE_FUEL_DRAIN * _throttle + FUEL_LEAK_RATE * fuel_tank_dmg) * delta, 0.0)
	var thrust_force : Vector3 = fwd * _p.thrust * _throttle * (1.0 - eng_dmg) * (1.0 if _fuel > 0.0 else 0.0)
	var weight : Vector3 = Vector3.DOWN * _p.mass * GRAVITY
	_velocity += ((lift_force + drag_force + side_force + thrust_force + weight) / _p.mass) * delta
	if assist != Vector3.INF:
		# Formation-keeping help (a real crew has a lifetime of practice): damps
		# the slow swings the autopilot alone can't
		_velocity = _velocity.lerp(assist, clampf(delta * 0.5, 0.0, 1.0))

	if _model:
		_model.set_controls(ai_pitch, -ai_roll, 0.0, _throttle)
	var pitch_accel : float = ai_pitch * PITCH_POWER * (1.0 - elev_dmg) * effectiveness
	var roll_accel  : float = -ai_roll * ROLL_POWER * (1.0 - wing_dmg) * effectiveness
	var yaw_accel   : float = 0.0
	pitch_accel -= alpha * PITCH_STABILITY * (1.0 - elev_dmg) * effectiveness
	yaw_accel   += beta * YAW_STABILITY * (1.0 - rudd_dmg) * effectiveness
	roll_accel  -= beta * DIHEDRAL_EFFECT * effectiveness
	pitch_accel -= _pitch_rate * (PITCH_DAMPING * 0.5 + PITCH_DAMPING * 0.5 * effectiveness)
	roll_accel  -= _roll_rate * (ROLL_DAMPING * 0.5 + ROLL_DAMPING * 0.5 * effectiveness)
	yaw_accel   -= _yaw_rate * (YAW_DAMPING * 0.5 + YAW_DAMPING * 0.5 * effectiveness)
	_pitch_rate = clampf(_pitch_rate + pitch_accel * delta, -0.8, 0.8)
	_roll_rate  = clampf(_roll_rate + roll_accel * delta, -1.5, 1.5)
	_yaw_rate   = clampf(_yaw_rate + yaw_accel * delta, -0.4, 0.4)
	rotate_object_local(Vector3(1, 0, 0),  _pitch_rate * delta)
	rotate_object_local(Vector3(0, 0, 1), -_roll_rate * delta)
	rotate_object_local(Vector3(0, 1, 0), -_yaw_rate * delta)
	global_transform.basis = global_transform.basis.orthonormalized()
	global_position += _velocity * delta
	if global_position.y <= _ground_y(global_position) + 2.0:
		_start_falling()

# ── Bombing ───────────────────────────────────────────────────────────────────

func _update_bombing(delta: float) -> void:
	if bomb_target == Vector2.INF or bombs_left <= 0:
		return
	if not _releasing:
		var w := WorldOrigin.to_world(global_position)
		var tgt_scene := WorldOrigin.to_scene(Vector3(bomb_target.x, 0.0, bomb_target.y))
		var fall_h := maxf(global_position.y - _ground_y(tgt_scene), 10.0)
		var t_fall := sqrt(2.0 * fall_h / GRAVITY)
		var impact := Vector2(w.x + _velocity.x * t_fall, w.z + _velocity.z * t_fall)
		# Start the stick a little short so it walks across the aiming point
		if impact.distance_to(bomb_target) < target_radius * 0.7:
			_releasing = true
			bombed = true
			get_tree().call_group("mission", "on_bombs_released", self)
		return
	_release_clock -= delta
	if _release_clock <= 0.0:
		_release_clock = STICK_GAP
		bombs_left -= 1
		var b := Node3D.new()
		b.set_script(_bomb_script)
		b.velocity = _velocity
		b.side = side
		get_parent().add_child(b)
		b.global_position = global_transform * _p.bay

# ── Defensive gunners ─────────────────────────────────────────────────────────

func _update_gunners(delta: float) -> void:
	_hostile_clock -= delta
	if _hostile_clock <= 0.0:
		_hostile_clock = 0.4
		_hostiles.clear()
		var enemy_side := "raf" if side == "lw" else "lw"
		for n in get_tree().get_nodes_in_group("side_" + enemy_side):
			if not n.is_in_group("fighters") or n.get("_dead") == true:
				continue
			if (n as Node3D).global_position.distance_to(global_position) < FIRE_RANGE * 1.5:
				_hostiles.append(n)
	if _hostiles.is_empty():
		return
	var gunners : Array = _p.gunners
	for i in range(gunners.size()):
		_gun_cds[i] = maxf(_gun_cds[i] - delta, 0.0)
		if _gun_cds[i] > 0.0:
			continue
		var muzzle : Vector3 = global_transform * (gunners[i][0] as Vector3)
		var axis : Vector3 = (global_transform.basis * (gunners[i][1] as Vector3)).normalized()
		var best : Node3D = null
		var best_d := FIRE_RANGE
		for h in _hostiles:
			if not is_instance_valid(h):
				continue
			var to : Vector3 = (h as Node3D).global_position - muzzle
			var d := to.length()
			if d < best_d and to.dot(axis) > 0.0:
				best_d = d
				best = h
		if best:
			_fire_gunner(best, muzzle)
			_gun_cds[i] = FIRE_INTERVAL

func _fire_gunner(target: Node3D, muzzle: Vector3) -> void:
	var bs : float = _p.bullet_speed
	var dist := target.global_position.distance_to(muzzle)
	var tv : Vector3 = target.get_velocity() if target.has_method("get_velocity") else Vector3.ZERO
	var lead := target.global_position + (tv - _velocity) * (dist / bs) * 0.65
	var aim := (lead - muzzle).normalized()
	var b := global_transform.basis
	aim = (aim + b.x * randf_range(-GUN_SPREAD, GUN_SPREAD) + b.y * randf_range(-GUN_SPREAD, GUN_SPREAD)).normalized()
	var bullet := Node3D.new()
	bullet.set_script(_bullet_script)
	bullet.velocity = _velocity + aim * bs
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
		if source.is_in_group("ai"):
			damage *= 2              # the AI pilots get a hand against the bombers
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
	_dead_vel = _velocity if _velocity.length() > 1.0 else -global_transform.basis.z * CRUISE
	get_tree().call_group("mission", "on_aircraft_down", self, _last_attacker if is_instance_valid(_last_attacker) else null)

func _update_falling(delta: float) -> void:
	_dead_age += delta
	_dead_vel.y -= 12.0 * delta
	global_position += _dead_vel * delta
	rotate_object_local(Vector3(1, 0, 0), 0.5 * delta)
	rotate_object_local(Vector3(0, 0, 1), 0.15 * delta)
	_smoke_timer -= delta
	if _smoke_timer <= 0.0:
		_smoke_timer = 0.08
		_puff(1, 3.5, 7.0)
	var g := _ground_y(global_position)
	if global_position.y <= g or _dead_age > 40.0:
		if global_position.y <= g + 5.0 and _smoke:
			_smoke.explosion(Vector3(global_position.x, g, global_position.z), 1.2)
		queue_free()

func _puff(kind: int, radius: float, life: float) -> void:
	if _smoke:
		_smoke.emit(global_position + global_transform.basis.z * 3.0, kind, radius, life, 1.5)

# ── Build ─────────────────────────────────────────────────────────────────────

func set_cloud_alpha(alpha: float) -> void:
	if _model:
		_model.set_cloud_alpha(alpha)

func _build_mesh() -> void:
	_model = Node3D.new()
	_model.name = _p.name
	_model.set_script(load(_p.model))
	_model.start_gear_up = true
	add_child(_model)

func _build_collision() -> void:
	var body := StaticBody3D.new()
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = _p.hitbox
	col.shape = box
	body.add_child(col)
	body.collision_layer = 2
	body.collision_mask = 2
	add_child(body)
	_body_rid = body.get_rid()
