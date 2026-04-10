extends Node3D
## He 111 medium bomber.
## Flies a steady orbit at 15,000 ft (4,572 m).
## Four defensive gunners each cover a 180° hemisphere; they fire at the player
## when within 500 m and inside their respective coverage arc.

const COMP_MAX        : int   = 8      # He 111 is tougher — 8 HP per component (40 total)
const MAX_FUEL        : float = 2400.0 # double fighter fuel — heavy bomber carries more
const BASE_FUEL_DRAIN : float = 1.0    # units/s at throttle 1.0
const FUEL_LEAK_RATE  : float = 3.0    # extra units/s when fuel tank fully destroyed

# ── Aerodynamics (He 111 H-6 class) ──────────────────────────────────────────
const AIRCRAFT_MASS  := 14000.0   # kg (loaded)
const WING_AREA      := 86.5      # m²
const WING_SPAN      := 22.6      # m
const MAX_THRUST     := 26000.0   # N  (2× Jumo 211F-2)
const AIR_DENSITY    := 1.225
const GRAVITY        := 9.81

const CL_SLOPE    := 5.0
const CL_0        := 0.15
const CD_0        := 0.030
const OSWALD      := 0.75
const STALL_ALPHA := 0.279        # rad ≈ 16°

const PITCH_POWER     := 1.5      # slow, heavy control response
const ROLL_POWER      := 1.0
const YAW_POWER       := 0.8
const PITCH_STABILITY := 1.0
const YAW_STABILITY   := 4.0
const DIHEDRAL_EFFECT := 1.5
const PITCH_DAMPING   := 3.0
const ROLL_DAMPING    := 3.0
const YAW_DAMPING     := 3.5

const ORBIT_SPEED  := 75.0        # m/s cruise (~270 km/h)
const TARGET_ALT   := 4572.0      # m  (15,000 ft)
const FIRE_RANGE   := 500.0       # m  — effective defensive range
const BULLET_SPEED := 750.0       # m/s — MG 15 muzzle velocity
const FIRE_INTERVAL := 0.18       # s  — fire rate per gunner position

# ── Gunner definitions ────────────────────────────────────────────────────────
# Local-space muzzle position for each gunner (nose, dorsal, ventral, tail)
const GUNNER_POSITIONS : Array = [
	Vector3(0.0,  0.5, -7.5),   # 0  Nose     — forward hemisphere
	Vector3(0.0,  2.0,  0.5),   # 1  Dorsal   — upper hemisphere
	Vector3(0.0, -1.5,  0.5),   # 2  Ventral  — lower hemisphere
	Vector3(0.0,  0.5,  7.5),   # 3  Tail     — rearward hemisphere
]
# The hemisphere each gunner covers: dot(dir_to_player, axis) > 0 to engage
const GUNNER_AXES : Array = [
	Vector3(0,  0, -1),   # Nose    — forward (+Z in Godot is rearward)
	Vector3(0,  1,  0),   # Dorsal  — up
	Vector3(0, -1,  0),   # Ventral — down
	Vector3(0,  0,  1),   # Tail    — rearward
]

# ── Flight path setup (set before add_child on the lead bomber) ──────────────
## World-space starting position for the lead bomber.
var start_position   : Vector3 = Vector3.ZERO
## Normalised direction of straight-line flight (set to (0,0,1) to fly toward +Z).
var flight_direction : Vector3 = Vector3(0, 0, 1)

# ── Formation following (set before add_child for wingmen) ────────────────────
## When set, this bomber flies at a fixed offset behind/beside the leader
## instead of orbiting independently.
var formation_leader : Node3D  = null
var formation_offset : Vector3 = Vector3.ZERO

# ── Shared state ──────────────────────────────────────────────────────────────
var comp_hp     : Dictionary = {"wing": 8, "elevator": 8, "rudder": 8, "engine": 8, "fuel_tank": 8}
var _on_fire    : bool  = false
var _burn_timer : float = 0.0
var _dead     : bool    = false
var _dead_vel : Vector3 = Vector3.ZERO
var _dead_age : float   = 0.0

# ── Aerodynamic state ─────────────────────────────────────────────────────────
var _fuel         : float   = MAX_FUEL
var _velocity     : Vector3 = Vector3.ZERO
var _pitch_rate   : float   = 0.0
var _roll_rate    : float   = 0.0
var _yaw_rate     : float   = 0.0
var _throttle     : float   = 0.85
var _aspect_ratio : float   = WING_SPAN * WING_SPAN / WING_AREA

