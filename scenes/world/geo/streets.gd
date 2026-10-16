extends RefCounted
## Procedural street layout for towns, shared by the terrain shader (which
## draws the streets) and building placement (which lines them with houses).
##
## Towns are split into irregular districts (Voronoi cells about 900 m
## across).  Each district has its own street grid — angle, block size and
## offset from an integer hash of its id — and main roads run along the
## district borders.  Every 4th street is a wider main street.
##
## The same maths lives in terrain.gdshader (district / street functions):
## keep both in sync.  Hashes use 32-bit unsigned arithmetic so GDScript's
## 64-bit ints and the GPU's uints give identical results.

const DIST_CELL := 900.0
const STREET_W := 8.0
const MAIN_W := 14.0
const BORDER_W := 14.0
const _M := 0xffffffff

static func uhash(x: int, y: int, s: int) -> int:
	var h := ((x * 0x8da6b343) & _M) ^ ((y * 0xd8163841) & _M) ^ ((s * 0xcb1ab31f) & _M)
	h ^= h >> 16
	h = (h * 0x7feb352d) & _M
	h ^= h >> 15
	h = (h * 0x846ca68b) & _M
	h ^= h >> 16
	return h

static func fhash(x: int, y: int, s: int) -> float:
	return float(uhash(x, y, s) & 0xffffff) / 16777216.0

## Voronoi site (district centre) of cell (cx, cy), world metres
static func site(cx: int, cy: int) -> Vector2:
	return Vector2(cx + 0.15 + 0.7 * fhash(cx, cy, 11), cy + 0.15 + 0.7 * fhash(cx, cy, 12)) * DIST_CELL

## District containing p: [id (Vector2i), site (Vector2), distance to border (m)]
static func district(p: Vector2) -> Array:
	var n := Vector2i(floori(p.x / DIST_CELL), floori(p.y / DIST_CELL))
	var best := INF
	var bid := n
	var bsite := Vector2.ZERO
	for j in range(-1, 2):
		for i in range(-1, 2):
			var s := site(n.x + i, n.y + j)
			var d := p.distance_squared_to(s)
			if d < best:
				best = d
				bid = Vector2i(n.x + i, n.y + j)
				bsite = s
	var mr := bsite - p
	var md := INF
	for j in range(-1, 2):
		for i in range(-1, 2):
			if i == 0 and j == 0:
				continue
			var r := site(bid.x + i, bid.y + j) - p
			md = minf(md, ((mr + r) * 0.5).dot((r - mr).normalized()))
	return [bid, bsite, md]

## Street grid of a district: [direction u (Vector2), spacing u, spacing v,
## offset u, offset v, industrial (bool)]
static func grid(id: Vector2i) -> Array:
	var a := fhash(id.x, id.y, 13) * PI * 0.5
	var su := 95.0 + 70.0 * fhash(id.x, id.y, 14)
	var sv := su * (1.0 + 0.6 * fhash(id.x, id.y, 15))
	return [Vector2(cos(a), sin(a)), su, sv, fhash(id.x, id.y, 16), fhash(id.x, id.y, 17),
		fhash(id.x, id.y, 20) < 0.12]

static func street_width(k: int) -> float:
	return MAIN_W if posmod(k, 4) == 0 else STREET_W

## Signed distance from p to the nearest road edge (negative on a road)
static func road_edge(p: Vector2) -> float:
	var dd := district(p)
	var g := grid(dd[0])
	var dir : Vector2 = g[0]
	var rel : Vector2 = p - (dd[1] as Vector2)
	var su : float = g[1]
	var sv : float = g[2]
	var qu : float = rel.dot(dir) / su - g[3]
	var qv : float = rel.dot(Vector2(-dir.y, dir.x)) / sv - g[4]
	var ku := roundi(qu)
	var kv := roundi(qv)
	var eu : float = absf(qu - ku) * su - street_width(ku) * 0.5
	var ev : float = absf(qv - kv) * sv - street_width(kv) * 0.5
	return minf(minf(eu, ev), dd[2] - BORDER_W * 0.5)
