extends RefCounted
## Low-poly town buildings of 1930s Britain (and, near enough, northern
## Europe), instanced with MultiMesh and drawn by building.gdshader.
##
## Each mesh is built at unit size — 1 m frontage (local X, along the
## street), 1 m depth (local Z, the street side is -Z) and 1 m eaves height
## (Y) — and every instance scales it, so one mesh serves many sizes.
## Vertex alpha tags parts: WALL and ROOF are tinted per instance; anything
## else (windows, doors, chimneys, stone) keeps its own colour.

const DoverScenery := preload("res://scenes/world/dover/dover_scenery.gd")

const WALL := Color(1.0, 1.0, 1.0, 1.0)
const ROOF := Color(1.0, 1.0, 1.0, 0.75)
const GLASS := Color(0.22, 0.25, 0.30, 0.0)
const FRAME := Color(0.90, 0.89, 0.84, 0.0)        # painted sashes and bays
const DOOR := Color(0.18, 0.20, 0.24, 0.0)
const BRICK := Color(0.55, 0.34, 0.27, 0.0)        # chimney stacks
const POT := Color(0.66, 0.38, 0.26, 0.0)          # terracotta chimney pots
const STONE := Color(0.80, 0.77, 0.70, 0.0)
const LEAD := Color(0.40, 0.42, 0.45, 0.0)

static func _st() -> SurfaceTool:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	return st

static func _box(st: SurfaceTool, base: Vector3, size: Vector3, col: Color) -> void:
	DoverScenery._box(st, base, size, col)

## Gabled roof over the 1 x 1 footprint at height y0, ridge along X
static func _gable(st: SurfaceTool, y0: float, rise: float, over := 0.04) -> void:
	var h := 0.5 + over
	var a := Vector3(-0.5, y0, -h); var b := Vector3(0.5, y0, -h)
	var c := Vector3(0.5, y0, h);   var d := Vector3(-0.5, y0, h)
	var r0 := Vector3(-0.5, y0 + rise, 0.0); var r1 := Vector3(0.5, y0 + rise, 0.0)
	var inside := Vector3(0, y0 + rise * 0.3, 0)
	DoverScenery._quad(st, d, c, r1, r0, ROOF, inside)
	DoverScenery._quad(st, b, a, r0, r1, ROOF, inside)
	DoverScenery._tri(st, a, d, r0, WALL, inside)        # gable ends
	DoverScenery._tri(st, c, b, r1, WALL, inside)

## Stack with chimney pots
static func _chimney(st: SurfaceTool, at: Vector3, w: float, d: float, h: float, pots: int) -> void:
	_box(st, at, Vector3(w, h, d), BRICK)
	var n := mini(pots, 2)
	for i in range(n):
		var x := at.x - w * 0.5 + w * (i + 0.5) / n
		_box(st, Vector3(x, at.y + h, at.z), Vector3(w / n * 0.5, h * 0.18, d * 0.5), POT)

## Flat pane on the z = ±0.5 face (2 triangles), lifted slightly off the wall
static func _pane(st: SurfaceTool, x: float, y: float, z: float, w: float, h: float, col: Color, lift := 0.004) -> void:
	var zz := z + signf(z) * lift
	var a := Vector3(x - w * 0.5, y, zz); var b := Vector3(x + w * 0.5, y, zz)
	var c := Vector3(x + w * 0.5, y + h, zz); var d := Vector3(x - w * 0.5, y + h, zz)
	DoverScenery._quad(st, a, b, c, d, col, Vector3(x, y + h * 0.5, 0.0))

## Windows across one face: `cols` per floor at the given heights.  z = -0.5 is the street front.
static func _windows(st: SurfaceTool, z: float, cols: int, floors: Array, w: float, h: float) -> void:
	for y in floors:
		for i in range(cols):
			var x := -0.5 + (i + 0.5) / cols
			_pane(st, x, y - 0.015, z, w + 0.03, h + 0.03, FRAME, 0.003)
			_pane(st, x, y, z, w, h, GLASS, 0.006)

## Semi-detached pair with two-storey bay windows and end chimneys
static func semi() -> Mesh:
	var st := _st()
	_box(st, Vector3.ZERO, Vector3(1, 1, 1), WALL)
	_gable(st, 1.0, 0.5)
	for sx in [-0.27, 0.27]:
		_box(st, Vector3(sx, 0.0, -0.55), Vector3(0.24, 0.85, 0.12), FRAME)        # bay
		_pane(st, sx, 0.12, -0.61, 0.2, 0.25, GLASS)
		_pane(st, sx, 0.55, -0.61, 0.2, 0.22, GLASS)
		_box(st, Vector3(sx, 0.85, -0.56), Vector3(0.26, 0.05, 0.15), ROOF)         # bay roof
		_pane(st, sx * 0.3, 0.0, -0.5, 0.07, 0.33, DOOR)
	_windows(st, 0.5, 4, [0.18, 0.62], 0.12, 0.2)
	_chimney(st, Vector3(-0.46, 1.25, 0.0), 0.08, 0.16, 0.42, 2)
	_chimney(st, Vector3(0.46, 1.25, 0.0), 0.08, 0.16, 0.42, 2)
	return st.commit()

