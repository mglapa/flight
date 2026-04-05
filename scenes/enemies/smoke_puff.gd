extends Node3D
## A single rising smoke puff. Set `dark` before adding to the scene tree.

const DURATION := 2.2

## Set to true for thick black smoke (heavy damage / falling).
var dark: bool = false

var _age: float = 0.0
var _vel: Vector3
var _mat: StandardMaterial3D

func _ready() -> void:
	var mesh_inst := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.5
	sphere.height = 1.0
	mesh_inst.mesh = sphere

	_mat = StandardMaterial3D.new()
	_mat.albedo_color = Color(0.12, 0.12, 0.12, 0.85) if dark else Color(0.45, 0.42, 0.40, 0.6)
	_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mesh_inst.material_override = _mat
	add_child(mesh_inst)

	_vel = Vector3(randf_range(-1.5, 1.5), randf_range(4.0, 8.0), randf_range(-1.5, 1.5))

func _process(delta: float) -> void:
	_age += delta
	var t := _age / DURATION
	if t >= 1.0:
		queue_free()
		return
	global_position += _vel * delta
	var s := 1.0 + t * 4.0
	scale = Vector3(s, s, s)
	_mat.albedo_color.a = (0.85 if dark else 0.6) * (1.0 - t)
