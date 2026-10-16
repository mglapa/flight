extends Node3D
## Shared machinery for the code-built low-poly aircraft models.
##
## Geometry helpers (flat-shaded triangles, lofts, struts, cylinders,
## airfoil sections, wrapped markings), hinged control surfaces, propeller
## spin, retractable undercarriage and cloud fading.  Subclasses build the
## airframe in _ready() and set `fuselage` to their cross-section table.
##
## Model space: nose toward -Z, up +Y, right wing +X, metres.
## Call set_controls() every physics frame to animate control surfaces.

const MAX_SURFACE_DEG := 22.0
const GEAR_TIME       := 2.5     # seconds to raise or lower the gear
const GEAR_AGL        := 120.0   # gear comes down below this height

# Airfoil: chord fraction → upper / lower surface, as multiples of thickness
const _AF_F : Array = [0.0, 0.08, 0.3, 0.65, 1.0]
const _AF_U : Array = [0.0, 0.55, 0.62, 0.38, 0.03]
const _AF_L : Array = [0.0, -0.32, -0.38, -0.20, -0.03]

## Start with the undercarriage already retracted (e.g. airborne spawns)
var start_gear_up := false

## Fuselage cross-sections: [z, half-width, half-height, centre-y], set by subclass
var fuselage : Array = []

var _st : SurfaceTool
var _props : Array = []       # spinning propeller nodes
var _disc_mats : Array = []   # their blur-disc materials
var _surfaces := {}            # name → [pivot, base transform, current deflection]
var _gear_pivots : Array = []  # [pivot, base transform, retract angle, axis]
var _gear_t := 1.0             # 1 = down, 0 = up
var _gear_target := 1.0
var _gear_clock := 0.0
var _materials : Array = []    # every material used, for cloud fading

var _pitch := 0.0
var _roll := 0.0
var _yaw := 0.0
var _throttle := 0.7

## Call at the end of a subclass _ready()
func _finish_build() -> void:
	if start_gear_up or _gear_pivots.is_empty():
		_gear_t = 0.0
		_gear_target = 0.0

## Fade the whole aircraft (e.g. while it is inside a cloud), 1 = opaque.
func set_cloud_alpha(alpha: float) -> void:
	for m in _materials:
		var mat := m as BaseMaterial3D
		if mat == null:
			continue
		var base_a : float = mat.get_meta("base_alpha", 1.0)
		var base_t : int = mat.get_meta("base_transparency", BaseMaterial3D.TRANSPARENCY_DISABLED)
		mat.albedo_color.a = base_a * alpha
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA if alpha < 0.99 else base_t

func _vc_material(roughness := 0.75) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.vertex_color_is_srgb = true
	mat.roughness = roughness
	return mat

func _glass_material(col: Color) -> StandardMaterial3D:
	var glass := StandardMaterial3D.new()
	glass.albedo_color = col
	glass.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	glass.metallic = 0.6
	glass.roughness = 0.08
	return glass


## Stick inputs in [-1, 1]: pitch +1 = nose up, roll +1 = roll right,
## yaw +1 = nose right.  Throttle in [0, 1].
func set_controls(pitch: float, roll: float, yaw: float, throttle: float) -> void:
	_pitch = clampf(pitch, -1.0, 1.0)
	_roll = clampf(roll, -1.0, 1.0)
	_yaw = clampf(yaw, -1.0, 1.0)
	_throttle = throttle

func _process(delta: float) -> void:
	# Propeller: spin plus a faint blur disc that thickens with power
	for i in range(_props.size()):
		(_props[i] as Node3D).rotate_object_local(Vector3.BACK, (18.0 + 30.0 * _throttle) * delta)
		(_disc_mats[i] as StandardMaterial3D).albedo_color.a = 0.04 + 0.06 * _throttle

	# Control surfaces ease toward the stick position
	var k := clampf(delta * 10.0, 0.0, 1.0)
	_ease_surface("aileron_r", -_roll, k)
	_ease_surface("aileron_l", -_roll, k)
	_ease_surface("elevator", -_pitch, k)
	_ease_surface("rudder", _yaw, k)

	_update_gear(delta)

