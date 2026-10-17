extends Node3D
## Main menu: a live diorama (the chosen aircraft cruising past the white
## cliffs) behind the mission cards, side, aircraft, start airfield, weather
## and map scale choices and the sortie button.

const AircraftTypes := preload("res://scenes/plane/aircraft_types.gd")
const Missions := preload("res://scenes/mission/missions.gd")
const Airfields := preload("res://scenes/world/geo/airfields.gd")
const Cloud := preload("res://scenes/world/weather/cloud.gd")
const SEA_SHADER := preload("res://scenes/world/dover/sea.gdshader")
const CLOUD_SHADER := preload("res://scenes/world/weather/cloud.gdshader")

const ACCENT := Color(1.0, 0.80, 0.25)
const TXT := Color(0.95, 0.96, 0.97)
const TXT_DIM := Color(0.70, 0.74, 0.79)
const SPEED := 70.0                       # diorama flight speed (m/s)
const CLIFF_LEN := 60000.0

var _rig : Node3D                         # moves along +X with the plane
var _plane : Node3D
var _cam : Camera3D
var _time := 0.0
var _cam_scale := 1.0
var _font : SystemFont
var _font_bold : SystemFont
var _loading : Label
var _fly : Button
var _brief : Label
var _side_row : HBoxContainer
var _aircraft_row : HBoxContainer
var _ac_hint : Label
var _field_pick : OptionButton
var _start_note : Label

func _ready() -> void:
	_font = _make_font(500)
	_font_bold = _make_font(700)
	_build_diorama()
	_build_ui()

func _make_font(weight: int) -> SystemFont:
	var f := SystemFont.new()
	f.font_names = PackedStringArray(["Bahnschrift", "DIN Alternate", "Segoe UI", "Helvetica Neue", "Arial"])
	f.font_weight = weight
	return f

func _process(delta: float) -> void:
	_time += delta
	_rig.position.x += SPEED * delta
	if _rig.position.x > CLIFF_LEN * 0.4:
		_rig.position.x = -CLIFF_LEN * 0.4
	# Gentle banking, bobbing and a slow camera drift around the plane
	_plane.rotation = Vector3(sin(_time * 0.4) * 0.04, -PI * 0.5, sin(_time * 0.27) * 0.22)
	_plane.position.y = sin(_time * 0.5) * 1.5
	_plane.set_controls(sin(_time * 0.4) * 0.3, -cos(_time * 0.27) * 0.4, 0.0, 0.85)
	var a := -0.5 + sin(_time * 0.07) * 0.55
	_cam.position = Vector3(sin(a) * 15.0 - 2.0, 3.0 + sin(_time * 0.11) * 1.5, cos(a) * 15.0) * _cam_scale
	_cam.look_at(_rig.global_position + Vector3(-1.0, 0.5, 0.0) + _plane.position)

# ---------------------------------------------------------------------------
# Diorama
# ---------------------------------------------------------------------------

func _build_diorama() -> void:
	var env := Environment.new()
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.20, 0.42, 0.80)
	sky_mat.sky_horizon_color = Color(0.66, 0.78, 0.90)
	sky_mat.ground_horizon_color = Color(0.66, 0.78, 0.90)
	sky_mat.ground_bottom_color = Color(0.10, 0.22, 0.32)
	sky.sky_material = sky_mat
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.fog_enabled = true
	env.fog_light_color = Color(0.66, 0.78, 0.90)
	env.fog_density = 0.00003
	env.fog_sky_affect = 0.3
	env.ssao_enabled = true
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-35.0, 150.0, 0.0)
	sun.light_color = Color(1.0, 0.95, 0.86)
	sun.light_energy = 1.3
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 120.0
	add_child(sun)

	# Sea
	var sea := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(400000, 400000)
	sea.mesh = pm
	var sea_mat := ShaderMaterial.new()
	sea_mat.shader = SEA_SHADER
	sea_mat.render_priority = -10
	sea.material_override = sea_mat
	sea.position.y = -600.0
	add_child(sea)

	_build_cliffs(-600.0)
	_build_clouds()

	_rig = Node3D.new()
	add_child(_rig)
	_spawn_plane()
	_cam = Camera3D.new()
	_cam.fov = 55.0
	_cam.h_offset = -6.0          # frame the plane on the right, clear of the menu
	_cam.far = 300000.0
	_rig.add_child(_cam)

