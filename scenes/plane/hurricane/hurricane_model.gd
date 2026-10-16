extends "res://scenes/plane/lowpoly_aircraft.gd"
## Low-poly Hawker Hurricane Mk I, summer 1940.
##
## Deep, hump-backed fuselage with the cockpit set well aft, a thick
## straight-tapered wing with rounded tips, the big belly radiator, wide-track
## undercarriage folding inwards and a three-blade Rotol propeller.
## Paint: Dark Earth / Dark Green over the early-war black (port) and white
## (starboard) undersides, Type B / A1 roundels and fin flash.
##
## Model space: nose toward -Z, up +Y, right wing +X, metres.  The wheels are
## built at the contact points listed for the Hurricane in aircraft_types.gd.

const DARK_EARTH := Color(0.46, 0.37, 0.24)
const DARK_GREEN := Color(0.25, 0.31, 0.18)
const SKY        := Color(0.72, 0.77, 0.62)
const NIGHT      := Color(0.08, 0.08, 0.09)
const WHITE      := Color(0.93, 0.93, 0.90)
const RAF_BLUE   := Color(0.14, 0.22, 0.45)
const RAF_RED    := Color(0.66, 0.13, 0.12)
const RAF_YELLOW := Color(0.88, 0.72, 0.16)
const BLACK      := Color(0.09, 0.09, 0.09)
const METAL      := Color(0.45, 0.46, 0.47)
const EXHAUST    := Color(0.26, 0.18, 0.13)

const WING_SEMI := 6.1
const WING_ROOT := 2.55
const WING_TIP  := 1.3
const TAPER_END := 5.55
const AIL_IN    := 3.8
const AIL_OUT   := 5.5
const AIL_F     := 0.76
const ELEV_F    := 0.6
const RUDDER_F  := 0.48

## Wheel contact points (match aircraft_types.gd)
const MAIN_WHEEL := Vector3(1.2, -1.62, -0.75)
const TAIL_WHEEL := Vector3(0.0, -1.0, 5.15)

# Fuselage cross-sections: [z, half-width, half-height, centre-y]
const FUSELAGE : Array = [
	[-3.85, 0.42, 0.45, 0.02],
	[-3.20, 0.50, 0.60, 0.02],
	[-2.20, 0.55, 0.70, 0.04],
	[-1.20, 0.58, 0.80, 0.08],
	[-0.30, 0.58, 0.88, 0.12],
	[ 0.80, 0.55, 0.86, 0.18],
	[ 2.00, 0.46, 0.74, 0.20],
	[ 3.30, 0.34, 0.58, 0.24],
	[ 4.50, 0.22, 0.42, 0.30],
	[ 5.40, 0.10, 0.30, 0.36],
]

func _ready() -> void:
	fuselage = FUSELAGE
	var mat := _vc_material()

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
	_build_prop(mat, Vector3(0, 0.02, -3.92), 1.7, 3, 0.43, 0.6,
		func(_a: float) -> Color: return NIGHT,
		func(r: float) -> Color: return RAF_YELLOW if r > 1.56 else BLACK)
	_build_gear(mat)
	_finish_build()

# ---------------------------------------------------------------------------
# Paint
# ---------------------------------------------------------------------------

static func _camo(p: Vector3) -> Color:
	var v := sin(p.x * 0.95 + p.z * 0.7 + p.y * 1.2) + 0.75 * sin(p.z * 1.3 - p.x * 0.6 + 2.1 + p.y * 0.7)
	return DARK_GREEN if v > 0.0 else DARK_EARTH

## Undersides: port wing black, starboard white, fuselage underside sky
static func _paint_surface(p: Vector3, n: Vector3) -> Color:
	if n.y < -0.2:
		return NIGHT if p.x < 0.0 else WHITE
	return _camo(p)

static func _paint_fuselage(p: Vector3, n: Vector3) -> Color:
	if p.z > 3.35 and p.z < 3.8:
		return SKY                                   # Sky fuselage band
	if p.z < -3.6:
		return BLACK
	return SKY if n.y < -0.45 else _camo(p)

