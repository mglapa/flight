extends Node3D
## Southern England / Cliffs of Dover terrain.
##
## Layout (north = +Z, south = -Z):
##   Inland rolling English countryside  (plateau ~100-180 m)
##   Flat airfield near spawn            (blended to PLATEAU_HEIGHT)
##   Chalk cliffs at COAST_Z             (~110 m sheer drop)
##   English Channel (flat sea)          (0 m)

# Heightmap shared between ground mesh, collision, and scenery spawning
const HMAP_GRID  := 150
const HMAP_WORLD := 80000.0
const HMAP_CELL  := HMAP_WORLD / HMAP_GRID
const HMAP_N     := HMAP_GRID + 1
var _hmap: PackedFloat32Array

# Coast parameters
const PLATEAU_HEIGHT :=  110.0   # cliff-top / inland base elevation (m)
const COAST_Z        := -4000.0  # base coastline Z position (south of spawn)
const COAST_VARY     := 1500.0   # bay / headland east-west variation (m)
const CLIFF_WIDTH    :=   80.0   # horizontal depth of cliff face (m)
const SEA_FLOOR      :=   -2.0   # terrain height under the sea (avoids z-fighting)

## Set false in the HTerrain scene to skip procedural terrain (enemies still spawn).
@export var spawn_terrain : bool = true

var _chaser      : Node3D = null
var _chase_clock : float  = 0.0

func _ready() -> void:
	if spawn_terrain:
		_build_hmap()
		_create_ground()
		_create_sea()
		_create_scenery()
	_spawn_enemies()

func _process(delta: float) -> void:
	_chase_clock -= delta
	if _chase_clock > 0.0:
		return
	_chase_clock = 3.0

	var players := get_tree().get_nodes_in_group("player")
	if players.is_empty():
		return
	var player : Node3D = players[0]

	# Only fighters chase — bombers have their own defensive gunner AI
	var enemies := get_tree().get_nodes_in_group("enemy_fighters")
	var closest  : Node3D = null
	var best_d   : float  = INF
	for e in enemies:
		if not is_instance_valid(e) or e.get("_dead") == true:
			continue
		var d : float = e.global_position.distance_to(player.global_position)
		if d < best_d:
			best_d  = d
			closest = e

	if closest == _chaser:
		return

	if is_instance_valid(_chaser):
		_chaser.chase_target = null

	_chaser = closest
	if closest != null:
		closest.chase_target = player

# ---------------------------------------------------------------------------
# Heightmap generation
# ---------------------------------------------------------------------------

func _build_hmap() -> void:
	# Rolling English countryside (gentle, low-frequency hills)
	var inland := FastNoiseLite.new()
	inland.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	inland.seed = 7
	inland.frequency = 0.00018
	inland.fractal_octaves = 5
	inland.fractal_gain = 0.45
	inland.fractal_lacunarity = 2.0

	# Long-wave coastline variation — creates bays and headlands
	var coast := FastNoiseLite.new()
	coast.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	coast.seed = 31
	coast.frequency = 0.000040
	coast.fractal_octaves = 2

	_hmap.resize(HMAP_N * HMAP_N)

	for zi in range(HMAP_N):
		for xi in range(HMAP_N):
			var wx  := (float(xi) / HMAP_GRID - 0.5) * HMAP_WORLD
			var wz  := (float(zi) / HMAP_GRID - 0.5) * HMAP_WORLD
			var idx := zi * HMAP_N + xi

			# Coastline meanders east-west to form bays and headlands
			var coast_z := COAST_Z + coast.get_noise_1d(wx) * COAST_VARY

			# Signed distance from cliff edge: +ve = inland, -ve = out to sea
			var d := wz - coast_z

			var h : float
			if d < -CLIFF_WIDTH:
				# Open sea — flat floor slightly below sea plane
				h = SEA_FLOOR
			elif d < 0.0:
				# Cliff face — power curve: steep lower section, eases near top
				var t := (d + CLIFF_WIDTH) / CLIFF_WIDTH   # 0 (sea) → 1 (top)
				h = pow(t, 0.35) * PLATEAU_HEIGHT
			else:
				# Inland plateau with gently rolling hills
				var v := inland.get_noise_2d(wx, wz) * 0.5 + 0.5
				h = PLATEAU_HEIGHT + v * 70.0 - 10.0       # ~100–170 m

			# Flatten the airfield / spawn area (blend toward plateau height)
			var r     := sqrt(wx * wx + wz * wz)
			var blend := clampf(1.0 - r / 700.0, 0.0, 1.0)
			_hmap[idx] = lerpf(h, PLATEAU_HEIGHT, blend * blend)

