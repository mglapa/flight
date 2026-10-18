extends Control
## Pause menu (Esc / Start) and the end-of-mission debrief.  Pauses the
## game while open.  Owned by hud.gd, which sets `mission` and the fonts.

const TXT     := Color(0.95, 0.96, 0.97)
const TXT_DIM := Color(0.70, 0.74, 0.79)
const ACCENT  := Color(1.0, 0.80, 0.25)
const GOOD    := Color(0.46, 0.86, 0.52)
const BAD     := Color(0.98, 0.42, 0.34)
const REF     := Vector2(2560, 1440)

var mission : Node = null
var font : Font
var font_bold : Font

var _panel : PanelContainer
var _title : Label
var _body : Label
var _resume : Button
var _restart : Button
var _menu : Button
var _debrief_seen := false

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false

	var shade := ColorRect.new()
	shade.color = Color(0.02, 0.03, 0.05, 0.55)
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(shade)

	_panel = PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.04, 0.05, 0.07, 0.92)
	sb.border_color = Color(1, 1, 1, 0.12)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(22)
	sb.content_margin_left = 56
	sb.content_margin_right = 56
	sb.content_margin_top = 44
	sb.content_margin_bottom = 44
	_panel.add_theme_stylebox_override("panel", sb)
	add_child(_panel)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 22)
	_panel.add_child(col)
	_title = _label("", 64, TXT, true)
	col.add_child(_title)
	_body = _label("", 30, TXT_DIM, false)
	_body.custom_minimum_size = Vector2(1100, 0)
	_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(_body)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 26)
	col.add_child(row)
	_resume = _button("RESUME", true)
	_resume.pressed.connect(_close)
	row.add_child(_resume)
	_restart = _button("RESTART", false)
	_restart.pressed.connect(_on_restart)
	row.add_child(_restart)
	_menu = _button("MAIN MENU", false)
	_menu.pressed.connect(_on_menu)
	row.add_child(_menu)

func _label(text: String, size: int, c: Color, bold: bool) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", font_bold if bold else font)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", c)
	return l

func _box(bg: Color, border: Color, bw: int) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(bw)
	sb.set_corner_radius_all(40)
	sb.content_margin_left = 30
	sb.content_margin_right = 30
	return sb

func _button(text: String, primary: bool) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(330, 84)
	b.add_theme_font_override("font", font_bold)
	b.add_theme_font_size_override("font_size", 32)
	if primary:
		b.add_theme_stylebox_override("normal", _box(ACCENT, Color(0, 0, 0, 0), 0))
		b.add_theme_stylebox_override("hover", _box(ACCENT.lightened(0.15), Color(0, 0, 0, 0), 0))
		b.add_theme_stylebox_override("pressed", _box(ACCENT.darkened(0.15), Color(0, 0, 0, 0), 0))
		for k in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
			b.add_theme_color_override(k, Color(0.08, 0.08, 0.1))
	else:
		b.add_theme_stylebox_override("normal", _box(Color(1, 1, 1, 0.10), Color(1, 1, 1, 0.25), 2))
		b.add_theme_stylebox_override("hover", _box(Color(1, 1, 1, 0.20), Color(1, 1, 1, 0.4), 2))
		b.add_theme_stylebox_override("pressed", _box(Color(1, 1, 1, 0.28), Color(1, 1, 1, 0.5), 2))
		b.add_theme_color_override("font_color", TXT)
	b.add_theme_stylebox_override("focus", _box(Color(0, 0, 0, 0), Color.WHITE, 4))
	return b

func _process(_delta: float) -> void:
	var vp := get_viewport_rect().size
	var s := minf(vp.x / REF.x, vp.y / REF.y) * 0.75
	_panel.scale = Vector2(s, s)
	_panel.position = (vp - _panel.size * s) * 0.5
	if mission and mission.finished and not _debrief_seen and not visible:
		_debrief_seen = true
		_open(true)

func _unhandled_input(event: InputEvent) -> void:
	if mission == null:              # still loading, or picking a start
		return
	var toggle := false
	if event is InputEventKey and event.pressed and not event.echo:
		toggle = (event as InputEventKey).keycode == KEY_ESCAPE or (event as InputEventKey).keycode == KEY_P
	elif event is InputEventJoypadButton and event.pressed:
		toggle = (event as InputEventJoypadButton).button_index == JOY_BUTTON_START
	if not toggle:
		return
	get_viewport().set_input_as_handled()
	if visible:
		_close()
	else:
		_open(false)

func _open(debrief: bool) -> void:
	visible = true
	get_tree().paused = true
	var player_alive := is_instance_valid(get_tree().get_first_node_in_group("player"))
	if mission == null:
		_title.text = "PAUSED"
		_body.text = ""
	elif debrief or mission.finished:
		_title.text = mission.result_title()
		var won : bool = mission.outcome == mission.side
		_title.add_theme_color_override("font_color", TXT if mission.outcome == "" else (GOOD if won else BAD))
		_body.text = "\n".join(PackedStringArray(mission.result_lines()))
	else:
		_title.text = "PAUSED"
		_title.add_theme_color_override("font_color", TXT)
		var lines : Array = [mission.def.name.to_upper() + "  ·  " + mission.def.date, mission.objective()]
		lines.append_array(mission.result_lines())
		_body.text = "\n".join(PackedStringArray(lines))
	_resume.text = "CONTINUE" if debrief else "RESUME"
	_resume.visible = player_alive
	if player_alive:
		_resume.grab_focus()
	else:
		_restart.grab_focus()

func _close() -> void:
	visible = false
	get_tree().paused = false

func _on_restart() -> void:
	get_tree().paused = false
	get_tree().reload_current_scene()

func _on_menu() -> void:
	get_tree().paused = false
	get_tree().change_scene_to_file("res://scenes/menu/menu.tscn")
