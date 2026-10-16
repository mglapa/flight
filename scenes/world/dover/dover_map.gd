extends Node3D
## Stylised Strait of Dover — builds terrain, chalk cliffs, sea and scenery.
##
## Terrain is two layers sharing one material:
##   * a regular height grid (CELL m) over the core map, plus a coarse outer
##     ring reaching the horizon;
##   * a high-resolution "ribbon" mesh that follows each coastline exactly,
##     giving sheer chalk cliffs, shingle beaches and the cliff-top edge.
## The grid dips under the ribbon near the coast, so cliffs stay crisp no
## matter how coarse the grid is.

const DoverGeo     := preload("res://scenes/world/dover/dover_geo.gd")
const DoverScenery := preload("res://scenes/world/dover/dover_scenery.gd")
const TERRAIN_SHADER := preload("res://scenes/world/dover/terrain.gdshader")
const SEA_SHADER     := preload("res://scenes/world/dover/sea.gdshader")

const CELL        := 120.0
const GRID        := 800                   # cells across the core (96 km)
const CHUNK       := 100                   # cells per render chunk
const OUTER_HALF  := 420000.0              # land/sea reach well past the horizon
const OUTER_CELL0 := 3000.0                # outer ring spacing at the core edge…
const OUTER_GROW  := 1.07                  # …growing by this factor per step
const RIBBON_STEP := 14.0                  # metres between cliff samples
const RIBBON_PIECE := 160                  # samples per ribbon mesh
const LOD_STEP    := 4                     # coarse meshes keep every Nth vertex
const LOD_DIST    := 20000.0               # switch to coarse meshes beyond this
const SKIRT       := 60.0                  # skirts hide cracks between LODs
const LANDUSE_SIZE := 768
const SEA_LEVEL   := 0.8

var geo
var landuse_image : Image
var terrain_material : ShaderMaterial

var _heights := PackedFloat32Array()

func _ready() -> void:
	var t0 := Time.get_ticks_msec()
	geo = DoverGeo.new()
	landuse_image = geo.build_landuse(LANDUSE_SIZE)
	var t1 := Time.get_ticks_msec()
	_make_terrain_material()
	_build_core_grid()
	_build_outer_ring()
	var t2 := Time.get_ticks_msec()
	_build_ribbon(false)
	_build_ribbon(true)
	_build_sea()
	var t3 := Time.get_ticks_msec()

	var scenery := Node3D.new()
	scenery.set_script(DoverScenery)
	scenery.name = "Scenery"
	scenery.map = self
	add_child(scenery)
	print("Dover map built in %d ms (landuse %d, grid %d, cliffs %d, scenery %d)" % [
		Time.get_ticks_msec() - t0, t1 - t0, t2 - t1, t3 - t2, Time.get_ticks_msec() - t3])

## Ground height for spawning objects (land surface, or sea level over water).
func surface_height(x: float, z: float) -> float:
	return geo.surface_height(x, z)

## Land-use sample at a world position: r = woods, g = town, b = downland.
func landuse(x: float, z: float) -> Color:
	var u := (x + DoverGeo.CORE_HALF) / (2.0 * DoverGeo.CORE_HALF) * LANDUSE_SIZE - 0.5
	var v := (z + DoverGeo.CORE_HALF) / (2.0 * DoverGeo.CORE_HALF) * LANDUSE_SIZE - 0.5
	if u < 0.0 or v < 0.0 or u >= LANDUSE_SIZE - 1 or v >= LANDUSE_SIZE - 1:
		return Color(0, 0, 0, 0)
	var xi := int(u)
	var zi := int(v)
	var tx := u - xi
	var tz := v - zi
	var a := landuse_image.get_pixel(xi, zi).lerp(landuse_image.get_pixel(xi + 1, zi), tx)
	var b := landuse_image.get_pixel(xi, zi + 1).lerp(landuse_image.get_pixel(xi + 1, zi + 1), tx)
	return a.lerp(b, tz)

# ---------------------------------------------------------------------------

func _make_terrain_material() -> void:
	terrain_material = ShaderMaterial.new()
	terrain_material.shader = TERRAIN_SHADER
	terrain_material.set_shader_parameter("landuse", ImageTexture.create_from_image(landuse_image))
	terrain_material.set_shader_parameter("core_half", DoverGeo.CORE_HALF)
	terrain_material.set_shader_parameter("airfield", geo.airfield_pos)
	terrain_material.set_shader_parameter("airfield_r", DoverGeo.AIRFIELD_R)

