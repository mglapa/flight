extends CanvasLayer
## Start-point picker, shown once the mission is planned and before the map
## is built: a theatre map with the target, the incoming raid and every place
## the player may start, plus a list of the same choices.  Click a field on
## the map or in the list, then TAKE OFF.  Emits `chosen` with the option
## name (or `back` for the main menu).  Owned by main.gd.

signal chosen(option_name: String)
signal back

const MAP_SHADER := preload("res://scenes/ui/map.gdshader")
const MAP_TEX_PATH := "res://data/europe/map.png"
const AircraftTypes := preload("res://scenes/plane/aircraft_types.gd")
const BOMBER_NAMES := {"he111": "He 111", "wellington": "Wellington"}

const REF := Vector2(2560, 1440)
const MAP_RECT := Rect2(40, 40, 1680, 1360)
const PANEL_X := 1770.0
const PANEL_W := 750.0

const BG      := Color(0.035, 0.045, 0.065)
const TXT     := Color(0.95, 0.96, 0.97)
const TXT_DIM := Color(0.66, 0.70, 0.75)
const ACCENT  := Color(1.0, 0.80, 0.25)
const ENEMY   := Color(1.0, 0.30, 0.25)
const ALLY    := Color(0.40, 0.72, 1.0)
const TARGET  := Color(1.0, 0.62, 0.15)
const SHADOW  := Color(0, 0, 0, 0.7)
const RAF_BLUE := Color(0.20, 0.36, 0.78)
const RAF_RED := Color(0.85, 0.20, 0.18)
const LW_BLACK := Color(0.08, 0.08, 0.08)

var geo
var mission : Node

var _options : Array = []
var _sel := 0
var _root : Control
var _map : ColorRect
var _mat : ShaderMaterial
var _overlay : Control
var _buttons : Array = []
var _go : Button
var _font : Font
var _font_bold : Font
var _centre_px := Vector2.ZERO
var _hy := 1.0                    ## map pixels from the centre to the top edge
var _time := 0.0

func _ready() -> void:
	layer = 40
	_font = _make_font(500)
	_font_bold = _make_font(700)
	_options = mission.start_options()
	for i in range(_options.size()):
		if _options[i].name == GameSettings.airfield:
			_sel = i

	var bg := ColorRect.new()
	bg.color = BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	_root = Control.new()
	_root.size = REF
	add_child(_root)

	_map = ColorRect.new()
	_map.position = MAP_RECT.position
	_map.size = MAP_RECT.size
	_mat = ShaderMaterial.new()
	_mat.shader = MAP_SHADER
	_mat.set_shader_parameter("circle", false)
	_mat.set_shader_parameter("corner", 0.015)
	if ResourceLoader.exists(MAP_TEX_PATH):
		var tex : Texture2D = load(MAP_TEX_PATH)
		_mat.set_shader_parameter("map_tex", tex)
		_mat.set_shader_parameter("tex_size", tex.get_size())
	_map.material = _mat
	_map.gui_input.connect(_on_map_input)
	_root.add_child(_map)
	_overlay = Control.new()
	_overlay.size = REF
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.draw.connect(_draw_overlay)
	_root.add_child(_overlay)
	_fit()
	_build_panel()

static func _make_font(weight: int) -> Font:
	var f := SystemFont.new()
	f.font_names = PackedStringArray(["Bahnschrift", "DIN Alternate", "Segoe UI", "Helvetica Neue", "Arial"])
	f.font_weight = weight
	f.antialiasing = TextServer.FONT_ANTIALIASING_GRAY
	return f

func _process(delta: float) -> void:
	_time += delta
	var vp := _root.get_viewport_rect().size
	var s := minf(vp.x / REF.x, vp.y / REF.y)
	_root.scale = Vector2(s, s)
	_root.position = (vp - REF * s) * 0.5
	_overlay.queue_redraw()

# ---------------------------------------------------------------------------
# Map framing
# ---------------------------------------------------------------------------

## Frames the target, the raid and every start option
func _fit() -> void:
	var pts : Array = []
	for o in _options:
		pts.append(o.pos)
	if mission.target != Vector2.INF:
		pts.append(mission.target)
		pts.append(mission.raid_start())
	var lo := Vector2(INF, INF)
	var hi := -lo
	for p in pts:
		var px : Vector2 = geo.map_pixel(p)
		lo = lo.min(px)
		hi = hi.max(px)
	_centre_px = (lo + hi) * 0.5
	var aspect := MAP_RECT.size.x / MAP_RECT.size.y
	var half := (hi - lo) * 0.5
	_hy = maxf(maxf(half.y, half.x / aspect) * 1.3, 25000.0 * geo.map_px_per_m())
	_mat.set_shader_parameter("centre_px", _centre_px)
	_mat.set_shader_parameter("half_extent", Vector2(_hy * aspect, _hy))

