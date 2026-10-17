extends "res://scenes/plane/lowpoly_aircraft.gd"
## Low-poly Vickers Wellington Mk IC medium bomber, 1940.
##
## Deep oval geodetic fuselage with Frazer-Nash nose and tail turrets, beam
## gun hatches, a long high-aspect wing with two Bristol Pegasus radials
## (three-blade props) and the tall rounded fin.
## Paint: Dark Earth / Dark Green upper surfaces over Night (black) undersides
## and lower flanks, Type B roundels above, A1 roundels and a fin flash.
##
## Model space: nose toward -Z, up +Y, right wing +X, origin near the wing
## quarter chord.  Shared helpers live in lowpoly_aircraft.gd.

const DARK_EARTH := Color(0.45, 0.36, 0.24)
const DARK_GREEN := Color(0.24, 0.30, 0.18)
const NIGHT      := Color(0.08, 0.08, 0.09)
const WHITE      := Color(0.93, 0.93, 0.90)
const RAF_BLUE   := Color(0.14, 0.22, 0.45)
const RAF_RED    := Color(0.66, 0.13, 0.12)
const RAF_YELLOW := Color(0.88, 0.72, 0.16)
const BLACK      := Color(0.07, 0.07, 0.07)
const METAL      := Color(0.42, 0.43, 0.44)
const FRAME      := Color(0.10, 0.10, 0.11)

const WING_SEMI := 13.13
const TAPER_END := 12.5
const AIL_IN    := 8.6
const AIL_OUT   := 12.3
const AIL_F     := 0.74
const ELEV_F    := 0.6
const RUDDER_F  := 0.56
const NACELLE_X := 3.65
const TAIL_Y    := 0.62

# Fuselage cross-sections between the turrets: [z, half-width, half-height, centre-y]
const FUSELAGE : Array = [
	[-8.60, 0.62, 0.78, 0.00],
	[-7.40, 0.80, 1.05, 0.05],
	[-5.60, 0.86, 1.20, 0.10],
	[-2.50, 0.88, 1.25, 0.08],
	[ 0.50, 0.86, 1.20, 0.05],
	[ 3.50, 0.74, 1.02, 0.10],
	[ 6.00, 0.56, 0.80, 0.22],
	[ 8.00, 0.40, 0.62, 0.35],
	[ 8.90, 0.36, 0.55, 0.40],
]
const NOSE_TURRET : Array = [
	[-9.58, 0.24, 0.26, 0.00],
	[-9.38, 0.50, 0.54, 0.00],
	[-8.98, 0.60, 0.70, 0.00],
	[-8.60, 0.62, 0.78, 0.00],
]
const TAIL_TURRET : Array = [
	[ 8.90, 0.36, 0.55, 0.40],
	[ 9.40, 0.42, 0.52, 0.42],
	[ 9.82, 0.32, 0.38, 0.42],
	[10.02, 0.12, 0.14, 0.42],
]

func _ready() -> void:
	fuselage = FUSELAGE
	var mat := _vc_material(0.85)

	_st = _begin()
	_build_fuselage()
	for side in [1.0, -1.0]:
		_build_wing(side)
		_build_nacelle(side)
		_build_tailplane(side)
	_build_fin()
	_build_details()
	_build_markings()
	_add_mesh(self, _st, mat, "Airframe")

	_build_glazing()
	_build_control_surfaces(mat)
	for side in [1.0, -1.0]:
		_build_prop(mat, _nacelle_centre(side, -4.72), 1.9, 3, 0.26, 0.45,
			func(_a: float) -> Color: return BLACK,
			func(r: float) -> Color: return RAF_YELLOW if r > 1.75 else BLACK)
	_finish_build()

# ---------------------------------------------------------------------------
# Paint
# ---------------------------------------------------------------------------

## Temperate land scheme: soft-edged Dark Earth / Dark Green patches
static func _camo(p: Vector3) -> Color:
	var v := sin(p.x * 0.42 + sin(p.z * 0.31) * 2.2) + sin(p.z * 0.37 - p.x * 0.13 + 1.3)
	return DARK_GREEN if v > 0.15 else DARK_EARTH

static func _paint_surface(p: Vector3, n: Vector3) -> Color:
	return NIGHT if n.y < -0.2 else _camo(p)

## Night bombers wore black well up the fuselage sides
static func _paint_fuselage(p: Vector3, n: Vector3) -> Color:
	return _camo(p) if n.y > 0.35 else NIGHT

