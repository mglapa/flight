extends RefCounted
## Builds streamed map pieces — terrain tiles and cliff-ribbon pieces — as
## detached node trees, from the real-world geography in geo/geo_data.gd.
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
const Buildings := preload("res://scenes/world/dover/buildings.gd")
const Streets := preload("res://scenes/world/geo/streets.gd")
const BUILDING_SHADER := preload("res://scenes/world/dover/building.gdshader")

## Wall colours of 1930s Britain: London stock brick (fresh and sooty),
## red brick, render and pebbledash.  [colour, weight] per building kind.
const WALLS := {
	"house": [[Color(0.74, 0.64, 0.48), 3], [Color(0.64, 0.36, 0.27), 3], [Color(0.88, 0.85, 0.76), 2],
		[Color(0.72, 0.70, 0.64), 2], [Color(0.55, 0.40, 0.30), 1]],
	"terrace": [[Color(0.72, 0.62, 0.46), 4], [Color(0.56, 0.50, 0.40), 3], [Color(0.62, 0.34, 0.26), 3],
		[Color(0.86, 0.83, 0.74), 1]],
	"block": [[Color(0.64, 0.34, 0.26), 3], [Color(0.70, 0.60, 0.45), 2], [Color(0.84, 0.80, 0.70), 2],
		[Color(0.52, 0.47, 0.40), 1]],
	"factory": [[Color(0.60, 0.34, 0.26), 3], [Color(0.48, 0.30, 0.24), 2], [Color(0.62, 0.56, 0.44), 1]],
}
## Roof picks (building.gdshader roof_color): 0-0.6 slates, 0.6-1 tiles
const ROOFS := {"house": [0.0, 1.0], "terrace": [0.0, 0.6], "block": [0.0, 0.6], "factory": [0.0, 0.6]}

const CELLS := 50                 ## grid cells per tile side, at every level
const LU_RES := 48                ## land-use texels per tile side
const COLLISION_LEVEL := 3        ## tiles at this level or finer get collision
const SCENERY_LEVEL := 4          ## tiles at this level get trees and houses
const SEA_LEVEL := 0.8
const TREE_STEP := 26.0
const TREE_RANGE := 7000.0
const HOUSE_RANGE := 8000.0
const HOUSE_DETAIL := 1600.0      ## detailed building meshes within this
const LOD_CELL := 1500.0          ## buildings are grouped in cells this size so
                                  ## the detail switch happens near the camera
const BUILDING_CAP := 9000        ## per tile: beyond this, cities thin out evenly
const WATER_RES := [64, 64, 64, 128, 160]   ## water texture size per tile level

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

var geo                           ## geo_data.gd instance
var terrain_shader : Shader
var tree_mesh : Mesh
var tree_mat : StandardMaterial3D
var house_mat : ShaderMaterial
var building_meshes := {}         ## type name -> Mesh
var root_size := 96000.0

func _init(geo_, shader: Shader) -> void:
	geo = geo_
	terrain_shader = shader
	tree_mesh = DoverScenery._tree_mesh()
	# [near mesh, distant mesh] per type
	building_meshes = {
		"semi": [Buildings.semi(), Buildings.semi_far()],
		"cottage": [Buildings.cottage(), Buildings.cottage_far()],
		"terrace": [Buildings.terrace(), Buildings.terrace_far()],
		"block": [Buildings.block(), Buildings.block_far()],
		"factory": [Buildings.factory(), Buildings.factory_far()],
		"church": [Buildings.church(), null],
	}
	tree_mat = StandardMaterial3D.new()
	tree_mat.vertex_color_use_as_albedo = true
	tree_mat.vertex_color_is_srgb = true
	tree_mat.roughness = 0.95
	house_mat = ShaderMaterial.new()
	house_mat.shader = BUILDING_SHADER
	house_mat.set_shader_parameter("fade_end", HOUSE_RANGE)
	house_mat.set_shader_parameter("fade_start", HOUSE_RANGE * 0.78)

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

func _material(lu: Image, lu_rect: Vector4, water: Image = null, water_rect := Vector4()) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = terrain_shader
	m.set_shader_parameter("landuse", ImageTexture.create_from_image(lu))
	m.set_shader_parameter("lu_rect", lu_rect)
	if water:
		m.set_shader_parameter("water_tex", ImageTexture.create_from_image(water))
		m.set_shader_parameter("water_rect", water_rect)
		m.set_shader_parameter("has_water", true)
	m.set_shader_parameter("airfield", geo.airfield_pos)
	m.set_shader_parameter("airfield_r", geo.AIRFIELD_R)
	return m

