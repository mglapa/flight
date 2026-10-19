extends Node
## Mission director (group "mission").
##
## plan() reads GameSettings (mission, side, aircraft) and lays out the raid;
## start_options() lists where the player may start (the spawn picker shows
## them on a map) and choose_start() fixes it.  On entering the tree it spawns the raid
## (bombers in vics with their escort), the defending squadrons and the
## player's own section.  While flying it hands AI fighters their targets,
## promotes a new bomber leader when one is lost, keeps the tally (bombs on
## target, aircraft lost, the player's kills), lights fires where bombs fall
## and decides the outcome once every bomber has bombed, turned for home or
## been shot down.  The HUD reads objective(), status_lines(), feed and the
## result fields.

const Missions := preload("res://scenes/mission/missions.gd")
const AircraftTypes := preload("res://scenes/plane/aircraft_types.gd")
const FighterAI := preload("res://scenes/ai/fighter.gd")
const BomberAI := preload("res://scenes/ai/bomber.gd")

## Take-off into a west-south-westerly breeze (+X is west, +Z north)
const INTO_WIND := Vector3(0.92, 0.0, -0.38)
const PLAYER_CAP := 2             ## AI fighters allowed on the player at once
const ASSIGN_EVERY := 0.5

## Vic formations behind the lead bomber (leader's local frame, +Z = behind)
const BOMBER_SLOTS : Array = [
	Vector3(0, 0, 0), Vector3(-110, 0, 110), Vector3(110, 0, 110),
	Vector3(-330, 30, 330), Vector3(-440, 30, 440), Vector3(-220, 30, 440),
	Vector3(330, -30, 330), Vector3(220, -30, 440), Vector3(440, -30, 440),
	Vector3(0, 0, 680), Vector3(-110, 0, 790), Vector3(110, 0, 790),
]
const ESCORT_SLOTS : Array = [
	Vector3(-650, 150, 250), Vector3(650, 150, 250), Vector3(-650, 150, 750), Vector3(650, 150, 750),
	Vector3(-320, 900, -250), Vector3(320, 900, -250), Vector3(-320, 900, 550), Vector3(320, 900, 550),
]
## Finger-four / section slots for fighters following a leader
const WING_SLOTS : Array = [
	Vector3(-60, 0, 50), Vector3(70, -10, 60), Vector3(130, -10, 110),
	Vector3(-120, 10, 110), Vector3(-180, 10, 160),
]

var geo                                ## GeoData, set before setup()

var def : Dictionary = {}
var side := "raf"                      ## the player's side
var attacker := ""
var defender := ""
var player : Node3D = null

# Player start (world space), filled in by setup()
var spawn_pos := Vector3(0, 4572, 1000)
var spawn_basis := Basis.IDENTITY
var spawn_on_ground := false
var spawn_field := ""

var target := Vector2.INF              ## aiming point (game x, z)
var target_name := ""
var target_radius := 0.0
var raid_dir := Vector2.ZERO           ## unit vector from the target toward the raid's origin
var _raid_start := Vector2.ZERO
var _route : Array = []
var _field_pos := Vector2.ZERO         ## the player's airfield
var _field_heading := Vector3.FORWARD

# Tally
var bombers_total := 0
var bombers_down := 0
var bombers_bombed := 0
var bomb_hits := 0
var bombs_dropped := 0
var losses := {"raf": 0, "lw": 0}      ## fighters lost per side (incl. the player)
var player_kills : Array = []          ## names of what the player shot down
var player_lost := false
var feed : Array = []                  ## [text, time]
var time := 0.0

var outcome := ""                      ## "" while undecided, else the winning side
var finished := false                  ## debrief is ready to show
var _decided_at := -1.0
var _lost_at := -1.0
var _had_player := false
var player_bailed := false
var _chute : Node3D = null             ## the player under his parachute

var _wing : Array = []                 ## AI wingmen of the player
var _fires : Array = []                ## [world Vector3, end time]
var _fire_clock := 0.0
var _assign_clock := 0.0
var _check_clock := 0.0
var _smoke : Node = null

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

