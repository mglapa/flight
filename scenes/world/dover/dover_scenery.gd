extends Node3D
## Scenery for the Dover map: woods, towns, Dover harbour and castle, Chain
## Home radar masts, lighthouses, barrage balloons, a Channel convoy and the
## RAF airfield.  Repeated objects use MultiMesh, one per map tile.

var map : Node3D            # dover_map.gd — set before add_child

const TILE         := 4000.0
const TREE_STEP    := 26.0
const TREE_REGION  := Rect2(-30000, -40000, 60000, 62000)   # x, z, w, d
const TREE_RANGE   := 7000.0
const HOUSE_STEP   := 36.0
const HOUSE_RANGE  := 12000.0

var _vc_mat : StandardMaterial3D
var _convoy : Node3D
var _convoy_t := 0.0              # metres travelled along the convoy route
var _convoy_a := Vector2.ZERO     # route start / end (world x, z)
var _convoy_b := Vector2.ZERO
var _balloons : Array = []
var _clock := 0.0

func _ready() -> void:
	add_to_group("origin_container")
	_vc_mat = StandardMaterial3D.new()
	_vc_mat.vertex_color_use_as_albedo = true
	_vc_mat.vertex_color_is_srgb = true
	_vc_mat.roughness = 0.85

	_build_airfield()
	_build_harbour()
	_build_castle()
	_build_radar()
	_build_lighthouses()
	_build_balloons()
	_build_convoy()

func _process(delta: float) -> void:
	_clock += delta
	if is_instance_valid(_convoy):
		# ~10 knots down-Channel along the route, then round again
		var route := _convoy_b - _convoy_a
		_convoy_t = fmod(_convoy_t + 5.0 * delta, route.length())
		var w := _convoy_a + route.normalized() * _convoy_t
		_convoy.position = WorldOrigin.to_scene(Vector3(w.x, 0.8, w.y))
	for b in _balloons:
		var node : Node3D = b[0]
		var phase : float = b[1]
		node.rotation.y = b[2] + sin(_clock * 0.15 + phase) * 0.25
		node.position.y = b[3] + sin(_clock * 0.3 + phase) * 4.0

# ---------------------------------------------------------------------------
# Mesh helpers
# ---------------------------------------------------------------------------

## Quad a-b-c-d; faces away from `inside` (winding and normal fixed up).
static func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3,
		col: Color, inside: Vector3) -> void:
	var n := (b - a).cross(c - a).normalized()
	if n.dot((a + b + c + d) * 0.25 - inside) < 0.0:
		var t := b; b = d; d = t
		n = -n
	st.set_color(col)
	st.set_normal(n)
	# a-b-c-d is now counter-clockwise from the front; Godot fronts are clockwise
	st.add_vertex(a); st.add_vertex(c); st.add_vertex(b)
	st.add_vertex(a); st.add_vertex(d); st.add_vertex(c)

static func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, col: Color, inside: Vector3) -> void:
	var n := (b - a).cross(c - a).normalized()
	if n.dot((a + b + c) / 3.0 - inside) < 0.0:
		var t := b; b = c; c = t
		n = -n
	st.set_color(col)
	st.set_normal(n)
	st.add_vertex(a); st.add_vertex(c); st.add_vertex(b)

## Box (in the given basis) with its base centred on `base`.
static func _box(st: SurfaceTool, base: Vector3, size: Vector3, col: Color,
		basis := Basis.IDENTITY, bottom := false) -> void:
	var hx := size.x * 0.5
	var hz := size.z * 0.5
	var y1 := size.y
	var c000 := base + basis * Vector3(-hx, 0, -hz); var c100 := base + basis * Vector3(hx, 0, -hz)
	var c010 := base + basis * Vector3(-hx, y1, -hz); var c110 := base + basis * Vector3(hx, y1, -hz)
	var c001 := base + basis * Vector3(-hx, 0, hz); var c101 := base + basis * Vector3(hx, 0, hz)
	var c011 := base + basis * Vector3(-hx, y1, hz); var c111 := base + basis * Vector3(hx, y1, hz)
	var ctr := base + basis * Vector3(0, y1 * 0.5, 0)
	_quad(st, c001, c101, c111, c011, col, ctr)
	_quad(st, c100, c000, c010, c110, col, ctr)
	_quad(st, c101, c100, c110, c111, col, ctr)
	_quad(st, c000, c001, c011, c010, col, ctr)
	_quad(st, c011, c111, c110, c010, col, ctr)
	if bottom:
		_quad(st, c000, c100, c101, c001, col, ctr)