## Bilinear-interpolated terrain height at any world (x, z) position.
func sample_height(wx: float, wz: float) -> float:
	var fx := clampf((wx / HMAP_WORLD + 0.5) * HMAP_GRID, 0.0, HMAP_GRID - 1.001)
	var fz := clampf((wz / HMAP_WORLD + 0.5) * HMAP_GRID, 0.0, HMAP_GRID - 1.001)
	var xi  := int(fx);  var tx := fx - float(xi)
	var zi  := int(fz);  var tz := fz - float(zi)
	var h00 := _hmap[zi * HMAP_N + xi]
	var h10 := _hmap[zi * HMAP_N + xi + 1]
	var h01 := _hmap[(zi + 1) * HMAP_N + xi]
	var h11 := _hmap[(zi + 1) * HMAP_N + xi + 1]
	return lerp(lerp(h00, h10, tx), lerp(h01, h11, tx), tz)

# ---------------------------------------------------------------------------

func _create_ground() -> void:
	var verts := PackedVector3Array()
	var uvs   := PackedVector2Array()
	var norms := PackedVector3Array()
	var idxs  := PackedInt32Array()
	verts.resize(HMAP_N * HMAP_N)
	uvs.resize(HMAP_N * HMAP_N)
	norms.resize(HMAP_N * HMAP_N)

	for zi in range(HMAP_N):
		for xi in range(HMAP_N):
			var wx  := (float(xi) / HMAP_GRID - 0.5) * HMAP_WORLD
			var wz  := (float(zi) / HMAP_GRID - 0.5) * HMAP_WORLD
			var idx := zi * HMAP_N + xi
			verts[idx] = Vector3(wx, _hmap[idx], wz)
			uvs[idx]   = Vector2(float(xi) / HMAP_GRID, float(zi) / HMAP_GRID)
			var hL := _hmap[zi * HMAP_N + max(xi - 1, 0)]
			var hR := _hmap[zi * HMAP_N + min(xi + 1, HMAP_GRID)]
			var hD := _hmap[max(zi - 1, 0) * HMAP_N + xi]
			var hU := _hmap[min(zi + 1, HMAP_GRID) * HMAP_N + xi]
			norms[idx] = Vector3(hL - hR, 2.0 * HMAP_CELL, hD - hU).normalized()

	idxs.resize(HMAP_GRID * HMAP_GRID * 6)
	var ii := 0
	for zi in range(HMAP_GRID):
		for xi in range(HMAP_GRID):
			var b := zi * HMAP_N + xi
			idxs[ii]   = b;      idxs[ii+1] = b + HMAP_N;   idxs[ii+2] = b + 1
			idxs[ii+3] = b + 1;  idxs[ii+4] = b + HMAP_N;   idxs[ii+5] = b + HMAP_N + 1
			ii += 6

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_INDEX]  = idxs

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.mesh = mesh

	var shader := Shader.new()
	shader.code = """
shader_type spatial;
render_mode cull_disabled;
varying float v_height;
varying vec3  v_normal;
void vertex() {
	v_height = VERTEX.y;
	v_normal = NORMAL;
}
void fragment() {
	if (!FRONT_FACING) NORMAL = -NORMAL;

	float slope = v_normal.y;   // 1.0 = flat, 0.0 = sheer vertical

	vec3 col;
	if (v_height < 2.0) {
		// Sea floor — hidden under the sea plane, but shade it dark
		col = vec3(0.05, 0.10, 0.20);
	} else if (slope < 0.45 && v_height < float(PLATEAU_HEIGHT) + 5.0) {
		// Chalk cliff face — white with faint horizontal grey streaks
		float streak = mod(floor(v_height * 0.4), 2.0);
		col = mix(vec3(0.93, 0.91, 0.88), vec3(0.75, 0.73, 0.70), streak * 0.25);
	} else {
		// Inland fields — green checkerboard + rocky highlands
		vec2 sc = UV * 100.0;
		float checker = mod(floor(sc.x) + floor(sc.y), 2.0);
		col = mix(vec3(0.35, 0.65, 0.25), vec3(0.27, 0.50, 0.19), checker);
		col = mix(col, vec3(0.50, 0.45, 0.38), smoothstep(140.0, 200.0, v_height));
	}

	ALBEDO    = col;
	ROUGHNESS = 0.9;
}
"""
	# Substitute the GDScript constant into the shader string
	shader.code = shader.code.replace("float(PLATEAU_HEIGHT)", str(PLATEAU_HEIGHT))

	var mat := ShaderMaterial.new()
	mat.shader = shader
	mesh_instance.material_override = mat

	var hms := HeightMapShape3D.new()
	hms.map_width = HMAP_N
	hms.map_depth = HMAP_N
	hms.map_data  = _hmap

	var col_shape := CollisionShape3D.new()
	col_shape.shape = hms
	col_shape.scale = Vector3(HMAP_CELL, 1.0, HMAP_CELL)

	var static_body := StaticBody3D.new()
	static_body.add_child(col_shape)
	mesh_instance.add_child(static_body)

	add_child(mesh_instance)

