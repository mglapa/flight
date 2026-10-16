extends RefCounted
## Builds streamed map pieces — terrain tiles and cliff-ribbon pieces — as
## detached node trees, from the geography in dover_geo.gd.
##
## Building is split in two so streaming is thread-safe:
##   * tile_data() / ribbon_data() run on WorkerThreadPool threads.  They only
##     read the (immutable) geography and produce plain data — vertex arrays,
##     images, instance buffers, height arrays.
##   * instantiate() runs on the main thread and turns that data into meshes,
##     materials, textures, physics shapes and nodes (rendering and physics
##     server calls stay on the main thread).
##
## All geometry is local to the piece's world origin (kept in the node's
## "world_origin" meta) so vertex coordinates stay small and precise.

const DoverScenery := preload("res://scenes/world/dover/dover_scenery.gd")

const CELLS := 50                 ## grid cells per tile side, at every level
const LU_RES := 48                ## land-use texels per tile side
const COLLISION_LEVEL := 3        ## tiles at this level or finer get collision
const SCENERY_LEVEL := 4          ## tiles at this level get trees and houses
const SEA_LEVEL := 0.8
const TREE_STEP := 26.0
const TREE_RANGE := 7000.0
const HOUSE_STEP := 36.0
const HOUSE_RANGE := 12000.0

# Cliff ribbon profile
# Seaward rows: [d_cliff, h_cliff, d_beach, h_beach, shore]
const SEA_ROWS : Array = [
	[-90.0, -24.0, -110.0, -24.0, 1.0],
	[-45.0,  -3.5,  -70.0,  -4.0, 1.0],
	[-24.0,  -0.6,  -42.0,  -0.9, 1.0],
	[-14.0,   1.0,  -26.0,   0.6, 1.0],
	[-10.0,   2.5,  -16.0,   1.3, 1.0],
]
const FACE_ROWS : Array = [0.18, 0.45, 0.72, 0.93]      ## fractions of cliff height
const CAP_ROWS : Array = [0.0, 8.0, 40.0, 110.0, 220.0, 330.0, 440.0]   ## inland distance
const RIBBON_STEP := 14.0         ## metres between cliff samples (fine LOD)
const RIBBON_PIECE := 160         ## samples per piece
const RIBBON_FAR_STEP := 4        ## coarse LOD keeps every Nth sample

var geo                           ## dover_geo.gd instance
var terrain_shader : Shader
var tree_mesh : Mesh
var house_mesh : Mesh
var tree_mat : StandardMaterial3D
var house_mat : StandardMaterial3D
var root_size := 96000.0

func _init(geo_, shader: Shader) -> void:
	geo = geo_
	terrain_shader = shader
	tree_mesh = DoverScenery._tree_mesh()
	house_mesh = DoverScenery._house_mesh()
	tree_mat = StandardMaterial3D.new()
	tree_mat.vertex_color_use_as_albedo = true
	tree_mat.vertex_color_is_srgb = true
	tree_mat.roughness = 0.95
	house_mat = StandardMaterial3D.new()
	house_mat.vertex_color_use_as_albedo = true
	house_mat.vertex_color_is_srgb = true
	house_mat.roughness = 0.85

func tile_size(level: int) -> float:
	return root_size / float(1 << level)

# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

static func grid_indices(w: int, h: int) -> PackedInt32Array:
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

## Adds a downward skirt around a w x w grid and returns mesh arrays.
## Skirt vertices are tagged with COLOR.g = 1 so the shader never paints
## them as cliff.  Normals are flat-shaded in the shader, so none are stored.
static func with_skirt(verts: PackedVector3Array, w: int, idx: PackedInt32Array, depth: float) -> Array:
	var cols := PackedColorArray()
	cols.resize(verts.size())
	cols.fill(Color(0, 0, 0, 1))
	var ring := PackedInt32Array()
	for i in range(w - 1):
		ring.append(i)
	for j in range(w - 1):
		ring.append(j * w + w - 1)
	for i in range(w - 1, 0, -1):
		ring.append((w - 1) * w + i)
	for j in range(w - 1, 0, -1):
		ring.append(j * w)
	var base := verts.size()
	for k in ring:
		verts.append(verts[k] - Vector3(0, depth, 0))
		cols.append(Color(0, 1, 0, 1))
	for r in range(ring.size()):
		var a := ring[r]
		var b := ring[(r + 1) % ring.size()]
		var a2 := base + r
		var b2 := base + (r + 1) % ring.size()
		idx.append_array([a, b, a2, b, b2, a2, a, a2, b, b, a2, b2])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_COLOR]  = cols
	arrays[Mesh.ARRAY_INDEX]  = idx
	return arrays