static func _cylinder(st: SurfaceTool, base: Vector3, r0: float, r1: float, height: float,
		sides: int, col: Color, cap := true) -> void:
	for i in range(sides):
		var a0 := TAU * i / sides
		var a1 := TAU * (i + 1) / sides
		var d0 := Vector3(cos(a0), 0, sin(a0))
		var d1 := Vector3(cos(a1), 0, sin(a1))
		var mid := base + Vector3.UP * height * 0.5
		if r1 <= 0.0:
			_tri(st, base + d0 * r0, base + d1 * r0, base + Vector3.UP * height, col, base)
			continue
		_quad(st, base + d0 * r0, base + d1 * r0, base + d1 * r1 + Vector3.UP * height,
			base + d0 * r1 + Vector3.UP * height, col, mid)
		if cap:
			_tri(st, base + Vector3.UP * height, base + d0 * r1 + Vector3.UP * height,
				base + d1 * r1 + Vector3.UP * height, col, mid)

func _commit(st: SurfaceTool, name_: String, pos := Vector3.ZERO, shadows := true) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = name_
	mi.mesh = st.commit()
	mi.material_override = _vc_mat
	mi.position = pos
	if not shadows:
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	return mi

func _ground(x: float, z: float) -> float:
	return map.surface_height(x, z)

# ---------------------------------------------------------------------------
# Tree and house meshes (instanced by tile_builder.gd)
# ---------------------------------------------------------------------------

static func _tree_mesh() -> Mesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var trunk := Color(0.36, 0.27, 0.18)
	_cylinder(st, Vector3.ZERO, 0.45, 0.35, 3.5, 5, trunk, false)
	# Rounded broadleaf crown: two stacked low-poly domes
	var leaf := Color(1, 1, 1)
	var sides := 6
	var rings : Array = [[2.6, 0.0], [4.4, 0.9], [4.6, 2.6], [3.6, 4.6], [1.6, 6.2], [0.0, 6.8]]
	for r in range(rings.size() - 1):
		var ra : float = rings[r][0]; var ya : float = 2.6 + rings[r][1]
		var rb : float = rings[r + 1][0]; var yb : float = 2.6 + rings[r + 1][1]
		for i in range(sides):
			var a0 := TAU * i / sides + r * 0.4
			var a1 := TAU * (i + 1) / sides + r * 0.4
			var p0 := Vector3(cos(a0) * ra, ya, sin(a0) * ra)
			var p1 := Vector3(cos(a1) * ra, ya, sin(a1) * ra)
			var q0 := Vector3(cos(a0) * rb, yb, sin(a0) * rb)
			var q1 := Vector3(cos(a1) * rb, yb, sin(a1) * rb)
			var shade := Color(leaf.r * (0.75 + 0.05 * r), leaf.g * (0.75 + 0.05 * r), leaf.b * (0.75 + 0.05 * r))
			_quad(st, p0, p1, q1, q0, shade, Vector3(0, 5.5, 0))
	# underside
	for i in range(sides):
		var a0 := TAU * i / sides
		var a1 := TAU * (i + 1) / sides
		_tri(st, Vector3(0, 2.6, 0), Vector3(cos(a1) * 2.6, 2.6, sin(a1) * 2.6),
			Vector3(cos(a0) * 2.6, 2.6, sin(a0) * 2.6), Color(0.6, 0.6, 0.6), Vector3(0, 5.0, 0))
	return st.commit()

static func _house_mesh() -> Mesh:
	# Unit house: 1 x 1 x 1 walls with a gabled roof, scaled per instance
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var wall := Color(0.93, 0.89, 0.80)
	var roof := Color(0.66, 0.34, 0.24)
	_box(st, Vector3.ZERO, Vector3(1, 1, 1), wall)
	var a := Vector3(-0.55, 1.0, -0.55); var b := Vector3(0.55, 1.0, -0.55)
	var c := Vector3(0.55, 1.0, 0.55);   var d := Vector3(-0.55, 1.0, 0.55)
	var r0 := Vector3(-0.55, 1.55, 0.0); var r1 := Vector3(0.55, 1.55, 0.0)
	var inside := Vector3(0, 0.9, 0)
	_quad(st, d, c, r1, r0, roof, inside)
	_quad(st, b, a, r0, r1, roof, inside)
	_tri(st, a, d, r0, wall, inside)
	_tri(st, c, b, r1, wall, inside)
	return st.commit()