func plan() -> void:
	side = GameSettings.side
	def = Missions.by_id(GameSettings.mission)
	attacker = def.attacker
	defender = Missions.other(attacker) if attacker != "" else ""
	if def.has("target"):
		var t : Array = def.target
		target_name = t[0]
		target = geo.latlon_to_game(t[1], t[2])
		target_radius = t[3]
		var from : Vector2 = geo.latlon_to_game(def.from[0], def.from[1])
		raid_dir = (from - target).normalized()
		_raid_start = target + raid_dir * float(def.approach)
		var alt : float = def.alt
		var out1 := target + raid_dir.rotated(0.75) * 12000.0
		var home := target + raid_dir.rotated(0.35) * (float(def.approach) + 15000.0)
		_route = [Vector3(target.x, alt, target.y), Vector3(out1.x, alt, out1.y), Vector3(home.x, alt + 300.0, home.y)]

## Where the player may start: [{name, pos (game Vector2), air, km}].
## Escorts start with the bombers, a defender scrambles from one of the
## fields nearest the target (or is already up, if the mission says so), and
## Free Flight offers every field of the side plus a start over Dover.
func start_options() -> Array:
	var out : Array = []
	if Missions.player_attacks(def, side):
		out.append({"name": "With the bombers", "pos": _raid_start, "air": true, "km": -1.0})
		return out
	if def.id != "free" and def.player_start == "air":
		out.append({"name": "Airborne, facing the raid", "pos": _raid_start - raid_dir * 5500.0, "air": true, "km": -1.0})
		return out
	var ref : Vector2 = target if target != Vector2.INF else geo.airfield_pos
	var fields : Array = []
	for i in range(geo.airfields.size()):
		var a : Array = geo.airfields[i]
		if a[1] == side:
			fields.append({"name": a[0], "pos": a[2], "air": false, "km": (a[2] as Vector2).distance_to(ref) / 1000.0})
	fields.sort_custom(func(x: Dictionary, y: Dictionary) -> bool: return x.km < y.km)
	if def.id == "free":
		out.append({"name": Missions.AIRBORNE, "pos": Vector2(0, 3000), "air": true, "km": -1.0})
		out.append_array(fields)
	else:
		out.append_array(fields.slice(0, 8))
	return out

## Where the raid starts (game x, z)
func raid_start() -> Vector2:
	return _raid_start

## Fixes the player's start (an option name from start_options())
func choose_start(option_name: String) -> void:
	GameSettings.airfield = option_name
	_plan_player_start()

func _plan_player_start() -> void:
	var p_attacks := Missions.player_attacks(def, side)
	if p_attacks:
		# Escorting: in the air on the bombers' starboard quarter
		var b := _raid_basis()
		var lead := Vector3(_raid_start.x, def.alt, _raid_start.y)
		spawn_pos = lead + b * Vector3(480, 250, -120)
		spawn_basis = b
		return
	if def.id != "free" and def.player_start == "air":
		# Already up, between the target and the raid, facing it
		var p := _raid_start - raid_dir * 5500.0
		spawn_pos = Vector3(p.x, float(def.alt) + 150.0, p.y)
		spawn_basis = Basis.looking_at(Vector3(raid_dir.x, 0, raid_dir.y), Vector3.UP)
		return
	var fid := _choose_field()
	if fid < 0:
		spawn_pos = Vector3(0, 2500, 3000)        # over Dover, heading out over the Channel
		spawn_basis = Basis.IDENTITY
		return
	var a : Array = geo.airfields[fid]
	spawn_field = a[0]
	_field_pos = a[2]
	_field_heading = _runway_heading(fid)
	var start : Vector2 = _field_pos - Vector2(_field_heading.x, _field_heading.z) * 420.0
	spawn_pos = Vector3(start.x, geo.land_height(start.x, start.y), start.y)
	spawn_basis = Basis.looking_at(_field_heading, Vector3.UP)
	spawn_on_ground = true

## The player's airfield: the menu choice if valid, else the nearest of their side
func _choose_field() -> int:
	if GameSettings.airfield == Missions.AIRBORNE:
		return -1
	var id : int = geo.airfield_index(GameSettings.airfield)
	if id >= 0 and geo.airfields[id][1] == side:
		return id
	var ref := target if target != Vector2.INF else Vector2.ZERO
	return _nearest_field(side, ref)

