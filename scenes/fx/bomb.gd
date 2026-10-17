extends Node3D
## A falling high-explosive bomb.  Released by scenes/ai/bomber.gd with the
## bomber's velocity; falls under gravity with a little drag, noses over
## along its path and bursts on the ground, telling the mission where.

const DRAG := 0.012          ## per second, horizontal speed bleeds off slowly

var velocity := Vector3.ZERO
var side := "lw"             ## the dropping side, for the mission tally

static var _mesh : Mesh = null

var _world : Node = null

func _ready() -> void:
	add_to_group("bombs")
	if _mesh == null:
		_mesh = _build_mesh()
	var mi := MeshInstance3D.new()
	mi.mesh = _mesh
	mi.visibility_range_end = 3000.0
	add_child(mi)
	_world = get_tree().get_first_node_in_group("world")

static func _build_mesh() -> Mesh:
	var body := CapsuleMesh.new()
	body.radius = 0.2
	body.height = 1.5
	body.radial_segments = 6
	body.rings = 1
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.20, 0.22, 0.20)
	mat.roughness = 0.8
	body.material = mat
	return body

func _process(delta: float) -> void:
	velocity += Vector3.DOWN * 9.81 * delta
	velocity.x -= velocity.x * DRAG * delta
	velocity.z -= velocity.z * DRAG * delta
	global_position += velocity * delta
	if velocity.length() > 1.0:
		look_at(global_position + velocity, Vector3.UP if absf(velocity.normalized().y) < 0.98 else Vector3.BACK)
		rotate_object_local(Vector3.RIGHT, PI * 0.5)     # capsule axis is local Y
	# Ground test only once low enough to matter
	if global_position.y > 2500.0:
		return
	var ground := 0.0
	if _world:
		ground = _world.sample_height(global_position.x, global_position.z)
	if global_position.y <= ground:
		_burst(Vector3(global_position.x, ground, global_position.z))

func _burst(at: Vector3) -> void:
	var smoke := get_tree().get_first_node_in_group("smoke_field")
	if smoke:
		smoke.explosion(at, 1.0, at.y < 1.0)        # surface_height is 0.8 over water
	get_tree().call_group("mission", "on_bomb_impact", WorldOrigin.to_world(at), side)
	queue_free()