# ---------------------------------------------------------------------------
# Landmarks
# ---------------------------------------------------------------------------

## Ground point at a real latitude / longitude (world coordinates)
func _ll(lat: float, lon: float) -> Vector3:
	var p : Vector2 = map.geo.latlon_to_game(lat, lon)
	return Vector3(p.x, _ground(p.x, p.y), p.y)

## Sea-level point at a real latitude / longitude
func _ll_sea(lat: float, lon: float) -> Vector3:
	var p : Vector2 = map.geo.latlon_to_game(lat, lon)
	return Vector3(p.x, 0.0, p.y)

func _build_airfield() -> void:
	# RAF fighter station: grass field with a tarmac strip, hangars and a watch office
	var ap : Vector2 = map.geo.airfield_pos
	var y : float = map.geo.airfield_h
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_box(st, Vector3(0, -0.2, 0), Vector3(30, 0.3, 900), Color(0.32, 0.32, 0.34))
	for i in range(12):
		_box(st, Vector3(0, 0.0, -400 + i * 72), Vector3(1.0, 0.16, 24), Color(0.92, 0.92, 0.9))
	var hangar := Color(0.40, 0.42, 0.36)
	for i in range(3):
		var hp := Vector3(160, 0, -220 + i * 110)
		_box(st, hp, Vector3(45, 12, 60), hangar)
		# curved roof approximated with a low gable
		_box(st, hp + Vector3(0, 12, 0), Vector3(36, 3, 60), hangar.darkened(0.1))
	_box(st, Vector3(120, 0, 120), Vector3(14, 8, 10), Color(0.88, 0.86, 0.80))       # watch office
	_box(st, Vector3(120, 8, 120), Vector3(6, 3, 6), Color(0.3, 0.3, 0.3))
	for i in range(6):                                                                  # blast pens
		var pp := Vector3(-140, 0, -300 + i * 120)
		_box(st, pp + Vector3(0, 0, -14), Vector3(30, 3, 4), Color(0.30, 0.42, 0.20))
		_box(st, pp + Vector3(-14, 0, 0), Vector3(4, 3, 30), Color(0.30, 0.42, 0.20))
		_box(st, pp + Vector3(0, 0, 14), Vector3(30, 3, 4), Color(0.30, 0.42, 0.20))
	_commit(st, "Airfield", Vector3(ap.x, y, ap.y))

func _build_harbour() -> void:
	# Dover: Admiralty Pier, Southern Breakwater and Eastern Arm
	var stone := Color(0.62, 0.61, 0.58)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var pier_root := _ll_sea(51.1132, 1.3050)
	var pier_head := _ll_sea(51.1048, 1.3160)
	var bw_west := _ll_sea(51.1052, 1.3195)
	var bw_east := _ll_sea(51.1088, 1.3400)
	var arm_root := _ll_sea(51.1225, 1.3352)
	var arm_head := _ll_sea(51.1112, 1.3440)
	_wall(st, pier_root, pier_head, 16.0, stone)    # Admiralty Pier
	_wall(st, bw_west, bw_east, 14.0, stone)        # Southern Breakwater
	_wall(st, arm_root, arm_head, 14.0, stone)      # Eastern Arm
	# Pier-head lighthouses
	for p in [pier_head, bw_west, bw_east, arm_head]:
		_cylinder(st, p + Vector3(0, 7.5, 0), 3.0, 2.5, 12.0, 8, Color(0.9, 0.9, 0.88))
	_commit(st, "DoverHarbour")

	# Ships at anchor in the harbour
	for i in range(5):
		var p : Vector3 = _ll_sea(51.1100 + (i % 2) * 0.003, 1.3180 + i * 0.0045)
		var ship := _ship_mesh(Color(0.30, 0.31, 0.33), 55.0 + i * 6.0)
		ship.position = Vector3(p.x, 0.8, p.z)
		ship.rotation.y = 0.3 * i
		ship.add_to_group("ships")
		add_child(ship)

