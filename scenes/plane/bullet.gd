extends Node3D
## A single gun round — moves at muzzle velocity, auto-despawns after 3 s.
## Raycasts each frame to detect terrain hits and spawns an impact effect.

var velocity     : Vector3   = Vector3.ZERO
var damage       : int       = 1   # 1 for MG rounds, 3 for cannon shells
var exclude_rids : Array = []  # set to shooter's hitbox RID to avoid self-damage

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
	timer.wait_time = 3.0
	timer.one_shot = true
	timer.timeout.connect(queue_free)
	add_child(timer)
	timer.start()

func _process(delta: float) -> void:
	var prev_pos := global_position
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
			parent.take_hit(hit.position, damage)
		else:
			# Hit terrain
			_spawn_impact(hit.position)
		queue_free()

func _spawn_impact(pos: Vector3) -> void:
	var impact := Node3D.new()
	impact.set_script(_impact_script)
	get_parent().add_child(impact)
	impact.global_position = pos