## Signed distance to river banks and lake shores, (e + 64) as bytes; null
## when there is no water anywhere near the rect.
func _water_image(x0: float, z0: float, size: float, res: int) -> Image:
	var rect := Rect2(x0, z0, size, size)
	var river : bool = geo.rivers_near(rect, 400.0)
	if not river and geo.lake_clearance(rect) > 300.0:
		return null
	var data := PackedByteArray()
	data.resize(res * res)
	var step := size / float(res - 1)
	var any := false
	for j in range(res):
		for i in range(res):
			var e : float = geo.water_edge(x0 + i * step, z0 + j * step)
			var v := clampi(int(round(e + 64.0)), 0, 255)
			data[j * res + i] = v
			if v < 70:
				any = true
	if not any:
		return null
	return Image.create_from_data(res, res, false, Image.FORMAT_R8, data)

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
	var water := _water_image(x0, z0, size, WATER_RES[mini(level, WATER_RES.size() - 1)])
	if water:
		data.water = water
		data.water_rect = Vector4(x0, z0, size, water.get_width())

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
		data.buildings = _town_buffers(key, lu, x0, z0, size, water)
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
		mi.material_override = _material(data.lu, data.lu_rect, data.get("water"), data.get("water_rect", Vector4()))
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
	if data.has("buildings") and not data.buildings.is_empty():
		var bmat := house_mat.duplicate() as ShaderMaterial    # own copy so the tile can fade in
		node.set_meta("building_mat", bmat)
		for t in data.buildings:
			var meshes : Array = building_meshes[t]
			var cells : Dictionary = data.buildings[t]
			for ck in cells:
				var buf : PackedFloat32Array = cells[ck]
				var nm := "%s_%d_%d" % [t, ck.x, ck.y]
				if meshes[1] == null:
					_multimesh(node, meshes[0], bmat, buf, HOUSE_RANGE + 200.0, nm, true)
				else:
					_multimesh(node, meshes[0], bmat, buf, HOUSE_DETAIL, nm, true)
					_multimesh(node, meshes[1], bmat, buf, HOUSE_RANGE + 200.0, nm + "_far", true, HOUSE_DETAIL)
		node.set_meta("has_buildings", not data.buildings.is_empty())
	return node

static func _body(node: Node3D, col: CollisionShape3D, name_: String) -> void:
	var body := StaticBody3D.new()
	body.name = name_
	body.add_child(col)
	node.add_child(body)

func _multimesh(parent: Node3D, mesh: Mesh, mat: Material, buf: PackedFloat32Array,
		range_end: float, name_: String, custom := false, range_begin := 0.0) -> void:
	if buf.is_empty():
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = not custom
	mm.use_custom_data = custom
	mm.mesh = mesh
	mm.instance_count = buf.size() / 16
	mm.buffer = buf
	var mmi := MultiMeshInstance3D.new()
	mmi.name = name_
	mmi.multimesh = mm
	mmi.material_override = mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.visibility_range_end = range_end
	mmi.visibility_range_begin = range_begin
	if custom:
		mmi.add_to_group("town_buildings")      # building.gdshader fades these itself
	else:
		mmi.visibility_range_end_margin = range_end * 0.1
		mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	parent.add_child(mmi)

static func _instance(buf: PackedFloat32Array, b: Basis, p: Vector3, col: Color) -> void:
	buf.append_array([b.x.x, b.y.x, b.z.x, p.x,
		b.x.y, b.y.y, b.z.y, p.y,
		b.x.z, b.y.z, b.z.z, p.z,
		col.r, col.g, col.b, col.a])

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
				if h < 3.0 or geo.coast_d(px, pz) < 120.0 or geo.water_edge(px, pz) < 12.0:
					continue
				if Vector2(px, pz).distance_to(geo.airfield_pos) < geo.AIRFIELD_R:
					continue
				var s := rng.randf_range(0.8, 1.5)
				var b := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s, s * rng.randf_range(0.85, 1.25), s))
				var g := rng.randf()
				_instance(buf, b, Vector3(px - x0, h - 0.3, pz - z0),
					Color(0.13 + g * 0.08, 0.26 + g * 0.12, 0.08 + g * 0.04))
	return buf

# ---------------------------------------------------------------------------
# Towns: buildings lining the procedural streets (see geo/streets.gd)
# ---------------------------------------------------------------------------