## (Re)build the diorama aircraft for the selected type
func _spawn_plane() -> void:
	if is_instance_valid(_plane):
		_plane.queue_free()
	var t : Dictionary = AircraftTypes.TYPES[GameSettings.aircraft]
	_plane = Node3D.new()
	_plane.set_script(load(t.model))
	_plane.start_gear_up = true
	_rig.add_child(_plane)
	var k : float = t.camera[0] / 20.0
	_cam_scale = k

## A long stretch of white chalk cliffs with green downland on top
func _build_cliffs(sea_y: float) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var noise := FastNoiseLite.new()
	noise.frequency = 1.0 / 900.0
	noise.fractal_octaves = 3
	var z0 := -2600.0                         # cliff line (camera looks toward -Z)
	var step := 60.0
	var x := -CLIFF_LEN * 0.5
	var chalk := Color(0.95, 0.94, 0.89)
	var grass := Color(0.42, 0.60, 0.27)
	var grass2 := Color(0.36, 0.53, 0.22)
	var prev : Array = []
	while x <= CLIFF_LEN * 0.5:
		var n := noise.get_noise_1d(x)
		var z := z0 + n * 220.0
		var h := sea_y + 105.0 + noise.get_noise_1d(x * 3.0 + 500.0) * 25.0
		var inset := noise.get_noise_1d(x * 7.0) * 8.0
		var row := [Vector3(x, sea_y - 5.0, z + 12.0), Vector3(x, sea_y + 3.0, z + 6.0 + inset),
			Vector3(x, h - 4.0, z - 4.0 + inset), Vector3(x, h, z - 10.0),
			Vector3(x, h + 25.0, z - 600.0), Vector3(x, h + 70.0, z - 3000.0)]
		if not prev.is_empty():
			for r in range(row.size() - 1):
				var col := chalk if r < 3 else (grass if r == 3 else grass2)
				_quad(st, prev[r], row[r], row[r + 1], prev[r + 1], col)
		prev = row
		x += step
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.vertex_color_is_srgb = true
	mat.roughness = 1.0
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)

## Quad facing south or up (toward the camera side of the cliffs)
static func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, col: Color) -> void:
	for t in [[a, b, c], [a, c, d]]:
		var p0 : Vector3 = t[0]; var p1 : Vector3 = t[1]; var p2 : Vector3 = t[2]
		var n := (p1 - p0).cross(p2 - p0).normalized()
		var verts := [p0, p2, p1]           # Godot fronts are clockwise
		if n.y + n.z < 0.0:
			n = -n
			verts = [p0, p1, p2]
		for v in verts:
			st.set_color(col)
			st.set_normal(n)
			st.add_vertex(v)

func _build_clouds() -> void:
	var mat := ShaderMaterial.new()
	mat.shader = CLOUD_SHADER
	mat.set_shader_parameter("self_light", 0.32)
	var rng := RandomNumberGenerator.new()
	rng.seed = 1940
	for i in range(40):
		var p := Vector3(rng.randf_range(-CLIFF_LEN * 0.5, CLIFF_LEN * 0.5), rng.randf_range(300, 900),
			rng.randf_range(-9000, -1500))
		var w := rng.randf_range(400, 1200)
		var blobs : Array = []
		for k in range(10):
			var o := Vector3(rng.randf_range(-0.4, 0.4) * w, rng.randf_range(0.0, 0.35) * w, rng.randf_range(-0.3, 0.3) * w)
			var r := w * rng.randf_range(0.16, 0.26)
			blobs.append([p + o, Vector3(r * 1.15, r * 0.85, r)])
		var c := Node3D.new()
		c.set_script(Cloud)
		c.blobs = blobs
		c.flat_base = p.y
		c.material = mat
		c.seed_ = i
		add_child(c)

