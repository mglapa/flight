extends "res://scenes/plane/lowpoly_aircraft.gd"
## Low-poly Messerschmitt Bf 109 E-4, Channel front, summer 1940.
##
## Angular airframe: slab-sided fuselage, straight-tapered wings with squared
## tips, strut-braced tailplane mounted on the fin, framed canopy, chin oil
## cooler, underwing radiators and the port supercharger intake.
## Paint: RLM 02/71 splinter over RLM 65, mottled flanks, yellow cowling and
## rudder, Balkenkreuze on wings and fuselage.  (The fin swastika is omitted.)
##
## Model space: nose toward -Z, up +Y, right wing +X, origin near the wing
## quarter chord.  Shared helpers live in lowpoly_aircraft.gd.

const RLM71 := Color(0.29, 0.32, 0.22)     # dark green
const RLM02 := Color(0.48, 0.48, 0.39)     # grey-green
const RLM65 := Color(0.62, 0.71, 0.77)     # light blue
const RLM70 := Color(0.16, 0.19, 0.14)     # black-green (spinner, prop)
const RLM04 := Color(0.92, 0.72, 0.13)     # yellow
const BLACK := Color(0.07, 0.07, 0.07)
const WHITE := Color(0.94, 0.94, 0.92)
const METAL := Color(0.42, 0.43, 0.44)
const EXHAUST := Color(0.24, 0.16, 0.12)

const WING_SEMI := 4.93
const WING_ROOT := 2.0
const WING_TIP  := 1.12
const TAPER_END := 4.55        # straight taper ends here; the tip is squared off
const AIL_IN    := 2.9
const AIL_OUT   := 4.55
const AIL_F     := 0.74
const ELEV_F    := 0.6
const RUDDER_F  := 0.42
const TAIL_Y    := 0.62        # tailplane sits high on the fin

# Fuselage cross-sections: [z, half-width, half-height, centre-y]
const FUSELAGE : Array = [
	[-3.70, 0.36, 0.40, 0.04],
	[-3.20, 0.42, 0.50, 0.00],
	[-2.20, 0.45, 0.58, -0.02],
	[-1.30, 0.46, 0.62, 0.00],
	[-0.40, 0.45, 0.62, 0.04],
	[ 0.60, 0.41, 0.56, 0.08],
	[ 1.80, 0.33, 0.46, 0.12],
	[ 3.00, 0.23, 0.36, 0.18],
	[ 3.90, 0.14, 0.29, 0.25],
	[ 4.25, 0.07, 0.22, 0.30],
]

func _ready() -> void:
	fuselage = FUSELAGE
	var mat := _vc_material(0.8)

	_st = _begin()
	_build_fuselage()
	_build_wing(1.0)
	_build_wing(-1.0)
	_build_tailplane(1.0)
	_build_tailplane(-1.0)
	_build_fin()
	_build_details()
	_build_markings()
	_add_mesh(self, _st, mat, "Airframe")

	_build_canopy()
	_build_control_surfaces(mat)
	# Spinner: black-green with one white segment
	_build_prop(mat, Vector3(0, 0.02, -3.75), 1.55, 3, 0.36, 0.62,
		func(a: float) -> Color: return WHITE if fposmod(a, TAU) < TAU / 3.0 else RLM70,
		func(_r: float) -> Color: return RLM70)
	_finish_build()

# ---------------------------------------------------------------------------
# Paint
# ---------------------------------------------------------------------------

## Splinter camouflage: angular patches from a rotated grid
static func _splinter(p: Vector3) -> Color:
	var a := deg_to_rad(28.0)
	var u := p.x * cos(a) - p.z * sin(a)
	var v := p.x * sin(a) + p.z * cos(a)
	var cell := Vector2(floor(u / 1.25), floor(v / 0.95 + floor(u / 1.25) * 0.5))
	var h := fposmod(sin(cell.dot(Vector2(12.9898, 78.233))) * 43758.5453, 1.0)
	return RLM71 if h > 0.45 else RLM02

static func _mottle(p: Vector3) -> Color:
	var cell := Vector3(floor(p.x / 0.35), floor(p.y / 0.3), floor(p.z / 0.4))
	var h := fposmod(sin(cell.dot(Vector3(12.9898, 78.233, 37.719))) * 43758.5453, 1.0)
	if h > 0.82:
		return RLM02
	if h > 0.74:
		return RLM71
	return RLM65