func _nearest_field(s: String, to: Vector2) -> int:
	var best := -1
	var best_d := INF
	for i in range(geo.airfields.size()):
		if geo.airfields[i][1] != s:
			continue
		var d : float = (geo.airfields[i][2] as Vector2).distance_to(to)
		if d < best_d:
			best_d = d
			best = i
	return best

## Take-off line across the field, clear of the hangars (see dover_scenery.gd)
func _runway_heading(fid: int) -> Vector3:
	var axis : Vector3 = Basis(Vector3.UP, geo.airfield_yaw(fid)) * Vector3(0, 0, 1)
	return axis if axis.dot(INTO_WIND) >= 0.0 else -axis

func _raid_basis() -> Basis:
	return Basis.looking_at(Vector3(-raid_dir.x, 0, -raid_dir.y), Vector3.UP)

# ---------------------------------------------------------------------------
# Spawning
# ---------------------------------------------------------------------------

func _ready() -> void:
	add_to_group("mission")
	_smoke = get_tree().get_first_node_in_group("smoke_field")
	if attacker == "":
		return
	_spawn_raid()
	_spawn_defenders()

func _world_node() -> Node:
	return get_parent()

func _spawn_raid() -> void:
	var b := _raid_basis()
	var lead_w := Vector3(_raid_start.x, def.alt, _raid_start.y)
	var lead : Node3D = null
	var n : int = mini(int(def.bombers[1]), BOMBER_SLOTS.size())
	for i in range(n):
		var bm := Node3D.new()
		bm.set_script(BomberAI)
		bm.bomber_type = def.bombers[0]
		bm.side = attacker
		bm.bomb_target = target
		bm.target_radius = target_radius
		if i == 0:
			bm.route = _route
			bm.position = WorldOrigin.to_scene(lead_w)
			bm.transform.basis = b
			lead = bm
		else:
			bm.formation_leader = lead
			bm.formation_offset = BOMBER_SLOTS[i]
		_world_node().add_child(bm)
	bombers_total = n
	var e : int = mini(int(def.escorts[1]), ESCORT_SLOTS.size())
	for i in range(e):
		var f := _fighter(def.escorts[0], attacker, "escort")
		f.formation_leader = lead
		f.formation_offset = ESCORT_SLOTS[i]
		_world_node().add_child(f)

func _fighter(type: String, s: String, role: String) -> Node3D:
	var f := Node3D.new()
	f.set_script(FighterAI)
	f.fighter_type = type
	f.side = s
	f.role = role
	return f

## A section of n fighters in the air at a world position, heading `fwd`
func _air_section(type: String, s: String, role: String, n: int, at: Vector3, fwd: Vector3) -> Array:
	var out : Array = []
	var b := Basis.looking_at(fwd, Vector3.UP)
	var leader : Node3D = null
	for i in range(n):
		var f := _fighter(type, s, role)
		if i == 0:
			f.position = WorldOrigin.to_scene(at)
			f.transform.basis = b
			leader = f
		else:
			f.formation_leader = leader
			f.formation_offset = WING_SLOTS[(i - 1) % WING_SLOTS.size()] * (1.0 + floorf((i - 1) / float(WING_SLOTS.size())))
		_world_node().add_child(f)
		out.append(f)
	return out

## Fighters lined up on an airfield, rolling one after another
func _ground_section(type: String, s: String, role: String, n: int, fid: int, first_delay: float,
		skip_lead := false) -> Array:
	var out : Array = []
	var a : Array = geo.airfields[fid]
	var fp : Vector2 = a[2]
	var head := _runway_heading(fid)
	var right := head.cross(Vector3.UP).normalized()
	for i in range(n):
		var slot := i + (1 if skip_lead else 0)
		var lateral := floorf((slot + 1) / 2.0) * 45.0 * (1.0 if slot % 2 == 1 else -1.0)
		var p := Vector3(fp.x, 0, fp.y) - head * (420.0 + 12.0 * slot) + right * lateral
		var f := _fighter(type, s, role)
		f.position = WorldOrigin.to_scene(p)
		f.transform.basis = Basis.looking_at(head, Vector3.UP)
		f.scramble_delay = first_delay + i * 1.6
		_world_node().add_child(f)
		out.append(f)
	return out