func _mesh_instance(arrays: Array, name_: String, lod := -1) -> MeshInstance3D:
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mi := MeshInstance3D.new()
	mi.name = name_
	mi.mesh = mesh
	mi.material_override = terrain_material
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if lod == 0:
		mi.visibility_range_end = LOD_DIST
	elif lod == 1:
		mi.visibility_range_begin = LOD_DIST
	add_child(mi)
	return mi

# ---------------------------------------------------------------------------
# Core height grid
# ---------------------------------------------------------------------------

func _build_core_grid() -> void:
	var n := GRID + 1
	var half := GRID * CELL * 0.5
	_heights.resize(n * n)
	for zi in range(n):
		var z := -half + zi * CELL
		for xi in range(n):
			_heights[zi * n + xi] = geo.grid_height(-half + xi * CELL, z)

	for cz in range(GRID / CHUNK):
		for cx in range(GRID / CHUNK):
			_build_grid_chunk(cx * CHUNK, cz * CHUNK, half)

	# Collision matches the render grid exactly
	var hms := HeightMapShape3D.new()
	hms.map_width = n
	hms.map_depth = n
	hms.map_data  = _heights
	var col := CollisionShape3D.new()
	col.shape = hms
	col.scale = Vector3(CELL, 1.0, CELL)
	var body := StaticBody3D.new()
	body.name = "TerrainCollision"
	body.add_child(col)
	add_child(body)

func _build_grid_chunk(x0: int, z0: int, half: float) -> void:
	var n := GRID + 1
	var any_land := false
	for j in range(CHUNK + 1):
		for i in range(CHUNK + 1):
			if _heights[(z0 + j) * n + x0 + i] > SEA_LEVEL - 1.0:
				any_land = true
				break
		if any_land:
			break
	if not any_land:
		return   # open sea — the sea plane covers it
	for lod in range(2):
		var step := 1 if lod == 0 else LOD_STEP
		var m := CHUNK / step + 1
		var verts := PackedVector3Array()
		verts.resize(m * m)
		for j in range(m):
			var zi := z0 + j * step
			for i in range(m):
				var xi := x0 + i * step
				verts[j * m + i] = Vector3(-half + xi * CELL, _heights[zi * n + xi], -half + zi * CELL)
		var arrays := _with_skirt(verts, m, _grid_indices(m, m))
		_mesh_instance(arrays, "Terrain_%d_%d_lod%d" % [x0 / CHUNK, z0 / CHUNK, lod], lod)

## Adds a downward skirt around a w x w grid and returns mesh arrays.
## Skirt vertices are tagged with COLOR.g = 1 so the shader never paints them
## as cliff.  Normals are flat-shaded in the shader, so none are stored.
static func _with_skirt(verts: PackedVector3Array, w: int, idx: PackedInt32Array) -> Array:
	var cols := PackedColorArray()
	cols.resize(verts.size())
	cols.fill(Color(0, 0, 0, 1))
	var ring := PackedInt32Array()
	for i in range(w - 1):
		ring.append(i)                              # south edge
	for j in range(w - 1):
		ring.append(j * w + w - 1)                  # east edge
	for i in range(w - 1, 0, -1):
		ring.append((w - 1) * w + i)                # north edge
	for j in range(w - 1, 0, -1):
		ring.append(j * w)                          # west edge
	var base := verts.size()
	for k in ring:
		verts.append(verts[k] - Vector3(0, SKIRT, 0))
		cols.append(Color(0, 1, 0, 1))
	for r in range(ring.size()):
		var a := ring[r]
		var b := ring[(r + 1) % ring.size()]
		var a2 := base + r
		var b2 := base + (r + 1) % ring.size()
		# both windings — skirts are seen from either side
		idx.append_array([a, b, a2, b, b2, a2, a, a2, b, b, a2, b2])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_COLOR]  = cols
	arrays[Mesh.ARRAY_INDEX]  = idx
	return arrays

static func _grid_indices(w: int, h: int) -> PackedInt32Array:
	var idx := PackedInt32Array()
	idx.resize((w - 1) * (h - 1) * 6)
	var ii := 0
	for j in range(h - 1):
		for i in range(w - 1):
			var a := j * w + i
			# Clockwise from above (Godot front faces)
			idx[ii]     = a
			idx[ii + 1] = a + 1
			idx[ii + 2] = a + w
			idx[ii + 3] = a + 1
			idx[ii + 4] = a + w + 1
			idx[ii + 5] = a + w
			ii += 6
	return idx

# ---------------------------------------------------------------------------
# Outer ring — coarse land and sea out to the horizon
# ---------------------------------------------------------------------------

