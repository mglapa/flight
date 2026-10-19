extends Node3D
## Anti-aircraft guns round every airfield and the mission's target (group
## "flak").
##
## Two kinds: heavy guns (the RAF's 3.7-inch, the Luftwaffe's 8.8 cm) throw
## time-fused shells up at bombers and leave black bursts in the sky, and
## light guns (Bofors 40 mm / 2 cm Flak) hose tracer at anything low and
## close.  Every gun shoots only at aircraft of the other side, and its shells
## only hurt them.  Aim is the target's predicted position plus an error that
## shrinks the longer the gun tracks the same aircraft, so a jinking fighter
## is far harder to hit than a bomber holding its bombing run.
##
## Guns are plain data (world coordinates) so a raid far from the player is
## still shot at; a gun is only built as a model when it is near the camera.
## An origin container: gun models and the tracer MultiMesh move with the
## floating origin, everything else is stored in world space.

const LowPoly := preload("res://scenes/plane/lowpoly_aircraft.gd")

enum { HEAVY, LIGHT }

const VIS_RANGE := 9000.0          ## gun models are built within this of the camera
const SCAN_EVERY := 0.25           ## re-list the aircraft and pick targets
const GRAVITY := 9.8

const HEAVY_RANGE := 9500.0        ## slant range
const HEAVY_MIN_AGL := 450.0
const HEAVY_SPEED := 620.0         ## mean shell speed up to the fuse point
const HEAVY_RELOAD := Vector2(3.2, 5.0)
const HEAVY_CORE := 15.0           ## inside this a burst is devastating
const HEAVY_REACH := 45.0          ## splinters reach this far
const HEAVY_TRACK := 20.0          ## seconds of tracking to reach full accuracy

const LIGHT_RANGE := 2600.0
const LIGHT_MIN_AGL := 20.0
const LIGHT_MAX_AGL := 2600.0
const LIGHT_MUZZLE := 850.0
const LIGHT_CLIP := 4              ## rounds per burst
const LIGHT_RATE := 0.5            ## seconds between rounds
const LIGHT_PAUSE := Vector2(1.4, 3.0)
const LIGHT_FUSE := 3.4            ## self-destruct time
const LIGHT_REACH := 7.0
const LIGHT_TRACK := 6.0
const TRACER_MAX := 400

## Gun layouts round an airfield, in its local frame (see dover_scenery.gd:
## hangars along +X, blast pens along -X, take-off line along Z)
const FIELD_LIGHT : Array = [Vector2(300, 790), Vector2(-300, 790), Vector2(300, -790), Vector2(-300, -790)]
const FIELD_HEAVY : Array = [Vector2(1250, 260), Vector2(-1250, -260)]

var geo                              ## GeoData
var mission : Node = null

var _guns : Array = []               ## see _add_gun()
var _shells : Array = []             ## light rounds: [world pos, velocity, age, side]
var _fused : Array = []              ## heavy shells in flight: [world burst point, time left, side, gun]
var _sounds : Array = []             ## [time due, world pos, stream, pitch, volume dB]
## Aircraft each side's guns may shoot at: [node, AGL, world position]
var _foes := {"raf": [], "lw": []}
var _scan := 0.0
var _vis := 0.0
var _time := 0.0
var _announced := false

var _smoke : Node = null
var _tracers : MultiMeshInstance3D
var _sfx : Array = []
var _sfx_next := 0

static var _meshes := {}
static var _streams := {}

func _ready() -> void:
	add_to_group("flak")
	add_to_group("origin_container")
	_smoke = get_tree().get_first_node_in_group("smoke_field")
	_place_guns()
	_build_tracers()
	_build_sfx()

# ---------------------------------------------------------------------------
# Placement
# ---------------------------------------------------------------------------

