extends Control
## North-up map: a circular minimap in the top-right corner and a large map
## toggled with M, the controller's Select/Back button, or a click on the
## minimap.  Mouse wheel, + / - or the shoulder buttons zoom the large map.
##
## The terrain picture is the baked data/europe/map.png; cities, airfields,
## aircraft and ships are drawn on top.  Owned by hud.gd.

const MAP_SHADER := preload("res://scenes/ui/map.gdshader")
const Airfields := preload("res://scenes/world/geo/airfields.gd")
const MAP_TEX_PATH := "res://data/europe/map.png"

const REF := Vector2(2560, 1440)
const MINI_R := 150.0             ## minimap radius (reference pixels)
const MINI_MARGIN := 34.0
const MINI_HALF_M := 16000.0      ## minimap shows this far from the plane
const BIG_MIN_M := 15000.0
const BIG_MAX_M := 700000.0

const TXT := Color(0.95, 0.96, 0.97)
const SHADOW := Color(0, 0, 0, 0.65)
const RAF_BLUE := Color(0.20, 0.36, 0.78)
const RAF_RED := Color(0.85, 0.20, 0.18)
const LW_BLACK := Color(0.08, 0.08, 0.08)
const ENEMY := Color(1.0, 0.30, 0.25)
const ALLY := Color(0.40, 0.72, 1.0)
const SHIP := Color(0.85, 0.87, 0.88)
const PLAYER := Color(1.0, 0.82, 0.25)
const TARGET := Color(1.0, 0.62, 0.15)

var plane : Node3D
var mission : Node = null
var font : Font
var font_bold : Font

var big_open := false
var big_half_m := 90000.0

var _geo
var _mini : ColorRect
var _big : ColorRect
var _overlay : Control
var _mini_mat : ShaderMaterial
var _big_mat : ShaderMaterial
var _tex : Texture2D
var _airfields : Array = []       ## [name, side, game Vector2]
var _s := 1.0

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_mini = _map_rect(true)
	_big = _map_rect(false)
	_mini_mat = _mini.material
	_big_mat = _big.material
	_big.visible = false
	_overlay = Control.new()
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.draw.connect(_draw_overlay)
	add_child(_overlay)
	if ResourceLoader.exists(MAP_TEX_PATH):
		_tex = load(MAP_TEX_PATH)
		for m in [_mini_mat, _big_mat]:
			m.set_shader_parameter("map_tex", _tex)
			m.set_shader_parameter("tex_size", _tex.get_size())

func _map_rect(circle: bool) -> ColorRect:
	var r := ColorRect.new()
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var m := ShaderMaterial.new()
	m.shader = MAP_SHADER
	m.set_shader_parameter("circle", circle)
	r.material = m
	add_child(r)
	return r

func _find_geo() -> void:
	if _geo != null:
		return
	var map := get_tree().get_first_node_in_group("world_map")
	if map == null or map.get("geo") == null:
		return
	_geo = map.geo
	for a in Airfields.LIST:
		_airfields.append([a[0], a[1], _geo.latlon_to_game(a[2], a[3])])

# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------

func _input(event: InputEvent) -> void:
	if event.is_action_pressed("map_toggle"):
		big_open = not big_open
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseButton and event.pressed:
		var mb := event as InputEventMouseButton
		if big_open and mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom(1.0 / 1.25)
		elif big_open and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom(1.25)
		elif mb.button_index == MOUSE_BUTTON_LEFT:
			if not big_open and mb.position.distance_to(_mini_centre()) < MINI_R * _s:
				big_open = true
				get_viewport().set_input_as_handled()
			elif big_open and not _big_rect().has_point(mb.position):
				big_open = false
	elif big_open and event is InputEventKey and event.pressed:
		var k := (event as InputEventKey).keycode
		if k == KEY_EQUAL or k == KEY_KP_ADD or k == KEY_PLUS:
			_zoom(1.0 / 1.25)
		elif k == KEY_MINUS or k == KEY_KP_SUBTRACT:
			_zoom(1.25)
		elif k == KEY_ESCAPE:
			big_open = false
			get_viewport().set_input_as_handled()
	elif big_open and event is InputEventJoypadButton and event.pressed:
		var b := (event as InputEventJoypadButton).button_index
		if b == JOY_BUTTON_RIGHT_SHOULDER:
			_zoom(1.0 / 1.25)
		elif b == JOY_BUTTON_LEFT_SHOULDER:
			_zoom(1.25)