static func _paint_surface(p: Vector3, n: Vector3) -> Color:
	return RLM65 if n.y < -0.2 else _splinter(p)

static func _paint_fuselage(p: Vector3, n: Vector3) -> Color:
	if p.z < -2.15:
		return RLM04 if n.y > -0.6 else RLM65        # yellow cowling
	if n.y > 0.55:
		return _splinter(p)                          # spine
	if n.y < -0.45:
		return RLM65                                 # belly
	return _mottle(p) if p.z < 3.6 else RLM65        # mottled flanks

# ---------------------------------------------------------------------------
# Fuselage
# ---------------------------------------------------------------------------

func _build_fuselage() -> void:
	var rings : Array = []
	for s in FUSELAGE:
		rings.append(_octagon(s))
	_loft(_st, rings, _paint_fuselage, true, false)
	var tip := Vector3(0.0, 0.31, 4.38)
	var last : PackedVector3Array = rings[-1]
	var inside := _centroid(last) + Vector3(0, 0, -0.1)
	for i in range(8):
		var a := last[i]
		var b := last[(i + 1) % 8]
		_tri(_st, a, b, tip, _paint_fuselage((a + b + tip) / 3.0, _face_normal(a, b, tip, inside)), inside)

# ---------------------------------------------------------------------------
# Flying surfaces
# ---------------------------------------------------------------------------

func _wing_chord(x: float) -> float:
	if x <= TAPER_END:
		return lerpf(WING_ROOT, WING_TIP, x / TAPER_END)
	# Squared-off tip with rounded corners
	var f := (x - TAPER_END) / (WING_SEMI - TAPER_END)
	return lerpf(WING_TIP, 0.55, f * f)
func _wing_le(x: float) -> float:
	var le := -0.55 + x * 0.05
	if x > TAPER_END:
		var f := (x - TAPER_END) / (WING_SEMI - TAPER_END)
		le += f * f * 0.2
	return le
func _wing_t(x: float) -> float:
	return _wing_chord(x) * lerpf(0.14, 0.11, x / WING_SEMI)
func _wing_y(x: float) -> float:
	return -0.45 + x * tan(deg_to_rad(6.5))

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
	_loft(_st, _wing_rings(side, [0.0, 0.7, 1.5, 2.2, AIL_IN], 0.0, 1.0), _paint_surface)
	_loft(_st, _wing_rings(side, [AIL_IN, 3.7, AIL_OUT], 0.0, AIL_F), _paint_surface)
	_loft(_st, _wing_rings(side, [AIL_OUT, 4.75, 4.88, WING_SEMI], 0.0, 1.0), _paint_surface)

func _tail_chord(x: float) -> float:
	return lerpf(0.95, 0.62, x / 1.45) if x < 1.45 else lerpf(0.62, 0.3, (x - 1.45) / 0.15)

func _tail_pt(side: float, x: float, f: float, k: float) -> Vector3:
	var c := _tail_chord(x)
	return Vector3(side * x, TAIL_Y + k * c * 0.09, 3.48 + x * 0.06 + f * c)

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
	_loft(_st, _tail_rings(side, [0.0, 0.5, 1.0, 1.45, 1.6], 0.0, ELEV_F), _paint_surface)
	# Bracing strut from the tailplane underside down to the fuselage
	var top := _tail_pt(side, 0.75, 0.35, -0.4)
	_strut(_st, top, Vector3(side * 0.12, 0.12, 3.75), 0.05, 0.05, RLM65)

func _fin_chord(h: float) -> float:
	return maxf(1.05 * sqrt(maxf(0.0, 1.0 - pow(h / 1.25, 2.0))), 0.22)

func _fin_pt(h: float, f: float, k: float) -> Vector3:
	var c := _fin_chord(h)
	return Vector3(k * c * 0.1, 0.38 + h, 3.62 - 0.25 * c + f * c)

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
	_loft(_st, _fin_rings([0.0, 0.4, 0.75, 1.0, 1.18], 0.0, RUDDER_F),
		func(p: Vector3, _n: Vector3) -> Color: return _splinter(p))