func _create_sea() -> void:
	var mesh_inst := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(HMAP_WORLD, HMAP_WORLD)
	mesh_inst.mesh  = plane
	mesh_inst.position = Vector3(0, 0.8, 0)   # water surface

	var mat := StandardMaterial3D.new()
	mat.albedo_color    = Color(0.05, 0.18, 0.38)
	mat.roughness       = 0.08
	mat.metallic_specular = 0.5
	mesh_inst.material_override = mat

	# Collision surface at y=0.8 so planes crash when they hit the water.
	# Box top face sits exactly at the visual water surface.
	var sea_body := StaticBody3D.new()
	var sea_col  := CollisionShape3D.new()
	var sea_box  := BoxShape3D.new()
	sea_box.size = Vector3(HMAP_WORLD + 20000.0, 4.0, HMAP_WORLD + 20000.0)
	sea_col.shape = sea_box
	sea_body.add_child(sea_col)
	# Center 2 m below the surface so the top face lands exactly at y=0.8
	sea_body.position = Vector3(0.0, -2.0, 0.0)
	mesh_inst.add_child(sea_body)

	add_child(mesh_inst)

func _create_scenery() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 42

	for i in range(8000):
		var x := rng.randf_range(-38000, 38000)
		var z := rng.randf_range(-38000, 38000)
		_spawn_tree(Vector3(x, 0, z), rng)

	for i in range(120):
		var x := rng.randf_range(-36000, 36000)
		var z := rng.randf_range(-36000, 36000)
		_spawn_building(Vector3(x, 0, z), rng)

	_create_runway()

func _spawn_tree(pos: Vector3, rng: RandomNumberGenerator) -> void:
	pos.y = sample_height(pos.x, pos.z)
	# Only place trees on the inland plateau — not in the sea or on the cliff face
	if pos.y < PLATEAU_HEIGHT - 15.0:
		return

	var tree := Node3D.new()
	tree.position = pos

	var trunk := MeshInstance3D.new()
	var trunk_mesh := CylinderMesh.new()
	trunk_mesh.top_radius    = 0.2
	trunk_mesh.bottom_radius = 0.3
	trunk_mesh.height        = 3.0
	trunk.mesh = trunk_mesh
	trunk.position.y = 1.5

	var trunk_mat := StandardMaterial3D.new()
	trunk_mat.albedo_color = Color(0.45, 0.3, 0.15)
	trunk.material_override = trunk_mat

	var foliage := MeshInstance3D.new()
	var foliage_mesh := CylinderMesh.new()
	foliage_mesh.top_radius    = 0.1
	foliage_mesh.bottom_radius = 2.0 + rng.randf_range(-0.5, 0.5)
	foliage_mesh.height        = 4.0 + rng.randf_range(-1.0, 2.0)
	foliage.mesh = foliage_mesh
	foliage.position.y = 4.5

	var foliage_mat := StandardMaterial3D.new()
	var green := 0.5 + rng.randf_range(-0.1, 0.15)
	foliage_mat.albedo_color = Color(0.2, green, 0.15)
	foliage.material_override = foliage_mat

	tree.add_child(trunk)
	tree.add_child(foliage)
	add_child(tree)

