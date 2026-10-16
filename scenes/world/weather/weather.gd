extends Node3D
## Weather scenarios: sky, haze and sun settings plus low-poly cloud layers
## modelled on real cloud types.
##
##   Cumulus humilis / mediocris — flat-based fair-weather heaps, ~1,500 m base
##   Cumulus congestus           — towering cauliflower columns to ~5 km
##   Cumulonimbus                — storm towers to ~10 km with a spreading anvil
##                                 and a rain shaft beneath
##   Stratocumulus               — a broken lumpy deck at ~1,300–1,800 m
##   Altocumulus                 — patches of small puffs at 3.5–5 km
##   Cirrus / cirrostratus       — thin streaks and a milky veil at 8–9.5 km
##
## world.gd sets `env` and `sun` before add_child().

const Cloud := preload("res://scenes/world/weather/cloud.gd")
const CLOUD_SHADER := preload("res://scenes/world/weather/cloud.gdshader")
const VEIL_SHADER  := preload("res://scenes/world/weather/veil.gdshader")
const Settings := preload("res://scenes/game_settings.gd")
const W := Settings.Weather

const INNER := 45000.0           ## detailed clouds out to here
const OUTER := 120000.0          ## sparse distant clouds out to here

## Player spawn and the incoming bomber stream — kept clear of cloud
const SPAWN_LINE_A := Vector3(0, 4572, -8000)
const SPAWN_LINE_B := Vector3(0, 4572, 6000)
const SPAWN_CLEAR  := 900.0

var env : Environment
var sun : DirectionalLight3D
var kind : int = W.FAIR_CUMULUS

var _rng := RandomNumberGenerator.new()
var _wrapped : Array = []         ## [node, period]: kept within ±period/2 of the camera
var _followers : Array = []       ## nodes that simply follow the camera (sheets, veils)
var _wrap_clock := 0.0
var _cloud_mat : ShaderMaterial
var _dark_mat : ShaderMaterial
var _deck_base := -INF            ## overcast: lighting dims below this height
var _deck_top := -INF
var _sun_energy := 1.3
var _ambient := 1.0

func _ready() -> void:
	add_to_group("origin_container")
	_rng.seed = Time.get_ticks_usec()
	_cloud_mat = _cloud_material(0.32)
	_dark_mat = _cloud_material(0.18)
	match kind:
		W.CLEAR:        _clear()
		W.FAIR_CUMULUS: _fair()
		W.STORMS:       _storms()
		W.OVERCAST:     _overcast()
		W.HIGH_CLOUD:   _high_cloud()
		_:              _fair()

func _process(delta: float) -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var cp := cam.global_position
	for f in _followers:
		(f as Node3D).position = Vector3(cp.x, (f as Node3D).position.y, cp.z)
	# Clouds wrap around the camera so the sky never runs out
	_wrap_clock -= delta
	if _wrap_clock <= 0.0:
		_wrap_clock = 0.5
		for w in _wrapped:
			var n : Node3D = w[0]
			var period : float = w[1]
			var d := n.position - cp
			if absf(d.x) > period * 0.5:
				n.position.x -= signf(d.x) * period
			if absf(d.z) > period * 0.5:
				n.position.z -= signf(d.z) * period
	if _deck_base == -INF or sun == null:
		return
	# Under the overcast the sun is hidden: dim, cool, flat light
	var y := cp.y
	var below := 1.0 - smoothstep(_deck_base, _deck_top + 150.0, y)
	sun.light_energy = lerpf(_sun_energy, _sun_energy * 0.22, below)
	env.ambient_light_energy = lerpf(_ambient, _ambient * 0.6, below)
	env.fog_light_color = Color(0.68, 0.72, 0.77).lerp(Color(0.52, 0.56, 0.60), below)

# ---------------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------------