## Detached cottage / villa with a hipped roof and a central chimney
static func cottage() -> Mesh:
	var st := _st()
	_box(st, Vector3.ZERO, Vector3(1, 1, 1), WALL)
	var h := 0.54
	var a := Vector3(-h, 1.0, -h); var b := Vector3(h, 1.0, -h)
	var c := Vector3(h, 1.0, h);   var d := Vector3(-h, 1.0, h)
	var r0 := Vector3(-0.15, 1.55, 0.0); var r1 := Vector3(0.15, 1.55, 0.0)
	var inside := Vector3(0, 1.15, 0)
	DoverScenery._quad(st, d, c, r1, r0, ROOF, inside)
	DoverScenery._quad(st, b, a, r0, r1, ROOF, inside)
	DoverScenery._tri(st, a, d, r0, ROOF, inside)
	DoverScenery._tri(st, c, b, r1, ROOF, inside)
	_windows(st, -0.5, 3, [0.2, 0.65], 0.14, 0.2)
	_windows(st, 0.5, 2, [0.2, 0.65], 0.14, 0.2)
	_pane(st, 0.0, 0.0, -0.5, 0.12, 0.38, DOOR)
	_chimney(st, Vector3(0.0, 1.3, 0.12), 0.12, 0.12, 0.45, 2)
	return st.commit()

## Victorian terraced row: party-wall chimney stacks, sash windows on two
## floors and a door to every house (frontage ~5 m per house at full scale)
static func terrace() -> Mesh:
	var st := _st()
	_box(st, Vector3.ZERO, Vector3(1, 1, 1), WALL)
	_gable(st, 1.0, 0.38, 0.03)
	var houses := 7
	for i in range(houses):
		var x := -0.5 + (i + 0.5) / houses
		_pane(st, x - 0.035, 0.0, -0.5, 0.03, 0.4, DOOR)
		_pane(st, x + 0.03, 0.15, -0.5, 0.05, 0.24, FRAME, 0.003)
		_pane(st, x + 0.03, 0.17, -0.5, 0.038, 0.2, GLASS, 0.006)
		_pane(st, x, 0.6, -0.5, 0.09, 0.22, FRAME, 0.003)
		_pane(st, x, 0.62, -0.5, 0.075, 0.18, GLASS, 0.006)
		if i > 0:
			_chimney(st, Vector3(-0.5 + float(i) / houses, 1.2, 0.0), 0.04, 0.16, 0.38, 4)
	_windows(st, 0.5, houses, [0.62], 0.07, 0.18)
	return st.commit()

## Mansion block / city-centre building: brick, rows of windows, a mansard
## roof with dormers (the London and Paris look)
static func block() -> Mesh:
	var st := _st()
	_box(st, Vector3.ZERO, Vector3(1, 1, 1), WALL)
	_pane(st, 0.0, 0.0, -0.5, 1.0, 0.14, STONE)                                  # stone ground floor
	_windows(st, -0.5, 6, [0.3, 0.52, 0.74], 0.08, 0.13)
	_windows(st, 0.5, 6, [0.3, 0.52, 0.74], 0.08, 0.13)
	_box(st, Vector3(0, 0.96, 0), Vector3(1.0, 0.04, 1.0), STONE)               # cornice
	# Mansard: steep lower slopes then a low pitched top
	var h := 0.5
	var y0 := 1.0
	var y1 := 1.22
	var a := Vector3(-0.5, y0, -h); var b := Vector3(0.5, y0, -h)
	var c := Vector3(0.5, y0, h);   var d := Vector3(-0.5, y0, h)
	var a1 := Vector3(-0.47, y1, -h + 0.08); var b1 := Vector3(0.47, y1, -h + 0.08)
	var c1 := Vector3(0.47, y1, h - 0.08); var d1 := Vector3(-0.47, y1, h - 0.08)
	var inside := Vector3(0, 1.1, 0)
	DoverScenery._quad(st, a, b, b1, a1, ROOF, inside)
	DoverScenery._quad(st, c, d, d1, c1, ROOF, inside)
	DoverScenery._quad(st, d, a, a1, d1, ROOF, inside)
	DoverScenery._quad(st, b, c, c1, b1, ROOF, inside)
	DoverScenery._quad(st, a1, b1, c1, d1, LEAD, Vector3(0, 1.0, 0))
	for i in range(5):
		var x := -0.4 + i * 0.2
		_box(st, Vector3(x, y0 + 0.03, -h + 0.03), Vector3(0.07, 0.12, 0.06), FRAME)  # dormers
	_chimney(st, Vector3(-0.3, y1, 0.0), 0.06, 0.12, 0.2, 3)
	_chimney(st, Vector3(0.3, y1, 0.0), 0.06, 0.12, 0.2, 3)
	return st.commit()

