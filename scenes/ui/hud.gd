extends CanvasLayer
## Heads-up display: flight data, radar, nav ball, heading card, damage
## diagram, fuel/ammo, gunsight and warnings.  Everything is drawn in code
## and scaled from a 2560×1440 reference layout.
##
## Draw order: _back (panels, gauges)  →  _ball (nav ball shader)  →  _front
## (ball markings, gunsight, warnings).

const NAVBALL_SHADER := preload("res://scenes/ui/navball.gdshader")

const REF := Vector2(2560, 1440)
const PANEL_H := 250.0
const PANEL_BOTTOM := 26.0
const CLUSTER_W := 720.0
const SIDE_W := 340.0
const GAP := 18.0
const BALL_R := 86.0
const DIAL_R := 76.0
const RADAR_RANGE := 3000.0

const TXT        := Color(0.92, 0.94, 0.96)
const TXT_DIM    := Color(0.62, 0.67, 0.72)
const ACCENT     := Color(1.0, 0.80, 0.25)
const GOOD       := Color(0.46, 0.86, 0.52)
const WARN       := Color(1.0, 0.72, 0.22)
const BAD        := Color(0.98, 0.32, 0.26)
const PANEL_COL  := Color(0.04, 0.05, 0.07, 0.74)
const RADAR_COL  := Color(0.36, 0.95, 0.55)

var plane: Node3D
var camera: Camera3D

## Set each frame by main.gd — drives the in-cloud whiteout (0 = clear, 1 = dense)
var cloud_fog : float = 0.0

var _back : Control
var _ball : ColorRect
var _front : Control
var _ball_mat : ShaderMaterial
var _font : Font
var _font_bold : Font
var _panel_style : StyleBoxFlat
var _s := 1.0
var _origin := Vector2.ZERO
var _sweep := 0.0
var _blink := 0.0

func _ready() -> void:
	_font = _make_font(500)
	_font_bold = _make_font(700)
	_panel_style = StyleBoxFlat.new()
	_panel_style.bg_color = PANEL_COL
	_panel_style.border_color = Color(1, 1, 1, 0.07)
	_panel_style.set_border_width_all(1)
	_panel_style.anti_aliasing = true

	_back = _layer("Back")
	_back.draw.connect(_draw_back)

	_ball = ColorRect.new()
	_ball.name = "NavBall"
	_ball.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ball_mat = ShaderMaterial.new()
	_ball_mat.shader = NAVBALL_SHADER
	_ball.material = _ball_mat
	add_child(_ball)

	_front = _layer("Front")
	_front.draw.connect(_draw_front)

func _make_font(weight: int) -> Font:
	var f := SystemFont.new()
	f.font_names = PackedStringArray(["Bahnschrift", "DIN Alternate", "Segoe UI", "Helvetica Neue", "Arial"])
	f.font_weight = weight
	f.antialiasing = TextServer.FONT_ANTIALIASING_GRAY
	return f

func _layer(name_: String) -> Control:
	var c := Control.new()
	c.name = name_
	c.set_anchors_preset(Control.PRESET_FULL_RECT)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(c)
	return c

func _process(delta: float) -> void:
	_sweep = fmod(_sweep + delta * TAU / 2.5, TAU)
	_blink += delta
	if not is_instance_valid(plane):
		_ball.visible = false
		return
	var vp := get_viewport().get_visible_rect().size
	_s = minf(vp.x / REF.x, vp.y / REF.y)
	_origin = Vector2((vp.x - REF.x * _s) * 0.5, vp.y - REF.y * _s)

	var b := plane.global_transform.basis
	_ball_mat.set_shader_parameter("b_right", b.x)
	_ball_mat.set_shader_parameter("b_up", b.y)
	_ball_mat.set_shader_parameter("b_fwd", -b.z)
	var c := _ball_centre()
	var r := BALL_R * _s
	_ball.position = c - Vector2(r, r)
	_ball.size = Vector2(r, r) * 2.0
	_ball.visible = true

	_back.queue_redraw()
	_front.queue_redraw()

