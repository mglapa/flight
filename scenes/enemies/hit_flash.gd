extends Node3D
## Brief bright flash at a bullet impact point on an aircraft.

const DURATION := 0.18

var _age: float = 0.0
var _mat: StandardMaterial3D

func _ready() -> void:
	var mesh_inst := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.25
	sphere.height = 0.5
	mesh_inst.mesh = sphere

	_mat = StandardMaterial3D.new()
	_mat.albedo_color              = Color(1.0, 0.9, 0.4, 1.0)
	_mat.emission_enabled          = true
	_mat.emission                  = Color(1.0, 0.85, 0.3)
	_mat.emission_energy_multiplier = 10.0
	_mat.transparency              = BaseMaterial3D.TRANSPARENCY_ALPHA
	mesh_inst.material_override = _mat
	add_child(mesh_inst)

func _process(delta: float) -> void:
	_age += delta
	var t := _age / DURATION
	if t >= 1.0:
		queue_free()
		return
	scale = Vector3.ONE * (1.0 + t * 3.0)
	_mat.albedo_color.a             = 1.0 - t
	_mat.emission_energy_multiplier = 10.0 * (1.0 - t)