static func _default_type(s: String) -> String:
	return "spitfire" if s == "raf" else "bf109"

func _wing_type() -> String:
	var t : String = GameSettings.aircraft
	if AircraftTypes.TYPES.has(t) and AircraftTypes.TYPES[t].side == side:
		return t
	return _default_type(side)

func _spawn_defenders() -> void:
	var perp := raid_dir.orthogonal()
	var k := 0
	for d in def.defenders:
		if d[3] != "air":
			continue
		var c : Vector2 = target + raid_dir * float(def.approach) * 0.42 + perp * (5000.0 if k % 2 == 0 else -5000.0)
		var alt : float = float(def.alt) + 300.0 + k * 300.0      # radar gave them time to climb
		_air_section(d[0], defender, d[2], int(d[1]), Vector3(c.x, alt, c.y), Vector3(raid_dir.x, 0, raid_dir.y))
		k += 1
	var p_defends := side == defender
	if p_defends and def.player_start == "ground":
		var fid : int = geo.airfield_index(spawn_field)
		if fid >= 0:
			_wing = _ground_section(_wing_type(), side, "wing", 3, fid, 3.0, true)
	elif p_defends:
		# Airborne start: two wingmen alongside the player
		var fwd := spawn_basis * Vector3.FORWARD
		for i in range(2):
			var f := _fighter(_wing_type(), side, "wing")
			f.position = WorldOrigin.to_scene(spawn_pos + spawn_basis * WING_SLOTS[i])
			f.transform.basis = Basis.looking_at(fwd, Vector3.UP)
			_world_node().add_child(f)
			_wing.append(f)
	if not p_defends or def.player_start != "ground":
		# A section scrambling from the field nearest the target
		var fid := _nearest_field(defender, target)
		if fid >= 0:
			_ground_section(_default_type(defender), defender, "intercept", 4, fid, 4.0)

## The player's aircraft abandoned (plane.gd): out of the fight from now on
func on_player_bailed(chute: Node3D) -> void:
	if player_lost:
		return
	player_lost = true
	player_bailed = true
	_lost_at = time
	losses[side] += 1
	_chute = chute
	player = null                          # wingmen and enemies forget the empty aircraft

## Debrief once the player is out: a moment after being shot down, or once
## the parachute is down (or after a long enough look)
func _player_out_done() -> bool:
	var t := time - _lost_at
	if not player_bailed:
		return t > 3.5
	if is_instance_valid(_chute) and not _chute.landed:
		return t > 75.0
	return t > 4.0

## Called by main.gd once the player's aircraft exists
func set_player(p: Node3D) -> void:
	player = p
	_had_player = true
	for i in range(_wing.size()):
		if not is_instance_valid(_wing[i]):
			continue
		var w : Node3D = _wing[i]
		w.formation_leader = p
		w.formation_offset = WING_SLOTS[i % WING_SLOTS.size()]

# ---------------------------------------------------------------------------
# Running the battle
# ---------------------------------------------------------------------------

func _process(delta: float) -> void:
	time += delta
	if _had_player and not is_instance_valid(player) and not player_lost:
		player_lost = true
		_lost_at = time
		losses[side] += 1
		_say("You are down.")
	_update_fires(delta)
	if not finished:
		if player_lost and _player_out_done():
			finished = true                  # the battle may still be raging without you
		elif outcome != "" and time - _decided_at > 6.0 and get_tree().get_nodes_in_group("bombs").is_empty():
			finished = true
	if attacker == "":
		return
	_assign_clock -= delta
	if _assign_clock <= 0.0:
		_assign_clock = ASSIGN_EVERY
		_assign_targets()
	_check_clock -= delta
	if _check_clock <= 0.0:
		_check_clock = 1.0
		_check_leader()
		_check_outcome()

func _say(text: String) -> void:
	feed.append([text, time])
	if feed.size() > 8:
		feed.pop_front()

static func _alive(n) -> bool:
	if not is_instance_valid(n):
		return false
	if n.has_method("is_airborne"):
		return n.is_airborne()
	return true                           # the player