# ---------------------------------------------------------------------------
# Layout helpers (reference coordinates → screen)
# ---------------------------------------------------------------------------

func _p(x: float, y: float) -> Vector2:
	return _origin + Vector2(x, y) * _s

func _cluster_rect() -> Rect2:
	var x := (REF.x - CLUSTER_W) * 0.5
	return Rect2(_p(x, REF.y - PANEL_BOTTOM - PANEL_H), Vector2(CLUSTER_W, PANEL_H) * _s)

func _left_rect() -> Rect2:
	var x := (REF.x - CLUSTER_W) * 0.5 - GAP - SIDE_W
	return Rect2(_p(x, REF.y - PANEL_BOTTOM - PANEL_H), Vector2(SIDE_W, PANEL_H) * _s)

func _right_rect() -> Rect2:
	var x := (REF.x + CLUSTER_W) * 0.5 + GAP
	return Rect2(_p(x, REF.y - PANEL_BOTTOM - PANEL_H), Vector2(SIDE_W, PANEL_H) * _s)

func _ball_centre() -> Vector2:
	return _p(REF.x * 0.5, REF.y - PANEL_BOTTOM - PANEL_H * 0.5 + 14.0)

func _radar_centre() -> Vector2:
	return _p(REF.x * 0.5 - 245.0, REF.y - PANEL_BOTTOM - PANEL_H * 0.5 + 8.0)

func _heading_centre() -> Vector2:
	return _p(REF.x * 0.5 + 245.0, REF.y - PANEL_BOTTOM - PANEL_H * 0.5 + 8.0)

func _panel(ci: Control, rect: Rect2) -> void:
	_panel_style.set_corner_radius_all(int(16 * _s))
	ci.draw_style_box(_panel_style, rect)

func _text(ci: Control, pos: Vector2, text: String, size: float, col: Color,
		align := HORIZONTAL_ALIGNMENT_LEFT, bold := false, width := -1.0) -> void:
	var f := _font_bold if bold else _font
	var w := width
	if align != HORIZONTAL_ALIGNMENT_LEFT and w < 0.0:
		w = 400.0 * _s
		if align == HORIZONTAL_ALIGNMENT_CENTER:
			pos.x -= w * 0.5
		else:
			pos.x -= w
	ci.draw_string(f, pos, text, align, w, int(size * _s), col)

func _caption(ci: Control, centre_x: float, y: float, text: String) -> void:
	_text(ci, Vector2(centre_x, y), text, 13.0, TXT_DIM, HORIZONTAL_ALIGNMENT_CENTER, true)

static func _health_color(ratio: float) -> Color:
	if ratio <= 0.0:
		return Color(0.30, 0.08, 0.07)
	if ratio < 0.5:
		return BAD.lerp(WARN, ratio * 2.0)
	return WARN.lerp(GOOD, (ratio - 0.5) * 2.0)

func _bar(ci: Control, rect: Rect2, ratio: float, col: Color, segments := 0) -> void:
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(1, 1, 1, 0.08)
	bg.set_corner_radius_all(int(rect.size.y * 0.5))
	bg.anti_aliasing = true
	ci.draw_style_box(bg, rect)
	if ratio > 0.0:
		var fill := bg.duplicate() as StyleBoxFlat
		fill.bg_color = col
		ci.draw_style_box(fill, Rect2(rect.position, Vector2(maxf(rect.size.x * ratio, rect.size.y), rect.size.y)))
	for i in range(1, segments):
		var x := rect.position.x + rect.size.x * i / segments
		ci.draw_line(Vector2(x, rect.position.y), Vector2(x, rect.end.y), Color(0, 0, 0, 0.35), maxf(1.0, 1.5 * _s))

# ---------------------------------------------------------------------------
# Back layer
# ---------------------------------------------------------------------------