# ---------------------------------------------------------------------------
# Fuselage
# ---------------------------------------------------------------------------

func _build_fuselage() -> void:
	var rings : Array = []
	for s in FUSELAGE:
		rings.append(_octagon(s))
	_loft(_st, rings, _paint_fuselage, true, false)
	var tip := Vector3(0.0, 0.38, 5.7)
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
	var f := (x - TAPER_END) / (WING_SEMI - TAPER_END)
	return lerpf(WING_TIP, 0.45, f * f)
func _wing_le(x: float) -> float:
	var le := -1.05 + x * 0.025
	if x > TAPER_END:
		var f := (x - TAPER_END) / (WING_SEMI - TAPER_END)
		le += f * f * 0.35
	return le
func _wing_t(x: float) -> float:
	return _wing_chord(x) * lerpf(0.19, 0.10, x / WING_SEMI)
func _wing_y(x: float) -> float:
	return -0.5 + maxf(x - 1.0, 0.0) * tan(deg_to_rad(3.5))

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
	_loft(_st, _wing_rings(side, [0.0, 1.0, 2.0, 3.0, AIL_IN], 0.0, 1.0), _paint_surface)
	_loft(_st, _wing_rings(side, [AIL_IN, 4.6, AIL_OUT], 0.0, AIL_F), _paint_surface)
	_loft(_st, _wing_rings(side, [AIL_OUT, 5.8, 5.98, WING_SEMI], 0.0, 1.0), _paint_surface)

func _tail_chord(x: float) -> float:
	return maxf(1.35 * sqrt(maxf(0.0, 1.0 - pow(x / 2.2, 2.0))), 0.3)

func _tail_pt(side: float, x: float, f: float, k: float) -> Vector3:
	var c := _tail_chord(x)
	return Vector3(side * x, 0.3 + k * c * 0.09, 4.55 - 0.2 * c + f * c)

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
	_loft(_st, _tail_rings(side, [0.0, 0.7, 1.4, 1.9, 2.15], 0.0, ELEV_F), _paint_surface)

func _fin_chord(h: float) -> float:
	return maxf(1.45 * sqrt(maxf(0.0, 1.0 - pow(h / 1.65, 2.0))), 0.25)

func _fin_pt(h: float, f: float, k: float) -> Vector3:
	var c := _fin_chord(h)
	return Vector3(k * c * 0.09, 0.45 + h, 4.75 - 0.4 * c + f * c)

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
	_loft(_st, _fin_rings([0.0, 0.4, 0.8, 1.15, 1.4, 1.58], 0.0, RUDDER_F),
		func(p: Vector3, _n: Vector3) -> Color: return _camo(p))

func _build_control_surfaces(mat: Material) -> void:
	for side in [1.0, -1.0]:
		var st := _begin()
		_loft(st, _wing_rings(side, [AIL_IN, 4.6, AIL_OUT], AIL_F, 1.0), _paint_surface)
		_hinged("aileron_r" if side > 0.0 else "aileron_l",
			_wing_pt(side, AIL_IN, AIL_F, 0.0), _wing_pt(side, AIL_OUT, AIL_F, 0.0), st, mat)
	var st_e := _begin()
	for side in [1.0, -1.0]:
		_loft(st_e, _tail_rings(side, [0.0, 0.7, 1.4, 1.9, 2.15], ELEV_F, 1.0), _paint_surface)
	var hinge := _tail_pt(1.0, 0.0, ELEV_F, 0.0)
	_hinged("elevator", Vector3(-1.0, hinge.y, hinge.z), Vector3(1.0, hinge.y, hinge.z), st_e, mat)
	# Big rudder reaching down to the bottom of the tail
	var st_r := _begin()
	_loft(st_r, _fin_rings([-0.35, 0.0, 0.4, 0.8, 1.15, 1.4, 1.58], RUDDER_F, 1.0),
		func(p: Vector3, _n: Vector3) -> Color: return _camo(p))
	_hinged("rudder", _fin_pt(0.0, RUDDER_F, 0.0), _fin_pt(1.58, RUDDER_F, 0.0), st_r, mat)

