extends Node3D
## Streaming map manager for the stylised Strait of Dover.
##
## Terrain is a quadtree of square tiles: 96 km roots split down to 6 km
## leaves (120 m cells) near the focus point, each tile 50 x 50 cells, with
## skirts hiding cracks between levels.  Cliff ribbons stream as coastline
## pieces in two levels of detail.  Pieces are built on WorkerThreadPool
## threads by tile_builder.gd, cached, and swapped in on the main thread.
## A coarse tile stays visible until every finer tile replacing it is ready,
## so the ground never has holes.
##
## Positions: everything is generated in world coordinates and placed at
## world - WorldOrigin, so the scene stays centred on the player.  This node
## and the scenery node are origin containers.

const GeoData      := preload("res://scenes/world/geo/geo_data.gd")
const DoverScenery := preload("res://scenes/world/dover/dover_scenery.gd")
const TileBuilder  := preload("res://scenes/world/dover/tile_builder.gd")
const TERRAIN_SHADER := preload("res://scenes/world/dover/terrain.gdshader")
const SEA_SHADER     := preload("res://scenes/world/dover/sea.gdshader")

const ROOT_SIZE    := 96000.0
const MAX_LEVEL    := 4               ## 96 km → 6 km leaves (120 m cells)
const SPLIT_K      := 2.0             ## split when closer than K × tile size
const ROOT_RADIUS  := 420000.0        ## terrain reaches past the horizon
const RIB_FINE     := 15000.0         ## full-detail cliffs (with collision) within
const RIB_FAR      := 80000.0         ## coarse cliffs within
const UPDATE_EVERY := 0.2
const MAX_JOBS     := 8               ## tiles building at once
const FRAME_BUDGET_MS := 4.0          ## time per frame for adding finished pieces
const CACHE_MAX    := 900
const SEA_LEVEL    := 0.8
const SEA_SIZE     := 1100000.0

## Where to centre the first build (world coords) before the player exists
var initial_focus := Vector3(0, 4572, 1000)

## The first build runs on worker threads over several frames; `built` fires
## once the ground around initial_focus is complete.  load_progress() is 0..1.
signal built
var is_built := false
var _init_total := 0
var _init_done := 0
var _build_t0 := 0

var geo
var builder

var _ready_tiles := {}       ## key → detached-or-shown Node3D
var _shown := {}             ## key → true, currently in the tree
var _jobs := {}              ## key → WorkerThreadPool task id
var _done : Array = []       ## [key, data, is_ribbon] finished by workers
var _mutex := Mutex.new()

var _pieces : Array = []     ## [coastline, s0, s1, centre (Vector2), radius]
var _piece_cells := {}       ## Vector2i -> Array of piece indices
const PIECE_CELL := 8000.0
var _rib_ready := {}         ## Vector3i(piece, lod, 0) → Node3D
var _rib_shown := {}
var _rib_jobs := {}

var _sea : MeshInstance3D
var _sea_body : StaticBody3D
var _clock := 0.0
var _fading := {}            ## tile node -> appear (0..1) for towns fading in
var _instant := true         ## first build: no fade
const FADE_TIME := 1.1
var stats := {"tiles_built": 0, "max_frame_ms": 0.0}

func _ready() -> void:
	add_to_group("origin_container")
	add_to_group("world_map")          # the HUD map finds the geography here
	var t0 := Time.get_ticks_msec()
	if geo == null:                    # world.gd normally hands the geography in
		geo = GeoData.new(GameSettings.map_scale)
	builder = TileBuilder.new(geo, TERRAIN_SHADER)
	builder.root_size = ROOT_SIZE
	_build_coasts()
	_build_sea()

	# First build: everything needed around the spawn point, in parallel on
	# the worker threads; _process turns the results into nodes as they come
	var focus := initial_focus
	for k in _wanted_tiles(focus):
		_request_tile(k)
	for k in _wanted_ribbons(focus):
		if k.y == 0:              # nearby full-detail cliffs now; distant ones stream in
			_request_ribbon(k)
	_init_total = _jobs.size() + _rib_jobs.size()
	_build_t0 = t0

## Fraction of the first build done (worker results turned into nodes)
func load_progress() -> float:
	if is_built:
		return 1.0
	return float(_init_done) / float(maxi(_init_total, 1))

func _finish_first_build() -> void:
	_apply(initial_focus)
	_instant = false
	var scenery := Node3D.new()
	scenery.set_script(DoverScenery)
	scenery.name = "Scenery"
	scenery.map = self
	add_child(scenery)
	is_built = true
	print("Dover map ready in %d ms (%d tiles, %d cliff pieces)" % [
		Time.get_ticks_msec() - _build_t0, _shown.size(), _rib_shown.size()])
	built.emit()