func _to_screen(p: Vector2) -> Vector2:
	var px : Vector2 = geo.map_pixel(p)
	return MAP_RECT.get_center() + (px - _centre_px) / _hy * (MAP_RECT.size.y * 0.5)

func _on_map_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT):
		return
	var at : Vector2 = (event as InputEventMouseButton).position + MAP_RECT.position
	var best := -1
	var best_d := 40.0
	for i in range(_options.size()):
		var d := _to_screen(_options[i].pos).distance_to(at)
		if d < best_d:
			best_d = d
			best = i
	if best >= 0:
		_select(best)
		(_buttons[best] as Button).grab_focus()
		if (event as InputEventMouseButton).double_click:
			_confirm()

# ---------------------------------------------------------------------------
# Side panel
# ---------------------------------------------------------------------------

func _label(text: String, size: int, col: Color, bold := false) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", _font_bold if bold else _font)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(PANEL_W, 0)
	return l

static func _box(bg: Color, border: Color, bw: int, radius := 14) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(bw)
	sb.set_corner_radius_all(radius)
	sb.content_margin_left = 24
	sb.content_margin_right = 24
	sb.content_margin_top = 10
	sb.content_margin_bottom = 10
	sb.anti_aliasing = true
	return sb

func _build_panel() -> void:
	var col := VBoxContainer.new()
	col.position = Vector2(PANEL_X, 60)
	col.custom_minimum_size = Vector2(PANEL_W, 1320)
	col.add_theme_constant_override("separation", 14)
	_root.add_child(col)
	var d : Dictionary = mission.def
	col.add_child(_label(String(d.name).to_upper(), 52, TXT, true))
	col.add_child(_label("%s  ·  %s" % [d.date, "RAF" if mission.side == "raf" else "LUFTWAFFE"], 24, ACCENT, true))
	col.add_child(_label(d.brief_raf if mission.side == "raf" else d.brief_lw, 24, TXT_DIM))
	if mission.target != Vector2.INF:
		col.add_child(_label(_raid_text(), 22, TXT))
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 12)
	col.add_child(gap)
	col.add_child(_label("CHOOSE YOUR START", 26, TXT_DIM, true))

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size = Vector2(PANEL_W, 200)
	col.add_child(scroll)
	var list := VBoxContainer.new()
	list.add_theme_constant_override("separation", 8)
	list.custom_minimum_size = Vector2(PANEL_W - 24, 0)
	scroll.add_child(list)
	var group := ButtonGroup.new()
	for i in range(_options.size()):
		var o : Dictionary = _options[i]
		var b := Button.new()
		b.toggle_mode = true
		b.button_group = group
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.text = o.name if o.km < 0.0 or d.id == "free" else "%s   ·   %d km from %s" % [o.name, roundi(o.km), mission.target_name]
		b.custom_minimum_size = Vector2(PANEL_W - 24, 64)
		b.add_theme_font_override("font", _font_bold)
		b.add_theme_font_size_override("font_size", 24)
		b.add_theme_stylebox_override("normal", _box(Color(1, 1, 1, 0.05), Color(1, 1, 1, 0.12), 2))
		b.add_theme_stylebox_override("hover", _box(Color(1, 1, 1, 0.10), Color(1, 1, 1, 0.3), 2))
		b.add_theme_stylebox_override("pressed", _box(Color(0.15, 0.13, 0.06, 0.9), ACCENT, 3))
		b.add_theme_stylebox_override("hover_pressed", _box(Color(0.18, 0.16, 0.08, 0.9), ACCENT, 3))
		b.add_theme_stylebox_override("focus", _box(Color(0, 0, 0, 0), Color(1, 1, 1, 0.8), 3))
		b.add_theme_color_override("font_color", TXT)
		b.add_theme_color_override("font_pressed_color", ACCENT)
		b.add_theme_color_override("font_hover_pressed_color", ACCENT)
		b.button_pressed = i == _sel
		b.pressed.connect(_select.bind(i))
		b.focus_entered.connect(_select.bind(i))
		list.add_child(b)
		_buttons.append(b)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 20)
	col.add_child(row)
	_go = _big_button("TAKE OFF" if not _options[0].air else "START", true)
	_go.pressed.connect(_confirm)
	row.add_child(_go)
	var back_b := _big_button("BACK", false)
	back_b.pressed.connect(func(): back.emit())
	row.add_child(back_b)
	_select(_sel)
	(_buttons[_sel] as Button).grab_focus()

