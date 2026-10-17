extends RefCounted
## Real-world geography for the campaign map, baked by tools/bake_europe.py.
##
## Answers the questions the terrain streamer asks — ground height, signed
## distance to the coast, land use, coastlines, towns — at any game position.
##
## Map scale: game position = projected real position × map_scale.  Only
## horizontal distances scale; heights, field sizes, trees, houses and all
## other objects keep their real size.  Every query takes game coordinates.
##
## Axes: +X = west, +Z = north, metres, origin at Dover Castle.
## Read-only after construction, so worker threads may query it freely.

const DATA_DIR := "res://data/europe/"
const Airfields := preload("res://scenes/world/geo/airfields.gd")

const RAMP_IN    := 220.0      ## land grid dips toward the sea floor inside this
const RAMP_OUT   := -60.0      ## ...reaching it here (hidden under the cliff ribbon)
const EXACT_COAST := 1200.0    ## measure exact coast distance within this
const BUCKET     := 1500.0     ## coastline spatial-hash cell (game metres)
const VILLAGE_CELL := 5000.0   ## one possible village per cell (real metres)
const AIRFIELD_R := 950.0     ## flattened, tree- and house-free radius (full scale size)
const AF_CELL    := 4000.0    ## airfield lookup grid

var map_scale := 1.0
var lat0 := 51.1279
var lon0 := 1.3134
var earth_r := 6371008.8

var _w := 0
var _h := 0
var _x_min := 0.0
var _z_min := 0.0
var _res := 250.0
var _elev := PackedByteArray()      ## int16 metres
var _cdist := PackedByteArray()     ## int16 metres, + inland
var _town := PackedByteArray()      ## uint8
var _lake := PackedByteArray()      ## int16 metres to lake shores, - inside

var _seg_a := PackedVector2Array()  ## coastline segments, game coords
var _seg_b := PackedVector2Array()
var _buckets := {}                  ## Vector2i -> PackedInt32Array of segment ids
var _lines : Array = []             ## [game points, closed, cumulative length]

var _riv_a := PackedVector2Array()  ## river segments, game coords
var _riv_b := PackedVector2Array()
var _riv_w := PackedFloat32Array()  ## half widths (game metres, not scaled)
var _riv_buckets := {}
const RIVER_BUCKET := 1000.0
var rivers : Array = []             ## [PackedVector2Array game points, width] for the map

var places : Array = []             ## [name, Vector2 game pos, population]
var map_meta := {}                  ## the baked map image: file, res, east_min, north_max
var airfield_pos := Vector2.ZERO   ## Hawkinge (the original home field)
var airfield_h := 0.0
var airfields : Array = []         ## [name, side, Vector2 game pos, ground height]
var _af_cells := {}                ## Vector2i -> PackedInt32Array of airfield ids

var _n_wood := FastNoiseLite.new()
var _n_det := FastNoiseLite.new()

func _init(scale := 1.0) -> void:
	map_scale = scale
	var t0 := Time.get_ticks_msec()
	var meta : Dictionary = JSON.parse_string(FileAccess.get_file_as_string(DATA_DIR + "meta.json"))
	lat0 = meta.lat0
	lon0 = meta.lon0
	earth_r = meta.radius
	_w = int(meta.width)
	_h = int(meta.height)
	_x_min = meta.x_min
	_z_min = meta.z_min
	_res = meta.res
	var sizes : Dictionary = meta.raw_sizes
	_elev = _load_z("elevation.bin", int(sizes.elevation))
	_cdist = _load_z("coastdist.bin", int(sizes.coastdist))
	_town = _load_z("town.bin", int(sizes.town))
	_lake = _load_z("lakedist.bin", int(sizes.lakedist))
	_load_rivers(_load_z("rivers.bin", int(sizes.rivers)))
	map_meta = meta.map
	_load_coast(_load_z("coast.bin", int(sizes.coast)))
	_load_places()

	_setup_noise(_n_wood, 53, 1.0 / 2100.0, 3)
	_setup_noise(_n_det, 71, 1.0 / 260.0, 2)

	_load_airfields()
	# RAF Hawkinge, the fighter station behind Folkestone
	airfield_pos = latlon_to_game(51.1135, 1.1530)
	airfield_h = _land_raw(airfield_pos.x, airfield_pos.y)
	print("Geography loaded in %d ms (scale %.2f, %d coast segments)" % [
		Time.get_ticks_msec() - t0, map_scale, _seg_a.size()])