func _place_guns() -> void:
	for i in range(geo.airfields.size()):
		var a : Array = geo.airfields[i]
		var b := Basis(Vector3.UP, geo.airfield_yaw(i))
		var ap : Vector2 = a[2]
		for l in FIELD_LIGHT:
			_site(LIGHT, a[1], ap + _rot(b, l), 120.0, false, ap + _rot(b, l))
		for h in FIELD_HEAVY:
			var inside : Vector2 = h.normalized() * 850.0
			_site(HEAVY, a[1], ap + _rot(b, h), 300.0, false, ap + _rot(b, inside))
	if mission == null or mission.target == Vector2.INF or mission.defender == "":
		return
	# A gun belt round the target: heavy guns in a wide ring, light guns closer in
	var tgt : Vector2 = mission.target
	var r : float = mission.target_radius
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(mission.target_name)
	var heavy := 8 if r > 2000.0 else 6
	for k in range(heavy):
		var ang := TAU * k / heavy + rng.randf_range(-0.25, 0.25)
		var d := rng.randf_range(r * 0.6 + 700.0, r * 1.1 + 1900.0)
		_site(HEAVY, mission.defender, tgt + Vector2(cos(ang), sin(ang)) * d, 500.0, true)
	for k in range(6):
		var ang := TAU * (k + 0.5) / 6.0 + rng.randf_range(-0.3, 0.3)
		var d := rng.randf_range(r * 0.3 + 200.0, r * 0.8 + 500.0)
		_site(LIGHT, mission.defender, tgt + Vector2(cos(ang), sin(ang)) * d, 300.0, true)

static func _rot(b: Basis, l: Vector2) -> Vector2:
	var w := b * Vector3(l.x, 0, l.y)
	return Vector2(w.x, w.z)

## Puts a gun on the most open dry ground near `want` (or none if it's all water)
func _site(kind: int, side: String, want: Vector2, search: float, at_target: bool,
		fallback := Vector2.INF) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(want)
	var best := Vector2.INF
	var best_s := INF
	var tries := 48 if at_target else 24
	for i in range(tries):
		# Look further afield as the near spots turn out to be built up
		var reach := search * (1.0 + i / (5.0 if at_target else 8.0))
		if kind == LIGHT:
			reach = minf(reach, 2000.0)          # light guns are no use far out
		var p := want if i == 0 else want + Vector2(rng.randf_range(-1, 1), rng.randf_range(-1, 1)) * reach
		if geo.coast_d(p.x, p.y) < 60.0 or geo.water_edge(p.x, p.y) < 30.0:
			continue
		# Houses and trees stand where town / wood is above zero (and the
		# terrain draws streets a little beyond): keep well clear all round
		var lu : Color = geo.landuse_at(p.x, p.y)
		var town := lu.g
		var wood := lu.r
		for k in range(16):
			var o := Vector2.from_angle(TAU * k / 8.0) * (20.0 if k < 8 else 40.0)
			town = maxf(town, geo.town_density(p.x + o.x, p.y + o.y))
		var s := town * 12.0 + wood * 4.0 + p.distance_to(want) / maxf(search, 1.0) * 0.05
		if s < best_s:
			best_s = s
			best = p
		if s < 0.05:
			break
	if best == Vector2.INF or best_s > 3.4:          # houses start at town 0.3
		# All built up or water: an airfield's gun goes just inside its edge,
		# anywhere else the gun is left out rather than stood in a street
		if fallback == Vector2.INF:
			return
		best = fallback
	_add_gun(kind, side, Vector3(best.x, geo.surface_height(best.x, best.y), best.y), at_target)

func _add_gun(kind: int, side: String, pos: Vector3, at_target: bool) -> void:
	_guns.append({
		"kind": kind, "side": side, "pos": pos, "at_target": at_target,
		"target": null, "track": 0.0, "cool": randf_range(0.0, 3.0), "clip": LIGHT_CLIP,
		"aim": Vector3(randf_range(-1, 1), 1.2, randf_range(-1, 1)).normalized(),
		"node": null, "yaw": randf() * TAU, "pitch": 0.6, "recoil": 0.0, "flash": 0.0,
	})

## For the maps: [world Vector3, kind, side] of every gun
func gun_list() -> Array:
	var out : Array = []
	for g in _guns:
		out.append([g.pos, g.kind, g.side])
	return out

# ---------------------------------------------------------------------------
# Running
# ---------------------------------------------------------------------------

func _process(delta: float) -> void:
	_time += delta
	_scan -= delta
	if _scan <= 0.0:
		_scan = SCAN_EVERY
		_list_foes()
		for g in _guns:
			_pick_target(g)
	_vis -= delta
	if _vis <= 0.0:
		_vis = 0.5
		_update_models()
	for g in _guns:
		_run_gun(g, delta)
	_update_fused(delta)
	_update_shells(delta)
	_update_sounds()