func _build_outer_ring() -> void:
	# Grid lines: exactly on the core edge, then progressively wider steps out
	# to the horizon.  Inside the core there are only a few sunken lines.
	var core := DoverGeo.CORE_HALF
	var half_lines : Array = [core]
	var step := OUTER_CELL0
	while half_lines[-1] < OUTER_HALF:
		half_lines.append(half_lines[-1] + step)
		step *= OUTER_GROW
	var coords : Array = []
	for i in range(half_lines.size() - 1, -1, -1):
		coords.append(-half_lines[i])
	for f in [-0.5, 0.0, 0.5]:
		coords.append(core * f)
	coords.append_array(half_lines)

	var m := coords.size()
	var verts := PackedVector3Array()
	var cols  := PackedColorArray()
	verts.resize(m * m)
	cols.resize(m * m)
	for j in range(m):
		var z : float = coords[j]
		for i in range(m):
			var x : float = coords[i]
			var h : float = geo.grid_height(x, z)
			# Inside the core this mesh is sunk out of sight below the detailed grid
			if absf(x) < core - 1.0 and absf(z) < core - 1.0:
				h = DoverGeo.SEA_FLOOR - 200.0
			verts[j * m + i] = Vector3(x, h, z)
			cols[j * m + i] = Color(0, 0, 0, 1)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_COLOR]  = cols
	arrays[Mesh.ARRAY_INDEX]  = _grid_indices(m, m)
	_mesh_instance(arrays, "OuterTerrain")

# ---------------------------------------------------------------------------
# Cliff ribbon
# ---------------------------------------------------------------------------

# Seaward profile rows: [d_cliff, h_cliff, d_beach, h_beach, shore]
const _SEA_ROWS : Array = [
	[-90.0, -24.0, -110.0, -24.0, 1.0],
	[-45.0,  -3.5,  -70.0,  -4.0, 1.0],
	[-24.0,  -0.6,  -42.0,  -0.9, 1.0],
	[-14.0,   1.0,  -26.0,   0.6, 1.0],
	[-10.0,   2.5,  -16.0,   1.3, 1.0],
]
# Cliff face rows as fractions of the cliff height
const _FACE_ROWS : Array = [0.18, 0.45, 0.72, 0.93]
# Cap rows (inland distance, m) — follow the exact land height
const _CAP_ROWS : Array = [0.0, 8.0, 40.0, 110.0, 220.0, 330.0, 440.0]

func _build_ribbon(is_france: bool) -> void:
	var line : Array = geo.coast_polyline(is_france, RIBBON_STEP)
	var pts   : PackedVector2Array = line[0]
	var nrms  : PackedVector2Array = line[1]
	var count := pts.size()
	if count < 2:
		return

	var erosion := FastNoiseLite.new()
	erosion.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	erosion.seed = 404 if is_france else 202
	erosion.frequency = 1.0 / 70.0
	erosion.fractal_octaves = 3
	var rng := RandomNumberGenerator.new()
	rng.seed = 77 if is_france else 55

	var rows := _SEA_ROWS.size() + _FACE_ROWS.size() + _CAP_ROWS.size()
	var grid := PackedVector3Array()
	var shore := PackedFloat32Array()
	grid.resize(count * rows)
	shore.resize(count * rows)

	for i in range(count):
		var p := pts[i]
		var nv := nrms[i]
		var s := i * RIBBON_STEP
		var top : float = geo.land_height(p.x, p.y)
		var c := smoothstep(14.0, 40.0, top)       # 1 = cliff, 0 = beach
		# Chunky erosion: buttresses and gullies read as big low-poly facets
		var e := erosion.get_noise_1d(s) * 7.0 + rng.randf_range(-2.0, 2.0)
		var r := 0
		for row in _SEA_ROWS:
			var d : float = lerpf(row[2], row[0], c)
			var h : float = lerpf(row[3], row[1], c)
			grid[i * rows + r] = Vector3(p.x + nv.x * d, h, p.y + nv.y * d)
			shore[i * rows + r] = row[4]
			r += 1
		var foot_d : float = lerpf(-16.0, -10.0, c)
		var foot_h : float = lerpf(1.3, 2.5, c)
		for f in _FACE_ROWS:
			var fd : float = lerpf(foot_d + (-1.0 - foot_d) * f, -10.0 + 9.0 * pow(f, 1.6), c)
			fd += e * sin(PI * f) * c
			var h : float = foot_h + (top - foot_h) * f
			grid[i * rows + r] = Vector3(p.x + nv.x * fd, h, p.y + nv.y * fd)
			shore[i * rows + r] = (1.0 - f) * (1.0 - c)
			r += 1
		for cd in _CAP_ROWS:
			var q : Vector2 = p + nv * cd
			var lift : float = 0.4 * (1.0 - cd / _CAP_ROWS[-1])
			var h : float = top if cd == 0.0 else geo.land_height(q.x, q.y)
			grid[i * rows + r] = Vector3(q.x, h + lift, q.y)
			shore[i * rows + r] = 0.0
			r += 1

	# Split into pieces for culling; neighbouring pieces share an edge sample
	var all_rows : Array = range(rows)
	var far_rows : Array = [0, 2, 4, _SEA_ROWS.size() + 1, _SEA_ROWS.size() + 3]
	for k in range(_CAP_ROWS.size()):
		if k % 2 == 0:
			far_rows.append(_SEA_ROWS.size() + _FACE_ROWS.size() + k)
	var start := 0
	var piece := 0
	while start < count - 1:
		var end := mini(start + RIBBON_PIECE, count - 1)
		_ribbon_piece(grid, shore, rows, start, end, 1, all_rows, is_france, piece, 0)
		_ribbon_piece(grid, shore, rows, start, end, LOD_STEP, far_rows, is_france, piece, 1)
		start = end
		piece += 1

	_ribbon_collision(grid, rows, count, is_france)