## Every airfield is a flat, open grass field of radius AIRFIELD_R
func _load_airfields() -> void:
	for a in Airfields.LIST:
		var p := latlon_to_game(a[2], a[3])
		var id := airfields.size()
		airfields.append([a[0], a[1], p, _land_raw(p.x, p.y)])
		var lo := Vector2i(floori((p.x - AIRFIELD_R) / AF_CELL), floori((p.y - AIRFIELD_R) / AF_CELL))
		var hi := Vector2i(floori((p.x + AIRFIELD_R) / AF_CELL), floori((p.y + AIRFIELD_R) / AF_CELL))
		for cy in range(lo.y, hi.y + 1):
			for cx in range(lo.x, hi.x + 1):
				var key := Vector2i(cx, cy)
				if not _af_cells.has(key):
					_af_cells[key] = PackedInt32Array()
				_af_cells[key].append(id)

## Index of the airfield covering (x, z), or -1
func airfield_at(x: float, z: float) -> int:
	var key := Vector2i(floori(x / AF_CELL), floori(z / AF_CELL))
	if not _af_cells.has(key):
		return -1
	var p := Vector2(x, z)
	for id in _af_cells[key]:
		if p.distance_to(airfields[id][2]) < AIRFIELD_R:
			return id
	return -1

## Airfields overlapping a rect (for the terrain shader): [Vector2 pos, ...]
func airfields_in(rect: Rect2) -> Array:
	var out : Array = []
	var r := rect.grow(AIRFIELD_R)
	for a in airfields:
		if r.has_point(a[2]):
			out.append(a[2])
	return out

## Layout angle of an airfield (hangars along its local +X edge, the
## take-off line along local Z).  Shared by the scenery and the missions.
func airfield_yaw(id: int) -> float:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(airfields[id][0])
	return rng.randf() * TAU

## Airfield index by name, or -1
func airfield_index(name_: String) -> int:
	for i in range(airfields.size()):
		if airfields[i][0] == name_:
			return i
	return -1

static func _setup_noise(n: FastNoiseLite, s: int, f: float, oct: int) -> void:
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.seed = s
	n.frequency = f
	n.fractal_octaves = oct

func _load_z(name: String, raw_size: int) -> PackedByteArray:
	var comp := FileAccess.get_file_as_bytes(DATA_DIR + name)
	return comp.decompress(raw_size, FileAccess.COMPRESSION_DEFLATE)

func _load_coast(buf: PackedByteArray) -> void:
	var n := buf.decode_s32(0)
	var off := 4
	for li in range(n):
		var count := buf.decode_s32(off)
		var closed := buf.decode_s32(off + 4) != 0
		off += 8
		var pts := PackedVector2Array()
		pts.resize(count)
		for i in range(count):
			pts[i] = Vector2(buf.decode_float(off), buf.decode_float(off + 4)) * map_scale
			off += 8
		var cum := PackedFloat32Array()
		cum.resize(count + 1)
		var acc := 0.0
		for i in range(count):
			cum[i] = acc
			if i + 1 < count or closed:
				acc += pts[i].distance_to(pts[(i + 1) % count])
		cum[count] = acc
		_lines.append([pts, closed, cum])
		var segs := count if closed else count - 1
		for i in range(segs):
			var a := pts[i]
			var b := pts[(i + 1) % count]
			var id := _seg_a.size()
			_seg_a.append(a)
			_seg_b.append(b)
			var lo := Vector2i(floori(minf(a.x, b.x) / BUCKET), floori(minf(a.y, b.y) / BUCKET))
			var hi := Vector2i(floori(maxf(a.x, b.x) / BUCKET), floori(maxf(a.y, b.y) / BUCKET))
			for by in range(lo.y, hi.y + 1):
				for bx in range(lo.x, hi.x + 1):
					var key := Vector2i(bx, by)
					if not _buckets.has(key):
						_buckets[key] = PackedInt32Array()
					_buckets[key].append(id)

