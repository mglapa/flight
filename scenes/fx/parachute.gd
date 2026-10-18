extends Node3D
## A pilot who has bailed out: a low-poly airman under a parachute.
## Falls free for a moment, the canopy blossoms open, then drifts down with
## the wind, swinging gently.  On landing the canopy collapses beside him;
## in the sea he slowly goes under.  Lives in an origin container (the
## caller adds it next to the aircraft), so positions are scene space.

const OPEN_DELAY := 1.2           ## free fall before the ripcord (s)
const OPEN_TIME := 1.1            ## canopy inflating (s)
const DESCENT := 5.5              ## sink rate under the canopy (m/s)
const TERMINAL := 55.0            ## free-fall speed (m/s)
const WIND := Vector3(2.4, 0.0, -1.0)   ## drift with the west-south-westerly
const CANOPY_H := 6.5             ## canopy above the harness (m)
const LINGER := 60.0              ## seconds on the ground before tidying away

var velocity := Vector3.ZERO
var landed := false
var in_water := false
## Flying-suit colour: RAF blue-grey or Luftwaffe brown-grey
var suit := Color(0.36, 0.40, 0.46)

var _age := 0.0
var _open := 0.0
var _land_age := 0.0
var _rig : Node3D                 ## swings under the canopy point
var _canopy : Node3D
var _world : Node = null
var _swing_seed := 0.0

func _ready() -> void:
	add_to_group("parachutes")
	_world = get_tree().get_first_node_in_group("world")
	_swing_seed = randf() * TAU
	_build()

func _physics_process(delta: float) -> void:
	_age += delta
	if landed:
		_settle(delta)
		return
	if _age > OPEN_DELAY:
		_open = minf(_open + delta / OPEN_TIME, 1.0)
	# Drag pulls the velocity toward free fall, then toward the gentle
	# canopy descent drifting downwind
	var target_v := Vector3(WIND.x * _open, lerpf(-TERMINAL, -DESCENT, _open), WIND.z * _open)
	var rate := lerpf(0.2, 1.6, _open)
	velocity = velocity.lerp(target_v, 1.0 - exp(-rate * delta))
	global_position += velocity * delta

	# Canopy: a streamer that blossoms into a dome
	var o := smoothstep(0.0, 1.0, _open)
	_canopy.visible = _age > OPEN_DELAY
	_canopy.scale = Vector3(lerpf(0.12, 1.0, o), lerpf(2.2, 1.0, o), lerpf(0.12, 1.0, o))
	# Pendulum swing, larger just after opening
	var amp := 0.05 + 0.18 * (1.0 - o) * float(_age > OPEN_DELAY) + 0.06 * o
	_rig.rotation = Vector3(sin(_age * 1.3 + _swing_seed) * amp, 0.0, sin(_age * 0.9 + _swing_seed * 2.0) * amp)
	rotation.y += 0.08 * delta * o

	var g := _ground_y()
	if global_position.y <= g:
		global_position.y = g
		landed = true
		in_water = g < 1.0
		_rig.rotation = Vector3.ZERO

func _settle(delta: float) -> void:
	_land_age += delta
	# The canopy sags over and flattens downwind
	var k := minf(_land_age / 2.5, 1.0)
	_canopy.visible = true
	_canopy.rotation = Vector3(0.0, 0.0, lerpf(0.0, -1.45, k))
	_canopy.scale = Vector3(1.0, lerpf(1.0, 0.25, k), 1.0)
	_canopy.position = Vector3(lerpf(0.0, -CANOPY_H * 0.85, k), lerpf(CANOPY_H, 0.4, k), 0.0) - Vector3(0, CANOPY_H, 0)
	if in_water:
		position.y -= 0.25 * delta
		if _land_age > 25.0:
			queue_free()
	elif _land_age > LINGER:
		queue_free()

func _ground_y() -> float:
	if _world and _world.has_method("sample_height"):
		return _world.sample_height(global_position.x, global_position.z)
	return 0.0

# ---------------------------------------------------------------------------
# Model
# ---------------------------------------------------------------------------

