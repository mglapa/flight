extends MultiMeshInstance3D
## Every smoke, dust and fire puff in the world, drawn as one MultiMesh
## (group "smoke_field").  emit() writes a puff into a ring buffer once; the
## shader (smoke.gdshader) animates it, so a sky full of burning aircraft and
## a bombed city cost almost nothing on the CPU.
##
## Lives in the World origin container, so its local frame is the world
## frame shifted with everything else; positions passed in are scene space.

const SHADER := preload("res://scenes/fx/smoke.gdshader")
const CAPACITY := 3000

enum { GREY, BLACK, FIRE, DUST }

var _next := 0
var _now := 0.0
var _mat : ShaderMaterial

func _ready() -> void:
	add_to_group("smoke_field")
	var sphere := SphereMesh.new()            # chunky low-poly puff
	sphere.radius = 1.0
	sphere.height = 2.0
	sphere.radial_segments = 7
	sphere.rings = 4
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = sphere
	mm.instance_count = CAPACITY
	for i in range(CAPACITY):
		mm.set_instance_transform(i, Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * 0.001), Vector3.ZERO))
		mm.set_instance_custom_data(i, Color(-1000.0, 0.01, 0.0, 0.0))
	mm.custom_aabb = AABB(Vector3(-2e6, -1000, -2e6), Vector3(4e6, 22000, 4e6))
	multimesh = mm
	_mat = ShaderMaterial.new()
	_mat.shader = SHADER
	material_override = _mat
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

func _process(delta: float) -> void:
	_now += delta
	_mat.set_shader_parameter("now", _now)

## One puff at a scene-space position: base radius (m), life (s), rise (m/s)
func emit(pos: Vector3, kind: int, radius: float, life: float, rise: float) -> void:
	var local := pos - position
	var b := Basis(Vector3.UP, randf() * TAU).scaled(Vector3.ONE * radius)
	multimesh.set_instance_transform(_next, Transform3D(b, local))
	multimesh.set_instance_custom_data(_next, Color(_now, life, float(kind), rise))
	_next = (_next + 1) % CAPACITY

## A bomb burst: fireball, dust ring and a column of smoke (over water, a
## tall column of white spray instead)
func explosion(pos: Vector3, scale_ := 1.0, water := false) -> void:
	if water:
		emit(pos + Vector3(0, 8, 0) * scale_, GREY, 10.0 * scale_, 4.0, 22.0)
		emit(pos + Vector3(0, 3, 0) * scale_, GREY, 14.0 * scale_, 6.0, 6.0)
		emit(pos + Vector3(0, 2, 0) * scale_, FIRE, 6.0 * scale_, 0.4, 4.0)
		return
	emit(pos + Vector3(0, 6, 0) * scale_, FIRE, 13.0 * scale_, 0.8, 8.0)
	emit(pos + Vector3(0, 14, 0) * scale_, FIRE, 9.0 * scale_, 1.1, 14.0)
	for i in range(4):
		var a := TAU * i / 4.0 + randf()
		emit(pos + Vector3(cos(a), 0.3, sin(a)) * 14.0 * scale_, DUST, 13.0 * scale_, 9.0, 3.0)
	emit(pos + Vector3(0, 10, 0) * scale_, BLACK, 14.0 * scale_, 16.0, 9.0)
	emit(pos + Vector3(4, 24, -3) * scale_, GREY, 12.0 * scale_, 20.0, 8.0)