func _sky(top: Color, horizon: Color, fog_density: float, sun_energy: float,
		sun_color := Color(1.0, 0.95, 0.86), ambient := 1.0) -> void:
	_sun_energy = sun_energy
	_ambient = ambient
	if env:
		env.fog_enabled = true
		env.fog_light_color = horizon
		env.fog_light_energy = 1.0
		env.fog_density = fog_density
		env.fog_aerial_perspective = 0.5
		env.fog_sky_affect = 0.35
		env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
		env.ambient_light_energy = ambient
		var sky_mat := env.sky.sky_material as ProceduralSkyMaterial if env.sky else null
		if sky_mat:
			sky_mat.sky_top_color = top
			sky_mat.sky_horizon_color = horizon
			sky_mat.ground_horizon_color = horizon
			sky_mat.ground_bottom_color = Color(0.10, 0.22, 0.32)
	if sun:
		sun.light_energy = sun_energy
		sun.light_color = sun_color

func _cloud_material(self_light: float) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = CLOUD_SHADER
	m.set_shader_parameter("self_light", self_light)
	return m

# ---------------------------------------------------------------------------
# Scenarios
# ---------------------------------------------------------------------------

func _clear() -> void:
	_sky(Color(0.16, 0.38, 0.80), Color(0.62, 0.76, 0.90), 0.000007, 1.4)
	_scatter_cumulus(18, INNER, 1600.0, Vector2(200, 550), Vector2(0.35, 0.5), 1)
	_scatter_cumulus(25, OUTER, 1600.0, Vector2(300, 700), Vector2(0.35, 0.5), 0, INNER)

func _fair() -> void:
	_sky(Color(0.20, 0.42, 0.80), Color(0.64, 0.76, 0.88), 0.000009, 1.3)
	_scatter_cumulus(150, INNER, 1500.0, Vector2(450, 1500), Vector2(0.5, 0.85), 1)
	_scatter_cumulus(220, OUTER, 1500.0, Vector2(600, 1800), Vector2(0.5, 0.8), 0, INNER)
	for i in range(12):
		var p := _random_point(INNER)
		_add_congestus(p, 1500.0, _rng.randf_range(1100, 2200), _rng.randf_range(3000, 4200), 1)

func _storms() -> void:
	_sky(Color(0.30, 0.38, 0.52), Color(0.56, 0.60, 0.66), 0.000016, 0.95,
		Color(1.0, 0.90, 0.78), 0.8)
	_scatter_cumulus(70, INNER, 1300.0, Vector2(500, 1600), Vector2(0.6, 0.95), 1,
		0.0, Color(0.55, 0.58, 0.64))
	_scatter_cumulus(120, OUTER, 1300.0, Vector2(700, 2000), Vector2(0.6, 0.9), 0, INNER,
		Color(0.55, 0.58, 0.64))
	for i in range(22):
		var p := _random_point(INNER)
		_add_congestus(p, 1300.0, _rng.randf_range(1400, 2600), _rng.randf_range(3800, 6000), 1,
			Color(0.50, 0.53, 0.60))
	# Cumulonimbus: one guaranteed in view ahead of the spawn, the rest around the map
	_add_cumulonimbus(Vector2(-9000, -16000))
	for i in range(4):
		var p := _random_point(INNER)
		if p.length() > 12000.0:
			_add_cumulonimbus(p)

func _overcast() -> void:
	_sky(Color(0.42, 0.50, 0.62), Color(0.68, 0.72, 0.77), 0.000013, 1.2,
		Color(1.0, 0.96, 0.9), 0.85)
	_deck_base = 1300.0
	_deck_top = 1800.0
	_stratocumulus_deck(_deck_base, _deck_top, 0.82)
	# A few cumulus poking through above the deck
	for i in range(10):
		_add_congestus(_random_point(INNER), 1500.0, _rng.randf_range(1000, 1800),
			_rng.randf_range(2600, 3400), 1, Color(0.62, 0.65, 0.70))

func _high_cloud() -> void:
	_sky(Color(0.24, 0.43, 0.76), Color(0.72, 0.79, 0.88), 0.000010, 1.15)
	_cirrus(90, 8200.0, 9600.0)
	_veil(9000.0, 0.2)
	_altocumulus(24, 3700.0, 5300.0)
	_scatter_cumulus(40, INNER, 1700.0, Vector2(300, 800), Vector2(0.35, 0.55), 1)