func _ease_surface(name_: String, target: float, k: float) -> void:
	if not _surfaces.has(name_):
		return
	var s : Array = _surfaces[name_]
	s[2] = lerpf(s[2], target, k)
	var pivot : Node3D = s[0]
	var base : Transform3D = s[1]
	pivot.transform = base * Transform3D(Basis(Vector3.RIGHT, deg_to_rad(MAX_SURFACE_DEG) * s[2]), Vector3.ZERO)

func _update_gear(delta: float) -> void:
	_gear_clock -= delta
	if _gear_clock <= 0.0:
		_gear_clock = 0.25
		_gear_target = 1.0 if _near_ground() else 0.0
	_gear_t = move_toward(_gear_t, _gear_target, delta / GEAR_TIME)
	var ease_t := smoothstep(0.0, 1.0, _gear_t)
	for g in _gear_pivots:
		var pivot : Node3D = g[0]
		var base : Transform3D = g[1]
		pivot.visible = _gear_t > 0.02
		pivot.transform = base * Transform3D(Basis(g[3], g[2] * (1.0 - ease_t)), Vector3.ZERO)

func _near_ground() -> bool:
	var owner_ := get_parent() as Node3D
	if owner_ == null or not owner_.is_inside_tree():
		return true
	if owner_.get("on_ground") == true:
		return true
	var from := owner_.global_position
	var query := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * GEAR_AGL)
	query.collision_mask = 1      # terrain and water
	return not owner_.get_world_3d().direct_space_state.intersect_ray(query).is_empty()

# ---------------------------------------------------------------------------
# Geometry helpers
# ---------------------------------------------------------------------------

static func _begin() -> SurfaceTool:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	return st

func _add_mesh(parent: Node3D, st: SurfaceTool, mat: Material, name_: String) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = name_
	mi.mesh = st.commit()
	mi.material_override = mat
	parent.add_child(mi)
	if mat and not _materials.has(mat):
		mat.set_meta("base_alpha", (mat as BaseMaterial3D).albedo_color.a if mat is BaseMaterial3D else 1.0)
		mat.set_meta("base_transparency", (mat as BaseMaterial3D).transparency if mat is BaseMaterial3D else 0)
		_materials.append(mat)
	return mi

## Flat-shaded triangle facing away from `inside`
static func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, col: Color, inside: Vector3) -> void:
	var n := (b - a).cross(c - a)
	if n.length_squared() < 1e-12:
		return
	n = n.normalized()
	if n.dot((a + b + c) / 3.0 - inside) < 0.0:
		var t := b; b = c; c = t
		n = -n
	st.set_color(col)
	st.set_normal(n)
	st.add_vertex(a); st.add_vertex(c); st.add_vertex(b)

static func _face_normal(a: Vector3, b: Vector3, c: Vector3, inside: Vector3) -> Vector3:
	var n := (b - a).cross(c - a).normalized()
	return n if n.dot((a + b + c) / 3.0 - inside) >= 0.0 else -n

## Skins a list of equal-length rings (closed loops) with flat triangles.
## color_fn(centre, normal) -> Color.  Ends are capped with fans.
func _loft(st: SurfaceTool, rings: Array, color_fn: Callable, cap_start := true, cap_end := true) -> void:
	var n : int = rings[0].size()
	for r in range(rings.size() - 1):
		var a_ring : PackedVector3Array = rings[r]
		var b_ring : PackedVector3Array = rings[r + 1]
		var inside := (_centroid(a_ring) + _centroid(b_ring)) * 0.5
		for i in range(n):
			var j := (i + 1) % n
			var p0 := a_ring[i]; var p1 := a_ring[j]
			var q0 := b_ring[i]; var q1 := b_ring[j]
			var nrm := _face_normal(p0, p1, q1, inside)
			var col : Color = color_fn.call((p0 + p1 + q0 + q1) * 0.25, nrm)
			_tri(st, p0, p1, q1, col, inside)
			_tri(st, p0, q1, q0, col, inside)
	if cap_start:
		_cap(st, rings[0], rings[1], color_fn)
	if cap_end:
		_cap(st, rings[-1], rings[-2], color_fn)