# ── Per-gunner fire cooldowns ─────────────────────────────────────────────────
var _gun_cds : Array[float] = [0.0, 0.0, 0.0, 0.0]

# ── Smoke ─────────────────────────────────────────────────────────────────────
var _smoke_timer    : float = 9999.0
var _smoke_interval : float = 9999.0
var _smoke_opacity  : float = 0.0

var _smoke_puff_script = preload("res://scenes/enemies/smoke_puff.gd")
var _hit_flash_script  = preload("res://scenes/enemies/hit_flash.gd")
var _bullet_script     = preload("res://scenes/plane/bullet.gd")
var _body_rid : RID
var _mats     : Array = []   # all mesh materials — used by set_cloud_alpha()

# ── Lifecycle ─────────────────────────────────────────────────────────────────

func _ready() -> void:
	add_to_group("enemies")
	_build_mesh()
	_build_collision()
	if formation_leader != null and is_instance_valid(formation_leader):
		# Snap directly to formation slot — no pop on the first frame
		global_position        = (formation_leader.global_position
								  + formation_leader.global_transform.basis * formation_offset)
		_velocity              = formation_leader._velocity
		global_transform.basis = formation_leader.global_transform.basis
	else:
		global_position = start_position
		_velocity = flight_direction.normalized() * ORBIT_SPEED
		look_at(global_position + _velocity, Vector3.UP)

func _process(delta: float) -> void:
	if _dead:
		_update_falling(delta)
		return

	_update_bomber(delta)

	_smoke_timer -= delta
	if _smoke_timer <= 0.0:
		_smoke_timer = _smoke_interval
		_spawn_smoke_puff(false, _smoke_opacity)

	if _on_fire and not _dead:
		_burn_timer += delta
		if _burn_timer >= 1.0:
			_burn_timer -= 1.0
			var fire_comps := ["wing", "elevator", "rudder", "engine", "fuel_tank"]
			var fc : String = fire_comps.pick_random()
			if comp_hp[fc] > 0:
				comp_hp[fc] -= 1
			var total_hp := 0
			for v in comp_hp.values():
				total_hp += v
			if total_hp <= 0:
				_start_falling()
				return
			_smoke_opacity  = 1.0
			_smoke_interval = 0.05
			_smoke_timer    = minf(_smoke_timer, 0.05)

# ── Flight model + autopilot ──────────────────────────────────────────────────