# ---------------------------------------------------------------------------
# Placement helpers
# ---------------------------------------------------------------------------

## Random point in the square ±half (squares tile seamlessly when wrapped)
func _random_point(half: float) -> Vector2:
	return Vector2(_rng.randf_range(-half, half), _rng.randf_range(-half, half))

func _period(half: float) -> float:
	return half * 2.0

func _blocks_spawn(blobs: Array) -> bool:
	for b in blobs:
		var c : Vector3 = b[0]
		var r : Vector3 = b[1]
		var ab := SPAWN_LINE_B - SPAWN_LINE_A
		var t := clampf((c - SPAWN_LINE_A).dot(ab) / ab.length_squared(), 0.0, 1.0)
		var closest := SPAWN_LINE_A + ab * t
		if c.distance_to(closest) < SPAWN_CLEAR + maxf(r.x, maxf(r.y, r.z)):
			return true
	return false

func _spawn_cloud(blobs: Array, base: float, base_col: Color, top_col: Color,
		detail: int, mat: Material = null, period := INNER * 2.0) -> Node3D:
	if blobs.is_empty() or _blocks_spawn(blobs):
		return null
	var c := Node3D.new()
	c.set_script(Cloud)
	c.blobs = blobs
	c.flat_base = base
	c.base_color = base_col
	c.top_color = top_col
	c.detail = detail
	c.material = mat if mat else _cloud_mat
	c.seed_ = _rng.randi()
	add_child(c)
	_wrapped.append([c, period])
	return c

# ---------------------------------------------------------------------------
# Cloud types
# ---------------------------------------------------------------------------

## Fair-weather cumulus: a wide flat-bottomed heap, tallest in the middle
func _cumulus_blobs(p: Vector2, base: float, width: float, height: float) -> Array:
	var blobs : Array = []
	var n := int(clampf(width / 110.0, 5.0, 16.0))
	var stretch := _rng.randf_range(0.65, 0.95)
	var ang := _rng.randf() * TAU
	var rot := Vector2(cos(ang), sin(ang))
	for i in range(n):
		var a := _rng.randf() * TAU
		var d := sqrt(_rng.randf()) * width * 0.36
		var o := Vector2(cos(a) * d, sin(a) * d * stretch)
		o = Vector2(o.x * rot.x - o.y * rot.y, o.x * rot.y + o.y * rot.x)
		var centre_k := 1.0 - pow(d / (width * 0.5), 2.0)
		var r := width * _rng.randf_range(0.17, 0.25) * (0.65 + 0.35 * centre_k)
		var y := base + r * 0.35 + _rng.randf() * height * 0.55 * centre_k
		blobs.append([Vector3(p.x + o.x, y, p.y + o.y), Vector3(r * 1.15, r * 0.8, r)])
	# Crown: a few rounded heads near the middle
	for i in range(maxi(2, n / 3)):
		var o := Vector2(_rng.randf_range(-1, 1), _rng.randf_range(-1, 1)) * width * 0.14
		var r := width * _rng.randf_range(0.14, 0.2)
		var y := base + height - r * 0.9
		blobs.append([Vector3(p.x + o.x, y, p.y + o.y), Vector3(r, r * 0.95, r)])
	return blobs

func _scatter_cumulus(count: int, half: float, base: float, width_range: Vector2,
		height_ratio: Vector2, detail: int, _unused := 0.0,
		base_col := Color(0.70, 0.74, 0.81)) -> void:
	for i in range(count):
		var p := _random_point(half)
		var w := _rng.randf_range(width_range.x, width_range.y)
		var h := w * _rng.randf_range(height_ratio.x, height_ratio.y)
		var b := base + _rng.randf_range(-80.0, 80.0)
		_spawn_cloud(_cumulus_blobs(p, b, w, h), b, base_col, Color.WHITE, detail, null, _period(half))