func _assign_targets() -> void:
	var fighters := {"raf": [], "lw": []}
	var bomber_list := {"raf": [], "lw": []}
	for f in get_tree().get_nodes_in_group("fighters"):
		if _alive(f):
			var s : String = f.side if f.is_in_group("ai") else side
			fighters[s].append(f)
	for b in get_tree().get_nodes_in_group("bombers"):
		if _alive(b):
			bomber_list[b.side].append(b)
	# How many are already on each target
	var on := {}
	for f in fighters.raf + fighters.lw:
		if f.is_in_group("ai") and is_instance_valid(f.target):
			on[f.target] = on.get(f.target, 0) + 1
	var raid := _raid_centre()
	for f in fighters.raf + fighters.lw:
		if not f.is_in_group("ai") or f.state != FighterAI.State.FLYING:
			continue
		var foes : Array = fighters[Missions.other(f.side)]
		var foe_bombers : Array = bomber_list[Missions.other(f.side)]
		var cur : Node3D = f.target if _alive(f.target) else null
		var keep_d := 40000.0 if cur != null and cur.is_in_group("bombers") else 7000.0
		if cur != null and cur.global_position.distance_to(f.global_position) > keep_d:
			cur = null
		var pick : Node3D = cur
		match f.role:
			"escort":
				var guard : Node3D = f.formation_leader if _alive(f.formation_leader) else f
				pick = _nearest(foes, guard.global_position, 2600.0, on)
				if pick == null:
					pick = _nearest(foes, f.global_position, 1200.0, on)
				if pick == null and cur != null and cur.global_position.distance_to(guard.global_position) < 4000.0:
					pick = cur
				if not _alive(f.formation_leader):
					f.goal_world = raid if raid != Vector3.INF else f.goal_world
			"intercept":
				var threat := _on_tail(f, foes)
				if threat:
					pick = threat
				elif cur == null or not cur.is_in_group("bombers"):
					pick = _least_attacked(foe_bombers, f.global_position, 30000.0, on)
					if pick == null:
						pick = _nearest(foes, f.global_position, 15000.0, on)
				f.goal_world = _intercept_goal(raid)
			"sweep":
				pick = _nearest(foes, f.global_position, 15000.0, on)
				if pick == null:
					pick = _nearest(foe_bombers, f.global_position, 6000.0, on)
				f.goal_world = _intercept_goal(raid)
			"wing":
				var lead_pos : Vector3 = player.global_position if is_instance_valid(player) else f.global_position
				var threat := _on_tail(f, foes)
				if threat:
					pick = threat
				elif cur == null or cur.global_position.distance_to(lead_pos) > 5000.0:
					pick = _nearest(foe_bombers, lead_pos, 3500.0, on)
					if pick == null:
						pick = _nearest(foes, lead_pos, 2500.0, on)
				# Until the leader is up, circle over him at a safe height
				f.goal_world = WorldOrigin.to_world(lead_pos) + Vector3(0, 1200, 0)
				if not is_instance_valid(player):
					f.role = "intercept"
		if not is_instance_valid(f.target):
			f.target = null
		if pick != f.target:
			if f.target != null:
				on[f.target] = on.get(f.target, 1) - 1
			if pick != null:
				on[pick] = on.get(pick, 0) + 1
			f.target = pick

func _player_full(n: Node, on: Dictionary) -> bool:
	return n == player and on.get(n, 0) >= PLAYER_CAP

func _nearest(list: Array, at: Vector3, max_d: float, on: Dictionary) -> Node3D:
	var best : Node3D = null
	var best_d := max_d
	for n in list:
		if _player_full(n, on):
			continue
		var d : float = (n as Node3D).global_position.distance_to(at)
		if d < best_d:
			best_d = d
			best = n
	return best

## Spread the attackers over the bomber formation
func _least_attacked(list: Array, at: Vector3, max_d: float, on: Dictionary) -> Node3D:
	var best : Node3D = null
	var best_s := INF
	for n in list:
		var d : float = (n as Node3D).global_position.distance_to(at)
		if d > max_d:
			continue
		var s : float = d + 1500.0 * on.get(n, 0)
		if s < best_s:
			best_s = s
			best = n
	return best

