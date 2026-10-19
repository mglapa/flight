extends Node3D
## A single gun round: fired at muzzle velocity, it slows in the air (drag
## falls with altitude) and drops under gravity, and despawns after LIFETIME.
## Raycasts each frame to detect terrain hits and spawns an impact effect.
##
## Drag: dv/dx = -k·v (per metre, sea level).  A .303 / 7.92 mm round
## (k 0.00085) falls from ~800 to ~570 m/s by 400 m and to ~220 m/s at
## 1,500 m; a 20 mm shell (k 0.0005) holds its speed better.

const FlightModel := preload("res://scenes/plane/flight_model.gd")
const GRAVITY := 9.81
const LIFETIME := 4.0
const DRAG_MG := 0.00085
const DRAG_CANNON := 0.0005

var velocity     : Vector3   = Vector3.ZERO
var damage       : int       = 1   # 1 for MG rounds, 3 for cannon shells
var exclude_rids : Array = []  # set to shooter's hitbox RID to avoid self-damage
var shooter      : Node      = null  # who fired it (kill credit)
var drag_k       : float     = DRAG_MG

var _impact_script = preload("res://scenes/plane/impact.gd")

func _ready() -> void:
	var mesh_inst := MeshInstance3D.new()
	var capsule := CapsuleMesh.new()
	capsule.radius = 0.04
	capsule.height = 0.6
	mesh_inst.mesh = capsule
	mesh_inst.rotation_degrees.x = 90.0

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.95, 0.4)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.7, 0.1)
	mat.emission_energy_multiplier = 4.0
	mesh_inst.material_override = mat
	add_child(mesh_inst)

	var timer := Timer.new()
	timer.wait_time = LIFETIME
	timer.one_shot = true
	timer.timeout.connect(queue_free)
	add_child(timer)
	timer.start()

func _process(delta: float) -> void:
	var prev_pos := global_position
	var sigma := FlightModel.density(prev_pos.y) / FlightModel.RHO0
	velocity += (Vector3.DOWN * GRAVITY - velocity * velocity.length() * drag_k * sigma) * delta
	global_position += velocity * delta

	# Raycast from previous to current position to catch terrain intersections
	var query := PhysicsRayQueryParameters3D.create(prev_pos, global_position)
	query.collision_mask = 3  # layer 1 = terrain/water, layer 2 = plane hitboxes
	query.exclude        = exclude_rids
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit:
		var parent = hit.collider.get_parent()
		if parent != null and parent.has_method("take_hit"):
			# Hit an enemy aircraft
			parent.take_hit(hit.position, damage, shooter if is_instance_valid(shooter) else null)
		else:
			# Hit terrain
			_spawn_impact(hit.position)
		queue_free()

func _spawn_impact(pos: Vector3) -> void:
	var impact := Node3D.new()
	impact.set_script(_impact_script)
	get_parent().add_child(impact)
	impact.global_position = pos

## Fire control: the launch direction (body-relative to the shooter's
## motion: bullet velocity = shooter_vel + d * muzzle) that meets a target at
## r (relative to the muzzle) moving at target_vel, allowing for drag and
## drop.  Returns [d, time of flight], or [] when the target is out of reach.
## `precise` refines the estimate by flying test rounds (for the gunsight).
static func intercept(r: Vector3, shooter_vel: Vector3, target_vel: Vector3, muzzle: float,
		k: float, altitude: float, precise := false) -> Array:
	var k0 := k
	k *= FlightModel.density(altitude) / FlightModel.RHO0
	var t := r.length() / muzzle
	var p := r
	var v0 := muzzle
	for i in range(12):
		p = r + target_vel * t + Vector3.UP * (0.5 * GRAVITY * t * t)
		var u := p.normalized()
		var along := u.dot(shooter_vel)
		var disc := muzzle * muzzle - shooter_vel.length_squared() + along * along
		if disc < 0.0:
			return []
		v0 = along + sqrt(disc)
		var x := k * p.length()
		if x > 3.0:
			return []
		t = (exp(x) - 1.0) / (k * v0)
	if t > LIFETIME:
		return []
	var d := (p.normalized() * v0 - shooter_vel) / muzzle
	if precise:
		# Fly a round, then shift the aim point by its miss at the target's range
		for pass_ in range(2):
			var miss := _fly_miss(r, shooter_vel + d * muzzle, target_vel, k0, altitude)
			if miss == Vector3.INF:
				break
			p -= miss
			var u := p.normalized()
			var along := u.dot(shooter_vel)
			var disc := muzzle * muzzle - shooter_vel.length_squared() + along * along
			if disc < 0.0:
				return []
			d = (u * (along + sqrt(disc)) - shooter_vel) / muzzle
	return [d, t]

## Miss vector (round minus target) as the round passes the target's range
static func _fly_miss(r: Vector3, v: Vector3, target_vel: Vector3, k: float, altitude: float) -> Vector3:
	var dt := 1.0 / 30.0
	var pos := Vector3.ZERO
	var t := 0.0
	while t < LIFETIME:
		var sigma := FlightModel.density(altitude + pos.y) / FlightModel.RHO0
		var nv := v + (Vector3.DOWN * GRAVITY - v * v.length() * k * sigma) * dt
		var np := pos + nv * dt
		var tgt := r + target_vel * (t + dt)
		var rel := tgt - np
		# Passed the target along the line of fire: interpolate the closest point
		if rel.dot(nv) <= 0.0:
			var tgt0 := r + target_vel * t
			var a := (tgt0 - pos).dot(v)
			var b := (tgt - np).dot(nv)
			var f := clampf(a / maxf(a - b, 1e-6), 0.0, 1.0)
			return pos.lerp(np, f) - tgt0.lerp(tgt, f)
		pos = np
		v = nv
		t += dt
	return Vector3.INF

## Upward tilt that harmonises fixed guns to cross the sight line at `dist`
## in level flight, making up for the drop
static func harmonise(muzzle: float, k: float, dist: float) -> float:
	var t := (exp(k * dist) - 1.0) / (k * muzzle)
	return 0.5 * GRAVITY * t * t / dist