# ---------------------------------------------------------------------------
# UI
# ---------------------------------------------------------------------------

func _box(bg: Color, border := Color(0, 0, 0, 0), radius := 18, bw := 0) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(bw)
	sb.set_corner_radius_all(radius)
	sb.content_margin_left = 34
	sb.content_margin_right = 34
	sb.content_margin_top = 18
	sb.content_margin_bottom = 18
	sb.anti_aliasing = true
	return sb

func _label(text: String, size: int, col: Color, bold := false) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", _font_bold if bold else _font)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	return l

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)

	# Soft dark gradient on the left so the text reads over the scene
	var shade := TextureRect.new()
	var grad := Gradient.new()
	grad.set_color(0, Color(0.02, 0.03, 0.05, 0.86))
	grad.set_color(1, Color(0.02, 0.03, 0.05, 0.0))
	var gt := GradientTexture2D.new()
	gt.gradient = grad
	gt.fill_from = Vector2(0.0, 0.5)
	gt.fill_to = Vector2(1.0, 0.5)
	gt.width = 256
	gt.height = 4
	shade.texture = gt
	shade.stretch_mode = TextureRect.STRETCH_SCALE
	shade.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	shade.offset_right = 2400
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(shade)

	var col := VBoxContainer.new()
	col.position = Vector2(200, 100)
	col.custom_minimum_size = Vector2(1560, 0)
	col.add_theme_constant_override("separation", 14)
	layer.add_child(col)

	col.add_child(_label("SPITFIRE", 150, TXT, true))
	col.add_child(_label("BATTLE OF BRITAIN  ·  1940", 40, ACCENT, true))
	col.add_child(_spacer(26))

	# Missions: two rows of cards
	col.add_child(_label("MISSION", 30, TXT_DIM, true))
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 20)
	grid.add_theme_constant_override("v_separation", 20)
	col.add_child(grid)
	var mgroup := ButtonGroup.new()
	for m in Missions.LIST:
		grid.add_child(_mission_card(m, mgroup))
	_brief = _label("", 28, TXT_DIM)
	_brief.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_brief.custom_minimum_size = Vector2(1500, 86)
	col.add_child(_brief)

	# Settings rows: a caption column, then the choices
	_side_row = _row(col, "SIDE")
	var sgroup := ButtonGroup.new()
	for sd in [["raf", "RAF"], ["lw", "LUFTWAFFE"]]:
		_side_row.add_child(_choice(sd[1], sgroup, GameSettings.side == sd[0], func(): _set_side(sd[0])))
	_aircraft_row = _row(col, "AIRCRAFT")
	_ac_hint = _label("", 26, TXT_DIM)
	var start_row := _row(col, "START")
	_field_pick = _option(640)
	_field_pick.item_selected.connect(func(i: int): GameSettings.airfield = _field_pick.get_item_metadata(i))
	start_row.add_child(_field_pick)
	_start_note = _label("", 28, TXT_DIM)
	start_row.add_child(_start_note)

	var wrow := _row(col, "WEATHER")
	var wpick := _option(420)
	var order := [GameSettings.Weather.FAIR_CUMULUS, GameSettings.Weather.CLEAR, GameSettings.Weather.STORMS,
		GameSettings.Weather.OVERCAST, GameSettings.Weather.HIGH_CLOUD, GameSettings.Weather.RANDOM]
	var whint := _label("", 26, TXT_DIM)
	for w in order:
		wpick.add_item(GameSettings.WEATHER_INFO[w][0])
		wpick.set_item_metadata(wpick.item_count - 1, w)
		if w == GameSettings.weather:
			wpick.select(wpick.item_count - 1)
			whint.text = GameSettings.WEATHER_INFO[w][1]
	wpick.item_selected.connect(func(i: int):
		GameSettings.weather = wpick.get_item_metadata(i)
		whint.text = GameSettings.WEATHER_INFO[GameSettings.weather][1])
	wrow.add_child(wpick)
	wrow.add_child(whint)

	var srow := _row(col, "MAP SCALE")
	var scale_group := ButtonGroup.new()
	var scale_hint := _label("", 26, TXT_DIM)
	for opt in GameSettings.MAP_SCALES:
		srow.add_child(_scale_button(opt, scale_group, scale_hint))
	srow.add_child(scale_hint)

	col.add_child(_spacer(26))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 30)
	col.add_child(row)
	_fly = _button("FLY SORTIE", true)
	_fly.pressed.connect(_start)
	row.add_child(_fly)
	var quit := _button("QUIT", false)
	quit.pressed.connect(func(): get_tree().quit())
	row.add_child(quit)

	var help := _label("W / S  pitch      A / D  roll      Q / E  rudder      ↑ / ↓  throttle (↓ brakes on the ground)" +
		"      SPACE  guns      M  map      ESC  pause", 28, TXT_DIM)
	help.position = Vector2(200, 2160 - 120)
	layer.add_child(help)

	_loading = _label("PREPARING SORTIE…", 64, TXT, true)
	_loading.set_anchors_preset(Control.PRESET_CENTER)
	_loading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_loading.position = Vector2(1920 - 500, 1080 - 40)
	_loading.custom_minimum_size = Vector2(1000, 80)
	_loading.visible = false
	layer.add_child(_loading)

	_refresh()
	_fly.grab_focus()