## An enemy fighter close behind f
func _on_tail(f: Node3D, foes: Array) -> Node3D:
	var fwd := -f.global_transform.basis.z
	for n in foes:
		var to : Vector3 = (n as Node3D).global_position - f.global_position
		if to.length() < 500.0 and to.normalized().dot(fwd) < -0.5:
			return n
	return null

## World position of the bomber formation's centre (INF when none are left)
func _raid_centre() -> Vector3:
	var sum := Vector3.ZERO
	var n := 0
	for b in get_tree().get_nodes_in_group("bombers"):
		if _alive(b):
			sum += (b as Node3D).global_position
			n += 1
	if n == 0:
		return Vector3.INF
	return WorldOrigin.to_world(sum / n)

## Head for a point ahead of the raid, a little above it
func _intercept_goal(raid: Vector3) -> Vector3:
	if raid == Vector3.INF:
		return Vector3(target.x, float(def.alt), target.y)
	var to_tgt := Vector2(target.x - raid.x, target.y - raid.z).normalized()
	return Vector3(raid.x + to_tgt.x * 3000.0, raid.y + 300.0, raid.z + to_tgt.y * 3000.0)

# ---------------------------------------------------------------------------
# Events from aircraft and bombs
# ---------------------------------------------------------------------------

func on_aircraft_down(n: Node, by) -> void:
	var s : String = n.side
	var what := _type_name(n)
	if n.is_in_group("bombers"):
		bombers_down += 1
		_promote(n)
	else:
		losses[s] += 1
	if by != null and is_instance_valid(by) and by.is_in_group("player"):
		if s == side:
			_say("You shot down a friendly %s!" % what)
		else:
			player_kills.append(what)
			_say("You shot down a %s." % what)
	elif by != null and is_instance_valid(by) and by.is_in_group("flak"):
		if s == side:
			_say("Enemy flak brings down a friendly %s." % what)
		else:
			_say("Flak brings down a %s." % what)
	elif n in _wing:
		_say("Your wingman is going down.")
	elif n.is_in_group("bombers") and s != side:
		_say("A %s goes down in flames." % what)

static func _type_name(n: Node) -> String:
	if n.is_in_group("bombers"):
		return BomberAI.PROFILES[n.bomber_type].name
	return AircraftTypes.TYPES[n.fighter_type].short

## The lead bomber is lost: the nearest wingman takes the lead
func _promote(dead: Node) -> void:
	if dead.formation_leader != null and is_instance_valid(dead.formation_leader) and not dead.formation_leader._dead:
		return
	var best : Node3D = null
	var best_d := INF
	for b in get_tree().get_nodes_in_group("bombers"):
		if b == dead or not _alive(b) or b.formation_leader != dead:
			continue
		var d : float = (b.formation_offset as Vector3).length()
		if d < best_d:
			best_d = d
			best = b
	if best == null:
		return
	var off : Vector3 = best.formation_offset
	best.take_lead(dead.route, dead.wp)
	for n in get_tree().get_nodes_in_group("aircraft"):
		if n != best and n.get("formation_leader") == dead:
			n.formation_leader = best
			n.formation_offset = n.formation_offset - off

## A crippled leader losing height hands over, so the formation isn't led down
func _check_leader() -> void:
	for b in get_tree().get_nodes_in_group("bombers"):
		if not _alive(b) or b.formation_leader != null or b.route.is_empty() or b.wp >= b.route.size():
			continue
		var want : float = b.route[b.wp].y
		if b.global_position.y < want - 500.0 and not b.has_meta("crippled"):
			b.set_meta("crippled", true)       # hands over once; the new leader climbs back
			_promote(b)

func on_bombs_released(b: Node) -> void:
	bombers_bombed += 1
	if bombers_bombed == 1:
		_say("Bombs falling on %s!" % target_name)

func on_bomb_impact(at: Vector3, _side: String) -> void:
	bombs_dropped += 1
	if Vector2(at.x, at.z).distance_to(target) < target_radius * 1.15:
		bomb_hits += 1
		if at.y > 1.0 and randf() < 0.6 and _fires.size() < 40:      # fires on land only
			_fires.append([at, time + randf_range(90.0, 180.0)])

func on_bomber_home(_b: Node) -> void:
	pass

