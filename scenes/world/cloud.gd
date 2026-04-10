extends Node3D
## Fluffy cumulus cloud — visual only, no collision.
## Composed of overlapping sphere blobs sharing one alpha material.
## Call depth_at(world_pos) to test containment (0 = outside, 1 = centre).

## Bounding radius — set before add_child. Controls both visual size and
## the containment sphere used for fog / visibility checks.
var radius : float = 180.0

func _ready() -> void:
	add_to_group("clouds")
	_build()

func _build() -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 1.0, 1.0, 0.52)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode    = BaseMaterial3D.CULL_DISABLED   # render inside faces too

	# Each puff: [local offset as fraction of radius, size multiplier]
	var puffs : Array = [
		[Vector3( 0.00,  0.00,  0.00), 1.00],
		[Vector3( 0.55,  0.18,  0.15), 0.80],
		[Vector3(-0.50,  0.20,  0.28), 0.76],
		[Vector3( 0.22, -0.15, -0.52), 0.70],
		[Vector3(-0.28,  0.38, -0.32), 0.66],
		[Vector3( 0.62, -0.08,  0.44), 0.62],
		[Vector3(-0.52, -0.24,  0.12), 0.65],
		[Vector3( 0.12,  0.42,  0.56), 0.58],
		[Vector3(-0.35, -0.10, -0.60), 0.55],
		[Vector3( 0.40,  0.50, -0.20), 0.60],
	]

	for puff in puffs:
		var mi := MeshInstance3D.new()
		var sm := SphereMesh.new()
		var r  : float = radius * float(puff[1])
		sm.radius          = r
		sm.height          = r * 2.0
		sm.radial_segments = 12
		sm.rings           = 7
		mi.mesh              = sm
		mi.material_override = mat
		mi.position          = (puff[0] as Vector3) * radius
		add_child(mi)

## Returns how deeply world_pos sits inside this cloud.
## 0.0 = at or outside the bounding sphere edge.
## 1.0 = exactly at the centre.
func depth_at(world_pos: Vector3) -> float:
	var d : float = global_position.distance_to(world_pos)
	var t : float = clampf(1.0 - d / radius, 0.0, 1.0)
	# Smooth-step so the edge transition is gradual, centre is strongly foggy
	return t * t * (3.0 - 2.0 * t)