func _update_bomber(delta: float) -> void:
	var fwd   : Vector3 = -global_transform.basis.z
	var up    : Vector3 =  global_transform.basis.y
	var right : Vector3 =  global_transform.basis.x
	var speed : float   = maxf(_velocity.length(), 5.0)

	var vel_fwd   : float = _velocity.dot(fwd)
	var vel_up    : float = _velocity.dot(up)
	var vel_right : float = _velocity.dot(right)

	var alpha : float = 0.0
	var beta  : float = 0.0
	if speed > 3.0:
		alpha = atan2(-vel_up,    maxf(vel_fwd, 3.0))
		beta  = atan2( vel_right, maxf(vel_fwd, 3.0))

	var q  : float = 0.5 * AIR_DENSITY * speed * speed
	var qS : float = q * WING_AREA
	var q_ref         : float = 0.5 * AIR_DENSITY * ORBIT_SPEED * ORBIT_SPEED
	var effectiveness : float = clampf(q / q_ref, 0.0, 1.5)

	# Lift
	var cl : float
	if absf(alpha) < STALL_ALPHA:
		cl = CL_0 + CL_SLOPE * alpha
	else:
		var cl_at_stall : float = CL_0 + CL_SLOPE * STALL_ALPHA * signf(alpha)
		cl = cl_at_stall * maxf(1.0 - (absf(alpha) - STALL_ALPHA) * 2.0, 0.2)

	var wing_dmg  : float = float(COMP_MAX - comp_hp["wing"])     / float(COMP_MAX)
	var elev_dmg  : float = float(COMP_MAX - comp_hp["elevator"]) / float(COMP_MAX)
	var rudd_dmg  : float = float(COMP_MAX - comp_hp["rudder"])   / float(COMP_MAX)
	var eng_dmg   : float = float(COMP_MAX - comp_hp["engine"])   / float(COMP_MAX)
	var lift_mult     : float = 1.0 - wing_dmg * 0.90
	var thrust_factor : float = 1.0 - eng_dmg
	var lift_force   : Vector3 = up * qS * cl * lift_mult

	# Drag
	var cd : float = CD_0 + (cl * cl) / (PI * _aspect_ratio * OSWALD)
	var drag_force : Vector3 = Vector3.ZERO
	if speed > 1.0:
		drag_force = -_velocity.normalized() * qS * cd

	# Side force
	var side_force : Vector3 = -right * qS * beta * 0.5

	# Thrust — auto-throttle + health degradation
	var throttle_target := 1.0 if speed < ORBIT_SPEED else 0.60
	_throttle = clampf(lerpf(_throttle, throttle_target, 1.5 * delta), 0.0, 1.0)
	var fuel_tank_dmg_f : float = float(COMP_MAX - comp_hp["fuel_tank"]) / float(COMP_MAX)
	_fuel = maxf(_fuel - (BASE_FUEL_DRAIN * _throttle + FUEL_LEAK_RATE * fuel_tank_dmg_f) * delta, 0.0)
	var fuel_factor : float = 1.0 if _fuel > 0.0 else 0.0
	var thrust_force : Vector3 = fwd * MAX_THRUST * _throttle * thrust_factor * fuel_factor

	var weight : Vector3 = Vector3.DOWN * AIRCRAFT_MASS * GRAVITY

	_velocity += ((lift_force + drag_force + side_force + thrust_force + weight)
				  / AIRCRAFT_MASS) * delta

	# ── Autopilot ─────────────────────────────────────────────────────────────
	var tgt : Vector3
	if formation_leader != null and is_instance_valid(formation_leader):
		var slot : Vector3 = (formation_leader.global_position
							  + formation_leader.global_transform.basis * formation_offset)
		# Small look-ahead prevents the waypoint coinciding with current position
		tgt = slot - formation_leader.global_transform.basis.z * 20.0
	else:
		formation_leader = null  # leader destroyed — continue straight independently
		tgt   = global_position + flight_direction.normalized() * 150.0
		tgt.y = TARGET_ALT       # altitude correction keeps the plane level
	var goal_dir : Vector3 = (tgt - global_position).normalized()

	var goal_right : float = goal_dir.dot(right)
	var goal_up    : float = goal_dir.dot(up)

	# Gentle bank angles (max ~20° for a heavy bomber)
	var ai_roll  : float = -clampf(goal_right * 2.0, -0.5, 0.5)
	# Pitch to stay on altitude + follow goal
	var ai_pitch : float = clampf(goal_up * 2.0 + 0.04, -0.4, 0.5)

	var eff_pitch_power     := PITCH_POWER     * (1.0 - elev_dmg)
	var eff_pitch_stability := PITCH_STABILITY * (1.0 - elev_dmg)
	var eff_roll_power      := ROLL_POWER      * (1.0 - wing_dmg)
	var eff_yaw_stability   := YAW_STABILITY   * (1.0 - rudd_dmg)

	var pitch_accel : float =  ai_pitch * eff_pitch_power * effectiveness
	var roll_accel  : float = -ai_roll  * eff_roll_power  * effectiveness
	var yaw_accel   : float = 0.0

	pitch_accel -= alpha * eff_pitch_stability * effectiveness
	yaw_accel   += beta  * eff_yaw_stability   * effectiveness
	roll_accel  -= beta  * DIHEDRAL_EFFECT * effectiveness

	pitch_accel -= _pitch_rate * (PITCH_DAMPING * 0.5 + PITCH_DAMPING * 0.5 * effectiveness)
	roll_accel  -= _roll_rate  * (ROLL_DAMPING  * 0.5 + ROLL_DAMPING  * 0.5 * effectiveness)
	yaw_accel   -= _yaw_rate   * (YAW_DAMPING   * 0.5 + YAW_DAMPING   * 0.5 * effectiveness)

	_pitch_rate += pitch_accel * delta
	_roll_rate  += roll_accel  * delta
	_yaw_rate   += yaw_accel   * delta

	_pitch_rate = clampf(_pitch_rate, -0.8,  0.8)
	_roll_rate  = clampf(_roll_rate,  -1.5,  1.5)
	_yaw_rate   = clampf(_yaw_rate,   -0.4,  0.4)

	rotate_object_local(Vector3(1, 0, 0),  _pitch_rate * delta)
	rotate_object_local(Vector3(0, 0, 1), -_roll_rate  * delta)
	rotate_object_local(Vector3(0, 1, 0), -_yaw_rate   * delta)
	global_transform.basis = global_transform.basis.orthonormalized()

	global_position += _velocity * delta

	if global_position.y <= _terrain_y(global_position) + 2.0:
		_start_falling()
		return

	# ── Defensive gunners ──────────────────────────────────────────────────────
	var players := get_tree().get_nodes_in_group("player")
	if players.is_empty():
		return
	var player : Node3D = players[0]
	if not is_instance_valid(player):
		return

	for i in range(4):
		_gun_cds[i] = maxf(_gun_cds[i] - delta, 0.0)
		if _gun_cds[i] > 0.0:
			continue

		var muzzle_world : Vector3 = global_transform * GUNNER_POSITIONS[i]
		var axis_world   : Vector3 = (global_transform.basis * GUNNER_AXES[i]).normalized()
		var to_player    : Vector3 = player.global_position - muzzle_world
		var dist         : float   = to_player.length()
		if dist > FIRE_RANGE:
			continue
		if (to_player / dist).dot(axis_world) <= 0.0:
			continue

		_fire_gunner(player, muzzle_world)
		_gun_cds[i] = FIRE_INTERVAL