## Land-use texture covering a world rect; texel centres sit exactly on the
## rect's edges so neighbouring tiles agree along shared borders.
func _landuse_image(x0: float, z0: float, size: float) -> Image:
	var data := PackedByteArray()
	data.resize(LU_RES * LU_RES * 4)
	var step := size / float(LU_RES - 1)
	var i := 0
	for zi in range(LU_RES):
		for xi in range(LU_RES):
			var c : Color = geo.landuse_at(x0 + xi * step, z0 + zi * step)
			data[i]     = int(c.r * 255.0)
			data[i + 1] = int(c.g * 255.0)
			data[i + 2] = int(c.b * 255.0)
			data[i + 3] = 255
			i += 4
	return Image.create_from_data(LU_RES, LU_RES, false, Image.FORMAT_RGBA8, data)

func _material(lu: Image, lu_rect: Vector4) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = terrain_shader
	m.set_shader_parameter("landuse", ImageTexture.create_from_image(lu))
	m.set_shader_parameter("lu_rect", lu_rect)
	m.set_shader_parameter("airfield", geo.airfield_pos)
	m.set_shader_parameter("airfield_r", geo.AIRFIELD_R)
	return m

## Bilinear land-use lookup inside a tile's own image
static func _lu_sample(lu: Image, x0: float, z0: float, size: float, x: float, z: float) -> Color:
	var f := float(LU_RES - 1) / size
	var u := clampf((x - x0) * f, 0.0, LU_RES - 1.001)
	var v := clampf((z - z0) * f, 0.0, LU_RES - 1.001)
	var xi := int(u)
	var zi := int(v)
	var a := lu.get_pixel(xi, zi).lerp(lu.get_pixel(xi + 1, zi), u - xi)
	var b := lu.get_pixel(xi, zi + 1).lerp(lu.get_pixel(xi + 1, zi + 1), u - xi)
	return a.lerp(b, v - zi)

static func _hash(a: int, b: int, c: int) -> int:
	var h := a * 73856093 ^ b * 19349663 ^ c * 83492791
	return h & 0x7fffffff

# ---------------------------------------------------------------------------
# Terrain tiles
# ---------------------------------------------------------------------------

## key = Vector3i(ix, iz, level).  Worker-thread stage: plain data only.
func tile_data(key: Vector3i) -> Dictionary:
	var level := key.z
	var size := tile_size(level)
	var x0 := key.x * size
	var z0 := key.y * size
	var cell := size / CELLS
	var n := CELLS + 1
	var data := {"name": "Tile_%d_%d_%d" % [level, key.x, key.y], "origin": Vector3(x0, 0, z0)}

	var heights := PackedFloat32Array()
	heights.resize(n * n)
	var any_land := false
	for j in range(n):
		for i in range(n):
			var h : float = geo.grid_height(x0 + i * cell, z0 + j * cell)
			heights[j * n + i] = h
			if h > SEA_LEVEL - 1.0:
				any_land = true
	if not any_land:
		return data                      # open sea: the sea plane covers it

	var verts := PackedVector3Array()
	verts.resize(n * n)
	for j in range(n):
		for i in range(n):
			verts[j * n + i] = Vector3(i * cell, heights[j * n + i], j * cell)
	data.arrays = with_skirt(verts, n, grid_indices(n, n), maxf(60.0, cell * 0.6))
	var lu := _landuse_image(x0, z0, size)
	data.lu = lu
	data.lu_rect = Vector4(x0, z0, size, LU_RES)

	if level >= COLLISION_LEVEL:
		# One extra cell all round so neighbouring tiles overlap: rays exactly
		# on a tile edge would otherwise slip between the two height maps.
		var cn := n + 2
		var cdata := PackedFloat32Array()
		cdata.resize(cn * cn)
		for j in range(cn):
			for i in range(cn):
				if i >= 1 and i <= n and j >= 1 and j <= n:
					cdata[j * cn + i] = heights[(j - 1) * n + (i - 1)]
				else:
					cdata[j * cn + i] = geo.grid_height(x0 + (i - 1) * cell, z0 + (j - 1) * cell)
		data.heightmap = [cn, cdata, cell, Vector3(size * 0.5, 0.0, size * 0.5)]

	if level >= SCENERY_LEVEL:
		data.trees = _tree_buffer(key, lu, x0, z0, size)
		data.houses = _house_buffer(key, x0, z0, size)
	return data