func _exit_tree() -> void:
	# Never free the map while workers still reference it
	for id in _jobs.values() + _rib_jobs.values():
		WorkerThreadPool.wait_for_task_completion(id)
	_jobs.clear()
	_rib_jobs.clear()
	# Cached pieces outside the tree are not freed with it
	for d in [_ready_tiles, _rib_ready]:
		for n in d.values():
			if is_instance_valid(n) and not (n as Node3D).is_inside_tree():
				(n as Node3D).free()
		d.clear()
	_mutex.lock()
	_done.clear()
	_mutex.unlock()

func _process(delta: float) -> void:
	if not is_built:
		# Spend most of the frame on the first build; the loading screen still animates
		_init_done += _collect(25.0)
		if _jobs.is_empty() and _rib_jobs.is_empty() and _done.is_empty():
			_finish_first_build()
		return
	var t0 := Time.get_ticks_usec()
	var focus := _focus_world()
	_follow_sea(focus)
	_clock -= delta
	if _clock <= 0.0:
		_clock = UPDATE_EVERY
		_apply(focus)
	_collect(FRAME_BUDGET_MS)
	_update_fades(delta)
	stats.max_frame_ms = maxf(stats.max_frame_ms, (Time.get_ticks_usec() - t0) / 1000.0)

## Ground height for spawning objects (world coords; sea level over water).
func surface_height(x: float, z: float) -> float:
	return geo.surface_height(x, z)

func _focus_world() -> Vector3:
	var cam := get_viewport().get_camera_3d()
	if cam:
		return WorldOrigin.to_world(cam.global_position)
	if is_instance_valid(WorldOrigin.focus):
		return WorldOrigin.to_world(WorldOrigin.focus.global_position)
	return initial_focus

func _place(node: Node3D) -> void:
	var w : Vector3 = node.get_meta("world_origin")
	node.position = WorldOrigin.to_scene(w)

# ---------------------------------------------------------------------------
# Quadtree selection
# ---------------------------------------------------------------------------

func _tile_size(level: int) -> float:
	return ROOT_SIZE / float(1 << level)

func _tile_distance(key: Vector3i, focus: Vector3) -> float:
	var s := _tile_size(key.z)
	var x0 := key.x * s
	var z0 := key.y * s
	var dx := maxf(maxf(x0 - focus.x, focus.x - (x0 + s)), 0.0)
	var dz := maxf(maxf(z0 - focus.z, focus.z - (z0 + s)), 0.0)
	var dy := maxf(focus.y - 100.0, 0.0)
	return sqrt(dx * dx + dz * dz + dy * dy)

func _wanted_tiles(focus: Vector3) -> Dictionary:
	var wanted := {}
	var ix0 := floori((focus.x - ROOT_RADIUS) / ROOT_SIZE)
	var ix1 := floori((focus.x + ROOT_RADIUS) / ROOT_SIZE)
	var iz0 := floori((focus.z - ROOT_RADIUS) / ROOT_SIZE)
	var iz1 := floori((focus.z + ROOT_RADIUS) / ROOT_SIZE)
	for iz in range(iz0, iz1 + 1):
		for ix in range(ix0, ix1 + 1):
			var k := Vector3i(ix, iz, 0)
			if _tile_distance(k, focus) < ROOT_RADIUS:
				_visit(k, focus, wanted)
	return wanted

func _visit(key: Vector3i, focus: Vector3, wanted: Dictionary) -> void:
	if key.z < MAX_LEVEL and _tile_distance(key, focus) < SPLIT_K * _tile_size(key.z):
		for c in range(4):
			_visit(Vector3i(key.x * 2 + (c & 1), key.y * 2 + (c >> 1), key.z + 1), focus, wanted)
	else:
		wanted[key] = true

static func _parent(k: Vector3i) -> Vector3i:
	return Vector3i(k.x >> 1, k.y >> 1, k.z - 1)

static func _is_descendant(d: Vector3i, k: Vector3i) -> bool:
	if d.z <= k.z:
		return false
	var sh := d.z - k.z
	return (d.x >> sh) == k.x and (d.y >> sh) == k.y