func _load_rivers(buf: PackedByteArray) -> void:
	var n := buf.decode_s32(0)
	var off := 4
	for li in range(n):
		var count := buf.decode_s32(off)
		var width := buf.decode_float(off + 4)
		off += 8
		var pts := PackedVector2Array()
		pts.resize(count)
		for i in range(count):
			pts[i] = Vector2(buf.decode_float(off), buf.decode_float(off + 4)) * map_scale
			off += 8
		rivers.append([pts, width])
		for i in range(count - 1):
			var a := pts[i]
			var b := pts[i + 1]
			var id := _riv_a.size()
			_riv_a.append(a)
			_riv_b.append(b)
			_riv_w.append(width * 0.5)
			var lo := Vector2i(floori((minf(a.x, b.x) - width) / RIVER_BUCKET), floori((minf(a.y, b.y) - width) / RIVER_BUCKET))
			var hi := Vector2i(floori((maxf(a.x, b.x) + width) / RIVER_BUCKET), floori((maxf(a.y, b.y) + width) / RIVER_BUCKET))
			for by in range(lo.y, hi.y + 1):
				for bx in range(lo.x, hi.x + 1):
					var key := Vector2i(bx, by)
					if not _riv_buckets.has(key):
						_riv_buckets[key] = PackedInt32Array()
					_riv_buckets[key].append(id)

func _load_places() -> void:
	var list = JSON.parse_string(FileAccess.get_file_as_string(DATA_DIR + "places.json"))
	for p in list:
		places.append([p.name, Vector2(p.x, p.z) * map_scale, int(p.pop)])

# ---------------------------------------------------------------------------
# Coordinates
# ---------------------------------------------------------------------------

## Latitude/longitude (degrees) → game (x, z), azimuthal equidistant about Dover
func latlon_to_game(lat: float, lon: float) -> Vector2:
	var p0 := deg_to_rad(lat0)
	var p := deg_to_rad(lat)
	var dl := deg_to_rad(lon - lon0)
	var cos_c := clampf(sin(p0) * sin(p) + cos(p0) * cos(p) * cos(dl), -1.0, 1.0)
	var c := acos(cos_c)
	var k := c / sin(c) if c > 1e-9 else 1.0
	var east := earth_r * k * cos(p) * sin(dl)
	var north := earth_r * k * (cos(p0) * sin(p) - sin(p0) * cos(p) * cos(dl))
	return Vector2(-east, north) * map_scale

## Pixel in the baked north-up map image (map.png) for a game position
func map_pixel(p: Vector2) -> Vector2:
	var res : float = map_meta.res
	var mw := _w * _res / res
	var mh := _h * _res / res
	return Vector2(mw - (p.x / map_scale - _x_min) / res, mh - (p.y / map_scale - _z_min) / res)

## Map-image pixels per game metre
func map_px_per_m() -> float:
	return 1.0 / (float(map_meta.res) * map_scale)

# ---------------------------------------------------------------------------
# Raster sampling (bilinear, clamped at the data edge)
# ---------------------------------------------------------------------------

func _grid(x: float, z: float) -> Vector2:
	return Vector2(clampf((x / map_scale - _x_min) / _res, 0.0, _w - 1.001),
		clampf((z / map_scale - _z_min) / _res, 0.0, _h - 1.001))

func _s16(buf: PackedByteArray, g: Vector2) -> float:
	var i := int(g.x)
	var j := int(g.y)
	var fx := g.x - i
	var fz := g.y - j
	var o := (j * _w + i) * 2
	var o2 := o + _w * 2
	var a := lerpf(buf.decode_s16(o), buf.decode_s16(o + 2), fx)
	var b := lerpf(buf.decode_s16(o2), buf.decode_s16(o2 + 2), fx)
	return lerpf(a, b, fz)

func _u8(buf: PackedByteArray, g: Vector2) -> float:
	var i := int(g.x)
	var j := int(g.y)
	var fx := g.x - i
	var fz := g.y - j
	var o := j * _w + i
	var a := lerpf(buf[o], buf[o + 1], fx)
	var b := lerpf(buf[o + _w], buf[o + _w + 1], fx)
	return lerpf(a, b, fz) / 255.0

# ---------------------------------------------------------------------------
# Coast
# ---------------------------------------------------------------------------

## Signed distance to the coast in game metres: + inland, - out to sea.
## Exact (against the coastline polylines) near the shore, coarse elsewhere.
func coast_d(x: float, z: float) -> float:
	var coarse := _s16(_cdist, _grid(x, z)) * map_scale
	if absf(coarse) > EXACT_COAST:
		return coarse
	var p := Vector2(x, z)
	var c := Vector2i(floori(x / BUCKET), floori(z / BUCKET))
	var best := INF
	var best_side := 1.0
	for by in range(c.y - 1, c.y + 2):
		for bx in range(c.x - 1, c.x + 2):
			var key := Vector2i(bx, by)
			if not _buckets.has(key):
				continue
			for id in _buckets[key]:
				var a := _seg_a[id]
				var ab := _seg_b[id] - a
				var t := clampf((p - a).dot(ab) / maxf(ab.length_squared(), 1e-6), 0.0, 1.0)
				var dd := p.distance_squared_to(a + ab * t)
				if dd < best:
					best = dd
					best_side = 1.0 if ab.cross(p - a) > 0.0 else -1.0   # land lies on the left
	if best == INF:
		return coarse
	return sqrt(best) * best_side