## Cumulus congestus: a cauliflower column of many overlapping bulges that
## narrows with height and leans slightly with the wind shear
func _congestus_blobs(p: Vector2, base: float, width: float, top: float) -> Array:
	var blobs : Array = _cumulus_blobs(p, base, width * 1.3, width * 0.45)
	var lean := Vector2(_rng.randf_range(-1, 1), _rng.randf_range(-1, 1)).normalized() * width * 0.06
	var y := base + width * 0.3
	var lv := 0
	while y < top:
		var f := clampf((y - base) / maxf(top - base, 1.0), 0.0, 1.0)
		var rr := width * lerpf(0.42, 0.24, f)
		var bulges := 5 if f < 0.8 else 3
		for k in range(bulges):
			var a := TAU * (k + _rng.randf() * 0.6) / bulges
			var o := Vector2(cos(a), sin(a)) * rr * _rng.randf_range(0.35, 0.65) + lean * lv
			var r := rr * _rng.randf_range(0.55, 0.85)
			var yy := minf(y + _rng.randf_range(-0.2, 0.3) * rr, top - r * 0.7)
			blobs.append([Vector3(p.x + o.x, yy, p.y + o.y), Vector3(r, r * 0.9, r)])
		y += rr * 0.55
		lv += 1
	# Rounded crown
	for k in range(4):
		var o := Vector2(_rng.randf_range(-1, 1), _rng.randf_range(-1, 1)) * width * 0.12 + lean * lv
		var r := width * _rng.randf_range(0.14, 0.2)
		blobs.append([Vector3(p.x + o.x, top - r * 0.8, p.y + o.y), Vector3(r, r, r)])
	return blobs

func _add_congestus(p: Vector2, base: float, width: float, top: float, detail: int,
		base_col := Color(0.62, 0.66, 0.73)) -> void:
	_spawn_cloud(_congestus_blobs(p, base, width, top), base, base_col, Color.WHITE, detail)

## Cumulonimbus: massive tower, spreading anvil, rain shaft beneath
func _add_cumulonimbus(p: Vector2) -> void:
	var base := 1100.0
	var width := _rng.randf_range(4500, 6500)
	var top := _rng.randf_range(8500, 10000)
	var blobs : Array = _congestus_blobs(p, base, width, top - 300.0)
	# Anvil: flattened blobs spreading downwind at the tropopause
	var wind := Vector2(1.0, 0.25).normalized()
	for i in range(16):
		var along := _rng.randf_range(-0.3, 1.0) * width * 1.6
		var across := _rng.randf_range(-1, 1) * width * (0.5 + 0.3 * along / (width * 1.6))
		var o := wind * along + Vector2(-wind.y, wind.x) * across
		var r := width * _rng.randf_range(0.3, 0.45)
		var y := top - r * 0.25 - absf(along) / (width * 1.6) * 600.0
		blobs.append([Vector3(p.x + o.x, y, p.y + o.y), Vector3(r * 1.5, r * 0.25, r * 1.2)])
	var cb := _spawn_cloud(blobs, base, Color(0.36, 0.39, 0.46), Color(0.97, 0.97, 0.98), 1, _dark_mat)
	if cb:
		_rain_shaft(cb, p, base, width * 0.45)

func _rain_shaft(cloud: Node3D, p: Vector2, base: float, radius: float) -> void:
	var mat := ShaderMaterial.new()
	mat.shader = VEIL_SHADER
	mat.set_shader_parameter("color", Color(0.42, 0.45, 0.50))
	mat.set_shader_parameter("alpha", 0.35)
	mat.set_shader_parameter("fade_bottom", true)
	mat.set_shader_parameter("height", base)
	var cyl := CylinderMesh.new()
	cyl.top_radius = radius
	cyl.bottom_radius = radius * 1.25
	cyl.height = base
	cyl.radial_segments = 9
	cyl.rings = 1
	cyl.cap_top = false
	cyl.cap_bottom = false
	var mi := MeshInstance3D.new()
	mi.mesh = cyl
	mi.material_override = mat
	mi.position = Vector3(p.x, base * 0.5, p.y) - cloud.position   # rides along with its cloud
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	cloud.add_child(mi)

