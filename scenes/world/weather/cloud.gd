extends Node3D
## One low-poly cloud (or one tile of a cloud deck) built from ellipsoid blobs.
##
## Each blob is a jittered icosphere; the merged mesh is flat-shaded with a
## vertex-colour gradient from the grey base to the sunlit top.  Cumulus-type
## clouds get a flat base.  depth_at() reports how deep a point is inside
## the cloud (0 outside, 1 at a blob centre) for the in-cloud whiteout.
##
## Set `blobs`, colours and options before add_child().

## Each blob: [centre, radii (Vector3)].  Given in world (scene) coordinates
## before add_child; converted to local coordinates in _ready so the cloud can
## be moved freely (floating origin, wrapping around the camera).
var blobs : Array = []
var flat_base := -INF                 ## clamp vertices below this height
var base_color := Color(0.72, 0.76, 0.82)
var top_color  := Color(1.0, 1.0, 1.0)
var detail := 1                       ## icosphere subdivisions (0 = 20 tris)
var material : Material
var seed_ := 0

var _bound_centre := Vector3.ZERO
var _bound_radius := 0.0

static var _ico_cache := {}

func _ready() -> void:
	add_to_group("clouds")
	_compute_bounds()
	_build()
	# From here on blobs and bounds are relative to this node
	var o := position
	for b in blobs:
		b[0] = (b[0] as Vector3) - o
	flat_base -= o.y
	_bound_centre -= o

func _compute_bounds() -> void:
	var lo := Vector3(INF, INF, INF)
	var hi := -lo
	for b in blobs:
		var c : Vector3 = b[0]
		var r : Vector3 = b[1]
		lo = lo.min(c - r)
		hi = hi.max(c + r)
	_bound_centre = (lo + hi) * 0.5
	_bound_radius = (hi - lo).length() * 0.5

## How deeply world_pos sits inside this cloud (0 = outside, 1 = centre).
func depth_at(world_pos: Vector3) -> float:
	world_pos -= global_position
	if world_pos.distance_squared_to(_bound_centre) > _bound_radius * _bound_radius:
		return 0.0
	var best := 0.0
	for b in blobs:
		var d : Vector3 = (world_pos - (b[0] as Vector3)) / (b[1] as Vector3)
		var t := 1.0 - d.length()
		if t > best:
			best = t
	if world_pos.y < flat_base:
		best = 0.0
	best = clampf(best * 1.6, 0.0, 1.0)
	return best * best * (3.0 - 2.0 * best)

# ---------------------------------------------------------------------------

static func _icosphere(subdiv: int) -> Array:
	if _ico_cache.has(subdiv):
		return _ico_cache[subdiv]
	var t := (1.0 + sqrt(5.0)) * 0.5
	var verts : Array = [
		Vector3(-1, t, 0), Vector3(1, t, 0), Vector3(-1, -t, 0), Vector3(1, -t, 0),
		Vector3(0, -1, t), Vector3(0, 1, t), Vector3(0, -1, -t), Vector3(0, 1, -t),
		Vector3(t, 0, -1), Vector3(t, 0, 1), Vector3(-t, 0, -1), Vector3(-t, 0, 1)]
	for i in range(verts.size()):
		verts[i] = (verts[i] as Vector3).normalized()
	var faces : Array = [
		[0, 11, 5], [0, 5, 1], [0, 1, 7], [0, 7, 10], [0, 10, 11],
		[1, 5, 9], [5, 11, 4], [11, 10, 2], [10, 7, 6], [7, 1, 8],
		[3, 9, 4], [3, 4, 2], [3, 2, 6], [3, 6, 8], [3, 8, 9],
		[4, 9, 5], [2, 4, 11], [6, 2, 10], [8, 6, 7], [9, 8, 1]]
	for _s in range(subdiv):
		var mid := {}
		var nf : Array = []
		for f in faces:
			var m : Array = []
			for e in [[f[0], f[1]], [f[1], f[2]], [f[2], f[0]]]:
				var key := Vector2i(mini(e[0], e[1]), maxi(e[0], e[1]))
				if not mid.has(key):
					verts.append(((verts[e[0]] as Vector3) + (verts[e[1]] as Vector3)).normalized())
					mid[key] = verts.size() - 1
				m.append(mid[key])
			nf.append([f[0], m[0], m[2]])
			nf.append([f[1], m[1], m[0]])
			nf.append([f[2], m[2], m[1]])
			nf.append([m[0], m[1], m[2]])
		faces = nf
	var res := [verts, faces]
	_ico_cache[subdiv] = res
	return res

func _build() -> void:
	var ico := _icosphere(detail)
	var unit : Array = ico[0]
	var faces : Array = ico[1]
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_

	var lo_y := INF
	var hi_y := -INF
	for b in blobs:
		lo_y = minf(lo_y, (b[0] as Vector3).y - (b[1] as Vector3).y)
		hi_y = maxf(hi_y, (b[0] as Vector3).y + (b[1] as Vector3).y)
	if flat_base > -INF:
		lo_y = flat_base

	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var cols  := PackedColorArray()
	var origin := _bound_centre
	position = origin
	for b in blobs:
		var c : Vector3 = b[0]
		var r : Vector3 = b[1]
		var pts := PackedVector3Array()
		pts.resize(unit.size())
		for i in range(unit.size()):
			var p : Vector3 = c + (unit[i] as Vector3) * r * rng.randf_range(0.86, 1.1)
			if p.y < flat_base:
				p.y = flat_base
			pts[i] = p - origin
		for f in faces:
			var a := pts[f[0]]
			var bb := pts[f[1]]
			var cc := pts[f[2]]
			var n := (bb - a).cross(cc - a)
			if n.length_squared() < 1e-6:
				continue
			n = n.normalized()
			# Faces of a convex blob point away from its centre
			if n.dot((a + bb + cc) / 3.0 - (c - origin)) < 0.0:
				var tmp := bb; bb = cc; cc = tmp
				n = -n
			var fy := (a.y + bb.y + cc.y) / 3.0 + origin.y
			var k := smoothstep(lo_y, hi_y, fy)
			var col := base_color.lerp(top_color, sqrt(k))
			# Godot fronts are clockwise
			for v in [a, cc, bb]:
				verts.append(v)
				norms.append(n)
				cols.append(col)

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_COLOR]  = cols
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = material
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)