func _list_foes() -> void:
	for s in _foes:
		_foes[s].clear()
	for n in get_tree().get_nodes_in_group("aircraft"):
		if not is_instance_valid(n) or not n.has_method("is_airborne") or not n.is_airborne():
			continue
		var s : String = n.side if n.is_in_group("ai") else GameSettings.side
		var w := WorldOrigin.to_world(n.global_position)
		var agl : float = w.y - geo.surface_height(w.x, w.z)
		_foes["lw" if s == "raf" else "raf"].append([n, agl, w])

func _pick_target(g: Dictionary) -> void:
	var best : Node3D = null
	var best_s := INF
	for f in _foes[g.side]:
		if not is_instance_valid(f[0]):
			continue                        # shot down since the list was made
		var d : float = (f[2] as Vector3).distance_to(g.pos)
		var agl : float = f[1]
		var s := d
		if g.kind == HEAVY:
			if d > HEAVY_RANGE or agl < HEAVY_MIN_AGL:
				continue
			if f[0].is_in_group("bombers"):
				s *= 0.6                    # the heavies are there for the bombers
		elif d > LIGHT_RANGE or agl < LIGHT_MIN_AGL or agl > LIGHT_MAX_AGL:
			continue
		if f[0] == g.target:
			s *= 0.5                        # stay on the aircraft already tracked
		if s < best_s:
			best_s = s
			best = f[0]
	if best != g.target:
		g.track = 0.0
	g.target = best

func _run_gun(g: Dictionary, delta: float) -> void:
	g.recoil = maxf(0.0, g.recoil - delta * 2.5)
	g.flash = maxf(0.0, g.flash - delta)
	if g.target != null and (not is_instance_valid(g.target) or not g.target.is_airborne()):
		g.target = null
	var t : Node3D = g.target
	if t == null:
		if g.node != null:
			_pose(g, delta)
		return
	g.track += delta
	g.cool -= delta
	if g.cool > 0.0 and g.node == null:
		return
	var tp := WorldOrigin.to_world(t.global_position)
	var tv : Vector3 = t.get_velocity()
	var muzzle : Vector3 = g.pos + Vector3(0, 2.0, 0)
	if g.kind == HEAVY:
		var tof := tp.distance_to(muzzle) / HEAVY_SPEED
		tof = (tp + tv * tof).distance_to(muzzle) / HEAVY_SPEED
		var aim := tp + tv * tof
		g.aim = (aim - muzzle).normalized()
		if g.cool <= 0.0:
			g.cool = randf_range(HEAVY_RELOAD.x, HEAVY_RELOAD.y)
			if g.aim.y > 0.15:
				_fire_heavy(g, aim, tof, muzzle)
	else:
		var tof := tp.distance_to(muzzle) / LIGHT_MUZZLE
		for i in range(2):
			tof = (tp + tv * tof).distance_to(muzzle) / LIGHT_MUZZLE
		var aim := tp + tv * tof + Vector3(0, 0.5 * GRAVITY * tof * tof, 0)
		g.aim = (aim - muzzle).normalized()
		if g.cool <= 0.0:
			if g.aim.y > 0.03:
				_fire_light(g, muzzle)
			g.clip -= 1
			if g.clip > 0:
				g.cool = LIGHT_RATE
			else:
				g.clip = LIGHT_CLIP
				g.cool = randf_range(LIGHT_PAUSE.x, LIGHT_PAUSE.y)
	if g.node != null:
		_pose(g, delta)

func _fire_heavy(g: Dictionary, aim: Vector3, tof: float, muzzle: Vector3) -> void:
	var d := aim.distance_to(muzzle)
	var sigma := (10.0 + d * 0.005) * lerpf(1.8, 1.0, clampf(g.track / HEAVY_TRACK, 0.0, 1.0))
	var p := aim + Vector3(randfn(0.0, sigma), randfn(0.0, sigma * 0.8), randfn(0.0, sigma))
	_fused.append([p, tof, g.side, g])
	_muzzle_fx(g, muzzle, 1.0)
	if g.at_target and not _announced and mission != null:
		_announced = true
		mission._say("Flak is coming up over %s." % mission.target_name)

func _fire_light(g: Dictionary, muzzle: Vector3) -> void:
	var s := lerpf(0.035, 0.012, clampf(g.track / LIGHT_TRACK, 0.0, 1.0))
	var dir := (g.aim as Vector3 + Vector3(randfn(0.0, s), randfn(0.0, s), randfn(0.0, s))).normalized()
	if _shells.size() < TRACER_MAX:
		_shells.append([muzzle, dir * LIGHT_MUZZLE, 0.0, g.side])
	_muzzle_fx(g, muzzle, 0.4)