func _zoom(f: float) -> void:
	big_half_m = clampf(big_half_m * f, BIG_MIN_M, BIG_MAX_M)

# ---------------------------------------------------------------------------
# Layout
# ---------------------------------------------------------------------------

func _mini_centre() -> Vector2:
	var vp := get_viewport_rect().size
	return Vector2(vp.x - (MINI_MARGIN + MINI_R) * _s, (MINI_MARGIN + MINI_R) * _s)

func _big_rect() -> Rect2:
	var vp := get_viewport_rect().size
	var h := vp.y * 0.8
	var w := minf(h * 1.45, vp.x * 0.9)
	return Rect2((vp - Vector2(w, h)) * 0.5, Vector2(w, h))

func _process(_delta: float) -> void:
	_find_geo()
	var vp := get_viewport_rect().size
	_s = minf(vp.x / REF.x, vp.y / REF.y)
	var ok := _geo != null and _tex != null and is_instance_valid(plane)
	_mini.visible = ok
	_big.visible = ok and big_open
	if not ok:
		_overlay.queue_redraw()
		return
	var centre := _geo.map_pixel(_player_world()) as Vector2
	var c := _mini_centre()
	var r := MINI_R * _s
	_mini.position = c - Vector2(r, r)
	_mini.size = Vector2(r, r) * 2.0
	var half_px : float = MINI_HALF_M * _geo.map_px_per_m()
	_mini_mat.set_shader_parameter("centre_px", centre)
	_mini_mat.set_shader_parameter("half_extent", Vector2(half_px, half_px))
	if big_open:
		var br := _big_rect()
		_big.position = br.position
		_big.size = br.size
		var hy : float = big_half_m * _geo.map_px_per_m()
		_big_mat.set_shader_parameter("centre_px", centre)
		_big_mat.set_shader_parameter("half_extent", Vector2(hy * br.size.x / br.size.y, hy))
	_overlay.queue_redraw()

func _player_world() -> Vector2:
	var w := WorldOrigin.to_world(plane.global_position)
	return Vector2(w.x, w.z)

# ---------------------------------------------------------------------------
# Overlay drawing
# ---------------------------------------------------------------------------

## Game position -> screen point for a map window (centre, half size in
## screen pixels, half extent in game metres along y)
func _to_screen(p: Vector2, win_c: Vector2, win_half: Vector2, half_m: float, centre_px: Vector2) -> Vector2:
	var px : Vector2 = _geo.map_pixel(p)
	var hy : float = half_m * _geo.map_px_per_m()
	return win_c + (px - centre_px) / hy * win_half.y

static func _screen_dir(n: Node3D) -> Vector2:
	var f := -n.global_transform.basis.z
	var d := Vector2(-f.x, -f.z)           # east is -X; north is -screen y
	return d.normalized() if d.length() > 0.01 else Vector2.UP

func _text(pos: Vector2, s: String, size: float, col: Color, bold := false, center := true) -> void:
	var f := font_bold if bold else font
	var fs := int(size * _s)
	var w := f.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var at := pos - Vector2(w * 0.5 if center else 0.0, 0.0)
	_overlay.draw_string(f, at + Vector2(1, 1) * maxf(1.0, _s), s, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, SHADOW)
	_overlay.draw_string(f, at, s, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)

func _arrow(at: Vector2, dir: Vector2, size: float, col: Color, outline := true) -> void:
	var side := Vector2(-dir.y, dir.x)
	var pts := PackedVector2Array([at + dir * size, at - dir * size * 0.7 + side * size * 0.65,
		at - dir * size * 0.35, at - dir * size * 0.7 - side * size * 0.65])
	if outline:
		var o := PackedVector2Array()
		for p in pts:
			o.append(at + (p - at) * 1.3)
		_overlay.draw_colored_polygon(o, Color(0, 0, 0, 0.7))
	_overlay.draw_colored_polygon(pts, col)