func _draw_back() -> void:
	if not is_instance_valid(plane):
		return
	var vp := get_viewport().get_visible_rect().size
	# In-cloud whiteout — drawn first so instruments stay legible on top
	if cloud_fog > 0.01:
		_back.draw_rect(Rect2(Vector2.ZERO, vp), Color(0.90, 0.93, 0.97, minf(cloud_fog * 0.94, 0.94)))

	_panel(_back, _left_rect())
	_panel(_back, _cluster_rect())
	_panel(_back, _right_rect())
	_draw_flight_data(_left_rect())
	_draw_radar(_radar_centre(), DIAL_R * _s)
	_draw_heading(_heading_centre(), DIAL_R * _s)
	_draw_status(_right_rect())

	var top := _cluster_rect().position.y + 22.0 * _s
	_caption(_back, _radar_centre().x, top, "RADAR")
	_caption(_back, _ball_centre().x, top, "ATTITUDE")
	_caption(_back, _heading_centre().x, top, "HEADING")

	_text(_back, Vector2(vp.x - 14.0 * _s, 26.0 * _s), "%d FPS" % Engine.get_frames_per_second(),
		13.0, Color(1, 1, 1, 0.45), HORIZONTAL_ALIGNMENT_RIGHT)

func _draw_flight_data(rect: Rect2) -> void:
	var x0 := rect.position.x + 24.0 * _s
	var y0 := rect.position.y
	var speed := int(plane.airspeed_display * 2.23694)
	var alt := int(plane.altitude * 3.28084)
	var vs := int(plane.velocity.y * 196.85)
	var g : float = plane.g_force

	_text(_back, Vector2(x0, y0 + 30 * _s), "AIRSPEED", 13.0, TXT_DIM, HORIZONTAL_ALIGNMENT_LEFT, true)
	_text(_back, Vector2(x0, y0 + 76 * _s), "%d" % speed, 44.0, TXT, HORIZONTAL_ALIGNMENT_LEFT, true)
	_text(_back, Vector2(x0 + 118 * _s, y0 + 76 * _s), "MPH", 14.0, TXT_DIM)

	_text(_back, Vector2(x0, y0 + 118 * _s), "ALTITUDE", 13.0, TXT_DIM, HORIZONTAL_ALIGNMENT_LEFT, true)
	_text(_back, Vector2(x0, y0 + 164 * _s), _thousands(alt), 44.0, TXT, HORIZONTAL_ALIGNMENT_LEFT, true)
	_text(_back, Vector2(x0 + 150 * _s, y0 + 164 * _s), "FT", 14.0, TXT_DIM)

	# Vertical speed with an arrow
	var vs_col := TXT if absi(vs) < 3000 else WARN
	var ax := x0 + 6.0 * _s
	var ay := y0 + 204.0 * _s
	var up := vs >= 0
	var tri := PackedVector2Array([Vector2(ax, ay + (-7 if up else 7) * _s),
		Vector2(ax - 6 * _s, ay + (5 if up else -5) * _s), Vector2(ax + 6 * _s, ay + (5 if up else -5) * _s)])
	_back.draw_colored_polygon(tri, vs_col)
	_text(_back, Vector2(x0 + 20 * _s, y0 + 210 * _s), "%+d FPM" % vs, 17.0, vs_col)

	# G meter
	var g_col := TXT if g < 5.0 and g > -1.5 else (WARN if g < 7.0 else BAD)
	_text(_back, Vector2(x0 + 150 * _s, y0 + 210 * _s), "%.1f G" % g, 17.0, g_col, HORIZONTAL_ALIGNMENT_LEFT, true)

	# Throttle: vertical bar on the right of the panel
	var bx := rect.end.x - 56.0 * _s
	var bar := Rect2(Vector2(bx, y0 + 46 * _s), Vector2(18, 150) * _s)
	var thr : float = plane.throttle
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(1, 1, 1, 0.08)
	bg.set_corner_radius_all(int(9 * _s))
	_back.draw_style_box(bg, bar)
	if thr > 0.0:
		var fill := bg.duplicate() as StyleBoxFlat
		fill.bg_color = ACCENT
		var h := maxf(bar.size.y * thr, 18.0 * _s)
		_back.draw_style_box(fill, Rect2(Vector2(bar.position.x, bar.end.y - h), Vector2(bar.size.x, h)))
	_text(_back, Vector2(bx + 9 * _s, y0 + 30 * _s), "THR", 13.0, TXT_DIM, HORIZONTAL_ALIGNMENT_CENTER, true)
	_text(_back, Vector2(bx + 9 * _s, y0 + 222 * _s), "%d%%" % int(thr * 100), 15.0, TXT, HORIZONTAL_ALIGNMENT_CENTER)