## Long stone breakwater between two points at sea level
func _wall(st: SurfaceTool, a: Vector3, b: Vector3, width: float, col: Color) -> void:
	var dir := (b - a)
	var len_ := dir.length()
	var basis := Basis(Vector3.UP, atan2(dir.x, dir.z))
	_box(st, (a + b) * 0.5 + Vector3(0, -20.0, 0), Vector3(width, 27.5, len_), col, basis)

func _build_castle() -> void:
	# Dover Castle on the hill east of the town
	var base := _ll(51.1294, 1.3214)
	var stone := Color(0.80, 0.76, 0.66)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_box(st, Vector3(0, -6, 0), Vector3(30, 34, 30), stone)              # Great Tower keep
	for cx in [-14, 14]:
		for cz in [-14, 14]:
			_box(st, Vector3(cx, 28, cz), Vector3(6, 6, 6), stone)        # corner turrets
	# Inner bailey wall with towers
	var wall_r := 70.0
	for i in range(14):
		var a0 := TAU * i / 14.0
		var a1 := TAU * (i + 1) / 14.0
		var p0 := Vector3(cos(a0) * wall_r, -4, sin(a0) * wall_r * 1.3)
		var p1 := Vector3(cos(a1) * wall_r, -4, sin(a1) * wall_r * 1.3)
		var d := p1 - p0
		_box(st, (p0 + p1) * 0.5, Vector3(4, 16, d.length()), stone, Basis(Vector3.UP, atan2(d.x, d.z)))
		_box(st, p0 + Vector3(0, 0, 0), Vector3(9, 20, 9), stone)
	# Outer curtain wall
	wall_r = 190.0
	for i in range(22):
		var a0 := TAU * i / 22.0
		var a1 := TAU * (i + 1) / 22.0
		var p0 := Vector3(cos(a0) * wall_r, 0, sin(a0) * wall_r * 1.6)
		var p1 := Vector3(cos(a1) * wall_r, 0, sin(a1) * wall_r * 1.6)
		p0.y = _ground(base.x + p0.x, base.z + p0.z) - base.y - 4.0
		p1.y = _ground(base.x + p1.x, base.z + p1.z) - base.y - 4.0
		var d := p1 - p0
		_box(st, (p0 + p1) * 0.5, Vector3(4, 14, Vector2(d.x, d.z).length()), stone.darkened(0.08),
			Basis(Vector3.UP, atan2(d.x, d.z)))
		_box(st, p0, Vector3(8, 18, 8), stone.darkened(0.08))
	_commit(st, "DoverCastle", base)

func _build_radar() -> void:
	# Chain Home station at Swingate: four 110 m steel transmitter masts
	# and four shorter timber receiver towers
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var steel := Color(0.42, 0.44, 0.46)
	var base := _ll(51.1442, 1.3395)
	for i in range(4):
		var p := Vector3(i * 140.0 - 210.0, 0.0, 0.0)
		p.y = _ground(base.x + p.x, base.z) - base.y - 1.0
		_lattice(st, p, 110.0, 7.0, steel)
		for k in range(3):   # cantilever platforms carrying the antenna curtain
			_box(st, p + Vector3(0, 50 + k * 30, 0), Vector3(3, 1.2, 26), steel)
	for i in range(4):
		var p := Vector3(i * 90.0 - 135.0, 0.0, 260.0)
		p.y = _ground(base.x + p.x, base.z + p.z) - base.y - 1.0
		_lattice(st, p, 72.0, 5.0, Color(0.38, 0.30, 0.22))
	_box(st, Vector3(0, 0, 130), Vector3(30, 5, 14), Color(0.7, 0.68, 0.6))   # operations block
	_commit(st, "ChainHomeRadar", base)

## Tapering square lattice tower built from thin boxes
func _lattice(st: SurfaceTool, base: Vector3, height: float, width: float, col: Color) -> void:
	var levels := int(height / 10.0)
	for lv in range(levels):
		var y0 := lv * 10.0
		var w := lerpf(width, width * 0.35, (y0 + 5.0) / height)
		for sx in [-0.5, 0.5]:
			for sz in [-0.5, 0.5]:
				_box(st, base + Vector3(sx * w, y0, sz * w), Vector3(0.6, 10.0, 0.6), col)
		_box(st, base + Vector3(0, y0 + 9.5, w * 0.5), Vector3(w, 0.4, 0.4), col)
		_box(st, base + Vector3(0, y0 + 9.5, -w * 0.5), Vector3(w, 0.4, 0.4), col)
		_box(st, base + Vector3(w * 0.5, y0 + 9.5, 0), Vector3(0.4, 0.4, w), col)
		_box(st, base + Vector3(-w * 0.5, y0 + 9.5, 0), Vector3(0.4, 0.4, w), col)