## Splits every coastline into pieces of `length` game metres (arc length).
## Returns an Array of [line index, s0, s1, centre (Vector2), radius].
func coast_pieces(length: float) -> Array:
	var out : Array = []
	for li in range(_lines.size()):
		var cum : PackedFloat32Array = _lines[li][2]
		var total := cum[cum.size() - 1] if _lines[li][1] else cum[cum.size() - 2]
		var s0 := 0.0
		while s0 < total - 1.0:
			var s1 := minf(s0 + length, total)
			var a := _at(li, s0)
			var m := _at(li, (s0 + s1) * 0.5)
			var b := _at(li, s1)
			var lo := a.min(m).min(b)
			var hi := a.max(m).max(b)
			out.append([li, s0, s1, (lo + hi) * 0.5, (hi - lo).length() * 0.5 + length * 0.25 + 300.0])
			s0 = s1
	return out

## Point at arc length s along coastline li
func _at(li: int, s: float) -> Vector2:
	var pts : PackedVector2Array = _lines[li][0]
	var closed : bool = _lines[li][1]
	var cum : PackedFloat32Array = _lines[li][2]
	var n := pts.size()
	var total := cum[n] if closed else cum[n - 1]
	if closed:
		s = fposmod(s, total)
	else:
		s = clampf(s, 0.0, total)
	# Binary search for the segment containing s
	var lo := 0
	var hi := (n if closed else n - 1)
	while hi - lo > 1:
		var mid := (lo + hi) >> 1
		if cum[mid] <= s:
			lo = mid
		else:
			hi = mid
	var seg := cum[lo + 1] - cum[lo]
	var t := (s - cum[lo]) / seg if seg > 1e-6 else 0.0
	return pts[lo].lerp(pts[(lo + 1) % n], t)

## Samples a coastline piece every `step` game metres from s0 to s1 (both
## ends included), with inland normals.  Returns [points, normals].
func sample_piece(li: int, s0: float, s1: float, step: float) -> Array:
	var count := int(round((s1 - s0) / step))
	var pts := PackedVector2Array()
	var nrms := PackedVector2Array()
	pts.resize(count + 1)
	nrms.resize(count + 1)
	for i in range(count + 1):
		var sv := s0 + i * step if i < count else s1
		pts[i] = _at(li, sv)
		var t := (_at(li, sv + step) - _at(li, sv - step)).normalized()
		nrms[i] = Vector2(-t.y, t.x)          # left of travel = inland
	return [pts, nrms]

# ---------------------------------------------------------------------------
# Heights
# ---------------------------------------------------------------------------

func _land_raw(x: float, z: float) -> float:
	return maxf(_s16(_elev, _grid(x, z)), 1.0)

## Land height (no coastal ramp) — for scenery and the cliff ribbons.
func land_height(x: float, z: float) -> float:
	var h := _land_raw(x, z)
	var id := airfield_at(x, z)
	if id >= 0:
		var a : Array = airfields[id]
		var ar := Vector2(x, z).distance_to(a[2])
		h = lerpf(h, a[3], 1.0 - smoothstep(AIRFIELD_R * 0.55, AIRFIELD_R, ar))
	return h

## Sea floor depth (negative)
func sea_floor(x: float, z: float) -> float:
	return minf(_s16(_elev, _grid(x, z)), -3.0)

## Height used by the terrain grid: land, with the coastal ramp down to the
## sea floor hidden under the cliff ribbon.
func grid_height(x: float, z: float) -> float:
	var d := coast_d(x, z)
	if d <= RAMP_OUT:
		return sea_floor(x, z)
	var l := land_height(x, z)
	if d >= RAMP_IN:
		return l
	var t := (d - RAMP_OUT) / (RAMP_IN - RAMP_OUT)
	return lerpf(minf(sea_floor(x, z), -8.0), l, t * t)

## Visible ground height for gameplay (sea counts as 0.8 m).
func surface_height(x: float, z: float) -> float:
	if coast_d(x, z) < 0.0:
		return 0.8
	return maxf(land_height(x, z), 0.8)