func _cap(st: SurfaceTool, ring: PackedVector3Array, neighbour: PackedVector3Array, color_fn: Callable) -> void:
	var c := _centroid(ring)
	var inside := c + (_centroid(neighbour) - c) * 0.5
	for i in range(ring.size()):
		var a := ring[i]
		var b := ring[(i + 1) % ring.size()]
		var nrm := _face_normal(a, b, c, inside)
		_tri(st, a, b, c, color_fn.call((a + b + c) / 3.0, nrm), inside)

static func _centroid(ring: PackedVector3Array) -> Vector3:
	var s := Vector3.ZERO
	for p in ring:
		s += p
	return s / ring.size()

## Thin box between two points (struts, legs, masts)
static func _strut(st: SurfaceTool, a: Vector3, b: Vector3, w: float, d: float, col: Color) -> void:
	var axis := (b - a).normalized()
	var side := axis.cross(Vector3.FORWARD if absf(axis.z) < 0.9 else Vector3.UP).normalized()
	var up := side.cross(axis).normalized()
	var ring_a := PackedVector3Array()
	var ring_b := PackedVector3Array()
	for k in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]:
		var o : Vector3 = side * (k.x * w * 0.5) + up * (k.y * d * 0.5)
		ring_a.append(a + o)
		ring_b.append(b + o)
	var inside := (a + b) * 0.5
	for i in range(4):
		var j := (i + 1) % 4
		_tri(st, ring_a[i], ring_a[j], ring_b[j], col, inside)
		_tri(st, ring_a[i], ring_b[j], ring_b[i], col, inside)
	_tri(st, ring_a[0], ring_a[1], ring_a[2], col, inside); _tri(st, ring_a[0], ring_a[2], ring_a[3], col, inside)
	_tri(st, ring_b[0], ring_b[1], ring_b[2], col, inside); _tri(st, ring_b[0], ring_b[2], ring_b[3], col, inside)

## Cylinder along an axis (wheels, spinner, exhausts); r1 = 0 makes a cone
static func _cylinder(st: SurfaceTool, base: Vector3, axis: Vector3, r0: float, r1: float,
		length: float, sides: int, col: Color, cap_col := Color(-1, 0, 0)) -> void:
	axis = axis.normalized()
	var u := axis.cross(Vector3.UP if absf(axis.y) < 0.9 else Vector3.RIGHT).normalized()
	var v := axis.cross(u)
	var top := base + axis * length
	var mid := base + axis * length * 0.5
	var cc := col if cap_col.r < 0.0 else cap_col
	for i in range(sides):
		var a0 := TAU * i / sides
		var a1 := TAU * (i + 1) / sides
		var d0 := u * cos(a0) + v * sin(a0)
		var d1 := u * cos(a1) + v * sin(a1)
		if r1 > 0.0:
			_tri(st, base + d0 * r0, base + d1 * r0, top + d1 * r1, col, mid)
			_tri(st, base + d0 * r0, top + d1 * r1, top + d0 * r1, col, mid)
			_tri(st, top, top + d0 * r1, top + d1 * r1, cc, mid)
		else:
			_tri(st, base + d0 * r0, base + d1 * r0, top, col, base)
		_tri(st, base, base + d1 * r0, base + d0 * r0, cc, mid)

# ---------------------------------------------------------------------------
# Fuselage sections
# ---------------------------------------------------------------------------

func _section(z: float) -> Array:
	for i in range(fuselage.size() - 1):
		var a : Array = fuselage[i]
		var b : Array = fuselage[i + 1]
		if z <= b[0]:
			var t := clampf((z - a[0]) / (b[0] - a[0]), 0.0, 1.0)
			return [z, lerpf(a[1], b[1], t), lerpf(a[2], b[2], t), lerpf(a[3], b[3], t)]
	return fuselage[-1]

## Octagon with flat top, bottom and sides
static func _octagon(s: Array) -> PackedVector3Array:
	var ring := PackedVector3Array()
	for k in range(8):
		var a := deg_to_rad(22.5 + 45.0 * k)
		ring.append(Vector3(cos(a) * s[1], s[3] + sin(a) * s[2], s[0]))
	return ring

