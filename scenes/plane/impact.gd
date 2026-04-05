extends Node3D
## Ground impact effect — an expanding glowing ring that fades out.

const DURATION := 0.45

var _age: float = 0.0
var _mat: StandardMaterial3D

func _ready() -> void:
	var mesh_inst := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius    = 0.5
	cyl.bottom_radius = 0.5
	cyl.height        = 0.06
	cyl.rings         = 1
	mesh_inst.mesh = cyl

	_mat = StandardMaterial3D.new()
	_mat.albedo_color              = Color(1.0, 0.55, 0.1, 1.0)
	_mat.emission_enabled          = true
	_mat.emission                  = Color(1.0, 0.4, 0.05)
	_mat.emission_energy_multiplier = 5.0
	_mat.transparency              = BaseMaterial3D.TRANSPARENCY_ALPHA
	mesh_inst.material_override = _mat
	add_child(mesh_inst)

func _process(delta: float) -> void:
	_age += delta
	var t := _age / DURATION
	if t >= 1.0:
		queue_free()
		return
	# Expand outward and fade
	var s := t * 6.0
	scale = Vector3(s, 1.0, s)
	_mat.albedo_color.a              = 1.0 - t
	_mat.emission_energy_multiplier  = 5.0 * (1.0 - t)