func _spacer(h: float) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	return c

## A settings row with its caption; returns the container for the choices
func _row(parent: Control, caption: String) -> HBoxContainer:
	var r := HBoxContainer.new()
	r.add_theme_constant_override("separation", 20)
	var cap := _label(caption, 30, TXT_DIM, true)
	cap.custom_minimum_size = Vector2(250, 0)
	cap.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	r.add_child(cap)
	parent.add_child(r)
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 20)
	r.add_child(box)
	return box

func _style_toggle(b: Button) -> void:
	b.add_theme_font_override("font", _font_bold)
	b.add_theme_font_size_override("font_size", 30)
	b.add_theme_stylebox_override("normal", _box(Color(0.05, 0.07, 0.10, 0.55), Color(1, 1, 1, 0.12), 42, 2))
	b.add_theme_stylebox_override("hover", _box(Color(0.10, 0.13, 0.17, 0.7), Color(1, 1, 1, 0.3), 42, 2))
	b.add_theme_stylebox_override("pressed", _box(Color(0.12, 0.11, 0.06, 0.75), ACCENT, 42, 4))
	b.add_theme_stylebox_override("hover_pressed", _box(Color(0.15, 0.14, 0.08, 0.8), ACCENT, 42, 4))
	b.add_theme_stylebox_override("focus", _box(Color(0, 0, 0, 0), Color(1, 1, 1, 0.7), 42, 3))
	b.add_theme_color_override("font_color", TXT)
	b.add_theme_color_override("font_pressed_color", ACCENT)
	b.add_theme_color_override("font_hover_pressed_color", ACCENT)

func _choice(text: String, group: ButtonGroup, on: bool, cb: Callable) -> Button:
	var b := Button.new()
	b.toggle_mode = true
	b.button_group = group
	b.text = text
	b.custom_minimum_size = Vector2(300, 76)
	_style_toggle(b)
	b.button_pressed = on
	b.toggled.connect(func(pressed: bool):
		if pressed:
			cb.call())
	return b

func _option(width: float) -> OptionButton:
	var o := OptionButton.new()
	o.custom_minimum_size = Vector2(width, 76)
	o.add_theme_font_override("font", _font_bold)
	o.add_theme_font_size_override("font_size", 30)
	o.add_theme_stylebox_override("normal", _box(Color(0.05, 0.07, 0.10, 0.55), Color(1, 1, 1, 0.12), 42, 2))
	o.add_theme_stylebox_override("hover", _box(Color(0.10, 0.13, 0.17, 0.7), Color(1, 1, 1, 0.3), 42, 2))
	o.add_theme_stylebox_override("pressed", _box(Color(0.12, 0.11, 0.06, 0.75), ACCENT, 42, 4))
	o.add_theme_stylebox_override("focus", _box(Color(0, 0, 0, 0), Color(1, 1, 1, 0.7), 42, 3))
	o.add_theme_color_override("font_color", TXT)
	var pm := o.get_popup()
	pm.add_theme_font_override("font", _font)
	pm.add_theme_font_size_override("font_size", 30)
	return o