# ── Damage ────────────────────────────────────────────────────────────────────

func take_hit(hit_pos: Vector3, damage: int = 1) -> void:
	if _dead:
		return

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
	if total_hp <= 0:
		_start_falling()
		return

	var damage_ratio := 1.0 - float(total_hp) / float(COMP_MAX * 5)
	_smoke_opacity  = damage_ratio
	_smoke_interval = lerpf(2.0, 0.08, damage_ratio)
	_smoke_timer    = minf(_smoke_timer, _smoke_interval)

func _start_falling() -> void:
	_dead     = true
	_dead_vel = _velocity if _velocity.length() > 1.0 else -global_transform.basis.z * ORBIT_SPEED

func _update_falling(delta: float) -> void:
	_dead_age  += delta
	_dead_vel.y -= 12.0 * delta   # gravity (heavy plane falls deliberately)
	global_position += _dead_vel * delta

	# Slow, heavy tumble
	rotate_object_local(Vector3(1, 0, 0),  0.5 * delta)
	rotate_object_local(Vector3(0, 0, 1),  0.15 * delta)

	_smoke_timer -= delta
	if _smoke_timer <= 0.0:
		_smoke_timer = 0.05
		_spawn_smoke_puff(true, 1.0)

	if global_position.y <= _terrain_y(global_position) or _dead_age > 30.0:
		queue_free()

# ── Firing ────────────────────────────────────────────────────────────────────

func _fire_gunner(player: Node3D, muzzle_world: Vector3) -> void:
	# Lead the target based on bullet travel time
	var to_player    : Vector3 = player.global_position - muzzle_world
	var dist         : float   = to_player.length()
	var time_to_hit  : float   = dist / BULLET_SPEED
	var player_vel   : Vector3 = player.get("velocity") if "velocity" in player else Vector3.ZERO
	var lead_pos     : Vector3 = player.global_position + player_vel * time_to_hit * 0.65
	var aim_dir      : Vector3 = (lead_pos - muzzle_world).normalized()

	var bullet := Node3D.new()
	bullet.set_script(_bullet_script)
	bullet.velocity     = _velocity + aim_dir * BULLET_SPEED
	bullet.exclude_rids = [_body_rid]
	get_parent().add_child(bullet)
	bullet.global_position = muzzle_world

# ── Terrain height ────────────────────────────────────────────────────────────

func _terrain_y(world_pos: Vector3) -> float:
	var space := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(
		Vector3(world_pos.x, 6000.0, world_pos.z),
		Vector3(world_pos.x,   -50.0, world_pos.z))
	query.collision_mask = 1   # terrain + water only
	var hit := space.intersect_ray(query)
	return hit.position.y if hit else 0.0

# ── Smoke ─────────────────────────────────────────────────────────────────────

func _spawn_smoke_puff(is_dark: bool, puff_opacity: float = 1.0) -> void:
	var puff := Node3D.new()
	puff.set_script(_smoke_puff_script)
	puff.dark    = is_dark
	puff.opacity = puff_opacity
	get_parent().add_child(puff)
	puff.global_position = global_position + Vector3(0.0, 1.0, 0.0)

# ── Mesh ──────────────────────────────────────────────────────────────────────