## Decide which tiles to show: wanted tiles that are ready, otherwise
## whatever is already on screen covering the same ground.
func _apply(focus: Vector3) -> void:
	var wanted := _wanted_tiles(focus)
	var show := {}
	var missing : Array = []
	for k in wanted:
		if _ready_tiles.has(k):
			show[k] = true
			continue
		missing.append(k)
		var a : Vector3i = k
		var found := false
		while a.z > 0:
			a = _parent(a)
			if _shown.has(a):
				show[a] = true
				found = true
				break
		if not found:
			for d in _shown:
				if _is_descendant(d, k):
					show[d] = true
	# A fallback ancestor covers its whole area: hide its descendants
	for k in show.keys():
		var a : Vector3i = k
		while a.z > 0:
			a = _parent(a)
			if show.has(a):
				show.erase(k)
				break

	for k in _shown.keys():
		if not show.has(k):
			var n : Node3D = _ready_tiles[k]
			if n.get_parent() == self:
				remove_child(n)
			_shown.erase(k)
	for k in show:
		if not _shown.has(k):
			var n : Node3D = _ready_tiles[k]
			_place(n)
			add_child(n)
			_shown[k] = true
			if n.get_meta("has_buildings", false):
				_set_appear(n, 1.0 if _instant else 0.0)
				if not _instant:
					_fading[n] = 0.0

	# Nearest missing tiles first
	missing.sort_custom(func(a, b): return _tile_distance(a, focus) < _tile_distance(b, focus))
	for k in missing:
		if _jobs.size() >= MAX_JOBS:
			break
		_request_tile(k)

	_apply_ribbons(focus)
	_evict(focus, wanted)

## Town buildings dissolve in while the ground's painted roofs fade out
func _set_appear(tile: Node3D, a: float) -> void:
	var bmat = tile.get_meta("building_mat", null)
	if bmat:
		(bmat as ShaderMaterial).set_shader_parameter("appear", a)
	for c in tile.get_children():
		if c is MeshInstance3D and c.name == "Ground":
			((c as MeshInstance3D).material_override as ShaderMaterial).set_shader_parameter("buildings_shown", a)

func _update_fades(delta: float) -> void:
	for n in _fading.keys():
		if not is_instance_valid(n) or not (n as Node3D).is_inside_tree():
			_fading.erase(n)
			continue
		var a : float = minf(_fading[n] + delta / FADE_TIME, 1.0)
		_set_appear(n, smoothstep(0.0, 1.0, a))
		if a >= 1.0:
			_fading.erase(n)
		else:
			_fading[n] = a

func _request_tile(k: Vector3i) -> void:
	if _jobs.has(k) or _ready_tiles.has(k):
		return
	_jobs[k] = WorkerThreadPool.add_task(_tile_job.bind(k), false, "map tile")

func _tile_job(k: Vector3i) -> void:
	var data : Dictionary = builder.tile_data(k)
	_mutex.lock()
	_done.append([k, data, false])
	_mutex.unlock()

## Turns finished worker data into nodes (main thread) and caches them.
func _collect(budget_ms: float) -> int:
	var t0 := Time.get_ticks_usec()
	var n := 0
	while true:
		_mutex.lock()
		var item = _done.pop_front() if not _done.is_empty() else null
		_mutex.unlock()
		if item == null:
			break
		var k : Vector3i = item[0]
		var jobs : Dictionary = _rib_jobs if item[2] else _jobs
		if jobs.has(k):
			WorkerThreadPool.wait_for_task_completion(jobs[k])
			jobs.erase(k)
		var node : Node3D = builder.instantiate(item[1])
		if item[2]:
			_rib_ready[k] = node
		else:
			_ready_tiles[k] = node
			stats.tiles_built += 1
		n += 1
		if (Time.get_ticks_usec() - t0) / 1000.0 > budget_ms:
			break
	return n

func _evict(focus: Vector3, wanted: Dictionary) -> void:
	if _ready_tiles.size() <= CACHE_MAX:
		return
	var spare : Array = []
	for k in _ready_tiles:
		if not _shown.has(k) and not wanted.has(k):
			spare.append(k)
	spare.sort_custom(func(a, b): return _tile_distance(a, focus) > _tile_distance(b, focus))
	for i in range(mini(spare.size(), _ready_tiles.size() - CACHE_MAX)):
		(_ready_tiles[spare[i]] as Node3D).queue_free()
		_ready_tiles.erase(spare[i])

# ---------------------------------------------------------------------------
# Cliff ribbons
# ---------------------------------------------------------------------------

func _build_coasts() -> void:
	var length := TileBuilder.RIBBON_STEP * TileBuilder.RIBBON_PIECE
	_pieces = geo.coast_pieces(length)
	for i in range(_pieces.size()):
		var c : Vector2 = _pieces[i][3]
		var key := Vector2i(floori(c.x / PIECE_CELL), floori(c.y / PIECE_CELL))
		if not _piece_cells.has(key):
			_piece_cells[key] = []
		_piece_cells[key].append(i)