func _update_fires(delta: float) -> void:
	_fire_clock -= delta
	if _fire_clock > 0.0 or _smoke == null:
		return
	_fire_clock = 0.6
	for i in range(_fires.size() - 1, -1, -1):
		var f : Array = _fires[i]
		if time > f[1]:
			_fires.remove_at(i)
			continue
		var p := WorldOrigin.to_scene(f[0])
		# A tall column of oily smoke over the flames
		_smoke.emit(p + Vector3(randf_range(-8, 8), 10, randf_range(-8, 8)), 1, 14.0, 40.0, 8.0)
		_smoke.emit(p + Vector3(randf_range(-6, 6), 3, randf_range(-6, 6)), 2, 7.0, 0.9, 4.0)

func _check_outcome() -> void:
	if outcome != "":
		return
	var resolved := true
	for b in get_tree().get_nodes_in_group("bombers"):
		if _alive(b) and not b.bombed and b.wp < 2:
			resolved = false
			break
	if not resolved:
		return
	outcome = attacker if bombers_bombed >= bombers_needed() else defender
	_say("The raid got through." if outcome == attacker else "The raid has been broken up!")
	_decided_at = time

# ---------------------------------------------------------------------------
# For the HUD
# ---------------------------------------------------------------------------

## Bombers that must bomb the target for the raid to succeed (60 %)
func bombers_needed() -> int:
	return ceili(bombers_total * 0.6)

func objective() -> String:
	if attacker == "":
		return "Free flight — no enemies about."
	if side == attacker:
		return "Escort the bombers to %s." % target_name
	return "Stop the raid on %s." % target_name

func status_lines() -> Array:
	var out : Array = []
	if attacker == "":
		return out
	var live := bombers_total - bombers_down
	out.append(["BOMBERS", "%d / %d" % [live, bombers_total]])
	out.append(["BOMBED  (RAID NEEDS %d)" % bombers_needed(), "%d" % bombers_bombed])
	var raid := _raid_centre()
	if raid != Vector3.INF and outcome == "":
		var d := Vector2(raid.x, raid.z).distance_to(target)
		out.append(["RAID → TARGET", "%.0f km" % (d / 1000.0)])
		var eta := int(maxf(d - target_radius, 0.0) / 75.0)
		out.append(["TIME TO TARGET", "%d:%02d" % [floori(eta / 60.0), eta % 60]])
	if not player_kills.is_empty():
		out.append(["YOUR KILLS", "%d" % player_kills.size()])
	return out

## Markers for the HUD: [world Vector3, label, friendly?]
func markers() -> Array:
	var out : Array = []
	if attacker == "":
		return out
	out.append([Vector3(target.x, 0.0, target.y), target_name.to_upper(), side == defender])
	var raid := _raid_centre()
	if raid != Vector3.INF:
		out.append([raid, "BOMBERS" if side == attacker else "RAID", side == attacker])
	return out

func result_title() -> String:
	if player_lost and outcome == "":
		return "BAILED OUT" if player_bailed else "SHOT DOWN"
	if outcome == "":
		return "MISSION IN PROGRESS"
	return "MISSION SUCCESS" if outcome == side else "MISSION FAILED"

func result_lines() -> Array:
	var out : Array = []
	if attacker == "":
		return out
	if outcome == attacker:
		out.append("The raid got through: %d of %d bombers bombed %s." % [bombers_bombed, bombers_total, target_name])
	elif outcome == defender:
		out.append("The raid was broken up: only %d of %d bombers bombed %s." % [bombers_bombed, bombers_total, target_name])
	else:
		out.append("The raid on %s is still in progress." % target_name)
	out.append("Bombers shot down: %d of %d.   Bombs on target: %d of %d." % [bombers_down, bombers_total,
		bomb_hits, bombs_dropped])
	out.append("Fighters lost — RAF: %d   Luftwaffe: %d." % [losses.raf, losses.lw])
	if player_kills.is_empty():
		out.append("You shot nothing down.")
	else:
		out.append("Your kills: %s." % ", ".join(PackedStringArray(player_kills)))
	if player_bailed:
		out.append("You bailed out.")
	elif player_lost:
		out.append("You were shot down.")
	return out