## Main-thread stage: build the node tree from tile_data() or ribbon_data().
func instantiate(data: Dictionary) -> Node3D:
	var node := Node3D.new()
	node.name = data.name
	node.set_meta("world_origin", data.origin)
	if data.has("arrays"):
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, data.arrays)
		var mi := MeshInstance3D.new()
		mi.name = "Ground"
		mi.mesh = mesh
		mi.material_override = _material(data.lu, data.lu_rect)
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		node.add_child(mi)
	if data.has("heightmap"):
		var hm : Array = data.heightmap
		var hms := HeightMapShape3D.new()
		hms.map_width = hm[0]
		hms.map_depth = hm[0]
		hms.map_data = hm[1]
		var col := CollisionShape3D.new()
		col.shape = hms
		col.scale = Vector3(hm[2], 1.0, hm[2])
		col.position = hm[3]
		_body(node, col, "Collision")
	if data.has("faces"):
		var shape := ConcavePolygonShape3D.new()
		shape.backface_collision = true
		shape.set_faces(data.faces)
		var col := CollisionShape3D.new()
		col.shape = shape
		_body(node, col, "CliffCollision")
	if data.has("trees"):
		_multimesh(node, tree_mesh, tree_mat, data.trees, TREE_RANGE, "Trees")
	if data.has("houses"):
		_multimesh(node, house_mesh, house_mat, data.houses, HOUSE_RANGE, "Houses")
	return node

static func _body(node: Node3D, col: CollisionShape3D, name_: String) -> void:
	var body := StaticBody3D.new()
	body.name = name_
	body.add_child(col)
	node.add_child(body)

func _multimesh(parent: Node3D, mesh: Mesh, mat: Material, buf: PackedFloat32Array,
		range_end: float, name_: String) -> void:
	if buf.is_empty():
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = mesh
	mm.instance_count = buf.size() / 16
	mm.buffer = buf
	var mmi := MultiMeshInstance3D.new()
	mmi.name = name_
	mmi.multimesh = mm
	mmi.material_override = mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.visibility_range_end = range_end
	mmi.visibility_range_end_margin = range_end * 0.1
	mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	parent.add_child(mmi)

static func _instance(buf: PackedFloat32Array, b: Basis, p: Vector3, col: Color) -> void:
	buf.append_array([b.x.x, b.y.x, b.z.x, p.x,
		b.x.y, b.y.y, b.z.y, p.y,
		b.x.z, b.y.z, b.z.z, p.z,
		col.r, col.g, col.b, 1.0])

func _tree_buffer(key: Vector3i, lu: Image, x0: float, z0: float, size: float) -> PackedFloat32Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = _hash(key.x, key.y, 8)
	var buf := PackedFloat32Array()
	var texel := size / float(LU_RES - 1)
	for tj in range(LU_RES - 1):
		for ti in range(LU_RES - 1):
			var cx := x0 + ti * texel
			var cz := z0 + tj * texel
			var lu_c := _lu_sample(lu, x0, z0, size, cx + texel * 0.5, cz + texel * 0.5)
			var wooded := lu_c.r > 0.3 and lu_c.g < 0.2
			var spots := PackedVector2Array()
			if wooded:
				var z := cz
				while z < cz + texel:
					var x := cx
					while x < cx + texel:
						spots.append(Vector2(x, z))
						x += TREE_STEP
					z += TREE_STEP
			elif lu_c.g < 0.1 and lu_c.b < 0.4 and rng.randf() < 0.18:
				spots.append(Vector2(cx + rng.randf() * texel, cz + rng.randf() * texel))   # lone field tree
			for sp in spots:
				var px := sp.x + rng.randf_range(-0.45, 0.45) * TREE_STEP
				var pz := sp.y + rng.randf_range(-0.45, 0.45) * TREE_STEP
				if wooded:
					var l := _lu_sample(lu, x0, z0, size, px, pz)
					if smoothstep(0.42, 0.65, l.r) < rng.randf() or l.g > 0.2 or l.b > 0.5:
						continue
				var h : float = geo.land_height(px, pz)
				if h < 3.0 or maxf(geo.england_d(px, pz), geo.france_d(px, pz)) < 120.0:
					continue
				if Vector2(px, pz).distance_to(geo.airfield_pos) < geo.AIRFIELD_R:
					continue
				var s := rng.randf_range(0.8, 1.5)
				var b := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s, s * rng.randf_range(0.85, 1.25), s))
				var g := rng.randf()
				_instance(buf, b, Vector3(px - x0, h - 0.3, pz - z0),
					Color(0.13 + g * 0.08, 0.26 + g * 0.12, 0.08 + g * 0.04))
	return buf

