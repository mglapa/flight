extends "res://scenes/plane/lowpoly_aircraft.gd"
## Low-poly Heinkel He 111 H medium bomber, summer 1940.
##
## Fully glazed "greenhouse" nose, long tapering fuselage, broad elliptical
## wings with two Jumo 211 nacelles (annular radiators, three-blade props),
## elliptical tail, dorsal gun cupola and ventral gondola.
## Paint: RLM 70/71 splinter over RLM 65, Balkenkreuze on wings and fuselage.
##
## Model space: nose toward -Z, up +Y, right wing +X, origin near the wing
## quarter chord.  Shared helpers live in lowpoly_aircraft.gd.

const RLM70 := Color(0.17, 0.20, 0.15)     # black-green
const RLM71 := Color(0.27, 0.31, 0.21)     # dark green
const RLM65 := Color(0.62, 0.71, 0.77)     # light blue
const BLACK := Color(0.07, 0.07, 0.07)
const WHITE := Color(0.94, 0.94, 0.92)
const METAL := Color(0.40, 0.41, 0.42)
const FRAME := Color(0.12, 0.13, 0.12)

const WING_SEMI := 11.3
const WING_ROOT := 4.6
const AIL_IN    := 6.8
const AIL_OUT   := 10.2
const AIL_F     := 0.74
const ELEV_F    := 0.62
const RUDDER_F  := 0.5
const NACELLE_X := 3.7

# Fuselage cross-sections behind the glazed nose: [z, half-width, half-height, centre-y]
const FUSELAGE : Array = [
	[-6.30, 0.85, 0.95, 0.00],
	[-4.50, 0.90, 1.00, 0.00],
	[-2.00, 0.90, 1.00, 0.00],
	[ 0.50, 0.85, 0.95, 0.05],
	[ 3.00, 0.68, 0.80, 0.10],
	[ 5.50, 0.45, 0.58, 0.20],
	[ 7.40, 0.25, 0.40, 0.32],
	[ 8.10, 0.12, 0.28, 0.38],
]
# Glazed nose rings, front to back: [z, half-width, half-height, centre-y]
const NOSE : Array = [
	[-8.05, 0.28, 0.26, -0.05],
	[-7.70, 0.58, 0.58, -0.03],
	[-7.10, 0.78, 0.84, -0.01],
	[-6.30, 0.85, 0.95, 0.00],
]

func _ready() -> void:
	fuselage = FUSELAGE
	var mat := _vc_material(0.8)

	_st = _begin()
	_build_fuselage()
	for side in [1.0, -1.0]:
		_build_wing(side)
		_build_nacelle(side)
		_build_tailplane(side)
	_build_fin()
	_build_gun_positions()
	_build_markings()
	_add_mesh(self, _st, mat, "Airframe")

	_build_glazing()
	_build_control_surfaces(mat)
	for side in [1.0, -1.0]:
		_build_prop(mat, _nacelle_centre(side, -4.75), 1.75, 3, 0.36, 0.7,
			func(_a: float) -> Color: return RLM70,
			func(_r: float) -> Color: return RLM70)
	_finish_build()

# ---------------------------------------------------------------------------
# Paint
# ---------------------------------------------------------------------------

static func _splinter(p: Vector3) -> Color:
	var a := deg_to_rad(32.0)
	var u := p.x * cos(a) - p.z * sin(a)
	var v := p.x * sin(a) + p.z * cos(a)
	var cell := Vector2(floor(u / 2.6), floor(v / 2.0 + floor(u / 2.6) * 0.5))
	var h := fposmod(sin(cell.dot(Vector2(12.9898, 78.233))) * 43758.5453, 1.0)
	return RLM70 if h > 0.5 else RLM71

static func _paint_surface(p: Vector3, n: Vector3) -> Color:
	return RLM65 if n.y < -0.25 else _splinter(p)

static func _paint_fuselage(p: Vector3, n: Vector3) -> Color:
	return RLM65 if n.y < -0.4 else _splinter(p)

# ---------------------------------------------------------------------------
# Fuselage
# ---------------------------------------------------------------------------

func _build_fuselage() -> void:
	var rings : Array = []
	for s in FUSELAGE:
		rings.append(_octagon(s))
	_loft(_st, rings, _paint_fuselage, false, false)
	var tip := Vector3(0.0, 0.40, 8.3)
	var last : PackedVector3Array = rings[-1]
	var inside := _centroid(last) + Vector3(0, 0, -0.1)
	for i in range(8):
		var a := last[i]
		var b := last[(i + 1) % 8]
		_tri(_st, a, b, tip, _paint_fuselage((a + b + tip) / 3.0, _face_normal(a, b, tip, inside)), inside)