func _spawn_building(pos: Vector3, rng: RandomNumberGenerator) -> void:
	pos.y = sample_height(pos.x, pos.z)
	# Only place buildings on the inland plateau
	if pos.y < PLATEAU_HEIGHT - 15.0:
		return

	var building := MeshInstance3D.new()
	var box := BoxMesh.new()
	var width  := rng.randf_range(4, 12)
	var height := rng.randf_range(3, 10)
	var depth  := rng.randf_range(4, 12)
	box.size = Vector3(width, height, depth)
	building.mesh = box
	building.position = Vector3(pos.x, pos.y + height / 2.0, pos.z)

	var mat := StandardMaterial3D.new()
	var colors := [
		Color(0.9, 0.75, 0.6),
		Color(0.85, 0.55, 0.45),
		Color(0.95, 0.9, 0.8),
		Color(0.7, 0.75, 0.8),
		Color(0.85, 0.8, 0.7),
	]
	mat.albedo_color = colors[rng.randi_range(0, colors.size() - 1)]
	mat.roughness = 0.85
	building.material_override = mat

	add_child(building)

func _spawn_enemies() -> void:
	var enemy_script  := load("res://scenes/enemies/enemy.gd")
	var bomber_script := load("res://scenes/enemies/bomber.gd")

	# ── He 111 V formation + 2 fighter escorts ────────────────────────────────
	# Player spawns at (0, 4572, 1000) facing -Z.
	# Formation starts 3 km ahead of the player (at z = -2000) and flies
	# straight toward the player in the +Z direction.
	const FORM_ALT  := 4572.0    # 15,000 ft — same as player spawn altitude
	const FORM_START_Z := -2000.0  # 3 km in front of player (player is at z=1000)

	# Lead bomber drives the whole formation
	var lead_bomber := Node3D.new()
	lead_bomber.set_script(bomber_script)
	lead_bomber.start_position   = Vector3(0.0, FORM_ALT, FORM_START_Z)
	lead_bomber.flight_direction = Vector3(0, 0, 1)   # +Z = toward player
	add_child(lead_bomber)

	# Four wingmen at V-formation offsets in the leader's local space.
	# Leader's local +Z = rearward (nose points in -Z local = +Z world).
	# Each arm steps 120 m laterally and 120 m rearward per position.
	var bomb_offsets : Array = [
		Vector3( 120, 0,  120),   # Right 1
		Vector3(-120, 0,  120),   # Left 1
		Vector3( 240, 0,  240),   # Right 2
		Vector3(-240, 0,  240),   # Left 2
	]
	for b_offset in bomb_offsets:
		var b := Node3D.new()
		b.set_script(bomber_script)
		b.flight_direction = Vector3(0, 0, 1)
		b.formation_leader = lead_bomber
		b.formation_offset = b_offset
		add_child(b)

	# Two fighter escorts flanking the outer wingmen, using formation following
	var escort_offsets : Array = [
		Vector3( 400, 0,  120),   # Right escort — outside Right 2
		Vector3(-400, 0,  120),   # Left  escort — outside Left 2
	]
	for e_offset in escort_offsets:
		var f := Node3D.new()
		f.set_script(enemy_script)
		f.formation_leader = lead_bomber
		f.formation_offset = e_offset
		add_child(f)

func _create_runway() -> void:
	var ry := PLATEAU_HEIGHT   # runway sits on the plateau

	var runway := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(15, 0.05, 200)
	runway.mesh = box
	runway.position = Vector3(0, ry + 0.03, 0)

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.3, 0.3, 0.35)
	runway.material_override = mat
	add_child(runway)

	for i in range(10):
		var marking := MeshInstance3D.new()
		var mark_mesh := BoxMesh.new()
		mark_mesh.size = Vector3(0.5, 0.06, 8)
		marking.mesh = mark_mesh
		marking.position = Vector3(0, ry + 0.06, -90 + i * 20)

		var mark_mat := StandardMaterial3D.new()
		mark_mat.albedo_color = Color(0.95, 0.95, 0.95)
		marking.material_override = mark_mat
		add_child(marking)