## Brick factory or warehouse: sawtooth north-light roof and a tall stack
static func factory() -> Mesh:
	var st := _st()
	_box(st, Vector3.ZERO, Vector3(1, 1, 1), WALL)
	_windows(st, -0.5, 8, [0.45], 0.06, 0.35)
	var teeth := 4
	for i in range(teeth):
		var z0 := -0.5 + float(i) / teeth
		var z1 := z0 + 1.0 / teeth
		var a := Vector3(-0.5, 1.0, z0); var b := Vector3(0.5, 1.0, z0)
		var c := Vector3(0.5, 1.0, z1); var d := Vector3(-0.5, 1.0, z1)
		var ta := Vector3(-0.5, 1.35, z1); var tb := Vector3(0.5, 1.35, z1)
		var inside := Vector3(0, 1.1, (z0 + z1) * 0.5 + 0.05)
		DoverScenery._quad(st, a, b, tb, ta, ROOF, inside)
		DoverScenery._quad(st, d, c, tb, ta, Color(0.50, 0.57, 0.62, 0.0), inside)   # glazing
		DoverScenery._tri(st, a, d, ta, WALL, inside)
		DoverScenery._tri(st, b, c, tb, WALL, inside)
	DoverScenery._cylinder(st, Vector3(0.38, 0.0, 0.3), 0.06, 0.045, 2.6, 6, BRICK)
	return st.commit()

## Parish church at real scale: nave, slate roof, west tower with a spire
## (instances only rotate and jitter size slightly)
static func church() -> Mesh:
	var st := _st()
	DoverScenery._box(st, Vector3(0, 0, 3), Vector3(11, 9, 22), STONE)
	var h := 6.0
	var a := Vector3(-h, 9, -8); var b := Vector3(h, 9, -8)
	var c := Vector3(h, 9, 14); var d := Vector3(-h, 9, 14)
	var r0 := Vector3(0, 15, -8); var r1 := Vector3(0, 15, 14)
	var inside := Vector3(0, 11, 3)
	var slate := Color(0.36, 0.38, 0.42, 0.0)
	DoverScenery._quad(st, a, d, r1, r0, slate, inside)
	DoverScenery._quad(st, c, b, r0, r1, slate, inside)
	DoverScenery._tri(st, a, b, r0, STONE, inside)
	DoverScenery._tri(st, d, c, r1, STONE, inside)
	for i in range(5):
		for sx in [5.53, -5.53]:
			var z := -4.0 + i * 4.5
			DoverScenery._quad(st, Vector3(sx, 3, z - 0.7), Vector3(sx, 3, z + 0.7), Vector3(sx, 7, z + 0.7),
				Vector3(sx, 7, z - 0.7), GLASS, Vector3(0, 5, z))
	DoverScenery._box(st, Vector3(0, 0, -11), Vector3(7, 20, 7), STONE)                 # tower
	DoverScenery._cylinder(st, Vector3(0, 20, -11), 3.6, 0.0, 18.0, 8, slate)          # spire
	return st.commit()

# ---------------------------------------------------------------------------
# Distant versions: walls, roof and chimney stacks only
# ---------------------------------------------------------------------------

static func semi_far() -> Mesh:
	var st := _st()
	_box(st, Vector3.ZERO, Vector3(1, 1, 1), WALL)
	_gable(st, 1.0, 0.5)
	_box(st, Vector3(-0.46, 1.25, 0.0), Vector3(0.08, 0.42, 0.16), BRICK)
	_box(st, Vector3(0.46, 1.25, 0.0), Vector3(0.08, 0.42, 0.16), BRICK)
	return st.commit()

static func cottage_far() -> Mesh:
	var st := _st()
	_box(st, Vector3.ZERO, Vector3(1, 1, 1), WALL)
	_gable(st, 1.0, 0.5)
	_box(st, Vector3(0.0, 1.3, 0.12), Vector3(0.12, 0.45, 0.12), BRICK)
	return st.commit()

static func terrace_far() -> Mesh:
	var st := _st()
	_box(st, Vector3.ZERO, Vector3(1, 1, 1), WALL)
	_gable(st, 1.0, 0.38, 0.03)
	for i in [2, 4]:
		_box(st, Vector3(-0.5 + i / 7.0, 1.2, 0.0), Vector3(0.04, 0.38, 0.16), BRICK)
	return st.commit()

static func block_far() -> Mesh:
	var st := _st()
	_box(st, Vector3.ZERO, Vector3(1, 1, 1), WALL)
	_gable(st, 1.0, 0.25, 0.0)
	return st.commit()

static func factory_far() -> Mesh:
	var st := _st()
	_box(st, Vector3.ZERO, Vector3(1, 1, 1), WALL)
	_gable(st, 1.0, 0.3, 0.0)
	DoverScenery._cylinder(st, Vector3(0.38, 0.0, 0.3), 0.06, 0.045, 2.6, 4, BRICK)
	return st.commit()
