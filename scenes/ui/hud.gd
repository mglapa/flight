extends CanvasLayer
## Heads-up display — text readouts plus graphical compass and attitude indicator.

@onready var speed_label: Label = $MarginContainer/VBoxContainer/SpeedLabel
@onready var altitude_label: Label = $MarginContainer/VBoxContainer/AltitudeLabel
@onready var throttle_label: Label = $MarginContainer/VBoxContainer/ThrottleLabel
@onready var g_force_label: Label = $MarginContainer/VBoxContainer/GForceLabel
@onready var stall_warning: Label = $StallWarning
@onready var fps_label: Label = $FPSLabel
@onready var draw_layer: Control = $DrawLayer

var plane: Node3D
var camera: Camera3D

## Scale factor relative to the 2560×1440 reference resolution.
## Recomputed every frame so the HUD adapts instantly to resolution changes.
var _hud_scale : float = 1.0

func _ready() -> void:
	draw_layer.draw.connect(_draw_instruments)

func _process(_delta: float) -> void:
	if not plane:
		return

	var speed_mph := int(plane.airspeed_display * 2.23694)
	var alt_ft    := int(plane.altitude * 3.28084)
	var thr_pct   := int(plane.throttle * 100)
	var g         := snappedf(plane.g_force, 0.1)

	speed_label.text    = "SPEED: %d MPH" % speed_mph
	altitude_label.text = "ALT: %d FT" % alt_ft
	throttle_label.text = "THROTTLE: %d%%" % thr_pct
	g_force_label.text  = "G: %.1f" % g

	stall_warning.visible = plane.is_stalling
	fps_label.text = "FPS: %d" % Engine.get_frames_per_second()
	draw_layer.queue_redraw()

# ---------------------------------------------------------------------------
# Instrument drawing — called each frame via DrawLayer's draw signal
# ---------------------------------------------------------------------------

func _draw_instruments() -> void:
	if not plane:
		return
	var basis := plane.global_transform.basis
	var fwd   := -basis.z
	var right := basis.x
	var up    := basis.y

	var pitch   := asin(clampf(fwd.y, -1.0, 1.0))
	var roll    := atan2(-right.y, up.y)
	var heading := atan2(fwd.x, -fwd.z)

	# Scale everything relative to the 2560×1440 reference resolution
	var vp        := get_viewport().get_visible_rect().size
	_hud_scale     = minf(vp.x / 2560.0, vp.y / 1440.0)
	var r         := 80.0  * _hud_scale   # instrument radius
	var gap       := 400.0 * _hud_scale   # centre-to-centre spacing
	var cx        := vp.x * 0.5
	var cy        := vp.y - 120.0 * _hud_scale

	_draw_radar(   Vector2(cx - gap, cy), r)
	_draw_attitude(Vector2(cx,       cy), r, pitch, roll)
	_draw_compass( Vector2(cx + gap, cy), r, heading)
	_draw_crosshair()

func _draw_radar(center: Vector2, radius: float) -> void:
	const RANGE := 5000.0
	var s := _hud_scale

	var font    := ThemeDB.fallback_font
	var dim     := Color(0.00, 0.30, 0.00, 0.50)
	var bright  := Color(0.10, 0.90, 0.10, 0.90)

	draw_layer.draw_circle(center, radius, Color(0.02, 0.07, 0.02))
	draw_layer.draw_arc(center, radius / 3.0,       0.0, TAU, 40, dim, maxf(1.0, 0.8 * s))
	draw_layer.draw_arc(center, radius * 2.0 / 3.0, 0.0, TAU, 40, dim, maxf(1.0, 0.8 * s))
	draw_layer.draw_line(center + Vector2(0, -radius), center + Vector2(0,  radius), dim, maxf(1.0, 0.8 * s))
	draw_layer.draw_line(center + Vector2(-radius, 0), center + Vector2(radius,  0), dim, maxf(1.0, 0.8 * s))

	# Player symbol
	var ps := 7.0 * s
	draw_layer.draw_polygon(
		PackedVector2Array([center + Vector2(0, -ps), center + Vector2(-ps * 0.57, ps * 0.57), center + Vector2(ps * 0.57, ps * 0.57)]),
		PackedColorArray([bright, bright, bright]))

	var fwd_3d  : Vector3 = -plane.global_transform.basis.z
	var fwd_h   : Vector3 = Vector3(fwd_3d.x, 0.0, fwd_3d.z).normalized()
	var right_h : Vector3 = Vector3(-fwd_h.z, 0.0, fwd_h.x)

	for enemy in get_tree().get_nodes_in_group("enemies"):
		if not is_instance_valid(enemy):
			continue
		var rel : Vector3 = enemy.global_position - plane.global_position
		var rx : float = rel.dot(right_h)
		var ry : float = -rel.dot(fwd_h)

		var blip := center + Vector2(rx, ry) * (radius / RANGE)
		var offset := blip - center
		if offset.length() > radius - 4.0 * s:
			blip = center + offset.normalized() * (radius - 4.0 * s)

		var e_col := Color(1.0, 0.20, 0.20, 0.95)
		draw_layer.draw_circle(blip, 3.5 * s, e_col)

		var e_fwd_3d : Vector3 = -enemy.global_transform.basis.z
		var e_fwd_h  : Vector3 = Vector3(e_fwd_3d.x, 0.0, e_fwd_3d.z).normalized()
		var head     := Vector2(e_fwd_h.dot(right_h), -e_fwd_h.dot(fwd_h))
		draw_layer.draw_line(blip, blip + head * 9.0 * s, e_col, maxf(1.0, 1.5 * s))

	draw_layer.draw_arc(center, radius, 0.0, TAU, 64, Color(0.0, 0.55, 0.0, 0.85), maxf(1.0, 2.0 * s))
	draw_layer.draw_string(font, center + Vector2(-16.0 * s, -radius - 10.0 * s),
		"RDR", HORIZONTAL_ALIGNMENT_LEFT, -1, int(14 * s), Color(0.0, 0.85, 0.0, 0.7))