func _mission_card(m: Dictionary, group: ButtonGroup) -> Button:
	var b := Button.new()
	b.toggle_mode = true
	b.button_group = group
	b.custom_minimum_size = Vector2(500, 128)
	b.add_theme_stylebox_override("normal", _box(Color(0.05, 0.07, 0.10, 0.55), Color(1, 1, 1, 0.12), 22, 2))
	b.add_theme_stylebox_override("hover", _box(Color(0.10, 0.13, 0.17, 0.7), Color(1, 1, 1, 0.3), 22, 2))
	b.add_theme_stylebox_override("pressed", _box(Color(0.12, 0.11, 0.06, 0.75), ACCENT, 22, 4))
	b.add_theme_stylebox_override("hover_pressed", _box(Color(0.15, 0.14, 0.08, 0.8), ACCENT, 22, 4))
	b.add_theme_stylebox_override("focus", _box(Color(0, 0, 0, 0), Color(1, 1, 1, 0.7), 22, 3))
	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.position = Vector2(30, 18)
	box.add_theme_constant_override("separation", 4)
	var name_l := _label(m.name, 38, TXT, true)
	var sub := "%s  ·  %s" % [m.date, "RAF attacks" if m.attacker == "raf" else ("Luftwaffe attacks" if m.attacker == "lw" else "Sandbox")]
	var date_l := _label(sub, 24, TXT_DIM)
	for l in [name_l, date_l]:
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(l)
	b.add_child(box)
	b.button_pressed = GameSettings.mission == m.id
	if b.button_pressed:
		name_l.add_theme_color_override("font_color", ACCENT)
	b.toggled.connect(func(on: bool):
		name_l.add_theme_color_override("font_color", ACCENT if on else TXT)
		if on:
			GameSettings.mission = m.id
			GameSettings.airfield = ""
			_refresh())
	return b

func _set_side(sd: String) -> void:
	GameSettings.side = sd
	GameSettings.airfield = ""
	_refresh()

## Rebuilds everything that depends on the mission and side
func _refresh() -> void:
	var m : Dictionary = Missions.by_id(GameSettings.mission)
	_brief.text = m.blurb + "  " + (m.brief_raf if GameSettings.side == "raf" else m.brief_lw)
	# Aircraft for this side
	for c in _aircraft_row.get_children():
		c.queue_free()
	var allowed : Array = AircraftTypes.for_side(GameSettings.side)
	if not allowed.has(GameSettings.aircraft):
		GameSettings.aircraft = allowed[0]
		_spawn_plane()
	var agroup := ButtonGroup.new()
	for key in allowed:
		var t : Dictionary = AircraftTypes.TYPES[key]
		_aircraft_row.add_child(_choice(t.short, agroup, GameSettings.aircraft == key, func():
			GameSettings.aircraft = key
			_ac_hint.text = AircraftTypes.TYPES[key].desc
			_spawn_plane()))
	if _ac_hint.get_parent() == null:
		_aircraft_row.get_parent().add_child(_ac_hint)
	_ac_hint.text = AircraftTypes.TYPES[GameSettings.aircraft].desc
	# Where the player starts
	_field_pick.clear()
	var attacks := Missions.player_attacks(m, GameSettings.side)
	var in_air : bool = attacks or (m.id != "free" and m.player_start == "air")
	_field_pick.visible = not in_air
	if in_air:
		_start_note.text = "In the air, alongside the bombers." if attacks else "In the air, facing the raid."
		return
	var fields : Array = Missions.start_fields(m, GameSettings.side, Airfields.LIST, GameSettings.map_scale)
	var pick := 0
	for i in range(fields.size()):
		var f : Array = fields[i]
		var label : String = f[0] if f[0] == Missions.AIRBORNE or m.id == "free" else "%s  —  %d km" % [f[0], roundi(f[1])]
		_field_pick.add_item(label)
		_field_pick.set_item_metadata(i, f[0])
		if f[0] == GameSettings.airfield:
			pick = i
	_field_pick.select(pick)
	GameSettings.airfield = _field_pick.get_item_metadata(pick)
	_start_note.text = "km to the target" if m.id != "free" else ""

