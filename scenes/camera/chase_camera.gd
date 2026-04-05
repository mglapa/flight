extends Camera3D
## Chase camera locked to the plane's orientation.
## Right stick pans: up = tilt 60° up, left/right = swing ±60°, down = look behind 180°.
## Offsets auto-recentre when stick is released.

@export var target_path: NodePath
@export var follow_distance: float = 28.0
@export var follow_height: float = 9.0
@export var position_speed: float = 8.0
@export var rotation_speed: float = 6.0

const _DEADZONE     := 0.15
const _SNAP_SPEED   := 8.0          # how fast offsets return to zero
const _MAX_YAW      := PI           # 180° look-behind
const _MAX_YAW_SIDE := 1.047197551  # 60° side swing
const _MAX_PITCH    := 1.047197551  # 60° tilt up

var target: Node3D

var _yaw_offset   : float = 0.0
var _pitch_offset : float = 0.0

func _ready() -> void:
	if target_path:
		target = get_node(target_path)

func _physics_process(delta: float) -> void:
	if not target:
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

	var desired_position : Vector3 = target.global_position + offset
	global_position = global_position.lerp(desired_position, position_speed * delta)

	# ── Rotation: always look at the plane ───────────────────────────────────
	var to_target := target.global_position - global_position
	if to_target.length_squared() > 0.001:
		var desired_basis := Basis.looking_at(to_target, tb.y)
		var current_quat  := Quaternion(global_transform.basis.orthonormalized())
		var desired_quat  := Quaternion(desired_basis)
		global_transform.basis = Basis(current_quat.slerp(desired_quat, rotation_speed * delta))