## Half-width of the fuselage skin at height y (for wrapping markings)
func _fuselage_x(z: float, y: float) -> float:
	var ring := _octagon(_section(z))
	# Right-hand edges: vertices at -67.5, -22.5, 22.5, 67.5 degrees
	var pts := [ring[6], ring[7], ring[0], ring[1]]
	for i in range(3):
		var a : Vector3 = pts[i]
		var b : Vector3 = pts[i + 1]
		if y >= a.y and y <= b.y:
			return lerpf(a.x, b.x, (y - a.y) / maxf(b.y - a.y, 0.0001))
	return pts[0].x if y < pts[0].y else pts[3].x

func _top_y(z: float) -> float:
	var s := _section(z)
	return s[3] + s[2] * sin(deg_to_rad(67.5))

# ---------------------------------------------------------------------------
# Airfoils and hinged surfaces
# ---------------------------------------------------------------------------

static func _af(table: Array, f: float) -> float:
	for i in range(_AF_F.size() - 1):
		if f <= _AF_F[i + 1]:
			var t : float = (f - _AF_F[i]) / (_AF_F[i + 1] - _AF_F[i])
			return lerpf(table[i], table[i + 1], t)
	return table[-1]

## Airfoil loop between chord fractions f0..f1 (upper surface, then lower)
static func _airfoil_loop(f0: float, f1: float) -> Array:
	var fs : Array = [f0]
	for f in _AF_F:
		if f > f0 + 0.01 and f < f1 - 0.01:
			fs.append(f)
	fs.append(f1)
	var loop : Array = []     # [f, thickness multiple]
	for f in fs:
		loop.append([f, _af(_AF_U, f)])
	for i in range(fs.size() - 1, -1, -1):
		var f : float = fs[i]
		if (f == 0.0 and i == 0):
			continue                     # leading edge point already in the loop
		loop.append([f, _af(_AF_L, f)])
	return loop

## Creates a pivot whose local +X is the hinge line from `a` to `b`;
## geometry built in model space is re-parented under it unchanged.
func _hinged(name_: String, a: Vector3, b: Vector3, st: SurfaceTool, mat: Material) -> void:
	var x := (b - a).normalized()
	var up := Vector3.UP if absf(x.y) < 0.9 else Vector3.BACK
	var z := x.cross(up).normalized()
	var y := z.cross(x).normalized()
	var base := Transform3D(Basis(x, y, z), (a + b) * 0.5)
	var pivot := Node3D.new()
	pivot.name = name_
	pivot.transform = base
	add_child(pivot)
	var mi := _add_mesh(pivot, st, mat, name_ + "Mesh")
	mi.transform = base.affine_inverse()
	_surfaces[name_] = [pivot, base, 0.0]

# ---------------------------------------------------------------------------
# Markings and propeller
# ---------------------------------------------------------------------------

## Concentric roundel. project(u, v) maps disc coordinates to a surface point.
func _roundel(rings: Array, project: Callable, inside: Vector3) -> void:
	var sides := 16
	for r in range(rings.size()):
		var ro : float = rings[r][0]
		var col : Color = rings[r][1]
		var ri : float = rings[r + 1][0] if r + 1 < rings.size() else 0.0
		for i in range(sides):
			var a0 := TAU * i / sides
			var a1 := TAU * (i + 1) / sides
			var o0 : Vector3 = project.call(cos(a0) * ro, sin(a0) * ro)
			var o1 : Vector3 = project.call(cos(a1) * ro, sin(a1) * ro)
			if ri > 0.0:
				var i0 : Vector3 = project.call(cos(a0) * ri, sin(a0) * ri)
				var i1 : Vector3 = project.call(cos(a1) * ri, sin(a1) * ri)
				_tri(_st, o0, o1, i1, col, inside)
				_tri(_st, o0, i1, i0, col, inside)
			else:
				_tri(_st, o0, o1, project.call(0.0, 0.0), col, inside)