static func _thousands(n: int) -> String:
	var s := str(absi(n))
	var out := ""
	while s.length() > 3:
		out = "," + s.substr(s.length() - 3) + out
		s = s.substr(0, s.length() - 3)
	return ("-" if n < 0 else "") + s + out

# ---------------------------------------------------------------------------
# Radar
# ---------------------------------------------------------------------------

func _draw_radar(c: Vector2, r: float) -> void:
	var lw := maxf(1.0, 1.4 * _s)
	_back.draw_circle(c, r, Color(0.02, 0.09, 0.05, 0.92))
	for k in [1.0 / 3.0, 2.0 / 3.0]:
		_back.draw_arc(c, r * k, 0.0, TAU, 48, Color(RADAR_COL, 0.18), lw)
	_back.draw_line(c - Vector2(r, 0), c + Vector2(r, 0), Color(RADAR_COL, 0.12), lw)
	_back.draw_line(c - Vector2(0, r), c + Vector2(0, r), Color(RADAR_COL, 0.12), lw)

	# Rotating sweep with a fading wedge behind it
	for i in range(14):
		var a := _sweep - i * 0.045
		_back.draw_line(c, c + Vector2(cos(a), sin(a)) * r, Color(RADAR_COL, 0.32 * (1.0 - i / 14.0)), maxf(1.0, 2.5 * _s))

	var fwd := -plane.global_transform.basis.z
	var fwd_h := Vector3(fwd.x, 0, fwd.z).normalized()
	var right_h := Vector3(-fwd_h.z, 0, fwd_h.x)
	for e in get_tree().get_nodes_in_group("enemies"):
		if not is_instance_valid(e) or e.get("_dead") == true:
			continue
		var rel : Vector3 = e.global_position - plane.global_position
		var blip := Vector2(rel.dot(right_h), -rel.dot(fwd_h)) * (r / RADAR_RANGE)
		var clipped := blip.length() > r - 6.0 * _s
		if clipped:
			blip = blip.normalized() * (r - 6.0 * _s)
		var pos := c + blip
		var col := BAD if not clipped else Color(BAD, 0.55)
		var sz := 4.5 * _s
		if e.is_in_group("enemy_fighters"):
			_back.draw_colored_polygon(PackedVector2Array([pos + Vector2(0, -sz * 1.2), pos + Vector2(sz, sz * 0.8),
				pos + Vector2(-sz, sz * 0.8)]), col)
		else:
			_back.draw_rect(Rect2(pos - Vector2(sz, sz), Vector2(sz, sz) * 2.0), col)
		# Above / below marker
		if absf(rel.y) > 150.0:
			var mark := "+" if rel.y > 0.0 else "-"
			_text(_back, pos + Vector2(sz + 2 * _s, 4 * _s), mark, 13.0, col, HORIZONTAL_ALIGNMENT_LEFT, true)

	# Own aircraft
	var ps := 6.0 * _s
	_back.draw_colored_polygon(PackedVector2Array([c + Vector2(0, -ps * 1.3), c + Vector2(ps, ps),
		c + Vector2(0, ps * 0.4), c + Vector2(-ps, ps)]), RADAR_COL)
	_back.draw_arc(c, r, 0.0, TAU, 64, Color(RADAR_COL, 0.55), maxf(1.0, 2.0 * _s))
	_text(_back, c + Vector2(0, r + 20 * _s), "%.0f KM" % (RADAR_RANGE / 1000.0), 12.0, TXT_DIM, HORIZONTAL_ALIGNMENT_CENTER)

# ---------------------------------------------------------------------------
# Heading card
# ---------------------------------------------------------------------------

## Compass heading in degrees: north = +Z, east = -X (see dover_geo.gd)
func _heading_deg() -> float:
	var f := -plane.global_transform.basis.z
	return fposmod(rad_to_deg(atan2(-f.x, f.z)), 360.0)