func _big_button(text: String, primary: bool) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(440 if primary else 260, 96)
	b.add_theme_font_override("font", _font_bold)
	b.add_theme_font_size_override("font_size", 38)
	if primary:
		b.add_theme_stylebox_override("normal", _box(ACCENT, Color(0, 0, 0, 0), 0, 48))
		b.add_theme_stylebox_override("hover", _box(ACCENT.lightened(0.15), Color(0, 0, 0, 0), 0, 48))
		b.add_theme_stylebox_override("pressed", _box(ACCENT.darkened(0.15), Color(0, 0, 0, 0), 0, 48))
		b.add_theme_stylebox_override("focus", _box(Color(0, 0, 0, 0), Color.WHITE, 4, 48))
		for k in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
			b.add_theme_color_override(k, Color(0.08, 0.08, 0.1))
	else:
		b.add_theme_stylebox_override("normal", _box(Color(1, 1, 1, 0.10), Color(1, 1, 1, 0.25), 2, 48))
		b.add_theme_stylebox_override("hover", _box(Color(1, 1, 1, 0.20), Color(1, 1, 1, 0.4), 2, 48))
		b.add_theme_stylebox_override("pressed", _box(Color(1, 1, 1, 0.28), Color(1, 1, 1, 0.5), 2, 48))
		b.add_theme_stylebox_override("focus", _box(Color(0, 0, 0, 0), Color.WHITE, 4, 48))
		b.add_theme_color_override("font_color", TXT)
	return b

func _raid_text() -> String:
	var d : Dictionary = mission.def
	var bname : String = BOMBER_NAMES.get(d.bombers[0], String(d.bombers[0]))
	var ename : String = AircraftTypes.TYPES[d.escorts[0]].short if AircraftTypes.TYPES.has(d.escorts[0]) else String(d.escorts[0])
	var who := "Your bombers" if mission.side == mission.attacker else "The raid"
	return "%s: %d %s with %d %s escorting, %.1f km up, bound for %s." % [who, d.bombers[1], bname,
		d.escorts[1], ename, float(d.alt) / 1000.0, mission.target_name]

func _select(i: int) -> void:
	_sel = i
	(_buttons[i] as Button).set_pressed_no_signal(true)

func _confirm() -> void:
	chosen.emit(String(_options[_sel].name))

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and (event as InputEventKey).keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		back.emit()
	elif event is InputEventJoypadButton and event.pressed and (event as InputEventJoypadButton).button_index == JOY_BUTTON_B:
		get_viewport().set_input_as_handled()
		back.emit()

# ---------------------------------------------------------------------------
# Overlay
# ---------------------------------------------------------------------------

func _inside(p: Vector2) -> bool:
	return MAP_RECT.grow(-10).has_point(p)

func _text(pos: Vector2, s: String, size: int, col: Color, bold := false) -> void:
	var f := _font_bold if bold else _font
	var w := f.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	var at := pos - Vector2(w * 0.5, 0)
	_overlay.draw_string(f, at + Vector2(2, 2), s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, SHADOW)
	_overlay.draw_string(f, at, s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)

func _arrow(at: Vector2, dir: Vector2, size: float, col: Color) -> void:
	var side := Vector2(-dir.y, dir.x)
	var pts := PackedVector2Array([at + dir * size, at - dir * size * 0.7 + side * size * 0.65,
		at - dir * size * 0.35, at - dir * size * 0.7 - side * size * 0.65])
	var o := PackedVector2Array()
	for p in pts:
		o.append(at + (p - at) * 1.35)
	_overlay.draw_colored_polygon(o, Color(0, 0, 0, 0.7))
	_overlay.draw_colored_polygon(pts, col)

func _airfield_icon(at: Vector2, side: String, r: float, alpha := 1.0) -> void:
	if side == "raf":
		_overlay.draw_circle(at, r, Color(RAF_BLUE, alpha))
		_overlay.draw_circle(at, r * 0.62, Color(1, 1, 1, alpha))
		_overlay.draw_circle(at, r * 0.3, Color(RAF_RED, alpha))
	else:
		_overlay.draw_rect(Rect2(at - Vector2(r, r), Vector2(r, r) * 2.0), Color(1, 1, 1, alpha))
		_overlay.draw_rect(Rect2(at - Vector2(r, r * 0.3), Vector2(r * 2.0, r * 0.6)), Color(LW_BLACK, alpha))
		_overlay.draw_rect(Rect2(at - Vector2(r * 0.3, r), Vector2(r * 0.6, r * 2.0)), Color(LW_BLACK, alpha))

## Game-space direction → screen direction (east is -X, north is up)
static func _sdir(d: Vector2) -> Vector2:
	return Vector2(-d.x, -d.y).normalized()

