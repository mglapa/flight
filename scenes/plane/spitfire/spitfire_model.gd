extends "res://scenes/plane/lowpoly_aircraft.gd"
## Low-poly Supermarine Spitfire Mk I in 1940 Battle of Britain markings.
##
## Built in code from lofted cross-sections: flat-shaded, vertex-coloured,
## one draw call for the airframe.  Moving parts (propeller, ailerons,
## elevators, rudder, undercarriage) are separate nodes.
##
## Model space: nose toward -Z, up +Y, right wing +X, metres.  The owner
## positions the model so the wheels match its gear contact points.
## Shared helpers live in lowpoly_aircraft.gd.

const DARK_EARTH := Color(0.46, 0.37, 0.24)
const DARK_GREEN := Color(0.25, 0.31, 0.18)
const SKY        := Color(0.72, 0.77, 0.62)
const RAF_BLUE   := Color(0.14, 0.22, 0.45)
const RAF_RED    := Color(0.66, 0.13, 0.12)
const RAF_YELLOW := Color(0.88, 0.72, 0.16)
const WHITE      := Color(0.93, 0.93, 0.90)
const BLACK      := Color(0.09, 0.09, 0.09)
const METAL      := Color(0.45, 0.46, 0.47)
const EXHAUST    := Color(0.26, 0.18, 0.13)

const WING_SEMI  := 5.62
const WING_ROOT  := 2.45
const AIL_IN     := 3.3
const AIL_OUT    := 5.0
const AIL_F      := 0.78
const ELEV_F     := 0.62
const RUDDER_F   := 0.5