# ---------------------------------------------------------------------------
# Canopy and details
# ---------------------------------------------------------------------------

func _build_canopy() -> void:
	var glass := _glass_material(Color(0.55, 0.68, 0.76, 0.55))
	var st := _begin()
	# [z, half-width, height] — set well back on the hump
	var secs : Array = [[-0.75, 0.25, 0.08], [-0.55, 0.32, 0.34], [0.15, 0.33, 0.38], [0.65, 0.28, 0.28], [1.05, 0.16, 0.04]]
	var rings : Array = []
	for s in secs:
		var z : float = s[0]; var w : float = s[1]; var h : float = s[2]
		var y0 := _top_y(z) - 0.03
		var ring := PackedVector3Array()
		for p in [Vector2(-w, 0), Vector2(-w * 0.85, h * 0.6), Vector2(-w * 0.35, h), Vector2(w * 0.35, h),
				Vector2(w * 0.85, h * 0.6), Vector2(w, 0)]:
			ring.append(Vector3(p.x, y0 + p.y, z))
		rings.append(ring)
	_loft(st, rings, func(_p: Vector3, _n: Vector3) -> Color: return Color.WHITE)
	_add_mesh(self, st, glass, "Canopy")
	var sf := _begin()
	_cylinder(sf, Vector3(0, _top_y(0.0) + 0.02, 0.0), Vector3.UP, 0.13, 0.11, 0.26, 6, Color(0.35, 0.24, 0.15))
	for s in secs.slice(1, 4):
		var z : float = s[0]; var w : float = s[1]; var h : float = s[2]
		var y0 := _top_y(z) - 0.02
		_strut(sf, Vector3(-w, y0, z), Vector3(-w * 0.35, y0 + h + 0.01, z), 0.045, 0.045, BLACK)
		_strut(sf, Vector3(-w * 0.35, y0 + h + 0.01, z), Vector3(w * 0.35, y0 + h + 0.01, z), 0.045, 0.045, BLACK)
		_strut(sf, Vector3(w * 0.35, y0 + h + 0.01, z), Vector3(w, y0, z), 0.045, 0.045, BLACK)
	_add_mesh(self, sf, _vc_material(), "Pilot")

func _build_details() -> void:
	# Merlin exhaust stacks
	for side in [1.0, -1.0]:
		for i in range(6):
			var z := -3.2 + i * 0.22
			var s := _section(z)
			var p := Vector3(side * (s[1] + 0.02), s[3] + 0.15, z)
			_strut(_st, p, p + Vector3(side * 0.06, -0.02, 0.1), 0.07, 0.07, EXHAUST)
	# The big belly radiator under the centre section
	var s8 := _section(0.8)
	var yb : float = s8[3] - s8[2] * 0.92
	var rad : Array = []
	for row in [[-0.2, 0.22, 0.05], [0.25, 0.34, 0.36], [1.3, 0.34, 0.40], [1.9, 0.25, 0.08]]:
		var z : float = row[0]; var w : float = row[1]; var d : float = row[2]
		rad.append(PackedVector3Array([Vector3(-w, yb + 0.05, z), Vector3(w, yb + 0.05, z),
			Vector3(w, yb - d, z), Vector3(-w, yb - d, z)]))
	_loft(_st, rad, func(_p: Vector3, n: Vector3) -> Color: return BLACK if absf(n.z) > 0.6 else SKY)
	# Aerial mast, and the eight gun ports grouped on each wing
	_strut(_st, Vector3(0, _top_y(1.4) - 0.02, 1.4), Vector3(0, _top_y(1.4) + 0.45, 1.55), 0.04, 0.09, BLACK)
	for side in [1.0, -1.0]:
		for x in [2.4, 2.65, 2.9, 3.15]:
			_strut(_st, _wing_pt(side, x, 0.0, -0.05) + Vector3(0, 0, 0.02),
				_wing_pt(side, x, 0.0, -0.05) + Vector3(0, 0, -0.05), 0.05, 0.05, BLACK)