func _muzzle_fx(g: Dictionary, muzzle: Vector3, size: float) -> void:
	if g.node == null:
		return
	g.recoil = 1.0
	g.flash = 0.07
	if _smoke:
		var sp := WorldOrigin.to_scene(muzzle + g.aim * 6.0 * size)
		_smoke.emit(sp, 0, 2.2 * size, 2.5, 1.0)
	_play(muzzle, "boom" if g.kind == HEAVY else "pom", 0.75 if g.kind == HEAVY else 1.0,
		0.0 if g.kind == HEAVY else -4.0)

## Heavy shells reach their fuse point and burst
func _update_fused(delta: float) -> void:
	for i in range(_fused.size() - 1, -1, -1):
		var f : Array = _fused[i]
		f[1] -= delta
		if f[1] > 0.0:
			continue
		_fused.remove_at(i)
		var p : Vector3 = f[0]
		if p.y < geo.surface_height(p.x, p.z) + 30.0:
			continue
		_burst_heavy(p, f[2])

func _burst_heavy(p: Vector3, side: String) -> void:
	if _smoke:
		var sp := WorldOrigin.to_scene(p)
		_smoke.emit(sp, 1, 2.6, 12.0, 0.3)
		_smoke.emit(sp + Vector3(randf_range(-3, 3), 1.5, randf_range(-3, 3)), 1, 1.8, 8.0, 0.5)
		_smoke.emit(sp, 2, 2.4, 0.2, 0.0)
	_play(p, "boom", 1.0, 2.0)
	for f in _foes[side]:
		if not is_instance_valid(f[0]):
			continue
		var n : Node3D = f[0]
		var d := WorldOrigin.to_world(n.global_position).distance_to(p)
		if d > HEAVY_REACH:
			continue
		var hits := 3 if d < HEAVY_CORE else (1 if randf() < 1.0 - smoothstep(HEAVY_CORE, HEAVY_REACH, d) else 0)
		# Shell splinters: hard on the AI's big damage pools, gentler on the
		# player, whose every component has only a few points
		var dmg := 2 if n.is_in_group("player") else 4
		for k in range(hits):
			n.take_hit(n.global_position + Vector3(randf_range(-2, 2), randf_range(-1, 1), randf_range(-2, 2)), dmg, self)
			if not n.is_airborne():
				break

## Light rounds fly on under gravity until they pass close to a target or
## self-destruct
func _update_shells(delta: float) -> void:
	var cam := get_viewport().get_camera_3d()
	var cam_w := WorldOrigin.to_world(cam.global_position) if cam else Vector3.ZERO
	var mm := _tracers.multimesh
	var shown := 0
	_tracers.position = Vector3.ZERO
	for i in range(_shells.size() - 1, -1, -1):
		var s : Array = _shells[i]
		var a : Vector3 = s[0]
		var v : Vector3 = s[1]
		v.y -= GRAVITY * delta
		var b := a + v * delta
		s[0] = b
		s[1] = v
		s[2] += delta
		var hit : Node3D = null
		for f in _foes[s[3]]:
			if not is_instance_valid(f[0]):
				continue
			var n : Node3D = f[0]
			if _seg_dist(WorldOrigin.to_world(n.global_position), a, b) < LIGHT_REACH:
				hit = n
				break
		if hit != null:
			hit.take_hit(hit.global_position + Vector3(randf_range(-1.5, 1.5), randf_range(-0.5, 0.5), randf_range(-1.5, 1.5)), 2, self)
			_burst_light(b)
			_shells.remove_at(i)
			continue
		if s[2] > LIGHT_FUSE:
			_burst_light(b)
			_shells.remove_at(i)
			continue
		if shown < TRACER_MAX and b.distance_to(cam_w) < 7000.0:
			var dir := v.normalized()
			var up := Vector3.UP if absf(dir.y) < 0.95 else Vector3.RIGHT
			mm.set_instance_transform(shown, Transform3D(Basis.looking_at(dir, up), WorldOrigin.to_scene(b)))
			shown += 1
	mm.visible_instance_count = shown

