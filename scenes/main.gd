extends Node3D
## Main scene — wires up the plane, camera, HUD and the mission.
##
## Start-up runs in stages behind a loading screen: read the geography and
## plan the mission, let the player pick a start on the spawn map, build the
## ground around it (the bar follows the real tile count), then put the
## aircraft in the air and hand over.

const LoadingScreen := preload("res://scenes/ui/loading_screen.gd")
const SpawnPicker := preload("res://scenes/ui/spawn_picker.gd")
const Missions := preload("res://scenes/mission/missions.gd")

@onready var plane: Node3D = $Plane
@onready var camera: Camera3D = $ChaseCamera
@onready var hud: CanvasLayer = $HUD
@onready var world: Node3D = $World

var _cloud_rr := 0
var _loading : CanvasLayer
var _started := false

func _ready() -> void:
	add_to_group("origin_container")    # plane, camera, bullets and effects live here
	# Nothing flies until the world is ready
	for n in [plane, camera]:
		n.process_mode = Node.PROCESS_MODE_DISABLED
	plane.visible = false
	hud.visible = false
	_start_up()

func _start_up() -> void:
	var def : Dictionary = Missions.by_id(GameSettings.mission)
	_loading = LoadingScreen.new()
	_loading.title = def.name
	_loading.subtitle = "%s  ·  %s" % [def.date, "RAF" if GameSettings.side == "raf" else "LUFTWAFFE"]
	add_child(_loading)
	_loading.stage("Reading the map", 0.0, 1.0)
	await get_tree().process_frame
	await world.load_geo()
	world.plan_mission()
	_loading.set_fraction(1.0)

	# The player picks where to start, with the raid on the map
	_loading.visible = false
	var picker := SpawnPicker.new()
	picker.geo = world.geo
	picker.mission = world.mission
	add_child(picker)
	var result : Array = await _wait_for_pick(picker)
	picker.queue_free()
	if result[0] == "back":
		get_tree().change_scene_to_file("res://scenes/menu/menu.tscn")
		return
	world.mission.choose_start(result[1])

	# Build the ground around the chosen start
	_loading.visible = true
	_loading.stage("Building the terrain", 0.0, 0.88)
	world.start_map()
	while not world.map.is_built:
		_loading.set_fraction(world.map_progress())
		await get_tree().process_frame
	_loading.stage("Scrambling the squadrons", 0.88, 1.0)
	# Let the bar draw before the last (blocking) step
	await get_tree().process_frame
	await get_tree().process_frame
	world.finish()
	_begin_flight()
	_loading.set_fraction(1.0)
	await get_tree().process_frame
	_loading.queue_free()

## Waits for the picker: ["go", option name] or ["back", ""]
func _wait_for_pick(picker: Node) -> Array:
	var out : Array = []
	picker.chosen.connect(func(n: String): out.append_array(["go", n]))
	picker.back.connect(func(): out.append_array(["back", ""]))
	while out.is_empty():
		await get_tree().process_frame
	return out

func _begin_flight() -> void:
	for n in [plane, camera]:
		n.process_mode = Node.PROCESS_MODE_INHERIT
	plane.visible = true
	hud.visible = true
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
	plane.bailed_out.connect(_on_bailed_out)

	# Snap the camera to the correct starting position so it doesn't lerp
	# up from the ground on the first frames.
	var b := plane.global_transform.basis
	camera.global_position = (
		plane.global_position
		+ b.z * camera.follow_distance
		+ b.y * camera.follow_height
	)
	_started = true

## The pilot is out: watch him come down under the canopy
func _on_bailed_out(chute: Node3D) -> void:
	WorldOrigin.focus = chute
	camera.target = chute
	camera.zoom_level = 0
	camera.follow_distance = 16.0
	camera.follow_height = 4.0
	hud.plane = null

func _process(delta: float) -> void:
	if not _started:
		return
	var watched : Node3D = camera.target if is_instance_valid(camera.target) else null
	if watched == null:
		return

	var clouds := get_tree().get_nodes_in_group("clouds")
	if clouds.is_empty():
		return

	# ── Player fog ────────────────────────────────────────────────────────────
	var player_depth := 0.0
	for cloud in clouds:
		if is_instance_valid(cloud):
			player_depth = maxf(player_depth, cloud.depth_at(watched.global_position))
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