## Buildings for one tile, by type: {type name: instance buffer}
func _town_buffers(key: Vector3i, lu: Image, x0: float, z0: float, size: float, water: Image) -> Dictionary:
	var any_town := false
	for j in range(0, LU_RES, 2):
		for i in range(0, LU_RES, 2):
			if lu.get_pixel(i, j).g > 0.05:
				any_town = true
				break
		if any_town:
			break
	if not any_town:
		return {}
	var rect := Rect2(x0, z0, size, size)
	var ctx := {"rect": rect, "lu": lu, "x0": x0, "z0": z0, "size": size, "sites": {},
		"rng": RandomNumberGenerator.new(), "out": {}, "water": water}
	ctx.rng.seed = _hash(key.x, key.y, 100)
	var D := Streets.DIST_CELL
	for cy in range(floori((z0 - D) / D), floori((z0 + size + D) / D) + 1):
		for cx in range(floori((x0 - D) / D), floori((x0 + size + D) / D) + 1):
			var id := Vector2i(cx, cy)
			var st := _site(ctx, id)
			if not rect.grow(D * 1.2).has_point(st):
				continue
			var g := Streets.grid(id)
			_street_family(ctx, id, st, g, true)
			_street_family(ctx, id, st, g, false)
			_church(ctx, id, st, g)
	# Thin evenly if the tile holds too many
	var total := 0
	for t in ctx.out:
		total += (ctx.out[t] as PackedFloat32Array).size() / 16
	if total > BUILDING_CAP:
		var keep := float(BUILDING_CAP) / total
		for t in ctx.out:
			var src : PackedFloat32Array = ctx.out[t]
			var dst := PackedFloat32Array()
			var acc := 0.0
			for i in range(src.size() / 16):
				acc += keep
				if acc >= 1.0:
					acc -= 1.0
					dst.append_array(src.slice(i * 16, i * 16 + 16))
			ctx.out[t] = dst
	# Group each type's buildings into LOD cells (instance x / z are floats 3 and 11)
	var grouped := {}
	for t in ctx.out:
		var src : PackedFloat32Array = ctx.out[t]
		var members := {}           # cell -> Array of instance indices (Arrays are shared, packed arrays are not)
		for i in range(src.size() / 16):
			var ck := Vector2i(int(src[i * 16 + 3] / LOD_CELL), int(src[i * 16 + 11] / LOD_CELL))
			if not members.has(ck):
				members[ck] = []
			members[ck].append(i)
		var cells := {}
		for ck in members:
			var buf := PackedFloat32Array()
			for i in members[ck]:
				buf.append_array(src.slice(i * 16, i * 16 + 16))
			cells[ck] = buf
		grouped[t] = cells
	return grouped

## Water-edge distance from the tile's own water texture (fast; 191 m = far)
func _water_at(ctx: Dictionary, p: Vector2) -> float:
	var img : Image = ctx.water
	if img == null:
		return 1000.0
	var res := img.get_width()
	var f := float(res - 1) / float(ctx.size)
	var u := clampf((p.x - ctx.x0) * f, 0.0, res - 1.001)
	var v := clampf((p.y - ctx.z0) * f, 0.0, res - 1.001)
	var i := int(u)
	var j := int(v)
	var a := lerpf(img.get_pixel(i, j).r, img.get_pixel(i + 1, j).r, u - i)
	var b := lerpf(img.get_pixel(i, j + 1).r, img.get_pixel(i + 1, j + 1).r, u - i)
	return lerpf(a, b, v - j) * 255.0 - 64.0

func _site(ctx: Dictionary, id: Vector2i) -> Vector2:
	var sites : Dictionary = ctx.sites
	if not sites.has(id):
		sites[id] = Streets.site(id.x, id.y)
	return sites[id]

## Distance from p to the edge of the district around site st (negative
## when p is in a neighbouring district).  nbrs = the 8 neighbouring sites.
static func _border(p: Vector2, st: Vector2, nbrs: PackedVector2Array) -> float:
	var md := INF
	var mr := st - p
	for s in nbrs:
		var r := s - p
		md = minf(md, ((mr + r) * 0.5).dot((r - mr).normalized()))
	return md

## District id and border distance at p, using the tile's site cache
func _district(ctx: Dictionary, p: Vector2) -> Array:
	var D := Streets.DIST_CELL
	var n := Vector2i(floori(p.x / D), floori(p.y / D))
	var best := INF
	var bid := n
	var bs := Vector2.ZERO
	for j in range(-1, 2):
		for i in range(-1, 2):
			var c := Vector2i(n.x + i, n.y + j)
			var s := _site(ctx, c)
			var d := p.distance_squared_to(s)
			if d < best:
				best = d
				bid = c
				bs = s
	var mr := bs - p
	var md := INF
	for j in range(-1, 2):
		for i in range(-1, 2):
			if i == 0 and j == 0:
				continue
			var r := _site(ctx, Vector2i(bid.x + i, bid.y + j)) - p
			md = minf(md, ((mr + r) * 0.5).dot((r - mr).normalized()))
	return [bid, md]