# ---------------------------------------------------------------------------
# Fuselage and turrets
# ---------------------------------------------------------------------------

func _build_fuselage() -> void:
	var rings : Array = []
	for s in FUSELAGE:
		rings.append(_octagon(s))
	_loft(_st, rings, _paint_fuselage, false, false)

	# Raised cockpit hump ahead of the wing, glazed on top (glass added below)
	var hump : Array = []
	for row in [[-7.2, 0.40, 0.02], [-6.7, 0.58, 0.30], [-5.0, 0.58, 0.34], [-4.2, 0.45, 0.06]]:
		var z : float = row[0]; var w : float = row[1]; var h : float = row[2]
		var y0 := _top_y(z) - 0.05
		hump.append(PackedVector3Array([Vector3(-w, y0, z), Vector3(-w * 0.7, y0 + h, z),
			Vector3(w * 0.7, y0 + h, z), Vector3(w, y0, z)]))
	_loft(_st, hump, func(p: Vector3, n: Vector3) -> Color:
		return FRAME if n.y > 0.3 and p.z < -5.2 else _camo(p))

## Nose and tail turrets: glazed domes with twin Brownings
func _build_glazing() -> void:
	var glass := _glass_material(Color(0.50, 0.60, 0.68, 0.5))
	var sf := _begin()
	for table in [NOSE_TURRET, TAIL_TURRET]:
		var rings : Array = []
		for s in table:
			rings.append(_octagon(s))
		var st := _begin()
		var nose : bool = table == NOSE_TURRET
		_loft(st, rings, func(_p: Vector3, _n: Vector3) -> Color: return Color.WHITE, nose, not nose)
		_add_mesh(self, st, glass, "NoseTurret" if nose else "TailTurret")
		for r in range(rings.size()):
			var ring : PackedVector3Array = rings[r]
			if r + 1 < rings.size():
				var nxt : PackedVector3Array = rings[r + 1]
				for i in [1, 3, 5, 7]:
					_strut(sf, ring[i], nxt[i], 0.05, 0.05, FRAME)
			for i in range(8):
				_strut(sf, ring[i], ring[(i + 1) % 8], 0.045, 0.045, FRAME)
		# Gunner and the twin guns
		var z_mid : float = table[1][0]
		var y_mid : float = table[1][3]
		_cylinder(sf, Vector3(0, y_mid - 0.15, z_mid + (0.1 if nose else -0.1)), Vector3.UP, 0.15, 0.13, 0.32, 6,
			Color(0.28, 0.22, 0.16))
		for gx in [-0.12, 0.12]:
			var g0 := Vector3(gx, y_mid, table[1][0] + (0.15 if nose else -0.15))
			_cylinder(sf, g0, Vector3.FORWARD if nose else Vector3.BACK, 0.035, 0.035, 0.75, 6, BLACK)
	_add_mesh(self, sf, _vc_material(), "TurretFrames")

	# Cockpit glazing on the hump
	var cst := _begin()
	var y0 := _top_y(-6.0) - 0.05
	var pane : Array = []
	for row in [[-6.75, 0.5, 0.29], [-5.3, 0.5, 0.33]]:
		var z : float = row[0]; var w : float = row[1]; var h : float = row[2]
		pane.append(PackedVector3Array([Vector3(-w * 0.95, y0 + 0.03, z), Vector3(-w * 0.68, y0 + h + 0.02, z),
			Vector3(w * 0.68, y0 + h + 0.02, z), Vector3(w * 0.95, y0 + 0.03, z)]))
	_loft(cst, pane, func(_p: Vector3, _n: Vector3) -> Color: return Color.WHITE)
	_add_mesh(self, cst, glass, "Cockpit")

# ---------------------------------------------------------------------------
# Wings, nacelles, tail
# ---------------------------------------------------------------------------

func _wing_chord(x: float) -> float:
	var straight := lerpf(5.0, 1.6, x / TAPER_END)
	if x <= TAPER_END:
		return straight
	var f := (x - TAPER_END) / (WING_SEMI - TAPER_END)
	return lerpf(1.6, 0.55, f * f)
func _wing_le(x: float) -> float:
	var le := -2.2 + x * 0.192
	if x > TAPER_END:
		var f := (x - TAPER_END) / (WING_SEMI - TAPER_END)
		le += f * f * 0.45
	return le
func _wing_t(x: float) -> float:
	return _wing_chord(x) * lerpf(0.16, 0.1, x / WING_SEMI)
