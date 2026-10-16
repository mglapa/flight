extends "res://scenes/plane/lowpoly_aircraft.gd"
## Low-poly Lockheed Martin F-22 Raptor — the anachronistic scenery scout.
##
## Faceted stealth airframe: chined fuselage with caret intakes, diamond
## wing (42° leading-edge sweep, forward-swept trailing edge), canted twin
## fins, all-moving tailplanes, two-dimensional nozzles with afterburner
## glow and a gold-tinted bubble canopy.  Low-visibility greys.
##
## Model space: nose toward -Z, up +Y, right wing +X, metres.  The wheels are
## built at the contact points listed for the F-22 in aircraft_types.gd.

const GREY_D := Color(0.40, 0.43, 0.46)      # FS 36170
const GREY_L := Color(0.50, 0.53, 0.56)      # FS 36176
const GREY_EDGE := Color(0.33, 0.35, 0.38)
const INTAKE := Color(0.06, 0.06, 0.07)
const NOZZLE := Color(0.22, 0.22, 0.23)
const METAL := Color(0.55, 0.56, 0.58)
const BLACK := Color(0.08, 0.08, 0.08)

## Wheel contact points (match aircraft_types.gd)
const MAIN_WHEEL := Vector3(1.7, -2.25, 1.0)
const NOSE_WHEEL := Vector3(0.0, -2.25, -5.6)

# Fuselage sections: [z, chine half-width, top height, bottom depth, centre y]
const SECTIONS : Array = [
	[-9.40, 0.06, 0.05, 0.05, -0.10],
	[-8.20, 0.45, 0.32, 0.25, -0.05],
	[-6.60, 0.85, 0.55, 0.45, 0.00],
	[-5.20, 1.05, 0.80, 0.60, 0.05],
	[-3.60, 1.60, 0.75, 0.75, 0.00],
	[-1.50, 1.95, 0.70, 0.85, -0.05],
	[ 1.00, 1.95, 0.62, 0.85, -0.05],
	[ 3.50, 1.80, 0.55, 0.80, 0.00],
	[ 5.80, 1.55, 0.50, 0.70, 0.05],
	[ 7.60, 1.50, 0.45, 0.60, 0.05],
	[ 8.60, 1.45, 0.40, 0.55, 0.05],
]

const WING_Y := -0.3
const AIL_F := 0.72

var _burner : MeshInstance3D
var _burner_mat : StandardMaterial3D

func _ready() -> void:
	var mat := _vc_material(0.55)
	_st = _begin()
	_build_fuselage()
	for side in [1.0, -1.0]:
		_build_wing(side)
		_build_fin(side)
	_build_nozzles()
	_add_mesh(self, _st, mat, "Airframe")
	_build_canopy()
	_build_control_surfaces(mat)
	_build_burner()
	_build_gear(mat)
	_finish_build()

func _process(delta: float) -> void:
	super._process(delta)
	_ease_surface("rudder_l", _yaw, clampf(delta * 10.0, 0.0, 1.0))
	# Afterburner glow above 85 % throttle
	var a := smoothstep(0.85, 1.0, _throttle)
	_burner.visible = a > 0.01
	_burner_mat.albedo_color.a = a * 0.85
	_burner.scale = Vector3(1.0, 1.0, 0.7 + 0.3 * a + randf() * 0.08)

# ---------------------------------------------------------------------------
# Paint
# ---------------------------------------------------------------------------

## Two-tone low-visibility greys in soft-edged blotches
static func _paint(p: Vector3, n: Vector3) -> Color:
	var v := sin(p.x * 0.55 + p.z * 0.33) + sin(p.z * 0.47 - p.x * 0.4 + 1.7)
	var c := GREY_L if v > 0.3 else GREY_D
	if n.y < -0.3:
		c = c.lerp(GREY_L, 0.6)
	return c

static func _paint_body(p: Vector3, n: Vector3) -> Color:
	# Caret intakes: the forward-facing faces of the intake shoulders
	if p.z > -4.4 and p.z < -3.4 and absf(p.x) > 0.9 and n.z < -0.35:
		return INTAKE
	return _paint(p, n)

# ---------------------------------------------------------------------------
# Fuselage
# ---------------------------------------------------------------------------

## Chined cross-section (9 points): flat sides meeting at a sharp chine
static func _ring(s: Array) -> PackedVector3Array:
	var z : float = s[0]; var w : float = s[1]; var t : float = s[2]; var b : float = s[3]; var cy : float = s[4]
	var pts : Array = [Vector2(0.0, t), Vector2(0.55 * w, 0.75 * t), Vector2(w, 0.05 * t),
		Vector2(0.92 * w, -0.45 * b), Vector2(0.45 * w, -b), Vector2(-0.45 * w, -b),
		Vector2(-0.92 * w, -0.45 * b), Vector2(-w, 0.05 * t), Vector2(-0.55 * w, 0.75 * t)]
	var ring := PackedVector3Array()
	for q in pts:
		ring.append(Vector3(q.x, cy + q.y, z))
	return ring