## Stratocumulus: broken deck of flattened lumps, tiled for culling, with a
## continuous sheet beyond the detailed area so the deck reaches the horizon
func _stratocumulus_deck(base: float, top: float, coverage: float) -> void:
	var tile := 6000.0
	var step := 1500.0
	var mid := (base + top) * 0.5
	var t := -INNER
	while t < INNER:
		var u := -INNER
		while u < INNER:
			var blobs : Array = []
			var z := t
			while z < t + tile:
				var x := u
				while x < u + tile:
					if _rng.randf() < coverage:
						var w := step * _rng.randf_range(0.7, 1.15)
						var h := (top - base) * _rng.randf_range(0.35, 0.6)
						var c := Vector3(x + _rng.randf() * step, mid + _rng.randf_range(-0.2, 0.25) * (top - base),
							z + _rng.randf() * step)
						blobs.append([c, Vector3(w, h, w * _rng.randf_range(0.6, 1.0))])
						# Rounded heads on top of each lump
						for k in range(2):
							var o := Vector3(_rng.randf_range(-0.4, 0.4) * w, 0.0, _rng.randf_range(-0.4, 0.4) * w)
							var r := w * _rng.randf_range(0.3, 0.45)
							blobs.append([c + o + Vector3(0, h * 0.35, 0), Vector3(r, r * 0.55, r)])
					x += step
				z += step
			_spawn_cloud(blobs, base, Color(0.55, 0.58, 0.64), Color(0.90, 0.91, 0.94), 1)
			u += tile
		t += tile
	_deck_sheet(mid, INNER - 4000.0, OUTER * 3.0)

func _deck_sheet(y: float, hole: float, extent: float) -> void:
	# Square ring with a hole over the detailed deck, both faces visible
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rects := [Rect2(-extent, -extent, extent * 2.0, extent - hole),
		Rect2(-extent, hole, extent * 2.0, extent - hole),
		Rect2(-extent, -hole, extent - hole, hole * 2.0),
		Rect2(hole, -hole, extent - hole, hole * 2.0)]
	for r in rects:
		var a := Vector3(r.position.x, y, r.position.y)
		var b := Vector3(r.end.x, y, r.position.y)
		var c := Vector3(r.end.x, y, r.end.y)
		var d := Vector3(r.position.x, y, r.end.y)
		# Top faces (clockwise from above) and bottom faces (clockwise from below)
		for tri in [[a, b, c, true], [a, c, d, true], [a, c, b, false], [a, d, c, false]]:
			for k in range(3):
				st.set_color(Color(0.94, 0.95, 0.97) if tri[3] else Color(0.56, 0.59, 0.65))
				st.set_normal(Vector3.UP if tri[3] else Vector3.DOWN)
				st.add_vertex(tri[k])
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = _cloud_mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	_followers.append(mi)

## Altocumulus: patches of small flattened puffs in loose rows
func _altocumulus(patches: int, lo: float, hi: float) -> void:
	for i in range(patches):
		var p := _random_point(INNER)
		if i < 4:
			p = Vector2(_rng.randf_range(-9000, 9000), _rng.randf_range(-22000, -5000))
		var y := _rng.randf_range(lo, hi)
		var ang := _rng.randf() * TAU
		var row_dir := Vector2(cos(ang), sin(ang))
		var col_dir := Vector2(-row_dir.y, row_dir.x)
		var blobs : Array = []
		var rows := _rng.randi_range(4, 7)
		var cols := _rng.randi_range(5, 9)
		for rw in range(rows):
			for cl in range(cols):
				if _rng.randf() < 0.25:
					continue
				var o := row_dir * (cl - cols * 0.5) * 260.0 + col_dir * (rw - rows * 0.5) * 200.0
				o += Vector2(_rng.randf_range(-60, 60), _rng.randf_range(-60, 60))
				var r := _rng.randf_range(70.0, 120.0)
				blobs.append([Vector3(p.x + o.x, y + _rng.randf_range(-20, 20), p.y + o.y),
					Vector3(r * 1.3, r * 0.45, r)])
		_spawn_cloud(blobs, y - 40.0, Color(0.78, 0.81, 0.87), Color.WHITE, 0)