func _wing_y(x: float) -> float:
	return -0.15 + x * tan(deg_to_rad(4.0))

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
	_loft(_st, _wing_rings(side, [0.0, 2.0, 3.65, 5.5, 7.2, AIL_IN], 0.0, 1.0), _paint_surface)
	_loft(_st, _wing_rings(side, [AIL_IN, 10.5, AIL_OUT], 0.0, AIL_F), _paint_surface)
	_loft(_st, _wing_rings(side, [AIL_OUT, 12.6, 12.9, WING_SEMI], 0.0, 1.0), _paint_surface)

func _nacelle_centre(side: float, z: float) -> Vector3:
	return Vector3(side * NACELLE_X, _wing_y(NACELLE_X) - 0.12, z)

## Bristol Pegasus radial in a long nacelle that carries the main gear
func _build_nacelle(side: float) -> void:
	var prof : Array = [[-4.55, 0.60], [-4.40, 0.74], [-3.50, 0.76], [-2.70, 0.70], [-1.0, 0.62],
		[1.5, 0.48], [3.4, 0.16]]
	var rings : Array = []
	for pr in prof:
		var c := _nacelle_centre(side, pr[0])
		var ring := _octagon([c.z, pr[1], pr[1] * 1.04, c.y])
		for i in range(ring.size()):
			ring[i] = ring[i] + Vector3(c.x, 0, 0)
		rings.append(ring)
	var paint := func(p: Vector3, n: Vector3) -> Color:
		if p.z < -4.45:
			return BLACK                                # open cowling front
		if p.z < -3.4:
			return METAL.darkened(0.25) if n.y > -0.2 else NIGHT   # Townend ring
		return _paint_fuselage(p, n)
	_loft(_st, rings, paint, true, true)
	# Nine cylinder heads showing through the cowling
	var fc := _nacelle_centre(side, -4.5)
	for i in range(9):
		var a := TAU * i / 9.0
		var d := Vector3(cos(a), sin(a), 0.0)
		_strut(_st, fc + d * 0.28, fc + d * 0.55 + Vector3(0, 0, -0.02), 0.2, 0.16, METAL)
	# Exhaust collector ring outlet under the nacelle
	var ex := _nacelle_centre(side, -3.2) + Vector3(0, -0.72, 0)
	_cylinder(_st, ex, Vector3.BACK, 0.09, 0.09, 1.2, 6, Color(0.22, 0.16, 0.12), BLACK)

func _tail_chord(x: float) -> float:
	return maxf(2.4 * sqrt(maxf(0.0, 1.0 - pow(x / 4.7, 2.0))), 0.4)

func _tail_pt(side: float, x: float, f: float, k: float) -> Vector3:
	var c := _tail_chord(x)
	return Vector3(side * x, TAIL_Y + k * c * 0.09, 6.4 - 0.2 * c + f * c)

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
	_loft(_st, _tail_rings(side, [0.0, 1.4, 2.8, 3.8, 4.5], 0.0, ELEV_F), _paint_surface)

func _fin_chord(h: float) -> float:
	return maxf(3.0 * sqrt(maxf(0.0, 1.0 - pow(h / 3.35, 2.0))), 0.4)

func _fin_pt(h: float, f: float, k: float) -> Vector3:
	var c := _fin_chord(h)
	return Vector3(k * c * 0.09, 0.62 + h, 6.5 - 0.35 * c + f * c)

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
	_loft(_st, _fin_rings([0.0, 1.0, 2.0, 2.7, 3.15], 0.0, RUDDER_F),
		func(p: Vector3, _n: Vector3) -> Color: return _camo(p))

func _build_control_surfaces(mat: Material) -> void:
	for side in [1.0, -1.0]:
		var st := _begin()
		_loft(st, _wing_rings(side, [AIL_IN, 10.5, AIL_OUT], AIL_F, 1.0), _paint_surface)
		_hinged("aileron_r" if side > 0.0 else "aileron_l",
			_wing_pt(side, AIL_IN, AIL_F, 0.0), _wing_pt(side, AIL_OUT, AIL_F, 0.0), st, mat)

	var st_e := _begin()
	for side in [1.0, -1.0]:
		_loft(st_e, _tail_rings(side, [0.0, 1.4, 2.8, 3.8, 4.5], ELEV_F, 1.0), _paint_surface)
	var hinge := _tail_pt(1.0, 0.0, ELEV_F, 0.0)
	_hinged("elevator", Vector3(-1.0, hinge.y, hinge.z), Vector3(1.0, hinge.y, hinge.z), st_e, mat)

	var st_r := _begin()
	_loft(st_r, _fin_rings([0.0, 1.0, 2.0, 2.7, 3.15], RUDDER_F, 1.0),
		func(p: Vector3, _n: Vector3) -> Color: return _camo(p))
	_hinged("rudder", _fin_pt(0.0, RUDDER_F, 0.0), _fin_pt(3.15, RUDDER_F, 0.0), st_r, mat)