func _house_buffer(key: Vector3i, x0: float, z0: float, size: float) -> PackedFloat32Array:
	var walls : Array = [Color(1.0, 0.97, 0.90), Color(0.96, 0.90, 0.82), Color(0.92, 0.86, 0.80),
		Color(0.98, 0.95, 0.92)]
	var buf := PackedFloat32Array()
	var tile := Rect2(x0, z0, size, size)
	for ti in range(geo.towns.size()):
		var t : Array = geo.towns[ti]
		var c : Vector2 = t[0]
		var r : float = t[1] * 1.3
		var area := Rect2(c - Vector2(r, r), Vector2(r, r) * 2.0).intersection(tile)
		if area.size.x <= 0.0 or area.size.y <= 0.0:
			continue
		var rng := RandomNumberGenerator.new()
		rng.seed = _hash(key.x, key.y, ti + 100)
		var street := fposmod(float(_hash(ti, 7, 7) % 1000) / 1000.0 * PI, PI)   # same for the whole town
		# Snap the sampling grid to world multiples so tile borders don't double up
		var z := ceilf(area.position.y / HOUSE_STEP) * HOUSE_STEP
		while z < area.end.y:
			var x := ceilf(area.position.x / HOUSE_STEP) * HOUSE_STEP
			while x < area.end.x:
				var px := x + rng.randf_range(-4.0, 4.0)
				var pz := z + rng.randf_range(-4.0, 4.0)
				x += HOUSE_STEP
				var dens : float = geo.town_density(px, pz)
				if dens * 1.1 < rng.randf():
					continue
				if maxf(geo.england_d(px, pz), geo.france_d(px, pz)) < 60.0:
					continue
				var h : float = geo.land_height(px, pz)
				var w := rng.randf_range(9.0, 14.0)
				var l := rng.randf_range(12.0, 22.0)
				var ht := rng.randf_range(6.0, 9.0) * (1.0 + dens * 0.3)
				var b := Basis(Vector3.UP, street + (PI * 0.5 if rng.randf() < 0.5 else 0.0)).scaled(Vector3(w, ht, l))
				_instance(buf, b, Vector3(px - x0, h - 0.5, pz - z0), walls[rng.randi() % walls.size()])
			z += HOUSE_STEP
	return buf

# ---------------------------------------------------------------------------
# Cliff ribbon pieces
# ---------------------------------------------------------------------------

## Profile row positions for coast sample i: Array of [d, h, shore]
func _ribbon_rows(pts: PackedVector2Array, nrms: PackedVector2Array, i: int, is_france: bool) -> Array:
	var p := pts[i]
	var nv := nrms[i]
	var s := i * RIBBON_STEP
	var top : float = geo.land_height(p.x, p.y)
	var c := smoothstep(14.0, 40.0, top)              # 1 = cliff, 0 = beach
	# Chunky erosion: buttresses and gullies read as big low-poly facets
	var hsh := float(_hash(i, 3 if is_france else 1, 5) % 10000) / 10000.0
	var e : float = geo.detail_noise(s * 3.7, 900.0 if is_france else 0.0) * 9.0 + (hsh - 0.5) * 4.0
	var rows : Array = []
	for row in SEA_ROWS:
		var d : float = lerpf(row[2], row[0], c)
		rows.append([Vector3(p.x + nv.x * d, lerpf(row[3], row[1], c), p.y + nv.y * d), row[4]])
	var foot_d := lerpf(-16.0, -10.0, c)
	var foot_h := lerpf(1.3, 2.5, c)
	for f in FACE_ROWS:
		var fd : float = lerpf(foot_d + (-1.0 - foot_d) * f, -10.0 + 9.0 * pow(f, 1.6), c)
		fd += e * sin(PI * f) * c
		rows.append([Vector3(p.x + nv.x * fd, foot_h + (top - foot_h) * f, p.y + nv.y * fd), (1.0 - f) * (1.0 - c)])
	for cd in CAP_ROWS:
		var q : Vector2 = p + nv * cd
		var lift : float = 0.4 * (1.0 - cd / CAP_ROWS[-1])
		var h : float = top if cd == 0.0 else geo.land_height(q.x, q.y)
		rows.append([Vector3(q.x, h + lift, q.y), 0.0])
	return rows