func _airfield_icon(at: Vector2, side: String, r: float) -> void:
	if side == "raf":
		_overlay.draw_circle(at, r, RAF_BLUE)
		_overlay.draw_circle(at, r * 0.62, Color.WHITE)
		_overlay.draw_circle(at, r * 0.3, RAF_RED)
	else:
		_overlay.draw_rect(Rect2(at - Vector2(r, r), Vector2(r, r) * 2.0), Color.WHITE)
		_overlay.draw_rect(Rect2(at - Vector2(r, r * 0.3), Vector2(r * 2.0, r * 0.6)), LW_BLACK)
		_overlay.draw_rect(Rect2(at - Vector2(r * 0.3, r), Vector2(r * 0.6, r * 2.0)), LW_BLACK)

func _draw_overlay() -> void:
	if _geo == null or _tex == null or not is_instance_valid(plane):
		return
	var centre_px : Vector2 = _geo.map_pixel(_player_world())
	var r := MINI_R * _s
	var c := _mini_centre()
	_draw_layer(c, Vector2(r, r), MINI_HALF_M, centre_px, func(p: Vector2) -> bool:
		return p.distance_to(c) < r - 6.0 * _s, false)
	# Minimap frame, north marker and hint
	_overlay.draw_arc(c, r, 0.0, TAU, 72, Color(0.04, 0.05, 0.07), maxf(2.0, 5.0 * _s))
	_overlay.draw_arc(c, r - 2.5 * _s, 0.0, TAU, 72, Color(1, 1, 1, 0.25), maxf(1.0, 1.5 * _s))
	var n_at := c + Vector2(0, -r + 4 * _s)
	_overlay.draw_circle(n_at, 13 * _s, Color(0.04, 0.05, 0.07))
	_text(n_at + Vector2(0, 6 * _s), "N", 16.0, Color(1.0, 0.35, 0.3), true)
	_text(c + Vector2(0, r + 26 * _s), "M  —  MAP", 13.0, Color(1, 1, 1, 0.55), true)

	if big_open:
		var br := _big_rect()
		var bc := br.get_center()
		_overlay.draw_rect(br.grow(3.0 * _s), Color(0.04, 0.05, 0.07, 0.9), false, maxf(2.0, 5.0 * _s))
		_draw_layer(bc, br.size * 0.5, big_half_m, centre_px, func(p: Vector2) -> bool:
			return br.grow(-8.0 * _s).has_point(p), true)
		# Title, scale bar and controls
		_text(br.position + Vector2(28 * _s, 44 * _s), "THEATRE MAP", 22.0, TXT, true, false)
		var km := _nice_km(big_half_m * 0.4 / 1000.0)
		var bar := km * 1000.0 / big_half_m * br.size.y * 0.5
		var b0 := br.end - Vector2(40 * _s + bar, 40 * _s)
		_overlay.draw_line(b0, b0 + Vector2(bar, 0), TXT, maxf(2.0, 3.0 * _s))
		_overlay.draw_line(b0, b0 - Vector2(0, 8 * _s), TXT, maxf(2.0, 3.0 * _s))
		_overlay.draw_line(b0 + Vector2(bar, 0), b0 + Vector2(bar, -8 * _s), TXT, maxf(2.0, 3.0 * _s))
		_text(b0 + Vector2(bar * 0.5, -14 * _s), "%d km" % km, 15.0, TXT, true)
		_text(br.position + Vector2(28 * _s, br.size.y - 30 * _s),
			"WHEEL / +  −  / LB RB  zoom      M / SELECT  close", 14.0, Color(1, 1, 1, 0.7), true, false)
		# Legend
		var lg := br.position + Vector2(br.size.x - 300 * _s, 40 * _s)
		_airfield_icon(lg, "raf", 8 * _s)
		_text(lg + Vector2(18 * _s, 6 * _s), "RAF airfield", 14.0, TXT, false, false)
		_airfield_icon(lg + Vector2(0, 28 * _s), "lw", 7 * _s)
		_text(lg + Vector2(18 * _s, 34 * _s), "Luftwaffe airfield", 14.0, TXT, false, false)
		_arrow(lg + Vector2(150 * _s, 0), Vector2.UP, 8 * _s, ENEMY)
		_text(lg + Vector2(166 * _s, 6 * _s), "Enemy", 14.0, TXT, false, false)
		_arrow(lg + Vector2(150 * _s, 28 * _s), Vector2.UP, 8 * _s, ALLY)
		_text(lg + Vector2(166 * _s, 34 * _s), "Friendly", 14.0, TXT, false, false)