func set_cloud_alpha(alpha: float) -> void:
	for m in _mats:
		var mat := m as StandardMaterial3D
		mat.transparency   = (BaseMaterial3D.TRANSPARENCY_ALPHA
							  if alpha < 0.99 else BaseMaterial3D.TRANSPARENCY_DISABLED)
		mat.albedo_color.a = alpha

func _build_mesh() -> void:
	var fus_mat := StandardMaterial3D.new()
	fus_mat.albedo_color = Color(0.30, 0.33, 0.24)   # RLM 70/71 dark green-grey
	fus_mat.roughness    = 0.85
	_mats.append(fus_mat)

	var wing_mat := StandardMaterial3D.new()
	wing_mat.albedo_color = Color(0.27, 0.30, 0.21)
	wing_mat.roughness    = 0.85
	_mats.append(wing_mat)

	var engine_mat := StandardMaterial3D.new()
	engine_mat.albedo_color = Color(0.20, 0.20, 0.19)
	engine_mat.roughness    = 0.9
	_mats.append(engine_mat)

	var turret_mat := StandardMaterial3D.new()
	turret_mat.albedo_color = Color(0.55, 0.52, 0.38)
	turret_mat.roughness    = 0.6
	_mats.append(turret_mat)

	# Main fuselage — 14 m long
	var fuselage := MeshInstance3D.new()
	var fm := BoxMesh.new(); fm.size = Vector3(1.6, 2.2, 14.0)
	fuselage.mesh = fm; fuselage.material_override = fus_mat
	add_child(fuselage)

	# Nose / greenhouse cockpit section — extends forward, slightly lower
	var nose := MeshInstance3D.new()
	var nm := BoxMesh.new(); nm.size = Vector3(1.8, 1.8, 4.0)
	nose.mesh = nm; nose.material_override = fus_mat
	nose.position = Vector3(0.0, -0.1, -7.0)
	add_child(nose)

	# Wings — 22 m span
	var wings := MeshInstance3D.new()
	var wm := BoxMesh.new(); wm.size = Vector3(22.0, 0.22, 3.0)
	wings.mesh = wm; wings.material_override = wing_mat
	add_child(wings)

	# Left engine nacelle
	var left_eng := MeshInstance3D.new()
	var lem := BoxMesh.new(); lem.size = Vector3(0.9, 0.9, 3.8)
	left_eng.mesh = lem; left_eng.material_override = engine_mat
	left_eng.position = Vector3(-5.0, -0.9, -0.5)
	add_child(left_eng)

	# Right engine nacelle
	var right_eng := MeshInstance3D.new()
	var rem := BoxMesh.new(); rem.size = Vector3(0.9, 0.9, 3.8)
	right_eng.mesh = rem; right_eng.material_override = engine_mat
	right_eng.position = Vector3(5.0, -0.9, -0.5)
	add_child(right_eng)

	# Horizontal tail stabilizer
	var h_stab := MeshInstance3D.new()
	var hm := BoxMesh.new(); hm.size = Vector3(8.0, 0.16, 2.0)
	h_stab.mesh = hm; h_stab.material_override = wing_mat
	h_stab.position = Vector3(0.0, 0.0, 6.5)
	add_child(h_stab)

	# Vertical tail fin
	var v_fin := MeshInstance3D.new()
	var vfm := BoxMesh.new(); vfm.size = Vector3(0.16, 2.5, 2.2)
	v_fin.mesh = vfm; v_fin.material_override = fus_mat
	v_fin.position = Vector3(0.0, 1.4, 6.8)
	add_child(v_fin)

	# Gunner turret blister at each position (small sphere)
	var gunner_labels := ["Nose", "Dorsal", "Ventral", "Tail"]
	for i in range(4):
		var turret := MeshInstance3D.new()
		var sm := SphereMesh.new()
		sm.radius = 0.45; sm.height = 0.9
		turret.mesh = sm; turret.material_override = turret_mat
		turret.position = GUNNER_POSITIONS[i]
		turret.name = gunner_labels[i] + "Turret"
		add_child(turret)

# ── Collision ─────────────────────────────────────────────────────────────────

func _build_collision() -> void:
	var body := StaticBody3D.new()
	var col  := CollisionShape3D.new()
	var box  := BoxShape3D.new()
	box.size = Vector3(24.0, 3.0, 18.0)   # spans full wingspan + fuselage length
	col.shape = box
	body.add_child(col)
	body.collision_layer = 2   # plane hitbox layer — bullets hit it, terrain raycasts do not
	body.collision_mask  = 2
	add_child(body)
	_body_rid = body.get_rid()