func _draw_heading(c: Vector2, r: float) -> void:
	var hdg := _heading_deg()
	_back.draw_circle(c, r, Color(0.04, 0.05, 0.07, 0.92))
	for deg in range(0, 360, 5):
		var a := deg_to_rad(deg - hdg) - PI * 0.5
		var dir := Vector2(cos(a), sin(a))
		var len := (12.0 if deg % 30 == 0 else (7.0 if deg % 10 == 0 else 4.0)) * _s
		var col := Color(1, 1, 1, 0.85 if deg % 30 == 0 else 0.45)
		_back.draw_line(c + dir * (r - 3 * _s), c + dir * (r - 3 * _s - len), col, maxf(1.0, (2.0 if deg % 30 == 0 else 1.2) * _s))
	var names := {0: "N", 90: "E", 180: "S", 270: "W", 30: "3", 60: "6", 120: "12", 150: "15", 210: "21", 240: "24", 300: "30", 330: "33"}
	for deg in names:
		var a := deg_to_rad(deg - hdg) - PI * 0.5
		var pos := c + Vector2(cos(a), sin(a)) * (r - 26 * _s)
		var cardinal : bool = deg % 90 == 0
		var col := BAD if deg == 0 else (TXT if cardinal else TXT_DIM)
		_text(_back, pos + Vector2(0, 6 * _s), names[deg], 17.0 if cardinal else 12.0, col,
			HORIZONTAL_ALIGNMENT_CENTER, cardinal)
	# Lubber mark and digital readout
	var tip := c + Vector2(0, -r + 2 * _s)
	_back.draw_colored_polygon(PackedVector2Array([tip, tip + Vector2(-7, -9) * _s, tip + Vector2(7, -9) * _s]), ACCENT)
	var box := Rect2(c - Vector2(30, 15) * _s, Vector2(60, 30) * _s)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0.75)
	sb.border_color = Color(ACCENT, 0.8)
	sb.set_border_width_all(maxi(1, int(1.5 * _s)))
	sb.set_corner_radius_all(int(6 * _s))
	_back.draw_style_box(sb, box)
	_text(_back, c + Vector2(0, 8 * _s), "%03d" % (int(round(hdg)) % 360), 20.0, TXT, HORIZONTAL_ALIGNMENT_CENTER, true)
	_back.draw_arc(c, r, 0.0, TAU, 64, Color(1, 1, 1, 0.25), maxf(1.0, 2.0 * _s))

# ---------------------------------------------------------------------------
# Damage diagram, fuel and ammunition
# ---------------------------------------------------------------------------

