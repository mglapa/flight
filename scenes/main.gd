extends Node3D
## Main scene — wires up the plane, camera, HUD and the mission.

@onready var plane: Node3D = $Plane
@onready var camera: Camera3D = $ChaseCamera
@onready var hud: CanvasLayer = $HUD
@onready var world: Node3D = $World

var _cloud_rr := 0

func _ready() -> void:
	add_to_group("origin_container")    # plane, camera, bullets and effects live here
	WorldOrigin.focus = plane           # keep the scene centred on the player
	camera.target = plane
	camera.follow_distance = plane.camera_distance
	camera.follow_height = plane.camera_height
	hud.plane = plane
	hud.camera = camera

	# The mission chose the start: on an airfield, or in the air
	var m : Node = world.mission
	plane.spawn(m.spawn_pos, m.spawn_basis, m.spawn_on_ground)
	m.set_player(plane)
	hud.mission = m

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

	# ── Other aircraft fade inside clouds (a few per frame) ──────────────────
	var ais := get_tree().get_nodes_in_group("ai")
	for i in range(mini(ais.size(), 8)):
		_cloud_rr = (_cloud_rr + 1) % ais.size()
		var ac : Node3D = ais[_cloud_rr]
		var depth := 0.0
		for cloud in clouds:
			if is_instance_valid(cloud):
				depth = maxf(depth, cloud.depth_at(ac.global_position))
		ac.set_cloud_alpha(lerpf(1.0, 0.08, depth))