## Rectangle marking in disc coordinates, subdivided so it hugs curved skin
func _rect_marking(rect: Rect2, col: Color, project: Callable, inside: Vector3, subdiv := 3,
		lift := 0.0) -> void:
	for j in range(subdiv):
		for i in range(subdiv):
			var u0 := rect.position.x + rect.size.x * i / subdiv
			var u1 := rect.position.x + rect.size.x * (i + 1) / subdiv
			var v0 := rect.position.y + rect.size.y * j / subdiv
			var v1 := rect.position.y + rect.size.y * (j + 1) / subdiv
			var a : Vector3 = project.call(u0, v0)
			var b : Vector3 = project.call(u1, v0)
			var c : Vector3 = project.call(u1, v1)
			var d : Vector3 = project.call(u0, v1)
			if lift != 0.0:      # layer above other markings, away from `inside`
				a += (a - inside).normalized() * lift
				b += (b - inside).normalized() * lift
				c += (c - inside).normalized() * lift
				d += (d - inside).normalized() * lift
			_tri(_st, a, b, c, col, inside)
			_tri(_st, a, c, d, col, inside)

## Spinner, blades and a faint blur disc.  blade_color(radius) picks colours.
func _build_prop(mat: Material, at: Vector3, radius: float, blades: int, spinner_r: float,
		spinner_len: float, spinner_color: Callable, blade_color: Callable) -> void:
	var prop := Node3D.new()
	prop.name = "Propeller"
	prop.position = at
	add_child(prop)
	_props.append(prop)
	var st := _begin()
	# Spinner as a cone with per-face colours (allows painted segments)
	var sides := 10
	var tip := Vector3(0, 0, -spinner_len)
	for i in range(sides):
		var a0 := TAU * i / sides
		var a1 := TAU * (i + 1) / sides
		var p0 := Vector3(cos(a0), sin(a0), 0) * spinner_r
		var p1 := Vector3(cos(a1), sin(a1), 0) * spinner_r
		var col : Color = spinner_color.call((a0 + a1) * 0.5)
		_tri(st, p0, p1, tip, col, Vector3(0, 0, -spinner_len * 0.3))
		_tri(st, p0, p1, Vector3.ZERO, col, Vector3(0, 0, -spinner_len * 0.3))
	for bl in range(blades):
		var ang := TAU * bl / blades
		var radial := Vector3(cos(ang), sin(ang), 0.0)
		var tangent := Vector3(-sin(ang), cos(ang), 0.0)
		var stations : Array = [[0.15, 0.20, 34.0], [0.55, 0.26, 24.0], [0.88, 0.19, 16.0], [1.0, 0.12, 13.0]]
		var rings : Array = []
		for s in stations:
			var r : float = s[0] * radius; var chord : float = s[1]; var pitch := deg_to_rad(s[2])
			var cdir := tangent * cos(pitch) + Vector3.BACK * sin(pitch)
			var tdir := cdir.cross(radial).normalized() * 0.025
			var c := radial * r + Vector3(0, 0, -0.1)
			rings.append(PackedVector3Array([c - cdir * chord * 0.5, c + cdir * chord * 0.5 + tdir,
				c + cdir * chord * 0.5 - tdir * 0.2, c - cdir * chord * 0.5 - tdir]))
		_loft(st, rings, func(p: Vector3, _n: Vector3) -> Color:
			return blade_color.call(Vector2(p.x, p.y).length()))
	_add_mesh(prop, st, mat, "Blades")

	var disc := CylinderMesh.new()
	disc.top_radius = radius
	disc.bottom_radius = radius
	disc.height = 0.01
	disc.radial_segments = 24
	disc.rings = 1
	var disc_mat := StandardMaterial3D.new()
	disc_mat.albedo_color = Color(0.55, 0.57, 0.6, 0.08)
	disc_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	disc_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	disc_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_disc_mats.append(disc_mat)
	var pd := MeshInstance3D.new()
	pd.name = "PropDisc"
	pd.mesh = disc
	pd.material_override = disc_mat
	pd.rotation_degrees = Vector3(90, 0, 0)
	pd.position = at + Vector3(0, 0, -0.1)
	pd.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(pd)