func _draw_status(rect: Rect2) -> void:
	var comp : Dictionary = plane.get("comp_hp") if "comp_hp" in plane else {}
	var cmax : float = float(plane.get("COMP_MAX")) if "COMP_MAX" in plane else 4.0
	var fire : bool = plane.get("_on_fire") == true
	var hp := func(k: String) -> float: return float(comp.get(k, cmax)) / cmax

	# Top-down Spitfire silhouette, parts coloured by their health
	var o := rect.position + Vector2(82, 132) * _s
	var k := 1.55 * _s
	var poly := func(pts: Array) -> PackedVector2Array:
		var out := PackedVector2Array()
		for q in pts:
			out.append(o + (q as Vector2) * k)
		return out
	var wing_pts : Array = []
	for i in range(13):
		var t := float(i) / 12.0
		var x := lerpf(-52.0, 52.0, t)
		var ch := 15.0 * sqrt(maxf(0.0, 1.0 - pow(x / 53.0, 2.0)))
		wing_pts.append(Vector2(x, -ch * 0.35))
	for i in range(12, -1, -1):
		var t := float(i) / 12.0
		var x := lerpf(-52.0, 52.0, t)
		var ch := 15.0 * sqrt(maxf(0.0, 1.0 - pow(x / 53.0, 2.0)))
		wing_pts.append(Vector2(x, ch * 0.65))
	var wing_col := _health_color(hp.call("wing"))
	_back.draw_colored_polygon(poly.call(wing_pts), wing_col)
	var body := Color(0.55, 0.60, 0.65)
	_back.draw_colored_polygon(poly.call([Vector2(-5, -18), Vector2(5, -18), Vector2(5.5, 10), Vector2(2.5, 50), Vector2(-2.5, 50), Vector2(-5.5, 10)]), body)
	var fuel_col := _health_color(hp.call("fuel_tank"))
	if fire and fmod(_blink, 0.5) < 0.25:
		fuel_col = Color(1.0, 0.55, 0.1)
	_back.draw_colored_polygon(poly.call([Vector2(-5, -17), Vector2(5, -17), Vector2(5.2, -4), Vector2(-5.2, -4)]), fuel_col)
	_back.draw_colored_polygon(poly.call([Vector2(-4.2, -38), Vector2(4.2, -38), Vector2(5, -19), Vector2(-5, -19)]),
		_health_color(hp.call("engine")))
	var tail : Array = []
	for i in range(9):
		var x := lerpf(-17.0, 17.0, i / 8.0)
		tail.append(Vector2(x, 44.0 - 4.5 * sqrt(maxf(0.0, 1.0 - pow(x / 17.5, 2.0)))))
	for i in range(8, -1, -1):
		var x := lerpf(-17.0, 17.0, i / 8.0)
		tail.append(Vector2(x, 44.0 + 6.0 * sqrt(maxf(0.0, 1.0 - pow(x / 17.5, 2.0)))))
	_back.draw_colored_polygon(poly.call(tail), _health_color(hp.call("elevator")))
	_back.draw_colored_polygon(poly.call([Vector2(-1.3, 38), Vector2(1.3, 38), Vector2(1.3, 56), Vector2(-1.3, 56)]),
		_health_color(hp.call("rudder")))
	_text(_back, Vector2(o.x, rect.position.y + 30 * _s), "DAMAGE", 13.0, TXT_DIM, HORIZONTAL_ALIGNMENT_CENTER, true)
	if fire:
		_text(_back, Vector2(o.x, rect.end.y - 18 * _s), "FIRE", 16.0, BAD, HORIZONTAL_ALIGNMENT_CENTER, true)

	# Fuel and ammunition bars
	var bx := rect.position.x + 166.0 * _s
	var bw := rect.end.x - bx - 22.0 * _s
	var fuel : float = plane.get("fuel") if "fuel" in plane else 0.0
	var fmax : float = plane.get("MAX_FUEL") if "MAX_FUEL" in plane else 1.0
	var fr := clampf(fuel / fmax, 0.0, 1.0)
	var fcol := GOOD if fr > 0.4 else (WARN if fr > 0.15 else BAD)
	var gun : int = plane.get("gun_ammo") if "gun_ammo" in plane else 0
	var gmax : int = plane.get("GUN_AMMO_MAX") if "GUN_AMMO_MAX" in plane else 1
	var can : int = plane.get("cannon_ammo") if "cannon_ammo" in plane else 0
	var cmax2 : int = plane.get("CANNON_AMMO_MAX") if "CANNON_AMMO_MAX" in plane else 1
	var rows := [
		["FUEL", "%d%%" % int(fr * 100.0), fr, fcol, 0],
		[".303 MG", str(gun), float(gun) / gmax, Color(0.86, 0.88, 0.90) if gun > gmax * 0.2 else WARN, 8],
		["20 MM", str(can), float(can) / cmax2, Color(1.0, 0.62, 0.30) if can > cmax2 * 0.2 else WARN, 6],
	]
	for i in range(rows.size()):
		var row : Array = rows[i]
		var y := rect.position.y + (40.0 + i * 68.0) * _s
		_text(_back, Vector2(bx, y + 16 * _s), row[0], 13.0, TXT_DIM, HORIZONTAL_ALIGNMENT_LEFT, true)
		_text(_back, Vector2(bx + bw, y + 16 * _s), row[1], 17.0, TXT, HORIZONTAL_ALIGNMENT_RIGHT, true)
		_bar(_back, Rect2(Vector2(bx, y + 28 * _s), Vector2(bw, 12 * _s)), row[2], row[3], row[4])