static func _nice_km(v: float) -> int:
	for k in [1, 2, 5, 10, 20, 50, 100, 200, 500]:
		if k >= v * 0.6:
			return k
	return 500

## Draws cities, airfields, ships and aircraft into one map window
func _draw_layer(wc: Vector2, wh: Vector2, half_m: float, centre_px: Vector2, inside: Callable, big: bool) -> void:
	var pop_min := 250000
	if big:
		pop_min = 1500000 if half_m > 300000.0 else (300000 if half_m > 120000.0 else 40000)
	var fsize := 15.0 if big else 12.0
	for pl in _geo.places:
		if pl[2] < pop_min:
			continue
		var p := _to_screen(pl[1], wc, wh, half_m, centre_px)
		if not inside.call(p):
			continue
		_overlay.draw_circle(p, 3.0 * _s, Color(0.2, 0.18, 0.18))
		_text(p + Vector2(0, -7 * _s), pl[0], fsize if pl[2] < 1000000 else fsize + 3.0, TXT, pl[2] >= 1000000)
	for a in _airfields:
		var p := _to_screen(a[2], wc, wh, half_m, centre_px)
		if not inside.call(p):
			continue
		_airfield_icon(p, a[1], (7.0 if big else 5.5) * _s)
		if big and half_m < 160000.0:
			_text(p + Vector2(0, 22 * _s), a[0], 12.0, Color(0.92, 0.94, 1.0) if a[1] == "raf" else Color(1.0, 0.86, 0.82))
	for sh in get_tree().get_nodes_in_group("ships"):
		if not is_instance_valid(sh):
			continue
		var w := WorldOrigin.to_world((sh as Node3D).global_position)
		var p := _to_screen(Vector2(w.x, w.z), wc, wh, half_m, centre_px)
		if inside.call(p):
			var q := 4.0 * _s
			_overlay.draw_colored_polygon(PackedVector2Array([p + Vector2(0, -q), p + Vector2(q, 0),
				p + Vector2(0, q), p + Vector2(-q, 0)]), SHIP)
	if mission != null and mission.target != Vector2.INF:
		var tp := _to_screen(mission.target, wc, wh, half_m, centre_px)
		if inside.call(tp):
			var rr := maxf(mission.target_radius / half_m * wh.y, 7.0 * _s)
			_overlay.draw_arc(tp, rr, 0.0, TAU, 32, Color(0, 0, 0, 0.6), maxf(2.0, 5.0 * _s))
			_overlay.draw_arc(tp, rr, 0.0, TAU, 32, TARGET, maxf(1.5, 2.5 * _s))
			_overlay.draw_line(tp - Vector2(rr + 6 * _s, 0), tp + Vector2(rr + 6 * _s, 0), TARGET, maxf(1.0, 1.5 * _s))
			_overlay.draw_line(tp - Vector2(0, rr + 6 * _s), tp + Vector2(0, rr + 6 * _s), TARGET, maxf(1.0, 1.5 * _s))
			if big:
				_text(tp + Vector2(0, -rr - 12 * _s), mission.target_name.to_upper(), 14.0, TARGET, true)
	for group in [["allies", ALLY], ["enemies", ENEMY]]:
		for e in get_tree().get_nodes_in_group(group[0]):
			if not is_instance_valid(e) or e.get("_dead") == true:
				continue
			var w := WorldOrigin.to_world((e as Node3D).global_position)
			var p := _to_screen(Vector2(w.x, w.z), wc, wh, half_m, centre_px)
			if inside.call(p):
				var size := (7.0 if e.is_in_group("fighters") else 9.0) * _s
				_arrow(p, _screen_dir(e), size, group[1])
	# The player, always on top
	_arrow(wc, _screen_dir(plane), 11.0 * _s, PLAYER)