func _burst_light(p: Vector3) -> void:
	if _smoke:
		var sp := WorldOrigin.to_scene(p)
		_smoke.emit(sp, 0, 2.2, 4.0, 0.2)
		_smoke.emit(sp, 2, 1.4, 0.12, 0.0)

static func _seg_dist(p: Vector3, a: Vector3, b: Vector3) -> float:
	var ab := b - a
	var t := clampf((p - a).dot(ab) / maxf(ab.length_squared(), 1e-6), 0.0, 1.0)
	return p.distance_to(a + ab * t)

# ---------------------------------------------------------------------------
# Sound: a flak burst's crump and the guns' bark, delayed by the speed of
# sound and played from a small pool of 3D players
# ---------------------------------------------------------------------------

func _build_sfx() -> void:
	if _streams.is_empty():
		_streams["boom"] = _make_wav(1.3, 42.0, 7.0, 3.6, 1600.0, 260.0)
		_streams["pom"] = _make_wav(0.35, 85.0, 22.0, 16.0, 2600.0, 600.0)
	for i in range(10):
		var p := AudioStreamPlayer3D.new()
		p.unit_size = 90.0
		p.max_distance = 6000.0
		p.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		p.bus = "Master"
		add_child(p)
		_sfx.append(p)

func _play(world: Vector3, what: String, pitch: float, vol: float) -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var d := WorldOrigin.to_world(cam.global_position).distance_to(world)
	if d > 5000.0 or _sounds.size() > 24:
		return
	_sounds.append([_time + d / 343.0, world, _streams[what], pitch * randf_range(0.9, 1.1), vol])

func _update_sounds() -> void:
	for i in range(_sounds.size() - 1, -1, -1):
		var s : Array = _sounds[i]
		if _time < s[0]:
			continue
		_sounds.remove_at(i)
		var p : AudioStreamPlayer3D = _sfx[_sfx_next]
		_sfx_next = (_sfx_next + 1) % _sfx.size()
		p.stream = s[2]
		p.pitch_scale = s[3]
		p.volume_db = s[4]
		p.global_position = WorldOrigin.to_scene(s[1])
		p.play()

