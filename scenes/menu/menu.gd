extends Node
## Main menu — Play button leads to map selection.

var _main_panel : Control
var _map_panel  : Control

func _ready() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)

	var bg := ColorRect.new()
	bg.color = Color(0.04, 0.07, 0.12)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(bg)

	_main_panel = _build_main_panel()
	layer.add_child(_main_panel)

	_map_panel = _build_map_panel()
	_map_panel.visible = false
	layer.add_child(_map_panel)

# ── Main menu ─────────────────────────────────────────────────────────────────

func _build_main_panel() -> Control:
	var p := Control.new()
	p.set_anchors_preset(Control.PRESET_FULL_RECT)

	p.add_child(_label("WW2 FLIGHT",        0.5, 0.28, 700, 80, 56))
	p.add_child(_label("Battle of Britain", 0.5, 0.40, 500, 44, 26))

	var play := _button("PLAY", 0.5, 0.60, 220, 64)
	play.pressed.connect(func():
		_main_panel.visible = false
		_map_panel.visible  = true)
	p.add_child(play)

	return p

# ── Map selection ─────────────────────────────────────────────────────────────

func _build_map_panel() -> Control:
	var p := Control.new()
	p.set_anchors_preset(Control.PRESET_FULL_RECT)

	p.add_child(_label("SELECT MAP", 0.5, 0.22, 500, 60, 38))

	# ── Cloud preset row ──────────────────────────────────────────────────────
	p.add_child(_label("CLOUDS", 0.5, 0.36, 300, 36, 18))

	var cloud_drop := OptionButton.new()
	cloud_drop.add_item("Random",        GameSettings.CloudPreset.RANDOM)
	cloud_drop.add_item("Clear",         GameSettings.CloudPreset.CLEAR)
	cloud_drop.add_item("Cumulus",       GameSettings.CloudPreset.CUMULUS)
	cloud_drop.add_item("Cirrostratus",  GameSettings.CloudPreset.CIRROSTRATUS)
	cloud_drop.add_item("Cirrocumulus",  GameSettings.CloudPreset.CIRROCUMULUS)
	cloud_drop.add_item("Overcast",      GameSettings.CloudPreset.OVERCAST)
	cloud_drop.selected = GameSettings.cloud_preset
	cloud_drop.anchor_left   = 0.5;  cloud_drop.anchor_right  = 0.5
	cloud_drop.anchor_top    = 0.43; cloud_drop.anchor_bottom = 0.43
	cloud_drop.offset_left   = -130; cloud_drop.offset_right  = 130
	cloud_drop.offset_top    = -22;  cloud_drop.offset_bottom = 22
	cloud_drop.item_selected.connect(func(idx: int):
		GameSettings.cloud_preset = cloud_drop.get_item_id(idx))
	p.add_child(cloud_drop)

	# ── Map buttons ───────────────────────────────────────────────────────────
	var proc := _button("Procedural Map\nCliffs of Dover", 0.38, 0.58, 280, 90)
	proc.pressed.connect(func():
		get_tree().change_scene_to_file("res://scenes/main.tscn"))
	p.add_child(proc)

	var custom := _button("Custom Map\nHTerrain Editor", 0.62, 0.58, 280, 90)
	custom.pressed.connect(func():
		get_tree().change_scene_to_file("res://scenes/main_hterrain.tscn"))
	p.add_child(custom)

	var back := _button("BACK", 0.5, 0.76, 160, 52)
	back.pressed.connect(func():
		_map_panel.visible  = false
		_main_panel.visible = true)
	p.add_child(back)

	return p

# ── Helpers ───────────────────────────────────────────────────────────────────

func _label(text: String, ax: float, ay: float, w: float, h: float, size: int) -> Label:
	var l := Label.new()
	l.text = text
	l.anchor_left   = ax;  l.anchor_right  = ax
	l.anchor_top    = ay;  l.anchor_bottom = ay
	l.offset_left   = -w * 0.5;  l.offset_right  = w * 0.5
	l.offset_top    = -h * 0.5;  l.offset_bottom = h * 0.5
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", size)
	return l

func _button(text: String, ax: float, ay: float, w: float, h: float) -> Button:
	var b := Button.new()
	b.text = text
	b.anchor_left   = ax;  b.anchor_right  = ax
	b.anchor_top    = ay;  b.anchor_bottom = ay
	b.offset_left   = -w * 0.5;  b.offset_right  = w * 0.5
	b.offset_top    = -h * 0.5;  b.offset_bottom = h * 0.5
	return b