func _build_lighthouses() -> void:
	var white := Color(0.95, 0.95, 0.93)
	var specs : Array = [
		[_ll(51.1403, 1.3712), 21.0],                   # South Foreland
		[_ll(50.8697, 1.5836), 28.0],                   # Cap Gris-Nez
	]
	for s in specs:
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		var ht : float = s[1]
		_cylinder(st, Vector3(0, -1, 0), 3.2, 2.4, ht, 10, white)
		_cylinder(st, Vector3(0, ht - 1, 0), 2.6, 2.6, 3.0, 10, Color(0.25, 0.25, 0.22))
		_cylinder(st, Vector3(0, ht + 2, 0), 2.8, 0.0, 2.0, 10, Color(0.2, 0.2, 0.2))
		_box(st, Vector3(8, -1, 0), Vector3(10, 6, 14), white)
		_commit(st, "Lighthouse", s[0])

func _build_balloons() -> void:
	# Barrage balloons over Dover harbour and town
	var balloon := _balloon_mesh()
	var rng := RandomNumberGenerator.new()
	rng.seed = 1940
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.vertex_color_is_srgb = true
	mat.roughness = 0.4
	mat.metallic = 0.3
	var cable_mat := StandardMaterial3D.new()
	cable_mat.albedo_color = Color(0.15, 0.15, 0.15)
	for i in range(14):
		var gp := _ll(rng.randf_range(51.100, 51.140), rng.randf_range(1.285, 1.350))
		var alt := rng.randf_range(450.0, 1300.0)
		var b := MeshInstance3D.new()
		b.name = "BarrageBalloon"
		b.mesh = balloon
		b.material_override = mat
		var yaw := 0.9 + rng.randf_range(-0.2, 0.2)    # all weathercock into the wind
		b.position = Vector3(gp.x, gp.y + alt, gp.z)
		add_child(b)
		_balloons.append([b, rng.randf() * TAU, yaw, gp.y + alt])
		var cable := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.15
		cyl.bottom_radius = 0.15
		cyl.height = alt
		cyl.radial_segments = 4
		cyl.rings = 1
		cable.mesh = cyl
		cable.material_override = cable_mat
		cable.position = Vector3(gp.x, gp.y + alt * 0.5, gp.z)
		cable.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		cable.visibility_range_end = 4000.0
		add_child(cable)

func _balloon_mesh() -> Mesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var silver := Color(0.74, 0.76, 0.74)
	# Body of revolution along local Z: [z, radius]
	var prof : Array = [[-11.0, 0.0], [-9.5, 3.2], [-6.0, 5.2], [-1.0, 5.8], [4.0, 5.0], [8.0, 3.0], [10.5, 0.8], [11.0, 0.0]]
	var sides := 10
	for k in range(prof.size() - 1):
		var za : float = prof[k][0]; var ra : float = prof[k][1]
		var zb : float = prof[k + 1][0]; var rb : float = prof[k + 1][1]
		for i in range(sides):
			var a0 := TAU * i / sides
			var a1 := TAU * (i + 1) / sides
			_quad(st, Vector3(cos(a0) * ra, sin(a0) * ra, za), Vector3(cos(a0) * rb, sin(a0) * rb, zb),
				Vector3(cos(a1) * rb, sin(a1) * rb, zb), Vector3(cos(a1) * ra, sin(a1) * ra, za), silver,
				Vector3(0, 0, (za + zb) * 0.5))
	# Three tail fins (top, left, right)
	for f in [Vector3(0, 1, 0), Vector3(1, -0.4, 0).normalized(), Vector3(-1, -0.4, 0).normalized()]:
		var root0 := Vector3(f.x * 3.0, f.y * 3.0, 4.0)
		var root1 := Vector3(f.x * 1.0, f.y * 1.0, 10.0)
		var tip := Vector3(f.x * 7.5, f.y * 7.5, 9.5)
		var side : Vector3 = f.cross(Vector3.BACK)
		_tri(st, root0, root1, tip, silver.darkened(0.1), root0 - side)
		_tri(st, root0, root1, tip, silver.darkened(0.1), root0 + side)
	return st.commit()