func _build_control_surfaces(mat: Material) -> void:
	for side in [1.0, -1.0]:
		var st := _begin()
		_loft(st, _wing_rings(side, [AIL_IN, 3.7, AIL_OUT], AIL_F, 1.0), _paint_surface)
		_hinged("aileron_r" if side > 0.0 else "aileron_l",
			_wing_pt(side, AIL_IN, AIL_F, 0.0), _wing_pt(side, AIL_OUT, AIL_F, 0.0), st, mat)

	var st_e := _begin()
	for side in [1.0, -1.0]:
		_loft(st_e, _tail_rings(side, [0.0, 0.5, 1.0, 1.45, 1.6], ELEV_F, 1.0), _paint_surface)
	var hinge := _tail_pt(1.0, 0.0, ELEV_F, 0.0)
	_hinged("elevator", Vector3(-1.0, hinge.y, hinge.z), Vector3(1.0, hinge.y, hinge.z), st_e, mat)

	# Yellow rudder, running down to the bottom of the tail cone
	var st_r := _begin()
	_loft(st_r, _fin_rings([-0.3, 0.0, 0.4, 0.75, 1.0, 1.18], RUDDER_F, 1.0),
		func(_p: Vector3, _n: Vector3) -> Color: return RLM04)
	_hinged("rudder", _fin_pt(0.0, RUDDER_F, 0.0), _fin_pt(1.18, RUDDER_F, 0.0), st_r, mat)

# ---------------------------------------------------------------------------
# Canopy and details
# ---------------------------------------------------------------------------

func _build_canopy() -> void:
	var glass := _glass_material(Color(0.52, 0.64, 0.72, 0.5))
	var st := _begin()
	# Angular "greenhouse": [z, half-width at sill, half-width at roof, height]
	var secs : Array = [[-1.05, 0.30, 0.12, 0.08], [-0.85, 0.32, 0.17, 0.34], [-0.05, 0.31, 0.18, 0.36],
		[0.45, 0.27, 0.15, 0.30], [0.70, 0.20, 0.08, 0.05]]
	var rings : Array = []
	for s in secs:
		var z : float = s[0]
		var y0 := _top_y(z) - 0.03
		var wb : float = s[1]; var wt : float = s[2]; var h : float = s[3]
		rings.append(PackedVector3Array([Vector3(-wb, y0, z), Vector3(-wt, y0 + h, z),
			Vector3(wt, y0 + h, z), Vector3(wb, y0, z)]))
	_loft(st, rings, func(_p: Vector3, _n: Vector3) -> Color: return Color.WHITE)
	_add_mesh(self, st, glass, "Canopy")

	# Heavy frames, armoured headrest and the pilot
	var sf := _begin()
	for s in secs.slice(1, 4):
		var z : float = s[0]
		var y0 := _top_y(z) - 0.02
		var wb : float = s[1]; var wt : float = s[2]; var h : float = s[3]
		_strut(sf, Vector3(-wb, y0, z), Vector3(-wt, y0 + h + 0.01, z), 0.05, 0.05, RLM71)
		_strut(sf, Vector3(-wt, y0 + h + 0.01, z), Vector3(wt, y0 + h + 0.01, z), 0.05, 0.05, RLM71)
		_strut(sf, Vector3(wt, y0 + h + 0.01, z), Vector3(wb, y0, z), 0.05, 0.05, RLM71)
	for sgn in [-1.0, 1.0]:
		var a : Vector3 = Vector3(sgn * 0.17, _top_y(-0.85) + 0.33, -0.85)
		var b : Vector3 = Vector3(sgn * 0.15, _top_y(0.45) + 0.29, 0.45)
		_strut(sf, a, b, 0.05, 0.05, RLM71)
	_strut(sf, Vector3(0, _top_y(-0.85) + 0.33, -0.85), Vector3(0, _top_y(0.45) + 0.29, 0.45), 0.05, 0.05, RLM71)
	_strut(sf, Vector3(0, _top_y(0.3) + 0.02, 0.3), Vector3(0, _top_y(0.3) + 0.3, 0.3), 0.24, 0.05, METAL)
	_cylinder(sf, Vector3(0, _top_y(-0.2) + 0.02, -0.2), Vector3.UP, 0.13, 0.11, 0.26, 6, Color(0.3, 0.22, 0.15))
	_add_mesh(self, sf, _vc_material(), "Frames")