## Cirrus: long translucent streaks drawn out by high winds, soft-edged.
## Built as a 4 x 4 grid of chunk meshes so each chunk can wrap on its own.
func _cirrus(count: int, lo: float, hi: float) -> void:
	var mat := ShaderMaterial.new()
	mat.shader = VEIL_SHADER
	mat.set_shader_parameter("color", Color(1.0, 1.0, 1.0))
	mat.set_shader_parameter("alpha", 0.6)
	mat.set_shader_parameter("vertex_alpha", true)
	var chunks := 4
	var chunk := OUTER * 2.0 / chunks
	var tools := {}
	var wind := Vector2(1.0, 0.3).normalized()
	var across := Vector2(-wind.y, wind.x)
	for i in range(count):
		var p := _random_point(OUTER)
		if i < count / 4:
			p = Vector2(_rng.randf_range(-15000, 15000), _rng.randf_range(-30000, 0))   # some overhead
		var ck := Vector2i(clampi(int((p.x + OUTER) / chunk), 0, chunks - 1), clampi(int((p.y + OUTER) / chunk), 0, chunks - 1))
		var centre := Vector2(-OUTER + (ck.x + 0.5) * chunk, -OUTER + (ck.y + 0.5) * chunk)
		if not tools.has(ck):
			var st0 := SurfaceTool.new()
			st0.begin(Mesh.PRIMITIVE_TRIANGLES)
			tools[ck] = [st0, centre]
		var st : SurfaceTool = tools[ck][0]
		var y := _rng.randf_range(lo, hi)
		var length := _rng.randf_range(4000, 12000)
		var width := _rng.randf_range(500, 1500)
		var curve := _rng.randf_range(-0.3, 0.3)
		var segs := 8
		var rows : Array = []
		for sg in range(segs + 1):
			var f := float(sg) / segs
			var bend := curve * length * (f - 0.5) * (f - 0.5) * 2.0
			var c2 := p - centre + wind * (f - 0.5) * length + across * bend
			var w := width * pow(sin(PI * f), 0.7) + 20.0       # tapered "mares' tails"
			var yy := y + f * 150.0
			var fade := sin(PI * f)
			rows.append([Vector3(c2.x + across.x * w, yy, c2.y + across.y * w),
				Vector3(c2.x, yy, c2.y), Vector3(c2.x - across.x * w, yy, c2.y - across.y * w), fade])
		for sg in range(segs):
			var r0 : Array = rows[sg]
			var r1 : Array = rows[sg + 1]
			for k in range(2):
				var quad := [[r0[k], 0.0 if k == 0 else r0[3]], [r0[k + 1], r0[3] if k == 0 else 0.0],
					[r1[k + 1], r1[3] if k == 0 else 0.0], [r1[k], 0.0 if k == 0 else r1[3]]]
				for idx in [0, 1, 2, 0, 2, 3]:
					st.set_color(Color(1, 1, 1, quad[idx][1]))
					st.add_vertex(quad[idx][0])
	for ck in tools:
		var mi := MeshInstance3D.new()
		mi.mesh = (tools[ck][0] as SurfaceTool).commit()
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var centre : Vector2 = tools[ck][1]
		mi.position = Vector3(centre.x, 0.0, centre.y)
		add_child(mi)
		_wrapped.append([mi, OUTER * 2.0])

## Cirrostratus: a thin milky veil over the whole sky
func _veil(y: float, alpha: float) -> void:
	var mat := ShaderMaterial.new()
	mat.shader = VEIL_SHADER
	mat.set_shader_parameter("color", Color(0.96, 0.97, 1.0))
	mat.set_shader_parameter("alpha", alpha)
	var pm := PlaneMesh.new()
	pm.size = Vector2(OUTER * 6.0, OUTER * 6.0)
	var mi := MeshInstance3D.new()
	mi.mesh = pm
	mi.material_override = mat
	mi.position.y = y
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	_followers.append(mi)
