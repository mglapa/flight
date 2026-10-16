extends Node
## Floating origin (autoload "WorldOrigin").
##
## Godot positions are 32-bit floats, which start to jitter a few hundred km
## from (0, 0, 0).  So the scene is kept centred on the player: whenever the
## player strays more than REBASE_DIST from the scene origin, every movable
## object is shifted back by a whole number of km and the shift is added to
## the stored world origin (kept as 64-bit floats).
##
##   world position = scene position + (origin_x, 0, origin_z)
##
## Containers (nodes in group "origin_container", always at identity) are not
## moved themselves; their direct Node3D children are.  Shifted nodes may
## implement on_origin_shift(shift: Vector3) to fix up cached positions.
## Shaders read the origin from the global uniform `world_origin` so their
## world-space patterns stay continuous across a shift.

signal shifted(shift: Vector3)

const REBASE_DIST := 4000.0
const SNAP := 1000.0

var origin_x := 0.0
var origin_z := 0.0
var shift_count := 0

## The node the scene is kept centred on (usually the player)
var focus : Node3D = null

func reset() -> void:
	origin_x = 0.0
	origin_z = 0.0
	shift_count = 0
	focus = null
	RenderingServer.global_shader_parameter_set("world_origin", Vector2.ZERO)

func to_scene(world: Vector3) -> Vector3:
	return Vector3(world.x - origin_x, world.y, world.z - origin_z)

func to_world(scene: Vector3) -> Vector3:
	return Vector3(scene.x + origin_x, scene.y, scene.z + origin_z)

func world_x(scene_x: float) -> float:
	return scene_x + origin_x

func world_z(scene_z: float) -> float:
	return scene_z + origin_z

func _ready() -> void:
	process_physics_priority = -100     # before the aircraft and camera move
	get_tree().node_added.connect(_on_node_added)

func _on_node_added(n: Node) -> void:
	# A new top-level scene starts with a fresh origin
	if n.get_parent() == get_tree().root and n != self and n is Node3D:
		reset()

func _physics_process(_delta: float) -> void:
	if not is_instance_valid(focus):
		return
	var p := focus.global_position
	if absf(p.x) < REBASE_DIST and absf(p.z) < REBASE_DIST:
		return
	var shift := Vector3(snappedf(p.x, SNAP), 0.0, snappedf(p.z, SNAP))
	origin_x += shift.x
	origin_z += shift.z
	shift_count += 1
	for c in get_tree().get_nodes_in_group("origin_container"):
		for child in c.get_children():
			var n := child as Node3D
			if n == null or n.is_in_group("origin_container"):
				continue
			n.position -= shift
			if n.has_method("on_origin_shift"):
				n.on_origin_shift(shift)
	RenderingServer.global_shader_parameter_set("world_origin", Vector2(origin_x, origin_z))
	shifted.emit(shift)