static func _mat(c: Color, both_sides := false) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.9
	if both_sides:
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m

func _part(parent: Node3D, mesh: Mesh, at: Vector3, mat: Material, rot := Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = at
	mi.rotation = rot
	mi.visibility_range_end = 7000.0
	parent.add_child(mi)
	return mi

static func _box(size: Vector3) -> BoxMesh:
	var b := BoxMesh.new()
	b.size = size
	return b

func _build() -> void:
	# The rig pivots at the canopy, so the airman swings beneath it
	var pivot := Node3D.new()
	pivot.position = Vector3(0, CANOPY_H, 0)
	add_child(pivot)
	_rig = pivot
	var body := Node3D.new()
	body.position = Vector3(0, -CANOPY_H, 0)
	_rig.add_child(body)

	var suit_m := _mat(suit)
	var dark := _mat(suit.darkened(0.35))
	var skin := _mat(Color(0.86, 0.68, 0.55))
	var leather := _mat(Color(0.32, 0.22, 0.14))
	var harness := _mat(Color(0.82, 0.78, 0.66))
	var vest := _mat(Color(0.86, 0.72, 0.22))       # life jacket

	# Legs, dangling slightly apart
	for sx in [-1.0, 1.0]:
		_part(body, _box(Vector3(0.17, 0.85, 0.2)), Vector3(sx * 0.12, 0.45, 0.0), suit_m, Vector3(0.08, 0, sx * 0.06))
		_part(body, _box(Vector3(0.19, 0.12, 0.3)), Vector3(sx * 0.14, 0.04, -0.05), leather)
	# Torso with life jacket and harness straps
	_part(body, _box(Vector3(0.44, 0.62, 0.26)), Vector3(0, 1.18, 0), suit_m)
	_part(body, _box(Vector3(0.46, 0.34, 0.3)), Vector3(0, 1.3, 0), vest)
	_part(body, _box(Vector3(0.48, 0.07, 0.32)), Vector3(0, 0.98, 0), harness)
	# Arms up, holding the risers
	for sx in [-1.0, 1.0]:
		_part(body, _box(Vector3(0.13, 0.7, 0.14)), Vector3(sx * 0.3, 1.72, 0.0), dark, Vector3(0, 0, sx * -0.28))
		_part(body, _box(Vector3(0.12, 0.12, 0.12)), Vector3(sx * 0.4, 2.08, 0.0), leather)
	# Head in a leather helmet
	var head := SphereMesh.new()
	head.radius = 0.13
	head.height = 0.27
	head.radial_segments = 6
	head.rings = 3
	_part(body, head, Vector3(0, 1.66, -0.02), skin)
	var helmet := SphereMesh.new()
	helmet.radius = 0.145
	helmet.height = 0.2
	helmet.radial_segments = 6
	helmet.rings = 2
	helmet.is_hemisphere = true
	_part(body, helmet, Vector3(0, 1.69, 0.0), leather)

	# Canopy: a faceted silk dome with its rigging lines
	_canopy = Node3D.new()
	_rig.add_child(_canopy)
	var dome := SphereMesh.new()
	dome.radius = 3.6
	dome.height = 2.4
	dome.radial_segments = 10
	dome.rings = 3
	dome.is_hemisphere = true
	_part(_canopy, dome, Vector3.ZERO, _mat(Color(0.93, 0.92, 0.86), true))
	var lines := _mat(Color(0.75, 0.74, 0.70))
	for i in range(10):
		var a := TAU * i / 10.0
		var rim := Vector3(cos(a) * 3.5, 0.0, sin(a) * 3.5)
		var hand := Vector3(0, -CANOPY_H + 2.1, 0)
		var mid := (rim + hand) * 0.5
		var len := rim.distance_to(hand)
		var line := _part(_canopy, _box(Vector3(0.025, len, 0.025)), mid, lines)
		var y := (rim - hand).normalized()
		var x := y.cross(Vector3(-sin(a), 0.0, cos(a))).normalized()
		line.basis = Basis(x, y, x.cross(y))
	_canopy.visible = false