## One ribbon piece (worker-thread stage).  lod 0 = full detail with
## collision, 1 = coarse.
func ribbon_data(pts: PackedVector2Array, nrms: PackedVector2Array, start: int, end: int,
		is_france: bool, lod: int) -> Dictionary:
	var step := 1 if lod == 0 else RIBBON_FAR_STEP
	var all_rows := SEA_ROWS.size() + FACE_ROWS.size() + CAP_ROWS.size()
	var use_rows : Array = range(all_rows)
	if lod == 1:
		use_rows = [0, 2, 4, SEA_ROWS.size() + 1, SEA_ROWS.size() + 3]
		for k in range(CAP_ROWS.size()):
			if k % 2 == 0:
				use_rows.append(SEA_ROWS.size() + FACE_ROWS.size() + k)
	var samples := PackedInt32Array()
	var i := start
	while i < end:
		samples.append(i)
		i += step
	samples.append(end)

	var origin := pts[start]
	var data := {"name": "Cliffs_%s_%d_%d" % ["F" if is_france else "E", start, lod],
		"origin": Vector3(origin.x, 0, origin.y)}

	var w := samples.size()
	var h := use_rows.size()
	var verts := PackedVector3Array()
	var cols := PackedColorArray()
	verts.resize(w * h)
	cols.resize(w * h)
	var lo := Vector2(INF, INF)
	var hi := -lo
	var o3 := Vector3(origin.x, 0, origin.y)
	var full_rows : Array = []            # for collision
	for k in range(w):
		var rows := _ribbon_rows(pts, nrms, samples[k], is_france)
		full_rows.append(rows)
		for r in range(h):
			var rr : Array = rows[use_rows[r]]
			var v : Vector3 = rr[0]
			verts[r * w + k] = v - o3
			cols[r * w + k] = Color(rr[1], 0, 0, 1)
			lo = lo.min(Vector2(v.x, v.z))
			hi = hi.max(Vector2(v.x, v.z))
	var idxs := grid_indices(w, h)
	if is_france:
		for t in range(0, idxs.size(), 3):
			var tmp := idxs[t + 1]
			idxs[t + 1] = idxs[t + 2]
			idxs[t + 2] = tmp
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_COLOR] = cols
	arrays[Mesh.ARRAY_INDEX] = idxs
	data.arrays = arrays

	# Land use over the piece's bounding square, for the cap rows
	var span := maxf(hi.x - lo.x, hi.y - lo.y) + 20.0
	data.lu = _landuse_image(lo.x - 10.0, lo.y - 10.0, span)
	data.lu_rect = Vector4(lo.x - 10.0, lo.y - 10.0, span, LU_RES)
	if lod == 0:
		data.faces = _ribbon_faces(full_rows, o3)
	return data

## Low-resolution trimesh so aircraft collide with the cliffs and cliff tops
## (the terrain grid underneath dips below the cap there).
func _ribbon_faces(rows: Array, o3: Vector3) -> PackedVector3Array:
	var sel : Array = [2, 4, SEA_ROWS.size() + 1, SEA_ROWS.size() + 3]
	for k in range(CAP_ROWS.size()):
		sel.append(SEA_ROWS.size() + FACE_ROWS.size() + k)
	var faces := PackedVector3Array()
	var i := 0
	while i < rows.size() - 1:
		var i2 := mini(i + 2, rows.size() - 1)
		for r in range(sel.size() - 1):
			var a : Vector3 = rows[i][sel[r]][0] - o3
			var b : Vector3 = rows[i2][sel[r]][0] - o3
			var c : Vector3 = rows[i][sel[r + 1]][0] - o3
			var d : Vector3 = rows[i2][sel[r + 1]][0] - o3
			faces.append_array([a, b, c, b, d, c])
		i = i2
	return faces