## Signed distance to the nearest river bank or lake shore in game metres
## (negative over water).  Values beyond ~200 m are only approximate.
func water_edge(x: float, z: float) -> float:
	var best := _s16(_lake, _grid(x, z)) * map_scale
	var key := Vector2i(floori(x / RIVER_BUCKET), floori(z / RIVER_BUCKET))
	if _riv_buckets.has(key):
		var p := Vector2(x, z)
		for id in _riv_buckets[key]:
			var a := _riv_a[id]
			var ab := _riv_b[id] - a
			var t := clampf((p - a).dot(ab) / maxf(ab.length_squared(), 1e-6), 0.0, 1.0)
			best = minf(best, p.distance_to(a + ab * t) - _riv_w[id])
	return best

## True if any river may be within `margin` of the rect (cheap bucket test)
func rivers_near(rect: Rect2, margin: float) -> bool:
	var lo := Vector2i(floori((rect.position.x - margin) / RIVER_BUCKET), floori((rect.position.y - margin) / RIVER_BUCKET))
	var hi := Vector2i(floori((rect.end.x + margin) / RIVER_BUCKET), floori((rect.end.y + margin) / RIVER_BUCKET))
	for by in range(lo.y, hi.y + 1):
		for bx in range(lo.x, hi.x + 1):
			if _riv_buckets.has(Vector2i(bx, by)):
				return true
	return false

## Lake distance at the rect centre minus its half-diagonal: > 0 means no lake inside
func lake_clearance(rect: Rect2) -> float:
	var c := rect.get_center()
	return _s16(_lake, _grid(c.x, c.y)) * map_scale - rect.size.length() * 0.5

func detail_noise(x: float, z: float) -> float:
	return _n_det.get_noise_2d(x, z)

# ---------------------------------------------------------------------------
# Land use
# ---------------------------------------------------------------------------

static func _hash2(x: int, y: int, s: int) -> float:
	var h := (x * 73856093) ^ (y * 19349663) ^ (s * 83492791)
	h = (h ^ (h >> 13)) * 1274126177
	return float((h ^ (h >> 16)) & 0xffffff) / float(0xffffff)

## Small villages scattered through the countryside (procedural)
func _village(x: float, z: float) -> float:
	var rx := x / map_scale
	var rz := z / map_scale
	var cx := floori(rx / VILLAGE_CELL)
	var cz := floori(rz / VILLAGE_CELL)
	var best := 0.0
	for j in range(cz - 1, cz + 2):
		for i in range(cx - 1, cx + 2):
			if _hash2(i, j, 1) > 0.55:
				continue
			var vc := Vector2((i + 0.2 + 0.6 * _hash2(i, j, 2)) * VILLAGE_CELL,
				(j + 0.2 + 0.6 * _hash2(i, j, 3)) * VILLAGE_CELL) * map_scale
			var r := 160.0 + 220.0 * _hash2(i, j, 4)
			var dist := Vector2(x, z).distance_to(vc)
			if dist < r * 1.3:
				best = maxf(best, (1.0 - smoothstep(r * 0.25, r * 1.3, dist)) * (0.5 + 0.3 * _hash2(i, j, 5)))
	return best

func town_density(x: float, z: float) -> float:
	var t := maxf(_u8(_town, _grid(x, z)), _village(x, z))
	if t > 0.0:
		t *= 0.8 + 0.4 * _n_det.get_noise_2d(x * 0.5, z * 0.5)
	return clampf(t, 0.0, 1.0)

## Land use at a point: r = woods, g = town, b = downland (0..1).
func landuse_at(x: float, z: float) -> Color:
	var d := coast_d(x, z)
	if d <= -50.0:
		return Color(0, 0, 0, 1)
	var h := land_height(x, z)
	var town := town_density(x, z)
	# Woods: patchy everywhere, commoner on high ground, never on cliff tops or marsh
	var w := _n_wood.get_noise_2d(x, z) + _n_det.get_noise_2d(x, z) * 0.12 + smoothstep(120.0, 500.0, h) * 0.18
	var wood := smoothstep(0.33, 0.45, w) * smoothstep(180.0, 600.0, d) * smoothstep(4.0, 12.0, h)
	wood *= 1.0 - smoothstep(0.05, 0.25, town)
	# Open chalk downland along high cliff tops
	var down := (1.0 - smoothstep(150.0, 550.0, d)) * smoothstep(35.0, 70.0, h)
	if airfield_at(x, z) >= 0:
		wood = 0.0
		town = 0.0
	return Color(wood, town, down, 1.0)
