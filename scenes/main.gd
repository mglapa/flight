extends Node3D
## Main scene — wires up the plane, camera, and HUD.

@onready var plane: Node3D = $Plane
@onready var camera: Camera3D = $ChaseCamera
@onready var hud: CanvasLayer = $HUD

func _ready() -> void:
	camera.target = plane
	hud.plane = plane
	hud.camera = camera

	# 5000 ft = 1524 m.  Player at +Z, facing -Z toward the head-on enemy.
	plane.position = Vector3(0, 1524, 1000)

	# Snap the camera to the correct starting position so it doesn't lerp
	# up from the ground on the first frames.
	var b := plane.global_transform.basis
	camera.global_position = (
		plane.global_position
		+ b.z * camera.follow_distance
		+ b.y * camera.follow_height
	)
