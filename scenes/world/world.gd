extends Node3D
## The world: streaming campaign map (scenes/world/dover/), the mission
## (scenes/mission/mission.gd) with its aircraft, the smoke field, clouds
## and the sky environment.  An origin container: aircraft, bombs and
## effects are its children and move with the floating origin.
##
## Built in stages so main.gd can show a loading screen and the spawn
## picker in between:  load_geo() → plan_mission() → (player picks a start)
## → start_map() → map.built → finish().

const GeoData  := preload("res://scenes/world/geo/geo_data.gd")
const DoverMap := preload("res://scenes/world/dover/dover_map.gd")
const Weather  := preload("res://scenes/world/weather/weather.gd")
const Mission  := preload("res://scenes/mission/mission.gd")
const SmokeField := preload("res://scenes/fx/smoke_field.gd")
const Flak := preload("res://scenes/world/flak.gd")

var geo = null
var map : Node3D = null
var weather : Node3D = null
var mission : Node = null
var flak : Node3D = null

func _ready() -> void:
	add_to_group("origin_container")
	add_to_group("world")

## Reads the geography on a worker thread (the loading screen keeps moving)
func load_geo() -> void:
	var scale := GameSettings.map_scale
	var task := WorkerThreadPool.add_task(func(): geo = GeoData.new(scale), false, "geography")
	while not WorkerThreadPool.is_task_completed(task):
		await get_tree().process_frame
	WorkerThreadPool.wait_for_task_completion(task)

## Lays out the raid; the player's start is chosen afterwards
func plan_mission() -> void:
	mission = Mission.new()
	mission.name = "Mission"
	mission.geo = geo
	mission.plan()

## Starts building the ground around the player's start (see map.built)
func start_map() -> void:
	map = Node3D.new()
	map.name = "DoverMap"
	map.set_script(DoverMap)
	map.geo = geo
	map.initial_focus = mission.spawn_pos
	add_child(map)

func map_progress() -> float:
	return map.load_progress() if map else 0.0

## Once the map is built: smoke, the mission's aircraft, the AA guns
## (not in Free Flight, which has no enemies) and the weather
func finish() -> void:
	var smoke := MultiMeshInstance3D.new()
	smoke.name = "SmokeField"
	smoke.set_script(SmokeField)
	add_child(smoke)
	add_child(mission)
	if mission.attacker != "":
		flak = Node3D.new()
		flak.name = "Flak"
		flak.set_script(Flak)
		flak.geo = geo
		flak.mission = mission
		add_child(flak)
	_create_weather()

func _create_weather() -> void:
	var we := get_node_or_null("WorldEnvironment") as WorldEnvironment
	var sun := get_node_or_null("DirectionalLight3D") as DirectionalLight3D
	# Afternoon sun in the south-west, so the south-facing chalk cliffs gleam
	if sun:
		sun.rotation_degrees = Vector3(-38.0, 155.0, 0.0)
	weather = Node3D.new()
	weather.name = "Weather"
	weather.set_script(Weather)
	weather.env = we.environment if we else null
	weather.sun = sun
	weather.kind = GameSettings.resolved_weather()
	add_child(weather)

## Ground height below a scene-space (x, z) position (sea level over water).
func sample_height(x: float, z: float) -> float:
	if map == null:
		return 0.0
	return map.surface_height(WorldOrigin.world_x(x), WorldOrigin.world_z(z))