## The "Stepless cockpit": a fully glazed, heavily framed bullet nose
func _build_glazing() -> void:
	var glass := _glass_material(Color(0.55, 0.66, 0.74, 0.45))
	var rings : Array = []
	for s in NOSE:
		rings.append(_octagon(s))
	var st := _begin()
	_loft(st, rings, func(_p: Vector3, _n: Vector3) -> Color: return Color.WHITE, true, false)
	_add_mesh(self, st, glass, "NoseGlazing")

	var sf := _begin()
	# Frames: around each ring and along each octagon edge
	for r in range(rings.size()):
		var ring : PackedVector3Array = rings[r]
		for i in range(8):
			_strut(sf, ring[i], ring[(i + 1) % 8], 0.05, 0.05, FRAME)
		if r + 1 < rings.size():
			var nxt : PackedVector3Array = rings[r + 1]
			for i in range(8):
				_strut(sf, ring[i], nxt[i], 0.05, 0.05, FRAME)
	# Extra mid-ring frame band for the many small panels
	var mid := _octagon([-7.4, 0.70, 0.72, -0.02])
	for i in range(8):
		_strut(sf, mid[i], mid[(i + 1) % 8], 0.04, 0.04, FRAME)
	# Crew visible through the glazing: pilot (offset to port) and bomb aimer
	_cylinder(sf, Vector3(-0.32, 0.15, -6.7), Vector3.UP, 0.15, 0.13, 0.32, 6, Color(0.30, 0.22, 0.15))
	_strut(sf, Vector3(-0.32, -0.45, -6.6), Vector3(-0.32, 0.15, -6.6), 0.4, 0.3, Color(0.22, 0.24, 0.2))
	_strut(sf, Vector3(0.1, -0.6, -7.5), Vector3(0.1, -0.35, -7.5), 0.4, 0.5, Color(0.22, 0.24, 0.2))
	# Nose MG poking out of the offset gun ball
	_cylinder(sf, Vector3(0.08, 0.12, -8.0), Vector3.FORWARD, 0.04, 0.04, 0.55, 6, BLACK)
	_add_mesh(self, sf, _vc_material(), "NoseFrames")

# ---------------------------------------------------------------------------
# Wings, nacelles, tail
# ---------------------------------------------------------------------------

func _wing_chord(x: float) -> float:
	var straight := lerpf(WING_ROOT, 1.7, x / 10.4)
	if x <= 10.4:
		return straight
	var f := (x - 10.4) / (WING_SEMI - 10.4)
	return lerpf(1.7, 0.5, f * f)
func _wing_le(x: float) -> float:
	var le := -1.85 + x * 0.13
	if x > 10.4:
		var f := (x - 10.4) / (WING_SEMI - 10.4)
		le += f * f * 0.5
	return le
func _wing_t(x: float) -> float:
	return _wing_chord(x) * lerpf(0.17, 0.1, x / WING_SEMI)
func _wing_y(x: float) -> float:
	return -0.35 + x * tan(deg_to_rad(4.0))

func _wing_pt(side: float, x: float, f: float, k: float) -> Vector3:
	return Vector3(side * x, _wing_y(x) + k * _wing_t(x), _wing_le(x) + f * _wing_chord(x))

func _wing_rings(side: float, stations: Array, f0: float, f1: float) -> Array:
	var loop := _airfoil_loop(f0, f1)
	var rings : Array = []
	for x in stations:
		var ring := PackedVector3Array()
		for p in loop:
			ring.append(_wing_pt(side, x, p[0], p[1]))
		rings.append(ring)
	return rings

func _build_wing(side: float) -> void:
	_loft(_st, _wing_rings(side, [0.0, 1.5, 3.0, 4.5, 5.8, AIL_IN], 0.0, 1.0), _paint_surface)
	_loft(_st, _wing_rings(side, [AIL_IN, 8.5, AIL_OUT], 0.0, AIL_F), _paint_surface)
	_loft(_st, _wing_rings(side, [AIL_OUT, 10.6, 10.95, 11.2, WING_SEMI], 0.0, 1.0), _paint_surface)

func _nacelle_centre(side: float, z: float) -> Vector3:
	return Vector3(side * NACELLE_X, _wing_y(NACELLE_X) - 0.02, z)