func _button(text: String, primary: bool) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(520 if primary else 300, 120)
	b.add_theme_font_override("font", _font_bold)
	b.add_theme_font_size_override("font_size", 48)
	if primary:
		b.add_theme_stylebox_override("normal", _box(ACCENT, Color(0, 0, 0, 0), 60))
		b.add_theme_stylebox_override("hover", _box(ACCENT.lightened(0.15), Color(0, 0, 0, 0), 60))
		b.add_theme_stylebox_override("pressed", _box(ACCENT.darkened(0.15), Color(0, 0, 0, 0), 60))
		b.add_theme_stylebox_override("focus", _box(Color(0, 0, 0, 0), Color.WHITE, 60, 4))
		for k in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
			b.add_theme_color_override(k, Color(0.08, 0.08, 0.1))
	else:
		b.add_theme_stylebox_override("normal", _box(Color(1, 1, 1, 0.10), Color(1, 1, 1, 0.25), 60, 2))
		b.add_theme_stylebox_override("hover", _box(Color(1, 1, 1, 0.20), Color(1, 1, 1, 0.4), 60, 2))
		b.add_theme_stylebox_override("pressed", _box(Color(1, 1, 1, 0.28), Color(1, 1, 1, 0.5), 60, 2))
		b.add_theme_stylebox_override("focus", _box(Color(0, 0, 0, 0), Color.WHITE, 60, 4))
		b.add_theme_color_override("font_color", TXT)
		b.add_theme_color_override("font_hover_color", Color.WHITE)
	return b

func _scale_button(opt: Array, group: ButtonGroup, hint: Label) -> Button:
	var b := Button.new()
	b.toggle_mode = true
	b.button_group = group
	b.text = "%s  %d%%" % [opt[1], int(round(opt[0] * 100.0))]
	b.custom_minimum_size = Vector2(330, 76)
	b.add_theme_font_override("font", _font_bold)
	b.add_theme_font_size_override("font_size", 30)
	b.add_theme_stylebox_override("normal", _box(Color(0.05, 0.07, 0.10, 0.55), Color(1, 1, 1, 0.12), 42, 2))
	b.add_theme_stylebox_override("hover", _box(Color(0.10, 0.13, 0.17, 0.7), Color(1, 1, 1, 0.3), 42, 2))
	b.add_theme_stylebox_override("pressed", _box(Color(0.12, 0.11, 0.06, 0.75), ACCENT, 42, 4))
	b.add_theme_stylebox_override("hover_pressed", _box(Color(0.15, 0.14, 0.08, 0.8), ACCENT, 42, 4))
	b.add_theme_stylebox_override("focus", _box(Color(0, 0, 0, 0), Color(1, 1, 1, 0.7), 42, 3))
	b.add_theme_color_override("font_color", TXT)
	b.add_theme_color_override("font_pressed_color", ACCENT)
	b.add_theme_color_override("font_hover_pressed_color", ACCENT)
	b.button_pressed = is_equal_approx(GameSettings.map_scale, opt[0])
	if b.button_pressed:
		hint.text = opt[2]
	b.toggled.connect(func(on: bool):
		if on:
			GameSettings.map_scale = opt[0]
			hint.text = opt[2]
			_refresh())
	return b

func _start() -> void:
	_loading.visible = true
	_fly.disabled = true
	# Let the loading text draw before the map build blocks the main thread
	await get_tree().process_frame
	await get_tree().process_frame
	get_tree().change_scene_to_file("res://scenes/main.tscn")