func _draw_overlay() -> void:
	_overlay.draw_rect(MAP_RECT.grow(4), Color(0.0, 0.0, 0.0, 0.6), false, 6.0)
	var km_per_px : float = _hy / (MAP_RECT.size.y * 0.5) / geo.map_px_per_m() / 1000.0
	# Towns for orientation
	var pop_min := 1500000 if km_per_px > 0.5 else (250000 if km_per_px > 0.15 else 60000)
	for pl in geo.places:
		if pl[2] < pop_min:
			continue
		var p := _to_screen(pl[1])
		if _inside(p):
			_overlay.draw_circle(p, 4, Color(0.2, 0.18, 0.18))
			_text(p + Vector2(0, -10), pl[0], 22 if pl[2] < 1000000 else 26, TXT, pl[2] >= 1000000)
	# Every airfield, dimmed; the ones on offer are drawn after
	for a in geo.airfields:
		var p := _to_screen(a[2])
		if _inside(p):
			_airfield_icon(p, a[1], 7, 0.45)

	# The raid: its formation, its track to the target and the target
	if mission.target != Vector2.INF:
		var raid_col := ALLY if mission.side == mission.attacker else ENEMY
		var rs := _to_screen(mission.raid_start())
		var tp := _to_screen(mission.target)
		var dir := (tp - rs).normalized()
		var dash := 18.0
		var dist := rs.distance_to(tp)
		var t := fmod(_time * 30.0, dash * 2.0)
		while t < dist - 20.0:
			_overlay.draw_line(rs + dir * t, rs + dir * minf(t + dash, dist - 20.0), Color(raid_col, 0.85), 4.0)
			t += dash * 2.0
		var side := Vector2(-dir.y, dir.x)
		for k in range(5):
			var off := Vector2(0, 0) if k == 0 else (side * (14.0 * ceilf(k / 2.0)) * (1.0 if k % 2 == 1 else -1.0) - dir * 14.0 * ceilf(k / 2.0))
			_arrow(rs + off, dir, 12.0, raid_col)
		_text(rs + Vector2(0, -34), "RAID", 26, raid_col, true)
		var rr := maxf(mission.target_radius / (km_per_px * 1000.0), 12.0)
		_overlay.draw_arc(tp, rr, 0.0, TAU, 40, Color(0, 0, 0, 0.6), 7.0)
		_overlay.draw_arc(tp, rr, 0.0, TAU, 40, TARGET, 4.0)
		_overlay.draw_line(tp - Vector2(rr + 10, 0), tp + Vector2(rr + 10, 0), TARGET, 2.0)
		_overlay.draw_line(tp - Vector2(0, rr + 10), tp + Vector2(0, rr + 10), TARGET, 2.0)
		_text(tp + Vector2(0, -rr - 18), mission.target_name.to_upper(), 26, TARGET, true)

	# Start options
	for i in range(_options.size()):
		var o : Dictionary = _options[i]
		var p := _to_screen(o.pos)
		if not _inside(p):
			continue
		var sel := i == _sel
		if o.air:
			var fwd := _sdir(-mission.raid_dir) if mission.side == mission.attacker else _sdir(mission.raid_dir)
			if mission.target == Vector2.INF:
				fwd = Vector2.UP
			_arrow(p, fwd, 16.0 if sel else 12.0, ACCENT if sel else Color(ACCENT, 0.7))
		else:
			_airfield_icon(p, mission.side, 12 if sel else 9)
		if sel:
			var pulse := 26.0 + 6.0 * sin(_time * 5.0)
			_overlay.draw_arc(p, pulse, 0.0, TAU, 36, ACCENT, 4.0)
		_text(p + Vector2(0, 40), o.name, 24 if sel else 20, ACCENT if sel else TXT, sel)

	# Legend and scale
	var lg := MAP_RECT.position + Vector2(30, 46)
	_overlay.draw_string(_font_bold, lg, "CLICK A START POINT, THEN TAKE OFF", HORIZONTAL_ALIGNMENT_LEFT, -1, 22,
		Color(1, 1, 1, 0.8))
	var km := _nice_km(km_per_px * 260.0)
	var bar := km / km_per_px
	var b0 := MAP_RECT.end - Vector2(40 + bar, 40)
	_overlay.draw_line(b0, b0 + Vector2(bar, 0), TXT, 4.0)
	_overlay.draw_line(b0, b0 - Vector2(0, 10), TXT, 4.0)
	_overlay.draw_line(b0 + Vector2(bar, 0), b0 + Vector2(bar, -10), TXT, 4.0)
	_text(b0 + Vector2(bar * 0.5, -18), "%d km" % km, 22, TXT, true)

static func _nice_km(v: float) -> int:
	for k in [1, 2, 5, 10, 20, 50, 100, 200, 500]:
		if k >= v * 0.6:
			return k
	return 500