func _ribbon_piece(grid: PackedVector3Array, shore: PackedFloat32Array, rows: int,
		start: int, end: int, step: int, use_rows: Array, is_france: bool, piece: int, lod: int) -> void:
	var samples := PackedInt32Array()
	var i := start
	while i < end:
		samples.append(i)
		i += step
	samples.append(end)
	var w := samples.size()
	var h := use_rows.size()
	var verts := PackedVector3Array()
	var cols  := PackedColorArray()
	verts.resize(w * h)
	cols.resize(w * h)
	for k in range(w):
		for r in range(h):
			var src : int = samples[k] * rows + use_rows[r]
			# Row-major (row, sample) so the grid helper winds correctly
			verts[r * w + k] = grid[src]
			cols[r * w + k] = Color(shore[src], 0, 0, 1)
	var idxs := _grid_indices(w, h)
	if is_france:
		for t in range(0, idxs.size(), 3):
			var tmp := idxs[t + 1]
			idxs[t + 1] = idxs[t + 2]
			idxs[t + 2] = tmp
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_COLOR]  = cols
	arrays[Mesh.ARRAY_INDEX]  = idxs
	_mesh_instance(arrays, "%s_Cliffs_%d_lod%d" % ["France" if is_france else "England", piece, lod], lod)

## Low-resolution trimesh of the ribbon so planes collide with the cliffs and
## cliff tops (the height grid underneath is lower there).
func _ribbon_collision(grid: PackedVector3Array, rows: int, count: int, is_france: bool) -> void:
	var sel_rows : Array = [2, 4, _SEA_ROWS.size() + 1, _SEA_ROWS.size() + 3]
	for k in range(_CAP_ROWS.size()):
		sel_rows.append(_SEA_ROWS.size() + _FACE_ROWS.size() + k)
	var step := 2
	var faces := PackedVector3Array()
	var i := 0
	while i < count - 1:
		var i2 := mini(i + step, count - 1)
		for r in range(sel_rows.size() - 1):
			var a := grid[i * rows + sel_rows[r]]
			var b := grid[i2 * rows + sel_rows[r]]
			var c := grid[i * rows + sel_rows[r + 1]]
			var d := grid[i2 * rows + sel_rows[r + 1]]
			faces.append_array([a, b, c, b, d, c])
		i = i2
	var shape := ConcavePolygonShape3D.new()
	shape.backface_collision = true
	shape.set_faces(faces)
	var col := CollisionShape3D.new()
	col.shape = shape
	var body := StaticBody3D.new()
	body.name = "%sCliffCollision" % ("France" if is_france else "England")
	body.add_child(col)
	add_child(body)

# ---------------------------------------------------------------------------
# Sea
# ---------------------------------------------------------------------------

func _build_sea() -> void:
	var mi := MeshInstance3D.new()
	mi.name = "Sea"
	var plane := PlaneMesh.new()
	plane.size = Vector2(OUTER_HALF * 2.5, OUTER_HALF * 2.5)
	mi.mesh = plane
	mi.position = Vector3(0, SEA_LEVEL, 0)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := ShaderMaterial.new()
	mat.shader = SEA_SHADER
	mat.render_priority = -10     # draw before clouds and smoke
	mi.material_override = mat
	add_child(mi)

	# Collision: top face at the water surface so planes crash on ditching
	var body := StaticBody3D.new()
	body.name = "SeaCollision"
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(OUTER_HALF * 2.4, 4.0, OUTER_HALF * 2.4)
	col.shape = box
	body.add_child(col)
	body.position = Vector3(0, SEA_LEVEL - 2.0, 0)
	add_child(body)
