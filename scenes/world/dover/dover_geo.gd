extends RefCounted
## Geography of the stylised Strait of Dover — pure data + height functions.
##
## Axes:  +Z = north, -Z = south, +X = west, -X = east.
## The English coast runs east-west a few km south of the spawn point; the
## French coast (Cap Gris-Nez / Cap Blanc-Nez) is ~22 km further south.
##
## Each coastline is a hand-placed spline z = c(x).  Land height is defined as
## a function of world position and signed distance from the coast, so the
## cliffs naturally follow the land: high chalk Downs give 100 m+ cliffs,
## river valleys (Dover, St Margaret's) cut notches down to beach level, and
## Romney Marsh / Deal / Calais are low shingle and sand shores.

const SEA_FLOOR  := -32.0
## Land-grid ramp: the coarse terrain grid drops from land height to the sea
## floor between these signed coast distances.  The cliff ribbon mesh covers
## this zone (out to CAP_WIDTH) so the ramp is never visible.
const RAMP_IN    := 220.0
const RAMP_OUT   := -60.0
const CAP_WIDTH  := 440.0

## Core map (detailed terrain, cliffs, scenery)
const CORE_HALF  := 48000.0

const _TAB_MIN  := -200000.0
const _TAB_STEP := 20.0
const _TAB_N    := 20001

# England coastline control points (x, z), ordered by x (east → west)
const _ENGLAND_PTS : Array = [
	Vector2(-90000,  62000),   # North Sea coast heading north
	Vector2(-40000,  24000),
	Vector2(-24000,   8000),   # Sandwich Bay
	Vector2(-17000,   1200),   # Deal / Walmer beach
	Vector2(-12500,  -2000),   # Kingsdown — cliffs begin
	Vector2( -8000,  -3200),   # St Margaret's Bay
	Vector2( -5200,  -4100),   # South Foreland
	Vector2( -1500,  -3700),   # Langdon Cliffs
	Vector2(  1500,  -3300),   # Dover harbour
	Vector2(  4500,  -3650),   # Shakespeare Cliff
	Vector2(  8500,  -3000),
	Vector2( 12000,  -2200),   # Folkestone
	Vector2( 16500,  -1700),   # Hythe
	Vector2( 22000,  -3200),   # Romney Marsh shore
	Vector2( 26500,  -7000),   # Dungeness
	Vector2( 30000,  -5200),
	Vector2( 37000,  -1500),   # Rye Bay
	Vector2( 48000,  -2500),
	Vector2( 90000,  -1000),
]

# French coastline (land lies to the SOUTH of this line)
const _FRANCE_PTS : Array = [
	Vector2(-90000, -36000),   # towards Dunkirk
	Vector2(-34000, -33500),   # Calais
	Vector2(-22000, -31200),
	Vector2(-14000, -28400),   # Cap Blanc-Nez
	Vector2( -9000, -27600),   # Wissant bay
	Vector2( -2000, -25600),   # Cap Gris-Nez — closest point to England
	Vector2(  3000, -27800),
	Vector2(  7500, -33500),   # Wimereux
	Vector2( 10500, -42000),   # Boulogne
	Vector2( 12500, -56000),
	Vector2( 14000, -90000),
]

var _eng_z   := PackedFloat32Array()
var _eng_cos := PackedFloat32Array()
var _fra_z   := PackedFloat32Array()
var _fra_cos := PackedFloat32Array()

var _n_low  := FastNoiseLite.new()
var _n_mid  := FastNoiseLite.new()
var _n_val  := FastNoiseLite.new()
var _n_wood := FastNoiseLite.new()
var _n_det  := FastNoiseLite.new()

var airfield_pos := Vector2(0.0, 0.0)
var airfield_h   := 0.0
const AIRFIELD_R := 950.0

## Towns: [centre (x, z), radius, density]; built in _init from coast-relative specs
var towns : Array = []
const _TOWN_BUCKET := 4000.0
var _town_buckets := {}