func _draw_crosshair() -> void:
	if not camera:
		return
	var s := _hud_scale

	var fwd         := -plane.global_transform.basis.z
	var bullet_dir: Vector3 = (plane.velocity + fwd * 800.0).normalized()
	var aim_world   := plane.global_position + bullet_dir * 2000.0

	var to_aim := aim_world - camera.global_position
	if to_aim.dot(-camera.global_transform.basis.z) <= 0.0:
		return

	var pos := camera.unproject_position(aim_world)

	var col    := Color(1.0, 1.0, 1.0, 0.85)
	var r      := 22.0 * s
	var gap    :=  8.0 * s
	var tick   := 10.0 * s

	draw_layer.draw_arc(pos, r, 0.0, TAU, 48, col, maxf(1.0, 1.5 * s))
	for angle in [0.0, PI * 0.5, PI, PI * 1.5]:
		var dir2 := Vector2(cos(angle), sin(angle))
		draw_layer.draw_line(
			pos + dir2 * (r + gap),
			pos + dir2 * (r + gap + tick),
			col, maxf(1.0, 1.5 * s))
	draw_layer.draw_circle(pos, 2.5 * s, col)

func _draw_attitude(center: Vector2, radius: float, pitch: float, roll: float) -> void:
	var s := _hud_scale

	draw_layer.draw_circle(center, radius, Color(0.18, 0.38, 0.72))

	var ai_right     := Vector2(cos(roll), -sin(roll))
	var earth_normal := Vector2(sin(roll),  cos(roll))
	var pitch_px     := clampf(pitch * 90.0 * s, -(radius - 4.0), radius - 4.0)
	var h_mid        := center + Vector2(0.0, pitch_px)

	var earth_col := Color(0.48, 0.28, 0.10)
	var d_h := h_mid - center
	var ai_dot := d_h.dot(ai_right)
	var disc := ai_dot * ai_dot - (d_h.length_squared() - (radius - 1.0) * (radius - 1.0))
	if disc < 0.0:
		if earth_normal.dot(d_h) < 0.0:
			draw_layer.draw_circle(center, radius, earth_col)
	else:
		var t1 := -ai_dot - sqrt(disc)
		var t2 := -ai_dot + sqrt(disc)
		var p1 := h_mid + ai_right * t1
		var p2 := h_mid + ai_right * t2
		var a1 := (p1 - center).angle()
		var a2 := (p2 - center).angle()
		var earth_arc_angle := (h_mid + earth_normal * radius - center).angle()
		var to_mid_ccw := fposmod(earth_arc_angle - a1, TAU)
		var a1_to_a2_ccw := fposmod(a2 - a1, TAU)
		var go_ccw := to_mid_ccw < a1_to_a2_ccw
		var earth_pts := PackedVector2Array()
		earth_pts.append(p1)
		var n_steps := 24
		for i in range(n_steps + 1):
			var frac := float(i) / float(n_steps)
			var angle := a1 + (a1_to_a2_ccw if go_ccw else -(TAU - a1_to_a2_ccw)) * frac
			earth_pts.append(center + Vector2(cos(angle), sin(angle)) * (radius - 1.0))
		earth_pts.append(p2)
		var e_colors := PackedColorArray()
		for _i in range(earth_pts.size()):
			e_colors.append(earth_col)
		draw_layer.draw_polygon(earth_pts, e_colors)

	draw_layer.draw_line(
		h_mid + ai_right * radius,
		h_mid - ai_right * radius,
		Color(1.0, 1.0, 1.0, 0.9), maxf(1.0, 2.0 * s))

	var font := ThemeDB.fallback_font
	var pitch_scale := 90.0 * s
	for mark_deg in [-30, -20, -10, 10, 20, 30]:
		var mark_rad_val := deg_to_rad(float(mark_deg))
		var mark_center := h_mid - earth_normal * (mark_rad_val - pitch) * pitch_scale
		if (mark_center - center).length() > radius - 5.0:
			continue
		var half_len := radius * (0.35 if absf(float(mark_deg)) == 30.0 else 0.25)
		var mark_color := Color(1.0, 1.0, 1.0, 0.85)
		draw_layer.draw_line(mark_center - ai_right * half_len,
			mark_center + ai_right * half_len, mark_color, maxf(1.0, 1.5 * s))
		var lbl := "%d" % mark_deg
		draw_layer.draw_string(font,
			mark_center + ai_right * (half_len + 3.0 * s) + Vector2(0.0, 4.0 * s),
			lbl, HORIZONTAL_ALIGNMENT_LEFT, -1, int(10 * s), mark_color)
		draw_layer.draw_string(font,
			mark_center - ai_right * (half_len + 14.0 * s) + Vector2(0.0, 4.0 * s),
			lbl, HORIZONTAL_ALIGNMENT_LEFT, -1, int(10 * s), mark_color)

	draw_layer.draw_arc(center, radius, 0.0, TAU, 64, Color(0.5, 0.5, 0.5, 0.8), maxf(1.0, 2.0 * s))

	# Fixed aircraft symbol
	var yellow := Color(1.0, 0.85, 0.0)
	draw_layer.draw_line(center + Vector2(-30.0 * s, 0.0), center + Vector2(-8.0 * s, 0.0), yellow, maxf(1.0, 3.0 * s))
	draw_layer.draw_line(center + Vector2(  8.0 * s, 0.0), center + Vector2(30.0 * s, 0.0), yellow, maxf(1.0, 3.0 * s))
	draw_layer.draw_circle(center, 4.0 * s, yellow)

	draw_layer.draw_string(font, center + Vector2(-12.0 * s, -radius - 10.0 * s),
		"ATT", HORIZONTAL_ALIGNMENT_LEFT, -1, int(14 * s), Color(1.0, 1.0, 1.0, 0.7))