## Picks a weighted wall colour and roof value for a building kind; the
## roof value's fraction also seeds the per-building colour jitter
static func _paint(rng: RandomNumberGenerator, kind: String) -> Color:
	var list : Array = WALLS.get(kind, WALLS.house)
	var total := 0.0
	for e in list:
		total += e[1]
	var r := rng.randf() * total
	var wall : Color = list[0][0]
	for e in list:
		r -= e[1]
		if r <= 0.0:
			wall = e[0]
			break
	var rr : Array = ROOFS.get(kind, ROOFS.house)
	wall.a = rng.randf_range(rr[0], rr[1] - 0.001)
	return wall

func _emit(ctx: Dictionary, type: String, centre: Vector2, along: Vector2, frontage: float,
		depth: float, height: float, tint: Color) -> void:
	var out : Dictionary = ctx.out
	if not out.has(type):
		out[type] = PackedFloat32Array()
	var x3 := Vector3(along.x, 0, along.y)
	var z3 := x3.cross(Vector3.UP)                   # right-handed: x × y = z
	var b := Basis(x3 * frontage, Vector3.UP * height, z3 * depth)
	var h : float = geo.land_height(centre.x, centre.y)
	_instance(out[type], b, Vector3(centre.x - ctx.x0, h - 0.4, centre.y - ctx.z0), tint)

## Walk every street of one family (u-lines or v-lines) in a district,
## lining both sides with buildings sized for the local density.
func _street_family(ctx: Dictionary, id: Vector2i, st: Vector2, g: Array, u_lines: bool) -> void:
	var rect : Rect2 = ctx.rect
	var rng : RandomNumberGenerator = ctx.rng
	var dir : Vector2 = g[0]
	var perp := Vector2(-dir.y, dir.x)
	var across := dir if u_lines else perp           # line normal (points away from street)
	var run := perp if u_lines else dir              # along the street
	var sp : float = g[1] if u_lines else g[2]
	var off : float = g[3] if u_lines else g[4]
	var cross_sp : float = g[2] if u_lines else g[1]
	var cross_off : float = g[4] if u_lines else g[3]
	var industrial : bool = g[5]
	var nbrs := PackedVector2Array()
	for j in range(-1, 2):
		for i in range(-1, 2):
			if i != 0 or j != 0:
				nbrs.append(_site(ctx, Vector2i(id.x + i, id.y + j)))
	var R := Streets.DIST_CELL * 0.95           # districts never reach further from their site
	var R2 := R * R
	for k in range(floori(-R / sp - off), ceili(R / sp - off) + 1):
		var w := Streets.street_width(k)
		var line_c := st + across * (k + off) * sp
		var t := -R
		while t < R:
			var base := line_c + run * t
			# Cheap rejects first: outside the tile or district, or no town here
			if not rect.grow(40.0).has_point(base) or base.distance_squared_to(st) > R2:
				t += 60.0
				continue
			var lu := _lu_sample(ctx.lu, ctx.x0, ctx.z0, ctx.size, base.x, base.y)
			if lu.g < 0.05:
				t += 40.0
				continue
			var dens : float = clampf(lu.g, 0.0, 1.0)
			var kind := "house"
			var frontage := rng.randf_range(9.0, 13.0)
			var depth := rng.randf_range(8.0, 11.0)
			var height := rng.randf_range(5.5, 7.0)
			var gap := rng.randf_range(5.0, 10.0)
			if industrial and dens > 0.3:
				kind = "factory"
				frontage = rng.randf_range(30.0, 60.0)
				depth = rng.randf_range(22.0, 38.0)
				height = rng.randf_range(8.0, 12.0)
				gap = rng.randf_range(6.0, 14.0)
			elif dens > 0.86:
				kind = "block"
				frontage = rng.randf_range(20.0, 36.0)
				depth = rng.randf_range(14.0, 22.0)
				height = rng.randf_range(10.0, 14.0) + (dens - 0.86) * 60.0 * rng.randf()
				gap = rng.randf_range(0.5, 2.0)
			elif dens > 0.36:
				kind = "terrace"
				frontage = rng.randf_range(28.0, 50.0)
				depth = rng.randf_range(9.0, 11.0)
				height = rng.randf_range(7.0, 8.5)
				gap = rng.randf_range(3.0, 7.0)
			var mid := base + run * frontage * 0.5
			for side in [-1.0, 1.0]:
				if rng.randf() > clampf(dens * 1.7, 0.0, 1.0):
					continue
				var centre : Vector2 = mid + across * side * (w * 0.5 + 2.0 + depth * 0.5)
				if not rect.has_point(centre):
					continue
				if _border(centre, st, nbrs) < Streets.BORDER_W * 0.5 + depth * 0.5 + 1.0:
					continue
				# Keep clear of the cross streets at block corners
				var qc := (centre - st).dot(run) / cross_sp - cross_off
				var kc := roundi(qc)
				if absf(qc - kc) * cross_sp - Streets.street_width(kc) * 0.5 < frontage * 0.5 + 1.5:
					continue
				var big := maxf(frontage, depth) * 0.5
				if _water_at(ctx, centre) < big + 4.0 or geo.coast_d(centre.x, centre.y) < big + 30.0:
					continue
				var type := kind
				if kind == "house":
					type = "cottage" if rng.randf() < 0.35 else "semi"
				_emit(ctx, type, centre, run, frontage, depth, height, _paint(rng, kind))
			t += frontage + gap

