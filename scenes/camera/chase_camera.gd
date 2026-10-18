extends Camera3D
## Chase camera locked to the plane's orientation.
## Right stick pans: up = tilt 60° up, left/right = swing ±60°, down = look behind 180°.
## Offsets auto-recentre when stick is released.  The zoom works in notches
## and, zoomed in, the camera looks down the gun line (see _physics_process).

@export var target_path: NodePath
@export var follow_distance: float = 28.0
@export var follow_height: float = 9.0
@export var position_speed: float = 8.0
@export var rotation_speed: float = 6.0

const _DEADZONE     := 0.15
const _SNAP_SPEED   := 8.0          # how fast offsets return to zero
const _MAX_YAW      := PI           # 180° look-behind
const _MAX_YAW_SIDE := 1.570796326  # 60° side swing
const _MAX_PITCH    := 1.570796326  # 60° tilt up

const _BASE_FOV := 75.0
## Zoom notches (RB / Z / wheel up = in, LB / X / wheel down = out)
const _ZOOM_FOVS : Array[float] = [75.0, 37.5, 18.75, 9.4]
const _ZOOM_SPEED := 10.0   # how fast FOV and aim blend ease to the notch
const _ZOOM_AIM_DIST := 2000.0   # zoomed, look this far ahead along the guns

var target: Node3D

var _yaw_offset   : float = 0.0
var _pitch_offset : float = 0.0
var _zoom_blend   : float = 0.0   # 0 = look at the plane, 1 = look down the guns
var zoom_level    : int = 0

func _unhandled_input(event: InputEvent) -> void:
	var step := 0
	if event is InputEventJoypadButton and event.pressed:
		var b := (event as InputEventJoypadButton).button_index
		if b == JOY_BUTTON_RIGHT_SHOULDER: step = 1
		elif b == JOY_BUTTON_LEFT_SHOULDER: step = -1
	elif event is InputEventKey and event.pressed and not event.echo:
		var k := (event as InputEventKey).keycode
		if k == KEY_Z: step = 1
		elif k == KEY_X: step = -1
	elif event is InputEventMouseButton and event.pressed:
		var mb := (event as InputEventMouseButton).button_index
		if mb == MOUSE_BUTTON_WHEEL_UP: step = 1
		elif mb == MOUSE_BUTTON_WHEEL_DOWN: step = -1
	if step != 0:
		zoom_level = clampi(zoom_level + step, 0, _ZOOM_FOVS.size() - 1)
		get_viewport().set_input_as_handled()

func _ready() -> void:
	if target_path:
		target = get_node(target_path)

func _physics_process(delta: float) -> void:
	if not is_instance_valid(target):
		return

	# ── Right-stick input ────────────────────────────────────────────────────
	var rx := Input.get_joy_axis(0, JOY_AXIS_RIGHT_X)
	var ry := Input.get_joy_axis(0, JOY_AXIS_RIGHT_Y)
	if absf(rx) < _DEADZONE: rx = 0.0
	if absf(ry) < _DEADZONE: ry = 0.0

	var tgt_yaw   := 0.0
	var tgt_pitch := 0.0

	if rx != 0.0 or ry != 0.0:
		if ry <= 0.0:
			# Upper half — pitch up and/or pan left/right
			tgt_yaw   = -rx * _MAX_YAW_SIDE
			tgt_pitch = -ry * _MAX_PITCH
		else:
			# Lower half — sweep from side-pan toward full look-behind.
			# end_yaw is ±PI depending on which side; the angle-wrap below
			# ensures the lerp always takes the short path, so crossing
			# rx = 0 near ry = 1 never triggers a full-circle sweep.
			var start_yaw := -rx * _MAX_YAW_SIDE
			var end_yaw   := PI * (1.0 if rx <= 0.0 else -1.0)
			tgt_yaw   = lerpf(start_yaw, end_yaw, ry)
			tgt_pitch = 0.0

	# Shortest-path lerp for yaw — wraps the difference to [-PI, PI] so the
	# camera always rotates the short way, even across the ±PI boundary.
	var yaw_diff := fposmod(tgt_yaw - _yaw_offset + PI, TAU) - PI
	_yaw_offset   = lerpf(_yaw_offset, _yaw_offset + yaw_diff, _SNAP_SPEED * delta)
	_pitch_offset = lerpf(_pitch_offset, tgt_pitch,             _SNAP_SPEED * delta)

	# ── Build follow offset with pan applied ─────────────────────────────────
	var tb := target.global_transform.basis

	# Base offset in plane-local space (behind + above)
	var offset : Vector3 = tb.z * follow_distance + tb.y * follow_height

	# Rotate offset around plane's world-up axis for yaw
	offset = offset.rotated(tb.y.normalized(), _yaw_offset)

	# Rotate offset around the right axis (after yaw) for pitch
	var right_after_yaw := tb.x.rotated(tb.y.normalized(), _yaw_offset).normalized()
	offset = offset.rotated(right_after_yaw, _pitch_offset)

	# ── Zoom ─────────────────────────────────────────────────────────────────
	# The camera keeps its chase position (so the right stick still swings it
	# round) and, zoomed, looks down the gun line instead of at the plane.
	# The chase spot is above and behind, so the sightline to the aim point
	# clears the airframe: the plane sits low in the frame, or out of it at
	# the tighter notches, and never covers the crosshair.
	var target_blend := 0.0 if zoom_level == 0 else 1.0
	fov         = lerpf(fov, _ZOOM_FOVS[zoom_level], minf(1.0, _ZOOM_SPEED * delta))
	_zoom_blend = lerpf(_zoom_blend, target_blend, minf(1.0, _ZOOM_SPEED * delta))

	var desired_position : Vector3 = target.global_position + offset
	global_position = global_position.lerp(desired_position, minf(1.0, position_speed * delta))

	# Look direction: the nose, swung by the same stick pan as the offset
	var look_dir := (-tb.z).rotated(tb.y.normalized(), _yaw_offset).rotated(right_after_yaw, _pitch_offset)
	var aim_point   : Vector3 = target.global_position + look_dir * _ZOOM_AIM_DIST
	var look_target : Vector3 = target.global_position.lerp(aim_point, _zoom_blend)

	# ── Rotation: look at blended target ─────────────────────────────────────
	# Stiffer when zoomed, or the narrow view swims behind the plane's motion
	var rot_speed := lerpf(rotation_speed, 30.0, _zoom_blend * (1.0 - fov / _BASE_FOV))
	var to_target := look_target - global_position
	if to_target.length_squared() > 0.001:
		var desired_basis := Basis.looking_at(to_target, tb.y)
		var current_quat  := Quaternion(global_transform.basis.orthonormalized())
		var desired_quat  := Quaternion(desired_basis)
		global_transform.basis = Basis(current_quat.slerp(desired_quat, minf(1.0, rot_speed * delta)))