func _top(z: float) -> float:
	for i in range(SECTIONS.size() - 1):
		var a : Array = SECTIONS[i]
		var b : Array = SECTIONS[i + 1]
		if z <= b[0]:
			var t := clampf((z - a[0]) / (b[0] - a[0]), 0.0, 1.0)
			return lerpf(a[4] + a[2], b[4] + b[2], t)
	return 0.45

func _build_fuselage() -> void:
	var rings : Array = []
	for s in SECTIONS:
		rings.append(_ring(s))
	_loft(_st, rings, _paint_body, true, true)

# ---------------------------------------------------------------------------
# Wings and tails
# ---------------------------------------------------------------------------

## Diamond wing: root at the chine, 42° leading edge, forward-swept trailing edge
func _wing_pt(side: float, x: float, f: float, k: float) -> Vector3:
	var x0 := 1.8
	var le := -2.8 + (x - x0) * tan(deg_to_rad(42.0))
	var te := 5.6 - (x - x0) * tan(deg_to_rad(17.0))
	var c := te - le
	var y := WING_Y - (x - x0) * tan(deg_to_rad(3.25)) + k * c * 0.05
	return Vector3(side * x, y, le + f * c)

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
	_loft(_st, _wing_rings(side, [1.8, 3.2, 4.5], 0.0, 1.0), _paint)
	_loft(_st, _wing_rings(side, [4.5, 5.6, 6.6], 0.0, AIL_F), _paint)
	_loft(_st, _wing_rings(side, [6.6, 6.78], 0.0, 1.0), _paint)

## Twin fins canted 28° outward
func _fin_pt(side: float, h: float, f: float, k: float) -> Vector3:
	var root_le := 4.8
	var root_c := 3.6
	var le := root_le + h * tan(deg_to_rad(28.0)) * 1.2
	var c := lerpf(root_c, 1.6, h / 2.7)
	var cant := deg_to_rad(28.0)
	var base := Vector3(side * 1.35, 0.35, 0.0)
	var out := Vector3(side * sin(cant), cos(cant), 0.0) * h
	var thick := Vector3(side * cos(cant), -sin(cant), 0.0) * k * c * 0.05
	return base + out + thick + Vector3(0, 0, le + f * c)

func _fin_rings(side: float, stations: Array, f0: float, f1: float) -> Array:
	var loop := _airfoil_loop(f0, f1)
	var rings : Array = []
	for h in stations:
		var ring := PackedVector3Array()
		for p in loop:
			ring.append(_fin_pt(side, h, p[0], p[1]))
		rings.append(ring)
	return rings

func _build_fin(side: float) -> void:
	_loft(_st, _fin_rings(side, [0.0, 1.3, 2.7], 0.0, 0.7), _paint)

## All-moving tailplanes
func _tail_pt(side: float, x: float, f: float, k: float) -> Vector3:
	var le := 6.4 + (x - 1.4) * 0.7
	var c := lerpf(3.0, 1.2, (x - 1.4) / 3.2)
	return Vector3(side * x, -0.15 + k * c * 0.04, le + f * c)

func _tail_rings(side: float, stations: Array) -> Array:
	var loop := _airfoil_loop(0.0, 1.0)
	var rings : Array = []
	for x in stations:
		var ring := PackedVector3Array()
		for p in loop:
			ring.append(_tail_pt(side, x, p[0], p[1]))
		rings.append(ring)
	return rings

func _build_control_surfaces(mat: Material) -> void:
	for side in [1.0, -1.0]:
		var st := _begin()
		_loft(st, _wing_rings(side, [4.5, 5.6, 6.6], AIL_F, 1.0), _paint)
		_hinged("aileron_r" if side > 0.0 else "aileron_l",
			_wing_pt(side, 4.5, AIL_F, 0.0), _wing_pt(side, 6.6, AIL_F, 0.0), st, mat)
	# Stabilators pivot about their mid chord
	var st_e := _begin()
	for side in [1.0, -1.0]:
		_loft(st_e, _tail_rings(side, [1.4, 3.0, 4.6]), _paint)
	var pz := 7.6
	_hinged("elevator", Vector3(-1.0, -0.15, pz), Vector3(1.0, -0.15, pz), st_e, mat)
	# A rudder on each canted fin, hinged along that fin
	for side in [1.0, -1.0]:
		var st_r := _begin()
		_loft(st_r, _fin_rings(side, [0.0, 1.3, 2.7], 0.7, 1.0), _paint)
		_hinged("rudder" if side > 0.0 else "rudder_l", _fin_pt(side, 0.0, 0.7, 0.0), _fin_pt(side, 2.7, 0.7, 0.0), st_r, mat)