# ---------------------------------------------------------------------------
# Front layer: nav ball markings, gunsight, warnings
# ---------------------------------------------------------------------------

func _draw_front() -> void:
	if not is_instance_valid(plane):
		return
	_draw_ball_overlay(_ball_centre(), BALL_R * _s)
	_draw_gunsight()
	if plane.is_stalling and fmod(_blink, 0.6) < 0.4:
		var vp := get_viewport().get_visible_rect().size
		var box := Rect2(Vector2(vp.x * 0.5 - 90 * _s, 120 * _s), Vector2(180, 48) * _s)
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(BAD, 0.85)
		sb.set_corner_radius_all(int(24 * _s))
		_front.draw_style_box(sb, box)
		_text(_front, Vector2(vp.x * 0.5, 154 * _s), "STALL", 26.0, Color.WHITE, HORIZONTAL_ALIGNMENT_CENTER, true)

## World direction → point on the nav ball (null if on the far side)
func _ball_point(c: Vector2, r: float, dir: Vector3, min_z := 0.12) -> Variant:
	var b := plane.global_transform.basis
	var lz := dir.dot(-b.z)
	if lz < min_z:
		return null
	return c + Vector2(dir.dot(b.x), -dir.dot(b.y)) * r

func _draw_ball_overlay(c: Vector2, r: float) -> void:
	var b := plane.global_transform.basis
	var fwd := -b.z
	var lw := maxf(1.0, 2.0 * _s)

	# Pitch ladder numbers along the meridian through the nose
	var flat := Vector3(fwd.x, 0, fwd.z)
	if flat.length() < 0.05:
		flat = Vector3(b.y.x, 0, b.y.z) * signf(-fwd.y)    # looking straight up/down
	flat = flat.normalized()
	var side := flat.cross(Vector3.UP)
	for deg in [-60, -30, 30, 60]:
		var a := deg_to_rad(deg)
		var d := flat * cos(a) + Vector3.UP * sin(a)
		var p = _ball_point(c, r, d, 0.5)
		if p == null:
			continue
		var tang = _ball_point(c, r, (d + side * 0.12).normalized(), 0.0)
		var t := Vector2.RIGHT if tang == null else ((tang as Vector2) - (p as Vector2)).normalized()
		for sgn in [-1.0, 1.0]:
			_text(_front, (p as Vector2) + t * sgn * r * 0.36 + Vector2(0, 5 * _s), str(absi(deg)), 12.0,
				Color(1, 1, 1, 0.85), HORIZONTAL_ALIGNMENT_CENTER, true)

	# Cardinal letters on the horizon
	for item in [["N", Vector3(0, 0, 1)], ["E", Vector3(-1, 0, 0)], ["S", Vector3(0, 0, -1)], ["W", Vector3(1, 0, 0)]]:
		var p = _ball_point(c, r, item[1], 0.2)
		if p != null:
			_text(_front, (p as Vector2) + Vector2(0, -6 * _s), item[0], 15.0,
				BAD if item[0] == "N" else Color.WHITE, HORIZONTAL_ALIGNMENT_CENTER, true)

	# Flight-path marker: where the aircraft is actually going
	if plane.velocity.length() > 5.0:
		var p = _ball_point(c, r, plane.velocity.normalized(), 0.05)
		if p != null:
			var q : Vector2 = p
			var green := Color(0.45, 1.0, 0.55)
			_front.draw_arc(q, 7 * _s, 0.0, TAU, 20, green, lw)
			_front.draw_line(q + Vector2(7, 0) * _s, q + Vector2(16, 0) * _s, green, lw)
			_front.draw_line(q - Vector2(7, 0) * _s, q - Vector2(16, 0) * _s, green, lw)
			_front.draw_line(q - Vector2(0, 7) * _s, q - Vector2(0, 13) * _s, green, lw)

	# Roll scale on the bezel; the sky pointer points at true "up"
	var bezel := Color(1, 1, 1, 0.75)
	for deg in [-60, -45, -30, -20, -10, 0, 10, 20, 30, 45, 60]:
		var a := deg_to_rad(deg) - PI * 0.5
		var dir := Vector2(cos(a), sin(a))
		var len := (14.0 if absi(deg) % 30 == 0 else 8.0) * _s
		_front.draw_line(c + dir * (r + 4 * _s), c + dir * (r + 4 * _s + len), bezel, lw)
	var up2 := Vector2(Vector3.UP.dot(b.x), -Vector3.UP.dot(b.y))
	if up2.length() > 0.02:
		var ua := up2.angle()
		var ud := Vector2(cos(ua), sin(ua))
		var un := Vector2(-ud.y, ud.x)
		var tip := c + ud * (r + 3 * _s)
		_front.draw_colored_polygon(PackedVector2Array([tip, tip + ud * 13 * _s + un * 8 * _s,
			tip + ud * 13 * _s - un * 8 * _s]), ACCENT)
	_front.draw_arc(c, r + 1.5 * _s, 0.0, TAU, 72, Color(0.02, 0.03, 0.04), maxf(2.0, 4.0 * _s))

	# Fixed aircraft symbol
	var yw := maxf(2.0, 4.0 * _s)
	_front.draw_line(c + Vector2(-44, 0) * _s, c + Vector2(-16, 0) * _s, ACCENT, yw)
	_front.draw_line(c + Vector2(-16, 0) * _s, c + Vector2(-8, 8) * _s, ACCENT, yw)
	_front.draw_line(c + Vector2(-8, 8) * _s, c, ACCENT, yw)
	_front.draw_line(c, c + Vector2(8, 8) * _s, ACCENT, yw)
	_front.draw_line(c + Vector2(8, 8) * _s, c + Vector2(16, 0) * _s, ACCENT, yw)
	_front.draw_line(c + Vector2(16, 0) * _s, c + Vector2(44, 0) * _s, ACCENT, yw)
	_front.draw_circle(c, 3.5 * _s, ACCENT)

	# Pitch and bank readouts under the ball
	var pitch := rad_to_deg(asin(clampf(fwd.y, -1.0, 1.0)))
	var bank := rad_to_deg(atan2(-b.x.y, b.y.y))
	_text(_front, c + Vector2(-r - 14 * _s, r * 0.95), "PITCH", 11.0, TXT_DIM, HORIZONTAL_ALIGNMENT_RIGHT, true)
	_text(_front, c + Vector2(-r - 14 * _s, r * 0.95 + 18 * _s), "%+d°" % int(round(pitch)), 16.0, TXT, HORIZONTAL_ALIGNMENT_RIGHT, true)
	_text(_front, c + Vector2(r + 14 * _s, r * 0.95), "BANK", 11.0, TXT_DIM, HORIZONTAL_ALIGNMENT_LEFT, true)
	_text(_front, c + Vector2(r + 14 * _s, r * 0.95 + 18 * _s), "%+d°" % int(round(bank)), 16.0, TXT, HORIZONTAL_ALIGNMENT_LEFT, true)

## Reflector gunsight at the bullet convergence point
func _draw_gunsight() -> void:
	if not camera:
		return
	var fwd := -plane.global_transform.basis.z
	var bullet_dir : Vector3 = (plane.velocity + fwd * 800.0).normalized()
	var aim := plane.global_position + bullet_dir * 2000.0
	if (aim - camera.global_position).dot(-camera.global_transform.basis.z) <= 0.0:
		return
	var pos := camera.unproject_position(aim)
	var col := Color(1.0, 0.62, 0.28, 0.9)
	var lw := maxf(1.0, 2.0 * _s)
	var r := 30.0 * _s
	_front.draw_arc(pos, r, 0.0, TAU, 48, col, lw)
	for a in [0.0, PI * 0.5, PI, PI * 1.5]:
		var d := Vector2(cos(a), sin(a))
		_front.draw_line(pos + d * (r - 8 * _s), pos + d * (r + 8 * _s), col, lw)
	_front.draw_circle(pos, 2.5 * _s, col)