func _build_markings() -> void:
	# Type B roundels on the upper wings
	for side in [1.0, -1.0]:
		var cx := 4.2
		var cz := _wing_le(cx) + 0.45 * _wing_chord(cx)
		var proj := func(u: float, v: float) -> Vector3:
			var x := cx + u
			var f := clampf((cz + v - _wing_le(x)) / _wing_chord(x), 0.0, 1.0)
			return Vector3(side * x, _wing_y(x) + _af(_AF_U, f) * _wing_t(x) + 0.035, cz + v)
		_roundel([[0.8, RAF_BLUE], [0.32, RAF_RED]], proj, Vector3(side * cx, _wing_y(cx) - 0.5, cz))
	# Type A1 roundels on the fuselage sides
	for side in [1.0, -1.0]:
		var cz := 2.65
		var cy := 0.2
		var proj := func(u: float, v: float) -> Vector3:
			var z := cz + u
			var y := cy + v
			return Vector3(side * (_fuselage_x(z, y) + 0.03), y, z)
		_roundel([[0.5, RAF_YELLOW], [0.44, RAF_BLUE], [0.29, WHITE], [0.14, RAF_RED]], proj, Vector3(0, cy, cz))
	# Fin flash
	for side in [1.0, -1.0]:
		var stripes := [RAF_RED, WHITE, RAF_BLUE]
		for i in range(3):
			var f0 := 0.06 + i * 0.13
			var f1 := f0 + 0.13
			var corners : Array = []
			for hf in [[0.1, f0], [0.1, f1], [0.9, f1], [0.9, f0]]:
				var h : float = hf[0]; var f : float = hf[1]
				var k := _af(_AF_U, f) + 0.12 if side > 0.0 else _af(_AF_L, f) - 0.12
				corners.append(_fin_pt(h, f, k))
			var inside := Vector3(0, 0.95, 4.6)
			_tri(_st, corners[0], corners[1], corners[2], stripes[i], inside)
			_tri(_st, corners[0], corners[2], corners[3], stripes[i], inside)

# ---------------------------------------------------------------------------
# Undercarriage: wide track, folding inwards into the centre section
# ---------------------------------------------------------------------------

func _build_gear(mat: Material) -> void:
	for side in [1.0, -1.0]:
		var top := Vector3(side * 1.25, _wing_y(1.25) - 0.15, -0.55)
		var wheel := Vector3(side * MAIN_WHEEL.x, MAIN_WHEEL.y + 0.36, MAIN_WHEEL.z)
		var st := _begin()
		_strut(st, top, wheel + Vector3(0, 0.05, 0), 0.11, 0.11, METAL)
		var along := (wheel - top).normalized()
		var door_n : Vector3 = along.cross(Vector3.BACK).normalized() * side
		_strut(st, top + door_n * 0.09 + along * 0.1, wheel + door_n * 0.09 - along * 0.3, 0.42, 0.03, NIGHT if side < 0.0 else WHITE)
		_cylinder(st, wheel - Vector3(side * 0.08, 0, 0), Vector3(side, 0, 0), 0.36, 0.36, 0.16, 10, BLACK, METAL)
		var pivot := Node3D.new()
		pivot.name = "MainGear_%s" % ("R" if side > 0.0 else "L")
		pivot.position = top
		add_child(pivot)
		var mi := _add_mesh(pivot, st, mat, "Leg")
		mi.position = -top
		_gear_pivots.append([pivot, pivot.transform, -side * deg_to_rad(86.0), Vector3.BACK])
	# Fixed tail wheel (the Hurricane's did not retract)
	var st_t := _begin()
	var t_top := Vector3(0, 0.0, 4.95)
	var t_wheel := TAIL_WHEEL + Vector3(0, 0.14, 0)
	_strut(st_t, t_top, t_wheel + Vector3(0, 0.08, 0), 0.08, 0.08, METAL)
	_cylinder(st_t, t_wheel - Vector3(0.04, 0, 0), Vector3.RIGHT, 0.14, 0.14, 0.08, 8, BLACK, METAL)
	_add_mesh(self, st_t, mat, "TailWheel")