# ---------------------------------------------------------------------------
# Canopy, nozzles, afterburner, gear
# ---------------------------------------------------------------------------

func _build_canopy() -> void:
	var glass := _glass_material(Color(0.62, 0.52, 0.30, 0.6))   # gold-tinted coating
	glass.metallic = 0.85
	var st := _begin()
	var secs : Array = [[-7.0, 0.2, 0.05], [-6.5, 0.48, 0.38], [-5.3, 0.55, 0.55], [-4.2, 0.45, 0.4], [-3.4, 0.2, 0.06]]
	var rings : Array = []
	for s in secs:
		var z : float = s[0]; var w : float = s[1]; var h : float = s[2]
		var y0 := _top(z) - 0.08
		var ring := PackedVector3Array()
		for q in [Vector2(-w, 0), Vector2(-w * 0.8, h * 0.65), Vector2(-w * 0.3, h), Vector2(w * 0.3, h),
				Vector2(w * 0.8, h * 0.65), Vector2(w, 0)]:
			ring.append(Vector3(q.x, y0 + q.y, z))
		rings.append(ring)
	_loft(st, rings, func(_p: Vector3, _n: Vector3) -> Color: return Color.WHITE)
	_add_mesh(self, st, glass, "Canopy")
	var sp := _begin()
	_cylinder(sp, Vector3(0, _top(-5.4) - 0.1, -5.4), Vector3.UP, 0.15, 0.13, 0.3, 6, Color(0.18, 0.2, 0.18))
	_add_mesh(self, sp, _vc_material(), "Pilot")

func _build_nozzles() -> void:
	for side in [1.0, -1.0]:
		var x : float = side * 0.62
		var rings : Array = []
		for row in [[8.3, 0.55, 0.42], [9.0, 0.5, 0.36], [9.35, 0.48, 0.3]]:
			var z : float = row[0]; var w : float = row[1] * 0.5; var h : float = row[2] * 0.5
			rings.append(PackedVector3Array([Vector3(x - w, -h, z), Vector3(x + w, -h, z),
				Vector3(x + w, h, z), Vector3(x - w, h, z)]))
		_loft(_st, rings, func(_p: Vector3, n: Vector3) -> Color: return BLACK if n.z > 0.6 else NOZZLE)

func _build_burner() -> void:
	_burner_mat = StandardMaterial3D.new()
	_burner_mat.albedo_color = Color(1.0, 0.62, 0.25, 0.0)
	_burner_mat.emission_enabled = true
	_burner_mat.emission = Color(1.0, 0.55, 0.2)
	_burner_mat.emission_energy_multiplier = 3.0
	_burner_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_burner_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var st := _begin()
	for side in [1.0, -1.0]:
		_cylinder(st, Vector3(side * 0.62, 0, 9.3), Vector3.BACK, 0.2, 0.0, 1.6, 8, Color.WHITE)
	_burner = MeshInstance3D.new()
	_burner.name = "Afterburner"
	_burner.mesh = st.commit()
	_burner.material_override = _burner_mat
	_burner.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_burner.visible = false
	add_child(_burner)

func _build_gear(mat: Material) -> void:
	var legs : Array = [
		[Vector3(1.4, -0.75, 0.6), Vector3(MAIN_WHEEL.x, MAIN_WHEEL.y + 0.42, MAIN_WHEEL.z), 0.42, Vector3.BACK, 1.0],
		[Vector3(-1.4, -0.75, 0.6), Vector3(-MAIN_WHEEL.x, MAIN_WHEEL.y + 0.42, MAIN_WHEEL.z), 0.42, Vector3.BACK, -1.0],
		[Vector3(0.0, -0.6, -5.8), NOSE_WHEEL + Vector3(0, 0.3, 0), 0.3, Vector3.RIGHT, 0.0],
	]
	for g in legs:
		var top : Vector3 = g[0]
		var wheel : Vector3 = g[1]
		var r : float = g[2]
		var st := _begin()
		_strut(st, top, wheel + Vector3(0, r * 0.5, 0), 0.14, 0.14, METAL)
		var axis := Vector3.RIGHT
		_cylinder(st, wheel - axis * 0.12, axis, r, r, 0.24, 10, BLACK, METAL)
		var pivot := Node3D.new()
		pivot.position = top
		add_child(pivot)
		var mi := _add_mesh(pivot, st, mat, "Gear")
		mi.position = -top
		var side : float = g[4]
		# Mains fold inwards, the nose leg folds forwards
		var angle := -side * deg_to_rad(80.0) if side != 0.0 else deg_to_rad(95.0)
		_gear_pivots.append([pivot, pivot.transform, angle, g[3]])