func _init() -> void:
	_setup_noise(_n_low,  11, 1.0 / 14000.0, 3)
	_setup_noise(_n_mid,  23, 1.0 / 3200.0,  3)
	_setup_noise(_n_val,  37, 1.0 / 5200.0,  2)
	_setup_noise(_n_wood, 53, 1.0 / 2100.0,  3)
	_setup_noise(_n_det,  71, 1.0 / 260.0,   2)

	var coast_noise := FastNoiseLite.new()
	_setup_noise(coast_noise, 91, 1.0 / 2600.0, 2)
	_build_table(_ENGLAND_PTS, coast_noise, 0.0,     _eng_z, _eng_cos)
	_build_table(_FRANCE_PTS,  coast_noise, 50000.0, _fra_z, _fra_cos)

	airfield_h = _land_england(airfield_pos.x, airfield_pos.y, england_d(airfield_pos.x, airfield_pos.y), false)
	_build_towns()

static func _setup_noise(n: FastNoiseLite, s: int, f: float, oct: int) -> void:
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.seed = s
	n.frequency = f
	n.fractal_octaves = oct

# ---------------------------------------------------------------------------
# Coastline tables
# ---------------------------------------------------------------------------

func _build_table(pts: Array, noise: FastNoiseLite, noise_ofs: float,
		out_z: PackedFloat32Array, out_cos: PackedFloat32Array) -> void:
	# Dense polyline through the control points (Catmull-Rom)
	var dense := PackedVector2Array()
	for i in range(pts.size() - 1):
		var p0: Vector2 = pts[maxi(i - 1, 0)]
		var p1: Vector2 = pts[i]
		var p2: Vector2 = pts[i + 1]
		var p3: Vector2 = pts[mini(i + 2, pts.size() - 1)]
		var steps := int(ceil((p2.x - p1.x) / 50.0))
		for s in range(steps):
			var t := float(s) / steps
			dense.append(_catmull(p0, p1, p2, p3, t))
	dense.append(pts[pts.size() - 1])

	# Resample to uniform x steps (the splines are monotone in x)
	out_z.resize(_TAB_N)
	var j := 0
	for k in range(_TAB_N):
		var x := _TAB_MIN + k * _TAB_STEP
		while j < dense.size() - 2 and dense[j + 1].x < x:
			j += 1
		var a := dense[j]
		var b := dense[j + 1]
		var t := clampf((x - a.x) / maxf(b.x - a.x, 0.001), 0.0, 1.0)
		# Medium-scale irregularity: small bays and headlands
		out_z[k] = lerpf(a.y, b.y, t) + noise.get_noise_1d(x + noise_ofs) * 160.0

	out_cos.resize(_TAB_N)
	for k in range(_TAB_N):
		var k0 := maxi(k - 1, 0)
		var k1 := mini(k + 1, _TAB_N - 1)
		var slope := (out_z[k1] - out_z[k0]) / ((k1 - k0) * _TAB_STEP)
		out_cos[k] = 1.0 / sqrt(1.0 + slope * slope)