func _ship_mesh(hull_col: Color, length: float) -> MeshInstance3D:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var w := length * 0.14
	var hull := hull_col
	# Hull with pointed bow
	var l := length * 0.5
	var y0 := -2.0
	var y1 := 3.5
	var pts : Array = [Vector3(-w * 0.5, 0, l * 0.65), Vector3(0, 0, l), Vector3(w * 0.5, 0, l * 0.65),
		Vector3(w * 0.5, 0, -l), Vector3(-w * 0.5, 0, -l)]
	for i in range(pts.size()):
		var a : Vector3 = pts[i]
		var b : Vector3 = pts[(i + 1) % pts.size()]
		_quad(st, a + Vector3(0, y0, 0), b + Vector3(0, y0, 0), b + Vector3(0, y1, 0), a + Vector3(0, y1, 0), hull,
			Vector3(0, 0, clampf((a.z + b.z) * 0.5, -l * 0.5, l * 0.5)))
	var deck := Color(0.45, 0.40, 0.35)
	_tri(st, pts[0] + Vector3(0, y1, 0), pts[1] + Vector3(0, y1, 0), pts[2] + Vector3(0, y1, 0), deck, Vector3(0, 0, l * 0.7))
	_quad(st, pts[0] + Vector3(0, y1, 0), pts[2] + Vector3(0, y1, 0), pts[3] + Vector3(0, y1, 0), pts[4] + Vector3(0, y1, 0), deck, Vector3.ZERO)
	# Superstructure, funnel and masts
	_box(st, Vector3(0, y1, -l * 0.25), Vector3(w * 0.7, 5.0, length * 0.18), Color(0.85, 0.83, 0.78))
	_cylinder(st, Vector3(0, y1 + 5.0, -l * 0.28), 1.6, 1.4, 6.0, 8, Color(0.15, 0.15, 0.15))
	_box(st, Vector3(0, y1, l * 0.45), Vector3(0.5, 14.0, 0.5), Color(0.3, 0.3, 0.3))
	_box(st, Vector3(0, y1, -l * 0.75), Vector3(0.5, 11.0, 0.5), Color(0.3, 0.3, 0.3))
	var mi := MeshInstance3D.new()
	mi.name = "Ship"
	mi.mesh = st.commit()
	mi.material_override = _vc_mat
	return mi

func _build_convoy() -> void:
	# A coastal convoy steaming down-Channel — the Kanalkampf of July 1940
	_convoy = Node3D.new()
	_convoy.name = "Convoy"
	# Route: off Cap Gris-Nez, down past Dungeness toward Beachy Head
	_convoy_a = map.geo.latlon_to_game(51.03, 1.60)
	_convoy_b = map.geo.latlon_to_game(50.70, 0.40)
	_convoy_t = 4000.0
	var route := _convoy_b - _convoy_a
	_convoy.rotation.y = atan2(-route.y, route.x)     # ships face local +X
	add_child(_convoy)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var wake_mat := StandardMaterial3D.new()
	wake_mat.albedo_color = Color(0.95, 0.97, 0.97, 0.75)
	wake_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	wake_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	wake_mat.render_priority = -5
	for i in range(9):
		var col := i % 3
		var rowi := i / 3
		var length := rng.randf_range(60.0, 95.0)
		var ship := _ship_mesh(Color(0.26, 0.27, 0.29).lerp(Color(0.35, 0.30, 0.26), rng.randf()), length)
		ship.position = Vector3(-rowi * 600.0 + rng.randf_range(-40, 40), 0, (col - 1) * 450.0)
		ship.rotation.y = PI * 0.5      # bows toward +X (west)
		ship.add_to_group("ships")
		_convoy.add_child(ship)
		var wake := MeshInstance3D.new()
		var q := PlaneMesh.new()
		q.size = Vector2(length * 0.18, 260.0)
		wake.mesh = q
		wake.material_override = wake_mat
		wake.position = Vector3(0, 0.15, -length * 0.5 - 130.0)
		wake.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		ship.add_child(wake)
