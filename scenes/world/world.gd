extends Node3D
## Battle of Britain world: the stylised Strait of Dover map (see
## scenes/world/dover/), enemy formations, clouds and the sky environment.

const DoverMap := preload("res://scenes/world/dover/dover_map.gd")
const Weather  := preload("res://scenes/world/weather/weather.gd")

var map : Node3D = null
var weather : Node3D = null

var _chaser      : Node3D = null
var _chase_clock : float  = 0.0

func _ready() -> void:
	add_to_group("origin_container")    # enemies, smoke and effects live here
	map = Node3D.new()
	map.name = "DoverMap"
	map.set_script(DoverMap)
	add_child(map)
	_spawn_enemies()
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

func _process(delta: float) -> void:
	_chase_clock -= delta
	if _chase_clock > 0.0:
		return
	_chase_clock = 3.0

	var players := get_tree().get_nodes_in_group("player")
	if players.is_empty():
		return
	var player : Node3D = players[0]

	# Only fighters chase — bombers have their own defensive gunner AI
	var enemies := get_tree().get_nodes_in_group("enemy_fighters")
	var closest  : Node3D = null
	var best_d   : float  = INF
	for e in enemies:
		if not is_instance_valid(e) or e.get("_dead") == true:
			continue
		var d : float = e.global_position.distance_to(player.global_position)
		if d < best_d:
			best_d  = d
			closest = e

	if closest == _chaser:
		return

	if is_instance_valid(_chaser):
		_chaser.chase_target = null

	_chaser = closest
	if closest != null:
		closest.chase_target = player

## Ground height below a scene-space (x, z) position (sea level over water).
func sample_height(x: float, z: float) -> float:
	if map == null:
		return 0.0
	return map.surface_height(WorldOrigin.world_x(x), WorldOrigin.world_z(z))

func _spawn_enemies() -> void:
	var enemy_script  := load("res://scenes/enemies/enemy.gd")
	var bomber_script := load("res://scenes/enemies/bomber.gd")

	# ── He 111 V formation + 2 fighter escorts ────────────────────────────────
	# Player spawns at (0, 4572, 1000) facing -Z.
	# Formation starts 3 km ahead of the player (at z = -2000) and flies
	# straight toward the player in the +Z direction.
	const FORM_ALT  := 4572.0    # 15,000 ft — same as player spawn altitude
	const FORM_START_Z := -2000.0  # 3 km in front of player (player is at z=1000)

	# Lead bomber drives the whole formation
	var lead_bomber := Node3D.new()
	lead_bomber.set_script(bomber_script)
	lead_bomber.start_position   = Vector3(0.0, FORM_ALT, FORM_START_Z)
	lead_bomber.flight_direction = Vector3(0, 0, 1)   # +Z = toward player
	add_child(lead_bomber)

	# Four wingmen at V-formation offsets in the leader's local space.
	# Leader's local +Z = rearward (nose points in -Z local = +Z world).
	# Each arm steps 120 m laterally and 120 m rearward per position.
	var bomb_offsets : Array = [
		Vector3( 120, 0,  120),   # Right 1
		Vector3(-120, 0,  120),   # Left 1
		Vector3( 240, 0,  240),   # Right 2
		Vector3(-240, 0,  240),   # Left 2
	]
	for b_offset in bomb_offsets:
		var b := Node3D.new()
		b.set_script(bomber_script)
		b.flight_direction = Vector3(0, 0, 1)
		b.formation_leader = lead_bomber
		b.formation_offset = b_offset
		add_child(b)

	# Two fighter escorts flanking the outer wingmen, using formation following
	var escort_offsets : Array = [
		Vector3( 400, 0,  120),   # Right escort — outside Right 2
		Vector3(-400, 0,  120),   # Left  escort — outside Left 2
	]
	for e_offset in escort_offsets:
		var f := Node3D.new()
		f.set_script(enemy_script)
		f.formation_leader = lead_bomber
		f.formation_offset = e_offset
		add_child(f)