# ---------------------------------------------------------------------------
# Details
# ---------------------------------------------------------------------------

func _build_details() -> void:
	# Beam gun hatches with a Vickers K gun poking out of each side
	for side in [1.0, -1.0]:
		var cz := 2.6
		var cy := 0.35
		var proj := func(u: float, v: float) -> Vector3:
			var z := cz + u
			var y := cy + v
			return Vector3(side * (_fuselage_x(z, y) + 0.02), y, z)
		_rect_marking(Rect2(-0.45, -0.3, 0.9, 0.6), FRAME, proj, Vector3(0, cy, cz), 3)
		var gp := Vector3(side * (_fuselage_x(cz, cy) + 0.02), cy, cz)
		_cylinder(_st, gp, Vector3(side, 0, -0.25), 0.035, 0.035, 0.6, 6, BLACK)
	# Small side windows along the fuselage
	for side in [1.0, -1.0]:
		for i in range(4):
			var cz := -3.6 + i * 1.1
			var cy := 0.55
			var proj := func(u: float, v: float) -> Vector3:
				var z := cz + u
				var y := cy + v
				return Vector3(side * (_fuselage_x(z, y) + 0.02), y, z)
			_rect_marking(Rect2(-0.18, -0.12, 0.36, 0.24), Color(0.25, 0.30, 0.34), proj, Vector3(0, cy, cz), 1)
	# Astrodome, aerial mast and the trailing aerial
	_cylinder(_st, Vector3(0, _top_y(-1.0) - 0.02, -1.0), Vector3.UP, 0.25, 0.14, 0.2, 8,
		Color(0.40, 0.48, 0.55))
	_strut(_st, Vector3(0, _top_y(-3.6) + 0.25, -3.6), Vector3(0, _top_y(-3.6) + 0.85, -3.4), 0.05, 0.1, NIGHT)

# ---------------------------------------------------------------------------
# Markings
# ---------------------------------------------------------------------------

func _build_markings() -> void:
	# Type B roundels on the upper wings
	for side in [1.0, -1.0]:
		var cx := 8.4
		var cz := _wing_le(cx) + 0.45 * _wing_chord(cx)
		var proj := func(u: float, v: float) -> Vector3:
			var x := cx + u
			var f := clampf((cz + v - _wing_le(x)) / _wing_chord(x), 0.0, 1.0)
			return Vector3(side * x, _wing_y(x) + _af(_AF_U, f) * _wing_t(x) + 0.05, cz + v)
		_roundel([[1.35, RAF_BLUE], [0.54, RAF_RED]], proj, Vector3(side * cx, _wing_y(cx) - 1.0, cz))
	# Type A1 roundels on the fuselage sides, aft of the wing
	for side in [1.0, -1.0]:
		var cz := 4.4
		var cy := 0.25
		var proj := func(u: float, v: float) -> Vector3:
			var z := cz + u
			var y := cy + v
			return Vector3(side * (_fuselage_x(z, y) + 0.03), y, z)
		_roundel([[0.75, RAF_YELLOW], [0.66, RAF_BLUE], [0.44, WHITE], [0.21, RAF_RED]], proj, Vector3(0, cy, cz))
	# Fin flash
	for side in [1.0, -1.0]:
		var stripes := [RAF_RED, WHITE, RAF_BLUE]
		for i in range(3):
			var f0 := 0.08 + i * 0.11
			var f1 := f0 + 0.11
			var corners : Array = []
			for hf in [[0.15, f0], [0.15, f1], [1.9, f1], [1.9, f0]]:
				var h : float = hf[0]; var f : float = hf[1]
				var k := _af(_AF_U, f) + 0.15 if side > 0.0 else _af(_AF_L, f) - 0.15
				corners.append(_fin_pt(h, f, k))
			var inside := Vector3(0, 1.6, 7.0)
			_tri(_st, corners[0], corners[1], corners[2], stripes[i], inside)
			_tri(_st, corners[0], corners[2], corners[3], stripes[i], inside)
