extends Node3D
## High-level cloud layer — cirrostratus, cirrus, or cirrocumulus.
## Spawns at a single altitude sampled between 20,000 and 30,000 ft (6096–9144 m).
## Set cloud_type and altitude before add_child so _ready() can build the geometry.

enum CloudType { CIRROSTRATUS, CIRRUS, CIRROCUMULUS }

## Chosen by world.gd before add_child.
var cloud_type : int   = CloudType.CIRROSTRATUS
var altitude   : float = 7500.0

# The sheet covers the full visible sky (horizon-to-horizon at game altitudes).
const SHEET_SIZE   := 1000000.0  # m — 1000 km square flat sheet
# Half-extent used when scattering individual cloud elements.
const CLOUD_SPREAD :=  55000.0   # m

func _ready() -> void:
	match cloud_type:
		CloudType.CIRROSTRATUS: _build_cirrostratus()
		CloudType.CIRRUS:       _build_cirrus()
		CloudType.CIRROCUMULUS: _build_cirrocumulus()

# ── Type builders ──────────────────────────────────────────────────────────────

func _build_cirrostratus() -> void:
	## Single thin translucent sheet that uniformly covers the sky.
	var mi  := MeshInstance3D.new()
	var pm  := PlaneMesh.new()
	pm.size        = Vector2(SHEET_SIZE, SHEET_SIZE)
	pm.subdivide_width = 0
	pm.subdivide_depth = 0
	mi.mesh              = pm
	mi.material_override = _alpha_mat(Color(0.97, 0.98, 1.00, 0.28))
	mi.position.y        = altitude
	add_child(mi)

func _build_cirrus() -> void:
	## Thin elongated streaks — sparse, east-west aligned, slightly tilted.
	var mat := _alpha_mat(Color(1.00, 1.00, 1.00, 0.42))
	var rng := RandomNumberGenerator.new()
	rng.seed = 13

	for _i in range(70):
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(
			rng.randf_range(1800.0, 5200.0),  # long axis (east-west)
			rng.randf_range(  28.0,   65.0),  # very thin vertically
			rng.randf_range(  90.0,  420.0))  # short horizontal axis
		mi.mesh              = bm
		mi.material_override = mat
		mi.position = Vector3(
			rng.randf_range(-CLOUD_SPREAD, CLOUD_SPREAD),
			altitude + rng.randf_range(-150.0, 150.0),
			rng.randf_range(-CLOUD_SPREAD, CLOUD_SPREAD))
		# Roughly east-west with ±35° variation — wind-streaked
		mi.rotation.y = deg_to_rad(rng.randf_range(-35.0, 35.0))
		# Gentle roll tilt gives a wispy, trailing appearance
		mi.rotation.z = deg_to_rad(rng.randf_range(-8.0, 8.0))
		add_child(mi)

func _build_cirrocumulus() -> void:
	## Thin base sheet + scattered small flat puffs — mackerel-sky texture.
	# Faint base veil (sparser than cirrostratus)
	var sheet_mi := MeshInstance3D.new()
	var pm       := PlaneMesh.new()
	pm.size        = Vector2(SHEET_SIZE, SHEET_SIZE)
	pm.subdivide_width = 0
	pm.subdivide_depth = 0
	sheet_mi.mesh              = pm
	sheet_mi.material_override = _alpha_mat(Color(0.97, 0.98, 1.00, 0.13))
	sheet_mi.position.y        = altitude
	add_child(sheet_mi)

	# Small flat puff clusters
	var puff_mat := _alpha_mat(Color(0.98, 0.99, 1.00, 0.32))
	var rng      := RandomNumberGenerator.new()
	rng.seed = 57

	for _i in range(240):
		var cx := rng.randf_range(-CLOUD_SPREAD, CLOUD_SPREAD)
		var cz := rng.randf_range(-CLOUD_SPREAD, CLOUD_SPREAD)
		var cy := altitude + rng.randf_range(-55.0, 55.0)

		for _j in range(rng.randi_range(3, 5)):
			var mi := MeshInstance3D.new()
			var sm := SphereMesh.new()
			var r  := rng.randf_range(280.0, 560.0)
			sm.radius          = r
			sm.height          = r * 0.32   # very flat disc shape
			sm.radial_segments = 8
			sm.rings           = 4
			mi.mesh              = sm
			mi.material_override = puff_mat
			mi.position = Vector3(
				cx + rng.randf_range(-500.0, 500.0),
				cy + rng.randf_range(-22.0,   22.0),
				cz + rng.randf_range(-500.0, 500.0))
			add_child(mi)

# ── Helper ─────────────────────────────────────────────────────────────────────

func _alpha_mat(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode    = BaseMaterial3D.CULL_DISABLED
	return mat