func _wanted_ribbons(focus: Vector3) -> Dictionary:
	var wanted := {}
	var f2 := Vector2(focus.x, focus.z)
	var dy := maxf(focus.y - 100.0, 0.0)
	var reach := int(ceil(RIB_FAR / PIECE_CELL)) + 1
	var fc := Vector2i(floori(f2.x / PIECE_CELL), floori(f2.y / PIECE_CELL))
	var near : Array = []
	for cz in range(fc.y - reach, fc.y + reach + 1):
		for cx in range(fc.x - reach, fc.x + reach + 1):
			var key := Vector2i(cx, cz)
			if _piece_cells.has(key):
				near.append_array(_piece_cells[key])
	for i in near:
		var p : Array = _pieces[i]
		var d := maxf(f2.distance_to(p[3]) - p[4], 0.0)
		d = sqrt(d * d + dy * dy)
		if d < RIB_FINE:
			wanted[Vector3i(i, 0, 0)] = true
		elif d < RIB_FAR:
			wanted[Vector3i(i, 1, 0)] = true
	return wanted

func _request_ribbon(k: Vector3i) -> void:
	if _rib_jobs.has(k) or _rib_ready.has(k):
		return
	_rib_jobs[k] = WorkerThreadPool.add_task(_ribbon_job.bind(k), false, "cliff piece")

func _ribbon_job(k: Vector3i) -> void:
	var p : Array = _pieces[k.x]
	var step := TileBuilder.RIBBON_STEP
	var line : Array = geo.sample_piece(p[0], p[1], p[2], step)
	var pts : PackedVector2Array = line[0]
	var data : Dictionary = builder.ribbon_data(pts, line[1], 0, pts.size() - 1, p[0], k.y,
		int(round(p[1] / step)))
	_mutex.lock()
	_done.append([k, data, true])
	_mutex.unlock()

func _apply_ribbons(focus: Vector3) -> void:
	var wanted := _wanted_ribbons(focus)
	var show := {}
	var missing : Array = []
	for k in wanted:
		if _rib_ready.has(k):
			show[k] = true
		else:
			missing.append(k)
			var other := Vector3i(k.x, 1 - k.y, 0)    # keep the other LOD until ready
			if _rib_shown.has(other):
				show[other] = true
	for k in _rib_shown.keys():
		if not show.has(k):
			var n : Node3D = _rib_ready[k]
			if n.get_parent() == self:
				remove_child(n)
			_rib_shown.erase(k)
	for k in show:
		if not _rib_shown.has(k):
			var n : Node3D = _rib_ready[k]
			_place(n)
			add_child(n)
			_rib_shown[k] = true
	var f2 := Vector2(focus.x, focus.z)
	missing.sort_custom(func(a, b): return f2.distance_to(_pieces[a.x][3]) < f2.distance_to(_pieces[b.x][3]))
	for k in missing:
		if _rib_jobs.size() >= MAX_JOBS:
			break
		_request_ribbon(k)
	# Drop far-away cached pieces
	if _rib_ready.size() > 500:
		for k in _rib_ready.keys():
			if not show.has(k) and not wanted.has(k):
				(_rib_ready[k] as Node3D).queue_free()
				_rib_ready.erase(k)

# ---------------------------------------------------------------------------
# Sea — a large plane that follows the camera; the shader works in world
# space so its waves stay put as it moves.
# ---------------------------------------------------------------------------

func _build_sea() -> void:
	_sea = MeshInstance3D.new()
	_sea.name = "Sea"
	var plane := PlaneMesh.new()
	plane.size = Vector2(SEA_SIZE, SEA_SIZE)
	_sea.mesh = plane
	_sea.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := ShaderMaterial.new()
	mat.shader = SEA_SHADER
	mat.render_priority = -10     # draw before clouds and smoke
	_sea.material_override = mat
	add_child(_sea)

	# Collision: top face at the water surface so planes crash on ditching
	_sea_body = StaticBody3D.new()
	_sea_body.name = "SeaCollision"
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(60000.0, 4.0, 60000.0)
	col.shape = box
	_sea_body.add_child(col)
	add_child(_sea_body)
	_follow_sea(initial_focus)

func _follow_sea(focus: Vector3) -> void:
	var p := WorldOrigin.to_scene(Vector3(snappedf(focus.x, 1000.0), 0.0, snappedf(focus.z, 1000.0)))
	_sea.position = Vector3(p.x, SEA_LEVEL, p.z)
	_sea_body.position = Vector3(p.x, SEA_LEVEL - 2.0, p.z)