func _build_details() -> void:
	# Exhaust stacks low on the inverted-V DB 601
	for side in [1.0, -1.0]:
		for i in range(6):
			var z := -3.0 + i * 0.2
			var s := _section(z)
			var p := Vector3(side * (s[1] + 0.01), s[3] - 0.12, z)
			_strut(_st, p, p + Vector3(side * 0.06, -0.03, 0.1), 0.06, 0.07, EXHAUST)

	# Supercharger intake on the port side of the cowling
	var s2 := _section(-2.4)
	var ip := Vector3(-(s2[1] + 0.02), s2[3] + 0.05, -2.6)
	_cylinder(_st, ip, Vector3.BACK, 0.09, 0.1, 0.5, 6, RLM04, BLACK)

	# Chin oil cooler under the nose
	var sb := _section(-2.4)
	var y_b : float = sb[3] - sb[2] * 0.92
	var oc : Array = []
	for row in [[-2.9, 0.12, 0.04], [-2.7, 0.18, 0.16], [-2.0, 0.18, 0.18], [-1.75, 0.12, 0.05]]:
		var z : float = row[0]; var w : float = row[1]; var d : float = row[2]
		oc.append(PackedVector3Array([Vector3(-w, y_b + 0.02, z), Vector3(w, y_b + 0.02, z),
			Vector3(w, y_b - d, z), Vector3(-w, y_b - d, z)]))
	_loft(_st, oc, func(_p: Vector3, n: Vector3) -> Color: return BLACK if absf(n.z) > 0.6 else RLM65)

	# Shallow radiator baths under each wing
	for side in [1.0, -1.0]:
		var rx := 1.75
		var ry := _wing_y(rx) - 0.4 * _wing_t(rx)
		var rr : Array = []
		for row in [[-0.25, 0.30, 0.04], [0.0, 0.36, 0.13], [0.65, 0.36, 0.14], [0.9, 0.30, 0.04]]:
			var z : float = row[0]; var w : float = row[1]; var d : float = row[2]
			rr.append(PackedVector3Array([Vector3(side * rx - w, ry, z), Vector3(side * rx + w, ry, z),
				Vector3(side * rx + w, ry - d, z), Vector3(side * rx - w, ry - d, z)]))
		_loft(_st, rr, func(_p: Vector3, n: Vector3) -> Color: return BLACK if absf(n.z) > 0.6 else RLM65)

	# Aerial mast and wing cannon barrels
	_strut(_st, Vector3(0, _top_y(1.1) - 0.02, 1.1), Vector3(0, _top_y(1.1) + 0.38, 1.22), 0.04, 0.08, RLM71)
	for side in [1.0, -1.0]:
		var gp := _wing_pt(side, 2.5, 0.0, 0.0)
		_cylinder(_st, gp + Vector3(0, -0.02, 0.05), Vector3.FORWARD, 0.04, 0.04, 0.32, 6, BLACK)

# ---------------------------------------------------------------------------
# Markings
# ---------------------------------------------------------------------------

## Balkenkreuz: black cross with white flanks, centred in disc coordinates
func _balkenkreuz(size: float, project: Callable, inside: Vector3, subdiv := 4) -> void:
	var h := size * 0.5
	var arm := size * 0.2
	var flank := size * 0.1
	var white := arm * 0.5 + flank
	_rect_marking(Rect2(-h, -white, size, white * 2.0), WHITE, project, inside, subdiv)
	_rect_marking(Rect2(-white, -h, white * 2.0, size), WHITE, project, inside, subdiv)
	_rect_marking(Rect2(-h, -arm * 0.5, size, arm), BLACK, project, inside, subdiv, 0.012)
	_rect_marking(Rect2(-arm * 0.5, -h, arm, size), BLACK, project, inside, subdiv, 0.012)

func _build_markings() -> void:
	# Upper and lower wing crosses
	for side in [1.0, -1.0]:
		var cx := 3.45
		var cz := _wing_le(cx) + 0.45 * _wing_chord(cx)
		for upper in [true, false]:
			var table : Array = _AF_U if upper else _AF_L
			var off := 0.03 if upper else -0.03
			var proj := func(u: float, v: float) -> Vector3:
				var x := cx + u
				var f := clampf((cz + v - _wing_le(x)) / _wing_chord(x), 0.0, 1.0)
				return Vector3(side * x, _wing_y(x) + _af(table, f) * _wing_t(x) + off, cz + v)
			_balkenkreuz(0.95, proj, Vector3(side * cx, _wing_y(cx) + (-0.5 if upper else 0.5), cz))

	# Fuselage crosses
	for side in [1.0, -1.0]:
		var cz := 2.05
		var cy := 0.12
		var proj := func(u: float, v: float) -> Vector3:
			var z := cz + u
			var y := cy + v
			return Vector3(side * (_fuselage_x(z, y) + 0.035), y, z)
		_balkenkreuz(0.72, proj, Vector3(0, cy, cz), 10)
