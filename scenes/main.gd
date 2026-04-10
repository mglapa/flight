extends Node3D
## Main scene — wires up the plane, camera, and HUD.

@onready var plane: Node3D = $Plane
@onready var camera: Camera3D = $ChaseCamera
@onready var hud: CanvasLayer = $HUD

func _ready() -> void:
	camera.target = plane
	hud.plane = plane
	hud.camera = camera

	# 15,000 ft = 4572 m.  Player faces -Z; formation is at z = -2000 flying +Z.
	plane.position = Vector3(0, 4572, 1000)

	# Snap the camera to the correct starting position so it doesn't lerp
	# up from the ground on the first frames.
	var b := plane.global_transform.basis
	camera.global_position = (
		plane.global_position
		+ b.z * camera.follow_distance
		+ b.y * camera.follow_height
	)

func _process(delta: float) -> void:
	if not is_instance_valid(plane):
		return

	var clouds := get_tree().get_nodes_in_group("clouds")
	if clouds.is_empty():
		return

	# ── Player fog ────────────────────────────────────────────────────────────
	var player_depth := 0.0
	for cloud in clouds:
		if is_instance_valid(cloud):
			player_depth = maxf(player_depth, cloud.depth_at(plane.global_position))
	hud.cloud_fog = lerpf(hud.cloud_fog, player_depth, 6.0 * delta)

	# ── Enemy visibility ──────────────────────────────────────────────────────
	for enemy in get_tree().get_nodes_in_group("enemies"):
		if not is_instance_valid(enemy):
			continue
		var depth := 0.0
		for cloud in clouds:
			if is_instance_valid(cloud):
				depth = maxf(depth, cloud.depth_at(enemy.global_position))
		if enemy.has_method("set_cloud_alpha"):
			enemy.set_cloud_alpha(lerpf(1.0, 0.08, depth))