## Jumo 211 nacelle with the annular radiator ring at the front
func _build_nacelle(side: float) -> void:
	var prof : Array = [[-4.6, 0.46], [-4.35, 0.62], [-3.0, 0.66], [-1.0, 0.62], [1.2, 0.46], [2.8, 0.18]]
	var rings : Array = []
	for pr in prof:
		var c := _nacelle_centre(side, pr[0])
		var ring := _octagon([c.z, pr[1], pr[1] * 1.05, c.y])
		for i in range(ring.size()):
			ring[i] = ring[i] + Vector3(c.x, 0, 0)
		rings.append(ring)
	var paint := func(p: Vector3, n: Vector3) -> Color:
		if p.z < -4.4:
			return BLACK if n.z < -0.5 else METAL           # annular radiator ring
		return _paint_fuselage(p, n)
	_loft(_st, rings, paint, true, true)
	# Exhaust stubs along both sides of the cowling
	for sx in [-1.0, 1.0]:
		for i in range(4):
			var z := -4.0 + i * 0.3
			var c := _nacelle_centre(side, z)
			var p := c + Vector3(sx * 0.66, 0.1, 0)
			_strut(_st, p, p + Vector3(sx * 0.07, -0.03, 0.12), 0.07, 0.08, Color(0.22, 0.15, 0.11))

func _tail_chord(x: float) -> float:
	return maxf(2.1 * sqrt(maxf(0.0, 1.0 - pow(x / 4.1, 2.0))), 0.35)

func _tail_pt(side: float, x: float, f: float, k: float) -> Vector3:
	var c := _tail_chord(x)
	return Vector3(side * x, 0.48 + k * c * 0.09, 6.35 - 0.25 * c + f * c)

func _tail_rings(side: float, stations: Array, f0: float, f1: float) -> Array:
	var loop := _airfoil_loop(f0, f1)
	var rings : Array = []
	for x in stations:
		var ring := PackedVector3Array()
		for p in loop:
			ring.append(_tail_pt(side, x, p[0], p[1]))
		rings.append(ring)
	return rings

func _build_tailplane(side: float) -> void:
	_loft(_st, _tail_rings(side, [0.0, 1.2, 2.4, 3.3, 3.9], 0.0, ELEV_F), _paint_surface)

func _fin_chord(h: float) -> float:
	return maxf(2.5 * sqrt(maxf(0.0, 1.0 - pow(h / 2.55, 2.0))), 0.35)

func _fin_pt(h: float, f: float, k: float) -> Vector3:
	var c := _fin_chord(h)
	return Vector3(k * c * 0.09, 0.55 + h, 6.6 - 0.35 * c + f * c)

func _fin_rings(stations: Array, f0: float, f1: float) -> Array:
	var loop := _airfoil_loop(f0, f1)
	var rings : Array = []
	for h in stations:
		var ring := PackedVector3Array()
		for p in loop:
			ring.append(_fin_pt(h, p[0], p[1]))
		rings.append(ring)
	return rings

func _build_fin() -> void:
	_loft(_st, _fin_rings([0.0, 0.8, 1.5, 2.0, 2.35], 0.0, RUDDER_F),
		func(p: Vector3, _n: Vector3) -> Color: return _splinter(p))

func _build_control_surfaces(mat: Material) -> void:
	for side in [1.0, -1.0]:
		var st := _begin()
		_loft(st, _wing_rings(side, [AIL_IN, 8.5, AIL_OUT], AIL_F, 1.0), _paint_surface)
		_hinged("aileron_r" if side > 0.0 else "aileron_l",
			_wing_pt(side, AIL_IN, AIL_F, 0.0), _wing_pt(side, AIL_OUT, AIL_F, 0.0), st, mat)

	var st_e := _begin()
	for side in [1.0, -1.0]:
		_loft(st_e, _tail_rings(side, [0.0, 1.2, 2.4, 3.3, 3.9], ELEV_F, 1.0), _paint_surface)
	var hinge := _tail_pt(1.0, 0.0, ELEV_F, 0.0)
	_hinged("elevator", Vector3(-1.0, hinge.y, hinge.z), Vector3(1.0, hinge.y, hinge.z), st_e, mat)

	var st_r := _begin()
	_loft(st_r, _fin_rings([0.0, 0.8, 1.5, 2.0, 2.35], RUDDER_F, 1.0),
		func(p: Vector3, _n: Vector3) -> Color: return _splinter(p))
	_hinged("rudder", _fin_pt(0.0, RUDDER_F, 0.0), _fin_pt(2.35, RUDDER_F, 0.0), st_r, mat)