# Fuselage cross-sections: [z, half-width, half-height, centre-y]
const FUSELAGE : Array = [
	[-3.85, 0.40, 0.42, 0.02],
	[-3.20, 0.47, 0.55, 0.05],
	[-2.30, 0.50, 0.62, 0.08],
	[-1.40, 0.52, 0.70, 0.04],
	[-0.50, 0.52, 0.74, 0.00],
	[ 0.60, 0.50, 0.72, 0.00],
	[ 1.80, 0.42, 0.62, 0.06],
	[ 3.00, 0.32, 0.50, 0.12],
	[ 4.00, 0.20, 0.38, 0.20],
	[ 4.70, 0.08, 0.26, 0.28],
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
	_build_prop(mat, Vector3(0, 0.02, -3.9), 1.65, 3, 0.41, 0.72,
		func(_a: float) -> Color: return SKY,
		func(r: float) -> Color: return RAF_YELLOW if r > 1.5 else BLACK)
	_build_gear(mat)
	_finish_build()

# ---------------------------------------------------------------------------
# Paint
# ---------------------------------------------------------------------------

## Temperate Land Scheme: disruptive Dark Earth / Dark Green
static func _camo(p: Vector3) -> Color:
	var v := sin(p.x * 1.05 + p.z * 0.62 + p.y * 1.3) + 0.75 * sin(p.z * 1.45 - p.x * 0.55 + 1.3 + p.y * 0.8)
	return DARK_GREEN if v > 0.05 else DARK_EARTH

static func _paint_surface(p: Vector3, n: Vector3) -> Color:
	return SKY if n.y < -0.2 else _camo(p)

static func _paint_fuselage(p: Vector3, n: Vector3) -> Color:
	if p.z > 2.95 and p.z < 3.4:
		return SKY                                  # Sky fuselage band
	if p.z < -3.6:
		return BLACK                                # nose ring behind the spinner
	return SKY if n.y < -0.45 else _camo(p)

# ---------------------------------------------------------------------------
# Fuselage
# ---------------------------------------------------------------------------

func _build_fuselage() -> void:
	var rings : Array = []
	for s in FUSELAGE:
		rings.append(_octagon(s))
	_loft(_st, rings, _paint_fuselage, true, false)
	# Tail cone tip
	var tip := Vector3(0.0, 0.30, 4.88)
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
	return maxf(WING_ROOT * sqrt(maxf(0.0, 1.0 - pow(x / WING_SEMI, 2.0))), 0.32)

func _wing_le(x: float) -> float:
	return -0.05 - 0.3 * _wing_chord(x)

func _wing_t(x: float) -> float:
	return _wing_chord(x) * lerpf(0.13, 0.07, x / WING_SEMI)

func _wing_y(x: float) -> float:
	return -0.42 + x * tan(deg_to_rad(6.0))          # 6° dihedral

## Point on the wing: span x (>= 0), chord fraction f, thickness multiple k
func _wing_pt(side: float, x: float, f: float, k: float) -> Vector3:
	var c := _wing_chord(x)
	return Vector3(side * x, _wing_y(x) + k * _wing_t(x), _wing_le(x) + f * c)

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
	_loft(_st, _wing_rings(side, [0.0, 0.6, 1.3, 2.1, 2.8, AIL_IN], 0.0, 1.0), _paint_surface)
	_loft(_st, _wing_rings(side, [AIL_IN, 3.9, 4.5, AIL_OUT], 0.0, AIL_F), _paint_surface)
	_loft(_st, _wing_rings(side, [AIL_OUT, 5.25, 5.45, 5.58], 0.0, 1.0), _paint_surface)

func _tail_chord(x: float) -> float:
	return maxf(1.15 * sqrt(maxf(0.0, 1.0 - pow(x / 1.72, 2.0))), 0.22)

func _tail_pt(side: float, x: float, f: float, k: float) -> Vector3:
	var c := _tail_chord(x)
	return Vector3(side * x, 0.22 + k * c * 0.09, 4.25 - 0.3 * c + f * c)

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
	_loft(_st, _tail_rings(side, [0.0, 0.5, 1.0, 1.4, 1.65], 0.0, ELEV_F), _paint_surface)

func _fin_chord(h: float) -> float:
	return maxf(1.3 * sqrt(maxf(0.0, 1.0 - pow(h / 1.56, 2.0))), 0.2)

func _fin_pt(h: float, f: float, k: float) -> Vector3:
	var c := _fin_chord(h)
	return Vector3(k * c * 0.09, 0.35 + h, 4.35 - 0.45 * c + f * c)

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
	_loft(_st, _fin_rings([0.0, 0.35, 0.7, 1.0, 1.25, 1.42, 1.52], 0.0, RUDDER_F),
		func(p: Vector3, _n: Vector3) -> Color: return _camo(p))

func _build_control_surfaces(mat: Material) -> void:
	for side in [1.0, -1.0]:
		var st := _begin()
		_loft(st, _wing_rings(side, [AIL_IN, 3.9, 4.5, AIL_OUT], AIL_F, 1.0), _paint_surface)
		_hinged("aileron_r" if side > 0.0 else "aileron_l",
			_wing_pt(side, AIL_IN, AIL_F, 0.0), _wing_pt(side, AIL_OUT, AIL_F, 0.0), st, mat)

	var st_e := _begin()
	for side in [1.0, -1.0]:
		_loft(st_e, _tail_rings(side, [0.0, 0.5, 1.0, 1.4, 1.65], ELEV_F, 1.0), _paint_surface)
	var hinge := _tail_pt(1.0, 0.0, ELEV_F, 0.0)
	_hinged("elevator", Vector3(-1.0, hinge.y, hinge.z), Vector3(1.0, hinge.y, hinge.z), st_e, mat)

	var st_r := _begin()
	_loft(st_r, _fin_rings([0.0, 0.35, 0.7, 1.0, 1.25, 1.42, 1.52], RUDDER_F, 1.0),
		func(p: Vector3, _n: Vector3) -> Color: return _camo(p))
	_hinged("rudder", _fin_pt(0.0, RUDDER_F, 0.0), _fin_pt(1.52, RUDDER_F, 0.0), st_r, mat)

# ---------------------------------------------------------------------------
# Details: canopy, exhausts, radiators, aerial
# ---------------------------------------------------------------------------

func _build_canopy() -> void:
	var glass := StandardMaterial3D.new()
	glass.albedo_color = Color(0.55, 0.68, 0.76, 0.55)
	glass.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	glass.metallic = 0.6
	glass.roughness = 0.08
	var st := _begin()
	# [z, half-width, height]
	var secs : Array = [[-1.10, 0.28, 0.12], [-0.85, 0.33, 0.36], [-0.10, 0.34, 0.40], [0.35, 0.30, 0.32], [0.75, 0.18, 0.06]]
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

	# Pilot's head and the canopy frame
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.vertex_color_is_srgb = true
	var sf := _begin()
	_cylinder(sf, Vector3(0, _top_y(-0.3) + 0.02, -0.3), Vector3.UP, 0.13, 0.11, 0.26, 6, Color(0.35, 0.24, 0.15))
	for s in secs.slice(1, 4):
		var z : float = s[0]; var w : float = s[1]; var h : float = s[2]
		var y0 := _top_y(z) - 0.02
		_strut(sf, Vector3(-w, y0, z), Vector3(-w * 0.35, y0 + h + 0.01, z), 0.04, 0.04, BLACK)
		_strut(sf, Vector3(-w * 0.35, y0 + h + 0.01, z), Vector3(w * 0.35, y0 + h + 0.01, z), 0.04, 0.04, BLACK)
		_strut(sf, Vector3(w * 0.35, y0 + h + 0.01, z), Vector3(w, y0, z), 0.04, 0.04, BLACK)
	_add_mesh(self, sf, mat, "Pilot")

func _build_details() -> void:
	# Merlin exhaust stacks: six per side
	for side in [1.0, -1.0]:
		for i in range(6):
			var z := -3.15 + i * 0.22
			var s := _section(z)
			var p := Vector3(side * (s[1] + 0.02), s[3] + 0.12, z)
			_strut(_st, p, p + Vector3(side * 0.06, -0.02, 0.1), 0.07, 0.07, EXHAUST)

	# Radiator under the starboard wing, oil cooler under the port wing
	var ry := _wing_y(1.55) - 0.4 * _wing_t(1.55)
	var rad_rings : Array = []
	for row in [[-0.55, 0.12, 0.10], [-0.25, 0.24, 0.30], [0.55, 0.24, 0.32], [0.95, 0.18, 0.12]]:
		var z : float = row[0]; var w : float = row[1]; var d : float = row[2]
		rad_rings.append(PackedVector3Array([Vector3(1.55 - w, ry, z), Vector3(1.55 + w, ry, z),
			Vector3(1.55 + w, ry - d, z), Vector3(1.55 - w, ry - d, z)]))
	_loft(_st, rad_rings, func(_p: Vector3, n: Vector3) -> Color:
		return Color(0.2, 0.21, 0.2) if absf(n.z) > 0.6 else SKY.darkened(0.12))
	_cylinder(_st, Vector3(-1.55, _wing_y(1.55) - 0.4 * _wing_t(1.55) - 0.1, -0.55), Vector3.BACK,
		0.12, 0.13, 0.9, 6, SKY.darkened(0.12), BLACK)

	# Aerial mast behind the cockpit
	_strut(_st, Vector3(0, _top_y(1.1) - 0.02, 1.1), Vector3(0, _top_y(1.1) + 0.42, 1.25), 0.04, 0.09, BLACK)
	# Gun ports on the wing leading edges
	for x in [3.0, 3.3, 3.6, 3.9]:
		for side in [1.0, -1.0]:
			_strut(_st, _wing_pt(side, x, 0.0, 0.0) + Vector3(0, 0, 0.02),
				_wing_pt(side, x, 0.0, 0.0) + Vector3(0, 0, -0.04), 0.05, 0.05, BLACK)

# ---------------------------------------------------------------------------
# Markings
# ---------------------------------------------------------------------------

func _build_markings() -> void:
	# Type B roundels on the upper wings
	for side in [1.0, -1.0]:
		var cx := 3.55
		var cz := _wing_le(cx) + 0.42 * _wing_chord(cx)
		var proj := func(u: float, v: float) -> Vector3:
			var x := cx + u
			var f := (cz + v - _wing_le(x)) / _wing_chord(x)
			return Vector3(side * x, _wing_y(x) + _af(_AF_U, clampf(f, 0.0, 1.0)) * _wing_t(x) + 0.035, cz + v)
		_roundel([[0.72, RAF_BLUE], [0.29, RAF_RED]], proj, Vector3(side * cx, _wing_y(cx) - 0.5, cz))

	# Type A1 roundels on the fuselage sides
	for side in [1.0, -1.0]:
		var cz := 2.2
		var cy := 0.08
		var proj := func(u: float, v: float) -> Vector3:
			var z := cz + u
			var y := cy + v
			return Vector3(side * (_fuselage_x(z, y) + 0.03), y, z)
		_roundel([[0.47, RAF_YELLOW], [0.41, RAF_BLUE], [0.27, WHITE], [0.13, RAF_RED]], proj, Vector3(0, cy, cz))

	# Fin flash: red, white, blue from the front
	for side in [1.0, -1.0]:
		var stripes := [RAF_RED, WHITE, RAF_BLUE]
		for i in range(3):
			var f0 := 0.08 + i * 0.13
			var f1 := f0 + 0.13
			var corners : Array = []
			for hf in [[0.08, f0], [0.08, f1], [0.78, f1], [0.78, f0]]:
				var h : float = hf[0]; var f : float = hf[1]
				var k := _af(_AF_U, f) + 0.12 if side > 0.0 else _af(_AF_L, f) - 0.12
				corners.append(_fin_pt(h, f, k))
			var inside := Vector3(0, 0.75, 4.2)
			_tri(_st, corners[0], corners[1], corners[2], stripes[i], inside)
			_tri(_st, corners[0], corners[2], corners[3], stripes[i], inside)

# ---------------------------------------------------------------------------
# Undercarriage
# ---------------------------------------------------------------------------

## Main wheels sit at model (±1.6, -1.17, -1.1) with 0.33 m tyres, so their
## contact points are (±1.6, -1.5, -1.1); the tail wheel touches at
## (0, -1.2, 4.7).  The owner offsets the model to match its gear constants.
func _build_gear(mat: Material) -> void:
	for side in [1.0, -1.0]:
		var top := Vector3(side * 0.95, _wing_y(0.95) - 0.12, -0.75)
		var wheel := Vector3(side * 1.6, -1.17, -1.1)
		var st := _begin()
		_strut(st, top, wheel + Vector3(-side * 0.1, 0.05, 0), 0.1, 0.1, METAL)
		# Gear door on the outside of the leg
		var along := (wheel - top).normalized()
		var door_n : Vector3 = along.cross(Vector3.BACK).normalized() * side
		_strut(st, top + door_n * 0.08 + along * 0.1, wheel + door_n * 0.08 - along * 0.32, 0.38, 0.03, SKY)
		_cylinder(st, wheel - Vector3(side * 0.07, 0, 0), Vector3(side, 0, 0), 0.33, 0.33, 0.14, 10, BLACK, METAL)
		var pivot := Node3D.new()
		pivot.name = "MainGear_%s" % ("R" if side > 0.0 else "L")
		pivot.position = top
		add_child(pivot)
		var mi := _add_mesh(pivot, st, mat, "Leg")
		mi.position = -top
		# Retracts outward into the wing
		_gear_pivots.append([pivot, pivot.transform, side * deg_to_rad(50.0), Vector3.BACK])

	var st_t := _begin()
	var t_top := Vector3(0, 0.05, 4.45)
	var t_wheel := Vector3(0, -1.07, 4.7)
	_strut(st_t, t_top, t_wheel + Vector3(0, 0.08, 0), 0.07, 0.07, METAL)
	_cylinder(st_t, t_wheel - Vector3(0.04, 0, 0), Vector3.RIGHT, 0.13, 0.13, 0.08, 8, BLACK, METAL)
	var tp := Node3D.new()
	tp.name = "TailWheel"
	tp.position = t_top
	add_child(tp)
	var tmi := _add_mesh(tp, st_t, mat, "Strut")
	tmi.position = -t_top
	_gear_pivots.append([tp, tp.transform, deg_to_rad(-80.0), Vector3.RIGHT])