static func _catmull(p0: Vector2, p1: Vector2, p2: Vector2, p3: Vector2, t: float) -> Vector2:
	var t2 := t * t
	var t3 := t2 * t
	return 0.5 * ((2.0 * p1) + (-p0 + p2) * t
		+ (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2
		+ (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3)

static func _tab(tab: PackedFloat32Array, x: float) -> float:
	var f := clampf((x - _TAB_MIN) / _TAB_STEP, 0.0, _TAB_N - 1.001)
	var i := int(f)
	return lerpf(tab[i], tab[i + 1], f - i)

func england_coast_z(x: float) -> float:
	return _tab(_eng_z, x)

func france_coast_z(x: float) -> float:
	return _tab(_fra_z, x)

## Signed distance from the English coast: + inland, - out to sea (approx.)
func england_d(x: float, z: float) -> float:
	return (z - _tab(_eng_z, x)) * _tab(_eng_cos, x)

## Signed distance from the French coast: + inland (south), - out to sea
func france_d(x: float, z: float) -> float:
	return (_tab(_fra_z, x) - z) * _tab(_fra_cos, x)

## Polyline along a coast, resampled by arc length, within the core map.
## Returns [points: PackedVector2Array, inland normals: PackedVector2Array]
func coast_polyline(is_france: bool, spacing: float) -> Array:
	var tab := _fra_z if is_france else _eng_z
	var raw := PackedVector2Array()
	var x := -CORE_HALF - 1000.0
	while x <= CORE_HALF + 1000.0:
		var z := _tab(tab, x)
		if absf(z) < CORE_HALF + 1000.0:
			raw.append(Vector2(x, z))
		x += 5.0

	var pts   := PackedVector2Array()
	var norms := PackedVector2Array()
	if raw.size() < 2:
		return [pts, norms]
	pts.append(raw[0])
	var need := spacing
	for i in range(raw.size() - 1):
		var a := raw[i]
		var b := raw[i + 1]
		var seg := a.distance_to(b)
		var pos := 0.0
		while seg - pos >= need:
			pos += need
			pts.append(a.lerp(b, pos / seg))
			need = spacing
		need -= seg - pos

	for i in range(pts.size()):
		var t := (pts[mini(i + 1, pts.size() - 1)] - pts[maxi(i - 1, 0)]).normalized()
		# England: land toward +Z.  France: land toward -Z.
		var n := Vector2(-t.y, t.x) if not is_france else Vector2(t.y, -t.x)
		norms.append(n)
	return [pts, norms]

# ---------------------------------------------------------------------------
# Land heights
# ---------------------------------------------------------------------------

static func _bump(v: float, centre: float, radius: float) -> float:
	return 1.0 - smoothstep(0.0, radius, absf(v - centre))

func _valley(h: float, x: float, d: float, cx: float, drift: float,
		w0: float, wk: float, floor0: float, floork: float, length: float) -> float:
	if d > length:
		return h
	var dd := maxf(d, 0.0)
	var vx := cx + dd * drift + sin(dd / 1700.0) * 260.0
	var w  := w0 + dd * wk
	var m  := 1.0 - smoothstep(w * 0.3, w, absf(x - vx))
	m *= 1.0 - smoothstep(length * 0.7, length, d)
	if m <= 0.0:
		return h
	return lerpf(h, minf(h, floor0 + dd * floork), m)

func _land_england(x: float, z: float, d: float, flatten := true) -> float:
	var n1 := _n_low.get_noise_2d(x, z)
	var n2 := _n_mid.get_noise_2d(x, z)
	var h := 100.0 + n1 * 26.0 + n2 * 11.0
	h += clampf(d / 9000.0, 0.0, 1.0) * 55.0            # rising toward the North Downs
	# Bolder rolling relief inland (the cliff edge itself stays ~100 m)
	var relief := smoothstep(800.0, 5000.0, d)
	h += relief * (n2 * 38.0 + _n_det.get_noise_2d(x * 0.25, z * 0.25) * 14.0)

	# Dry chalk valleys (rounded troughs)
	var r := absf(_n_val.get_noise_2d(x, z))
	h -= (1.0 - smoothstep(0.0, 0.18, r)) * 55.0 * smoothstep(500.0, 3000.0, d)

	# Deal / Walmer: low shingle shore, land rising gently inland
	var east := 1.0 - smoothstep(-14500.0, -11000.0, x)
	if east > 0.0:
		h = lerpf(h, minf(h, 4.0 + maxf(d, 0.0) * 0.011), east)

	# Folkestone: lower cliffs
	var fk := _bump(x, 12000.0, 3500.0)
	if fk > 0.0:
		h = lerpf(h, minf(h, 32.0 + maxf(d, 0.0) * 0.03), fk * (1.0 - smoothstep(600.0, 3500.0, d)))

	# Romney Marsh: flat levels behind the coast, old cliff line inland
	var marsh := smoothstep(14500.0, 18500.0, x)
	if marsh > 0.0:
		var esc := 4200.0 + n2 * 1500.0 + smoothstep(18000.0, 30000.0, x) * 4000.0
		var m := marsh * (1.0 - smoothstep(esc - 700.0, esc + 500.0, d))
		h = lerpf(h, 2.4 + n2 * 0.8, m)

	# River Dour valley — Dover town and harbour
	h = _valley(h, x, d, 1500.0, 0.42, 380.0, 0.07, 2.4, 0.011, 12000.0)
	# St Margaret's Bay
	h = _valley(h, x, d, -8100.0, -0.1, 230.0, 0.06, 5.0, 0.03, 3200.0)

	if flatten:
		var ax := x - airfield_pos.x
		var az := z - airfield_pos.y
		var ar := sqrt(ax * ax + az * az)
		if ar < AIRFIELD_R:
			var b := 1.0 - smoothstep(AIRFIELD_R * 0.55, AIRFIELD_R, ar)
			h = lerpf(h, airfield_h, b)
	return h

func _land_france(x: float, z: float, d: float) -> float:
	var n1 := _n_low.get_noise_2d(x + 30000.0, z)
	var n2 := _n_mid.get_noise_2d(x + 30000.0, z)
	var h := 9.0 + n1 * 5.0 + clampf(d / 7000.0, 0.0, 1.0) * (45.0 + n2 * 25.0)
	var r := absf(_n_val.get_noise_2d(x, z))
	h -= (1.0 - smoothstep(0.0, 0.14, r)) * 18.0 * smoothstep(800.0, 4000.0, d)

	# Cap Blanc-Nez — tall chalk headland
	var bn := _bump(x, -14000.0, 3600.0)
	if bn > 0.0:
		h = maxf(h, bn * (138.0 - maxf(d, 0.0) * 0.012))
	# Cap Gris-Nez — lower sandstone/clay cliffs
	var gn := _bump(x, -2000.0, 2800.0)
	if gn > 0.0:
		h = maxf(h, gn * (52.0 + maxf(d, 0.0) * 0.004))
	# Calais and the flat coast to the east
	var cal := 1.0 - smoothstep(-28000.0, -21000.0, x)
	if cal > 0.0:
		h = lerpf(h, 3.5 + n2 * 1.0 + maxf(d, 0.0) * 0.002, cal)
	return maxf(h, 2.0)

## Exact land height (no ramp) — used for the cliff ribbon and scenery.
func land_height(x: float, z: float) -> float:
	var de := england_d(x, z)
	var df := france_d(x, z)
	if de >= df:
		return _land_england(x, z, de)
	return _land_france(x, z, df)

## Height used by the coarse terrain grid: land height with the coastal ramp
## down to the sea floor (hidden under the cliff ribbon).
func grid_height(x: float, z: float) -> float:
	var de := england_d(x, z)
	var df := france_d(x, z)
	var d := maxf(de, df)
	if d <= RAMP_OUT:
		return SEA_FLOOR
	var l := _land_england(x, z, de) if de >= df else _land_france(x, z, df)
	if d >= RAMP_IN:
		return l
	var t := (d - RAMP_OUT) / (RAMP_IN - RAMP_OUT)
	return lerpf(SEA_FLOOR, l, t * t)

## Visible ground height for gameplay (sea counts as 0.8 m).
func surface_height(x: float, z: float) -> float:
	var de := england_d(x, z)
	var df := france_d(x, z)
	if maxf(de, df) < 0.0:
		return 0.8
	return maxf(land_height(x, z), 0.8)

func detail_noise(x: float, z: float) -> float:
	return _n_det.get_noise_2d(x, z)

# ---------------------------------------------------------------------------
# Land use: woods, towns, downland
# ---------------------------------------------------------------------------

func _coast_point(is_france: bool, x: float, inland: float) -> Vector2:
	var z := france_coast_z(x) if is_france else england_coast_z(x)
	return Vector2(x, z - inland if is_france else z + inland)

func _build_towns() -> void:
	# [is_france, x, inland distance, radius, density]
	var specs : Array = [
		[false,   1700.0,   500.0,  650.0, 1.0],   # Dover (harbour end)
		[false,   2000.0,  1500.0,  700.0, 0.9],   # Dover (valley)
		[false,   2600.0,  2700.0,  550.0, 0.7],   # River / Buckland
		[false,  12000.0,   700.0, 1100.0, 0.9],   # Folkestone
		[false,  16500.0,   450.0,  700.0, 0.8],   # Hythe
		[false, -17200.0,   350.0,  900.0, 0.85],  # Deal
		[false, -15500.0,   300.0,  550.0, 0.7],   # Walmer
		[false,  -8100.0,   500.0,  300.0, 0.6],   # St Margaret's
		[false,  24000.0,  1800.0,  500.0, 0.6],   # New Romney
		[false,   6000.0, 22000.0, 1500.0, 0.9],   # Canterbury
		[true,  -34000.0,   900.0, 2200.0, 1.0],   # Calais
		[true,   -9000.0,   500.0,  380.0, 0.7],   # Wissant
		[true,    7500.0,   600.0,  650.0, 0.8],   # Wimereux
		[true,   11000.0,  1300.0, 1800.0, 0.95],  # Boulogne
		[true,   -4500.0,  4500.0,  350.0, 0.6],   # Inland village
		[true,  -20000.0,  6000.0,  700.0, 0.7],   # Guînes
	]
	for s in specs:
		var p := _coast_point(s[0], s[1], s[2])
		towns.append([p, float(s[3]), float(s[4])])

	# Scattered Kentish and French villages
	var rng := RandomNumberGenerator.new()
	rng.seed = 1940
	var tries := 0
	while tries < 400 and towns.size() < 70:
		tries += 1
		var p := Vector2(rng.randf_range(-44000, 44000), rng.randf_range(-44000, 44000))
		var d := maxf(england_d(p.x, p.y), france_d(p.x, p.y))
		if d < 1500.0:
			continue
		if p.distance_to(airfield_pos) < 2500.0:
			continue
		towns.append([p, rng.randf_range(180.0, 380.0), rng.randf_range(0.5, 0.8)])

	# Spatial buckets so town_density() only tests nearby towns
	for t in towns:
		var c: Vector2 = t[0]
		var reach: float = t[1] * 1.3
		for bx in range(int(floor((c.x - reach) / _TOWN_BUCKET)), int(floor((c.x + reach) / _TOWN_BUCKET)) + 1):
			for bz in range(int(floor((c.y - reach) / _TOWN_BUCKET)), int(floor((c.y + reach) / _TOWN_BUCKET)) + 1):
				var key := Vector2i(bx, bz)
				if not _town_buckets.has(key):
					_town_buckets[key] = []
				_town_buckets[key].append(t)

func town_density(x: float, z: float) -> float:
	var key := Vector2i(int(floor(x / _TOWN_BUCKET)), int(floor(z / _TOWN_BUCKET)))
	if not _town_buckets.has(key):
		return 0.0
	var best := 0.0
	var p := Vector2(x, z)
	for t in _town_buckets[key]:
		var c: Vector2 = t[0]
		var r: float = t[1]
		var dist := p.distance_to(c)
		if dist < r * 1.3:
			var v: float = (1.0 - smoothstep(r * 0.25, r * 1.3, dist)) * t[2]
			best = maxf(best, v)
	if best > 0.0:
		best *= 0.8 + 0.4 * _n_det.get_noise_2d(x * 0.5, z * 0.5)
	return clampf(best, 0.0, 1.0)

func wood_density(x: float, z: float, d: float, h: float) -> float:
	var w := _n_wood.get_noise_2d(x, z) + _n_det.get_noise_2d(x, z) * 0.12
	var v := smoothstep(0.33, 0.45, w)
	v *= smoothstep(180.0, 600.0, d)           # keep cliff tops open
	v *= smoothstep(4.0, 12.0, h)              # no woods on the marsh/beaches
	return v

## Chalk downland (open, pale grass) along the English cliff tops
func downland(d: float, x: float) -> float:
	var on_chalk := smoothstep(-13500.0, -11500.0, x) * (1.0 - smoothstep(10000.0, 13500.0, x))
	return on_chalk * (1.0 - smoothstep(150.0, 550.0, d))

## Land-use image over the core: R = woods, G = town, B = downland.
func build_landuse(size: int) -> Image:
	var data := PackedByteArray()
	data.resize(size * size * 4)
	var cell := CORE_HALF * 2.0 / size
	var i := 0
	for zi in range(size):
		var z := -CORE_HALF + (zi + 0.5) * cell
		for xi in range(size):
			var x := -CORE_HALF + (xi + 0.5) * cell
			var de := england_d(x, z)
			var df := france_d(x, z)
			var d := maxf(de, df)
			var wood := 0.0
			var town := 0.0
			var down := 0.0
			if d > -50.0:
				var h := land_height(x, z)
				town = town_density(x, z)
				wood = wood_density(x, z, d, h) * (1.0 - smoothstep(0.05, 0.25, town))
				if de >= df:
					down = downland(de, x)
				if Vector2(x, z).distance_to(airfield_pos) < AIRFIELD_R:
					wood = 0.0
					town = 0.0
			data[i]     = int(wood * 255.0)
			data[i + 1] = int(town * 255.0)
			data[i + 2] = int(down * 255.0)
			data[i + 3] = 255
			i += 4
	return Image.create_from_data(size, size, false, Image.FORMAT_RGBA8, data)