# ---------------------------------------------------------------------------
# Defensive positions
# ---------------------------------------------------------------------------

func _build_gun_positions() -> void:
	# Dorsal "B-Stand": raised glazed cupola behind the wing with a rear MG
	var glass_col := Color(0.42, 0.52, 0.6)
	var top := _top_y(1.8)
	var cup : Array = []
	for row in [[1.0, 0.25, 0.05], [1.4, 0.42, 0.32], [2.3, 0.42, 0.34], [2.7, 0.3, 0.1]]:
		var z : float = row[0]; var w : float = row[1]; var h : float = row[2]
		var y0 := _top_y(z) - 0.04
		cup.append(PackedVector3Array([Vector3(-w, y0, z), Vector3(-w * 0.6, y0 + h, z),
			Vector3(w * 0.6, y0 + h, z), Vector3(w, y0, z)]))
	_loft(_st, cup, func(_p: Vector3, n: Vector3) -> Color: return glass_col if n.y > 0.2 else FRAME)
	_cylinder(_st, Vector3(0, top + 0.3, 2.5), Vector3.BACK, 0.04, 0.04, 0.8, 6, BLACK)

	# Ventral gondola ("Bola") slung under the fuselage, offset to port
	var gy := -1.0
	var gond : Array = []
	for row in [[-1.6, 0.25, 0.1], [-1.1, 0.42, 0.42], [1.8, 0.42, 0.45], [2.9, 0.3, 0.28]]:
		var z : float = row[0]; var w : float = row[1]; var h : float = row[2]
		gond.append(PackedVector3Array([Vector3(-0.15 - w, gy + 0.2, z), Vector3(-0.15 + w, gy + 0.2, z),
			Vector3(-0.15 + w, gy - h, z), Vector3(-0.15 - w, gy - h, z)]))
	_loft(_st, gond, func(p: Vector3, n: Vector3) -> Color:
		return glass_col if n.z > 0.5 else RLM65)
	_cylinder(_st, Vector3(-0.15, gy - 0.2, 2.8), Vector3.BACK, 0.04, 0.04, 0.7, 6, BLACK)

	# Aerial mast
	_strut(_st, Vector3(0, _top_y(-1.5) - 0.02, -1.5), Vector3(0, _top_y(-1.5) + 0.5, -1.35), 0.05, 0.1, RLM70)

# ---------------------------------------------------------------------------
# Markings
# ---------------------------------------------------------------------------

## Balkenkreuz: black cross with white flanks, centred in disc coordinates
func _balkenkreuz(size: float, project: Callable, inside: Vector3, subdiv := 4) -> void:
	var h := size * 0.5
	var arm := size * 0.2
	var white := arm * 0.5 + size * 0.1
	_rect_marking(Rect2(-h, -white, size, white * 2.0), WHITE, project, inside, subdiv)
	_rect_marking(Rect2(-white, -h, white * 2.0, size), WHITE, project, inside, subdiv)
	_rect_marking(Rect2(-h, -arm * 0.5, size, arm), BLACK, project, inside, subdiv, 0.02)
	_rect_marking(Rect2(-arm * 0.5, -h, arm, size), BLACK, project, inside, subdiv, 0.02)

func _build_markings() -> void:
	for side in [1.0, -1.0]:
		var cx := 8.0
		var cz := _wing_le(cx) + 0.45 * _wing_chord(cx)
		for upper in [true, false]:
			var table : Array = _AF_U if upper else _AF_L
			var off := 0.04 if upper else -0.04
			var proj := func(u: float, v: float) -> Vector3:
				var x := cx + u
				var f := clampf((cz + v - _wing_le(x)) / _wing_chord(x), 0.0, 1.0)
				return Vector3(side * x, _wing_y(x) + _af(table, f) * _wing_t(x) + off, cz + v)
			_balkenkreuz(1.7, proj, Vector3(side * cx, _wing_y(cx) + (-1.0 if upper else 1.0), cz))

	for side in [1.0, -1.0]:
		var cz := 4.4
		var cy := 0.15
		var proj := func(u: float, v: float) -> Vector3:
			var z := cz + u
			var y := cy + v
			return Vector3(side * (_fuselage_x(z, y) + 0.04), y, z)
		_balkenkreuz(1.1, proj, Vector3(0, cy, cz), 10)