## One parish church per district, in the middle of a block near its centre
func _church(ctx: Dictionary, id: Vector2i, st: Vector2, g: Array) -> void:
	if Streets.fhash(id.x, id.y, 21) > 0.55:
		return
	var dir : Vector2 = g[0]
	var perp := Vector2(-dir.y, dir.x)
	var ou : float = g[3]
	var ov : float = g[4]
	var u : float = (floorf(-ou) + 0.5 + ou) * (g[1] as float)
	var v : float = (floorf(-ov) + 0.5 + ov) * (g[2] as float)
	var p : Vector2 = st + dir * u + perp * v
	var rect : Rect2 = ctx.rect
	if not rect.has_point(p) or geo.town_density(p.x, p.y) < 0.3:
		return
	var dd := _district(ctx, p)
	if dd[0] != id or dd[1] < 40.0 or _water_at(ctx, p) < 40.0:
		return
	var s := 0.9 + 0.25 * Streets.fhash(id.x, id.y, 22)
	_emit(ctx, "church", p, perp, s, s, s, Color(1, 1, 1, Streets.fhash(id.x, id.y, 23)))

# ---------------------------------------------------------------------------
# Cliff ribbon pieces
# ---------------------------------------------------------------------------

## Profile row positions for coast sample i: Array of [d, h, shore]
func _ribbon_rows(pts: PackedVector2Array, nrms: PackedVector2Array, i: int, seed_: int, gi: int) -> Array:
	var p := pts[i]
	var nv := nrms[i]
	var s := gi * RIBBON_STEP           # arc position along the whole coastline
	# Elevation data smears a cliff edge over a few hundred metres, so take the
	# highest ground just inland as the cliff top
	var top : float = maxf(geo.land_height(p.x, p.y), maxf(
		geo.land_height(p.x + nv.x * 120.0, p.y + nv.y * 120.0),
		geo.land_height(p.x + nv.x * 250.0, p.y + nv.y * 250.0)))
	var c := smoothstep(14.0, 40.0, top)              # 1 = cliff, 0 = beach
	# Chunky erosion: buttresses and gullies read as big low-poly facets
	var hsh := float(_hash(gi, seed_, 5) % 10000) / 10000.0
	var e : float = geo.detail_noise(s * 3.7, seed_ * 131.0) * 9.0 + (hsh - 0.5) * 4.0
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
		if cd <= 110.0:
			h = maxf(h, top)              # keep the cliff-top lip level with the top
		rows.append([Vector3(q.x, h + lift, q.y), 0.0])
	return rows

## One ribbon piece (worker-thread stage).  lod 0 = full detail with
## collision, 1 = coarse.
## `first` is the index of pts[0] along the whole coastline, so erosion and
## coarse sampling line up across neighbouring pieces.
func ribbon_data(pts: PackedVector2Array, nrms: PackedVector2Array, start: int, end: int,
		seed_: int, lod: int, first := 0) -> Dictionary:
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
	var data := {"name": "Cliffs_%d_%d_%d" % [seed_, start, lod],
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
		var rows := _ribbon_rows(pts, nrms, samples[k], seed_, first + samples[k])
		full_rows.append(rows)
		for r in range(h):
			var rr : Array = rows[use_rows[r]]
			var v : Vector3 = rr[0]
			verts[r * w + k] = v - o3
			cols[r * w + k] = Color(rr[1], 0, 0, 1)
			lo = lo.min(Vector2(v.x, v.z))
			hi = hi.max(Vector2(v.x, v.z))
	var idxs := grid_indices(w, h)       # normals point inland-left, so no flip needed
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