## A noise burst with a falling low-pass and a low thump under it
static func _make_wav(dur: float, thump_hz: float, thump_decay: float, decay: float,
		cut0: float, cut1: float) -> AudioStreamWAV:
	const RATE := 22050
	var n := int(dur * RATE)
	var data := PackedByteArray()
	data.resize(n * 2)
	var rng := RandomNumberGenerator.new()
	rng.seed = int(thump_hz * 1000.0)
	var lp1 := 0.0
	var lp2 := 0.0
	for i in range(n):
		var t := float(i) / RATE
		var cut := lerpf(cut0, cut1, sqrt(t / dur))
		var k := 1.0 - exp(-TAU * cut / RATE)
		lp1 += (rng.randf_range(-1.0, 1.0) - lp1) * k
		lp2 += (lp1 - lp2) * k
		var env := (1.0 - exp(-t * 900.0)) * exp(-t * decay)
		var thump := sin(TAU * thump_hz * t * (1.0 - t * 0.25)) * exp(-t * thump_decay)
		var s := tanh(lp2 * env * 4.0 + thump * 0.9) * (1.0 - smoothstep(dur * 0.8, dur, t))
		data.encode_s16(i * 2, int(clampf(s, -1.0, 1.0) * 30000.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = RATE
	w.stereo = false
	w.data = data
	return w

# ---------------------------------------------------------------------------
# Models
# ---------------------------------------------------------------------------

func _build_tracers() -> void:
	var box := BoxMesh.new()
	box.size = Vector3(0.5, 0.5, 9.0)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 0.62, 0.25)
	box.material = mat
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = box
	mm.instance_count = TRACER_MAX
	mm.visible_instance_count = 0
	_tracers = MultiMeshInstance3D.new()
	_tracers.name = "Tracers"
	_tracers.multimesh = mm
	_tracers.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mm.custom_aabb = AABB(Vector3(-1e5, -1000, -1e5), Vector3(2e5, 20000, 2e5))
	add_child(_tracers)

## Builds the models of guns near the camera and drops the far ones
func _update_models() -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var c := WorldOrigin.to_world(cam.global_position)
	for g in _guns:
		var d := Vector2(c.x - g.pos.x, c.z - g.pos.z).length()
		if g.node == null and d < VIS_RANGE:
			g.node = _make_model(g)
		elif g.node != null and d > VIS_RANGE + 1500.0:
			g.node.queue_free()
			g.node = null
		elif g.node != null:
			_snap(g.node)

## Sits a gun on the terrain as built: the mesh differs a little from the
## height data, and finer tiles replace coarse ones as the camera closes in
func _snap(root: Node3D) -> void:
	var p := root.position
	var q := PhysicsRayQueryParameters3D.create(Vector3(p.x, p.y + 300.0, p.z), Vector3(p.x, p.y - 300.0, p.z), 1)
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if hit:
		root.position.y = hit.position.y - 0.15

## Turns the mount and lifts the barrel toward the aim (slewing at a gun's pace)
func _pose(g: Dictionary, delta: float) -> void:
	var node : Node3D = g.node
	var aim : Vector3 = g.aim if g.target != null else Vector3(0, 0, 0)
	var rate := 0.45 if g.kind == HEAVY else 1.1
	if g.target != null:
		var want_yaw := atan2(-aim.x, -aim.z)
		g.yaw = rotate_toward(g.yaw, want_yaw, rate * delta)
		g.pitch = move_toward(g.pitch, asin(clampf(aim.y, -1.0, 1.0)), rate * 0.7 * delta)
	else:
		g.pitch = move_toward(g.pitch, 0.75 if g.kind == HEAVY else 0.35, 0.2 * delta)
	var mount : Node3D = node.get_child(0)
	var barrel : Node3D = mount.get_child(0)
	mount.rotation.y = g.yaw
	barrel.rotation.x = g.pitch
	barrel.get_child(0).position.z = g.recoil * (0.7 if g.kind == HEAVY else 0.25)
	barrel.get_child(1).visible = g.flash > 0.0

func _make_model(g: Dictionary) -> Node3D:
	var key := "%d_%s" % [g.kind, g.side]
	if not _meshes.has(key):
		_meshes[key] = _build_meshes(g.kind, g.side)
	var m : Array = _meshes[key]
	var root := Node3D.new()
	root.name = "Gun"
	var mount := Node3D.new()
	var barrel := Node3D.new()
	var heavy : bool = g.kind == HEAVY
	mount.position.y = 1.3 if heavy else 0.75
	barrel.position.y = 1.0 if heavy else 0.6
	root.add_child(mount)
	mount.add_child(barrel)
	var gun := MeshInstance3D.new()
	gun.mesh = m[2]
	barrel.add_child(gun)                  # child 0: the barrel (recoils)
	var flash := MeshInstance3D.new()
	flash.mesh = m[3]
	flash.position = Vector3(0, 0, -6.6 if heavy else -2.9)
	flash.visible = false
	flash.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	barrel.add_child(flash)                # child 1: the muzzle flash
	var mi := MeshInstance3D.new()
	mi.mesh = m[1]
	mount.add_child(mi)
	var base := MeshInstance3D.new()
	base.mesh = m[0]
	root.add_child(base)
	for n in [gun, mi, base]:
		n.visibility_range_end = VIS_RANGE + 1500.0
	base.rotation.y = randf() * TAU        # sandbags and crew at a random turn
	add_child(root)
	root.position = WorldOrigin.to_scene(g.pos - Vector3(0, 0.25, 0))
	_snap(root)
	mount.rotation.y = g.yaw
	return root

## [base, mount, barrel, flash] meshes for one kind of gun and side
static func _build_meshes(kind: int, side: String) -> Array:
	var raf := side == "raf"
	var paint := Color(0.33, 0.36, 0.24) if raf else Color(0.40, 0.42, 0.41)
	var dark := paint.darkened(0.3)
	var steel := Color(0.22, 0.23, 0.22)
	var sand := Color(0.34, 0.30, 0.20)
	var kit := Color(0.45, 0.40, 0.28) if raf else Color(0.34, 0.37, 0.33)
	var heavy := kind == HEAVY
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.85

	# Base: sandbag ring, platform, crew
	var st := LowPoly._begin()
	var ring_r := 6.0 if heavy else 3.8
	var segs := 14 if heavy else 10
	for i in range(segs):
		var a := TAU * i / segs
		var w := TAU * ring_r / segs * 0.92
		var b := Basis(Vector3.UP, -a)
		var c := Vector3(cos(a), 0, sin(a)) * ring_r
		if i == 0:
			continue                           # a gap to walk in
		var col := sand.darkened(0.08 * (i % 2))
		var th := 1.1 if heavy else 0.75
		var lo := 0.7 if heavy else 0.5
		_box(st, c + Vector3(0, lo * 0.5, 0), Vector3(th, lo, w), col, b)
		_box(st, c + Vector3(0, lo + 0.22, 0), Vector3(th * 0.8, 0.45, w * 0.95), col.lightened(0.05), b.rotated(Vector3.UP, 0.08))
	if heavy:
		_box(st, Vector3(0, 0.25, 0), Vector3(8.0, 0.3, 0.6), dark, Basis.IDENTITY)
		_box(st, Vector3(0, 0.25, 0), Vector3(0.6, 0.3, 8.0), dark, Basis.IDENTITY)
		for p in [Vector3(4, 0.1, 0), Vector3(-4, 0.1, 0), Vector3(0, 0.1, 4), Vector3(0, 0.1, -4)]:
			_box(st, p, Vector3(0.9, 0.2, 0.9), steel, Basis.IDENTITY)
		LowPoly._cylinder(st, Vector3(0, 0.3, 0), Vector3.UP, 0.7, 0.55, 1.0, 8, paint)
		# Ready-use ammunition boxes inside the ring
		for p in [Vector3(-4.2, 0.3, 2.6), Vector3(-3.4, 0.3, 3.4), Vector3(3.8, 0.3, -3.0)]:
			_box(st, p, Vector3(0.8, 0.6, 0.5), Color(0.30, 0.26, 0.18), Basis(Vector3.UP, p.x))
	else:
		_box(st, Vector3(0, 0.3, 0), Vector3(1.8, 0.35, 3.2), dark, Basis.IDENTITY)
		_box(st, Vector3(0, 0.25, 0), Vector3(4.4, 0.2, 0.4), dark, Basis.IDENTITY)
		LowPoly._cylinder(st, Vector3(0, 0.45, 0), Vector3.UP, 0.45, 0.4, 0.4, 8, paint)
		_box(st, Vector3(2.4, 0.25, -1.8), Vector3(0.6, 0.5, 0.4), Color(0.30, 0.26, 0.18), Basis.IDENTITY)
	var crew : Array = [Vector3(-2.6, 0, 1.4), Vector3(2.2, 0, 2.2), Vector3(1.6, 0, -2.6)] if heavy \
		else [Vector3(-1.9, 0, 1.2), Vector3(1.7, 0, -1.4)]
	for p in crew:
		_man(st, p, kit, raf)
	var base := st.commit()
	base.surface_set_material(0, mat)

	# Mount (turns): carriage, side plates, layers' seats
	st = LowPoly._begin()
	if heavy:
		_box(st, Vector3(0, 0.15, 0.2), Vector3(1.8, 0.4, 2.6), paint, Basis.IDENTITY)
		for x in [-0.6, 0.6]:
			_box(st, Vector3(x, 0.85, 0.1), Vector3(0.14, 1.2, 1.6), paint, Basis.IDENTITY)
			_box(st, Vector3(x * 1.7, 0.55, 0.6), Vector3(0.45, 0.1, 0.45), steel, Basis.IDENTITY)
		_box(st, Vector3(0.9, 0.55, -0.6), Vector3(0.4, 0.6, 0.5), dark, Basis.IDENTITY)   # fuze setter
	else:
		_box(st, Vector3(0, 0.2, 0), Vector3(1.0, 0.4, 1.2), paint, Basis.IDENTITY)
		for x in [-0.38, 0.38]:
			_box(st, Vector3(x, 0.55, 0), Vector3(0.1, 0.7, 0.8), paint, Basis.IDENTITY)
			_box(st, Vector3(x * 2.0, 0.45, 0.4), Vector3(0.35, 0.08, 0.35), steel, Basis.IDENTITY)
	var mount := st.commit()
	mount.surface_set_material(0, mat)

	# Barrel (elevates, recoils): cradle, tube, recuperator; 88s and 2 cm guns get a shield
	st = LowPoly._begin()
	if heavy:
		var length := 5.9 if raf else 6.4
		_box(st, Vector3(0, 0, 0.3), Vector3(0.55, 0.55, 2.6), paint, Basis.IDENTITY)
		_box(st, Vector3(0, 0, 1.8), Vector3(0.7, 0.7, 0.6), dark, Basis.IDENTITY)          # breech
		LowPoly._cylinder(st, Vector3(0, 0.05, -0.9), Vector3(0, 0, -1), 0.15, 0.11, length - 0.7, 8, paint)
		LowPoly._cylinder(st, Vector3(0, -0.32, -0.6), Vector3(0, 0, -1), 0.13, 0.13, 2.2, 6, dark)
		if not raf:
			_box(st, Vector3(0, 0.1, -0.9), Vector3(2.4, 1.5, 0.08), paint, Basis.IDENTITY)
	else:
		var length := 2.3 if raf else 1.6
		_box(st, Vector3(0, 0, 0.2), Vector3(0.32, 0.36, 1.1), paint, Basis.IDENTITY)
		LowPoly._cylinder(st, Vector3(0, 0.02, -0.35), Vector3(0, 0, -1), 0.055, 0.05, length, 6, steel)
		LowPoly._cylinder(st, Vector3(0, 0.02, -0.35 - length), Vector3(0, 0, -1), 0.06, 0.1, 0.25, 6, steel)
		if raf:
			_box(st, Vector3(0, 0.3, 0.15), Vector3(0.14, 0.3, 0.35), Color(0.55, 0.45, 0.20), Basis.IDENTITY)   # clip
		else:
			_box(st, Vector3(0, 0.15, -0.2), Vector3(1.2, 0.8, 0.05), paint, Basis.IDENTITY)
	var barrel := st.commit()
	barrel.surface_set_material(0, mat)

	var flash := SphereMesh.new()
	flash.radius = 1.3 if heavy else 0.45
	flash.height = flash.radius * 2.6
	flash.radial_segments = 6
	flash.rings = 3
	var fm := StandardMaterial3D.new()
	fm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	fm.albedo_color = Color(1.0, 0.75, 0.3)
	flash.material = fm
	return [base, mount, barrel, flash]

## A standing gunner: legs, body, arms, head and tin hat
static func _man(st: SurfaceTool, at: Vector3, kit: Color, raf: bool) -> void:
	var b := Basis(Vector3.UP, at.x * 1.7)
	var skin := Color(0.85, 0.66, 0.52)
	_box(st, at + b * Vector3(-0.12, 0.42, 0), Vector3(0.18, 0.84, 0.22), kit.darkened(0.15), b)
	_box(st, at + b * Vector3(0.12, 0.42, 0), Vector3(0.18, 0.84, 0.22), kit.darkened(0.15), b)
	_box(st, at + Vector3(0, 1.15, 0), Vector3(0.48, 0.62, 0.28), kit, b)
	_box(st, at + b * Vector3(-0.32, 1.1, -0.08), Vector3(0.13, 0.58, 0.15), kit, b)
	_box(st, at + b * Vector3(0.32, 1.1, -0.08), Vector3(0.13, 0.58, 0.15), kit, b)
	_box(st, at + Vector3(0, 1.6, 0), Vector3(0.22, 0.24, 0.22), skin, b)
	var hat := Color(0.30, 0.33, 0.24) if raf else Color(0.36, 0.38, 0.36)
	if raf:
		_box(st, at + Vector3(0, 1.75, 0), Vector3(0.44, 0.04, 0.44), hat, b)          # Brodie brim
		_box(st, at + Vector3(0, 1.8, 0), Vector3(0.26, 0.1, 0.26), hat, b)
	else:
		_box(st, at + Vector3(0, 1.76, 0), Vector3(0.3, 0.16, 0.32), hat, b)           # Stahlhelm
		_box(st, at + Vector3(0, 1.67, 0.04), Vector3(0.34, 0.06, 0.34), hat, b)

static func _box(st: SurfaceTool, c: Vector3, s: Vector3, col: Color, b: Basis) -> void:
	var h := s * 0.5
	var p : Array = []
	for i in range(8):
		var l := Vector3(h.x if i & 1 else -h.x, h.y if i & 2 else -h.y, h.z if i & 4 else -h.z)
		p.append(c + b * l)
	for f in [[0, 1, 3, 2], [4, 6, 7, 5], [0, 4, 5, 1], [2, 3, 7, 6], [0, 2, 6, 4], [1, 5, 7, 3]]:
		LowPoly._tri(st, p[f[0]], p[f[1]], p[f[2]], col, c)
		LowPoly._tri(st, p[f[0]], p[f[2]], p[f[3]], col, c)