func _draw_compass(center: Vector2, radius: float, heading: float) -> void:
	var s := _hud_scale
	var font := ThemeDB.fallback_font

	draw_layer.draw_circle(center, radius, Color(0.07, 0.07, 0.10))

	var hdg_deg := rad_to_deg(heading)

	for deg in range(0, 360, 5):
		var screen_a := deg_to_rad(float(deg) - hdg_deg) - PI * 0.5
		var mark_len : float
		if deg % 30 == 0:
			mark_len = 10.0 * s
		elif deg % 10 == 0:
			mark_len = 6.0 * s
		else:
			mark_len = 3.0 * s
		var outer := center + Vector2(cos(screen_a), sin(screen_a)) * (radius - 2.0)
		var inner := center + Vector2(cos(screen_a), sin(screen_a)) * (radius - 2.0 - mark_len)
		draw_layer.draw_line(inner, outer, Color(0.75, 0.75, 0.75), maxf(1.0, 1.2 * s))

	var labels := {"N": 0, "NE": 45, "E": 90, "SE": 135,
				   "S": 180, "SW": 225, "W": 270, "NW": 315}
	for lbl in labels:
		var deg: int = labels[lbl]
		var screen_a := deg_to_rad(float(deg) - hdg_deg) - PI * 0.5
		var pos := center + Vector2(cos(screen_a), sin(screen_a)) * (radius - 20.0 * s)
		var color := Color(1.0, 0.25, 0.25) if lbl == "N" else Color(0.9, 0.9, 0.9)
		var font_size := int((15 if len(lbl) == 1 else 11) * s)
		draw_layer.draw_string(font, pos + Vector2(-6.0 * s, 5.0 * s),
			lbl, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)

	# Lubber line
	var tip := center + Vector2(0.0, -radius + 4.0 * s)
	var tl  := center + Vector2(-6.0 * s, -radius + 16.0 * s)
	var tr  := center + Vector2( 6.0 * s, -radius + 16.0 * s)
	var yellow := Color(1.0, 0.85, 0.0)
	draw_layer.draw_polygon(
		PackedVector2Array([tip, tl, tr]),
		PackedColorArray([yellow, yellow, yellow]))

	draw_layer.draw_string(font, center + Vector2(-20.0 * s, 8.0 * s),
		"%03d°" % int(fposmod(hdg_deg, 360.0)),
		HORIZONTAL_ALIGNMENT_LEFT, -1, int(18 * s), Color(1.0, 1.0, 1.0))

	# Mask ring
	draw_layer.draw_arc(center, radius + 8.0 * s, 0.0, TAU, 64,
		Color(0.07, 0.07, 0.09), maxf(2.0, 18.0 * s))

	draw_layer.draw_string(font, center + Vector2(-15.0 * s, -radius - 10.0 * s),
		"HDG", HORIZONTAL_ALIGNMENT_LEFT, -1, int(14 * s), Color(1.0, 1.0, 1.0, 0.7))
