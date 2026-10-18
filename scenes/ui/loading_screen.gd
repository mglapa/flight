extends CanvasLayer
## Full-screen loading card with a progress bar (main.gd drives it).
##
## stage(text, from, to) starts a step that fills the bar from `from` to
## `to`.  Measurable steps report their fraction with set_fraction(); steps
## that can't be measured creep toward `to` without ever reaching it, so
## the bar always moves and never claims to be done before it is.

const REF := Vector2(2560, 1440)
const BG      := Color(0.035, 0.045, 0.065)
const TXT     := Color(0.95, 0.96, 0.97)
const TXT_DIM := Color(0.62, 0.67, 0.72)
const ACCENT  := Color(1.0, 0.80, 0.25)

var title := ""
var subtitle := ""

var _text := ""
var _from := 0.0
var _to := 0.0
var _frac := -1.0                 ## measured fraction of this step, or -1
var _creep := 0.0
var _shown := 0.0                 ## the bar as drawn (eases toward the real value)
var _time := 0.0
var _font : Font
var _font_bold : Font
var _canvas : Control

func _ready() -> void:
	layer = 50
	_font = _make_font(500)
	_font_bold = _make_font(700)
	_canvas = Control.new()
	_canvas.set_anchors_preset(Control.PRESET_FULL_RECT)
	_canvas.mouse_filter = Control.MOUSE_FILTER_STOP
	_canvas.draw.connect(_draw_card)
	add_child(_canvas)

static func _make_font(weight: int) -> Font:
	var f := SystemFont.new()
	f.font_names = PackedStringArray(["Bahnschrift", "DIN Alternate", "Segoe UI", "Helvetica Neue", "Arial"])
	f.font_weight = weight
	f.antialiasing = TextServer.FONT_ANTIALIASING_GRAY
	return f

func stage(text: String, from: float, to: float) -> void:
	_text = text
	_from = from
	_to = to
	_frac = -1.0
	_creep = 0.0
	_shown = maxf(_shown, from)

func set_fraction(f: float) -> void:
	_frac = clampf(f, 0.0, 1.0)

## The value the bar is heading for
func value() -> float:
	var f := _frac
	if f < 0.0:
		f = _creep
	return lerpf(_from, _to, f)

func _process(delta: float) -> void:
	_time += delta
	# Unmeasured steps: approach 90 % of the step, ever more slowly
	_creep += (0.9 - _creep) * minf(1.0, delta * 0.6)
	_shown = lerpf(_shown, value(), minf(1.0, delta * 6.0))
	_canvas.queue_redraw()

func _draw_card() -> void:
	var vp := _canvas.get_viewport_rect().size
	var s := minf(vp.x / REF.x, vp.y / REF.y)
	_canvas.draw_rect(Rect2(Vector2.ZERO, vp), BG)
	var c := vp * 0.5
	_str(c + Vector2(0, -150) * s, title.to_upper(), 64 * s, TXT, true)
	_str(c + Vector2(0, -90) * s, subtitle, 26 * s, ACCENT, true)
	# Bar
	var w := 900.0 * s
	var h := 14.0 * s
	var r := Rect2(c + Vector2(-w * 0.5, 10 * s), Vector2(w, h))
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(1, 1, 1, 0.08)
	bg.set_corner_radius_all(int(h * 0.5))
	bg.anti_aliasing = true
	_canvas.draw_style_box(bg, r)
	var fill := bg.duplicate() as StyleBoxFlat
	fill.bg_color = ACCENT
	var fw := maxf(w * _shown, h)
	_canvas.draw_style_box(fill, Rect2(r.position, Vector2(fw, h)))
	# A soft glint running along the filled part, so it's clearly alive
	var gx := fmod(_time * 0.6, 1.0) * fw
	for i in range(6):
		var x := r.position.x + gx - i * 6.0 * s
		if x > r.position.x + h * 0.5 and x < r.position.x + fw - h * 0.5:
			_canvas.draw_line(Vector2(x, r.position.y + 2 * s), Vector2(x, r.end.y - 2 * s),
				Color(1, 1, 1, 0.35 * (1.0 - i / 6.0)), 4.0 * s)
	_str(Vector2(r.position.x, r.end.y + 46 * s), _text + "  " + _dots(), 24 * s, TXT_DIM, false, false)
	_str(Vector2(r.end.x, r.end.y + 46 * s), "%d%%" % int(_shown * 100.0), 24 * s, TXT, true, false, true)

func _dots() -> String:
	return ".".repeat(1 + int(_time * 2.5) % 3)

func _str(at: Vector2, t: String, size: float, col: Color, bold: bool, centre := true, right := false) -> void:
	var f := _font_bold if bold else _font
	var fs := int(size)
	var tw := f.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var x := at.x
	if centre:
		x -= tw * 0.5
	elif right:
		x -= tw
	_canvas.draw_string(f, Vector2(x, at.y), t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)
