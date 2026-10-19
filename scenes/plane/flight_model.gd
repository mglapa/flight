extends RefCounted
## Shared flight model: the player, the AI fighters and the bombers all fly
## this, with the values of their type (aircraft_types.gd / bomber.gd).
##
## Physics
##   - Standard atmosphere: air density (lift, drag, engine) and the speed of
##     sound fall with height.
##   - Piston engines give roughly constant power up to their rated altitude
##     (the supercharger), then lose it with the air; the propeller turns that
##     power into thrust that falls with speed.  Jets: thrust with density.
##   - Lift curve with a rounded peak and a soft drop past the stall; induced
##     drag (hard turns bleed speed), separation drag and compressibility.
##
## Controls (the approachable part)
##   The stick asks for angle of attack, scaled so that neutral holds 1 G,
##   full back pulls the G limit (5 G) — or, below corner speed, just past the
##   stall into the buffet.  Rolls and the rudder ask for rates.  The aircraft
##   chases those demands within the authority its control surfaces have at
##   the current airspeed, so a slow aircraft is sluggish and a stalled one
##   barely answers.
##
## Stalls and spins
##   Buffet builds near the stall.  Pulled past it (slow, at the top of a zoom,
##   or yanked in a slow turn) a wing drops; hold the stick back and add
##   rudder and she spins.  Stick forward and opposite rudder recover.
##
## Pilot
##   Sustained G past the pilot's tolerance greys the view out (`grey`); held
##   long enough he blacks out (`blackout`) and the stick goes slack until he
##   comes round.  Strong negative G reds out (`red`).

const GRAVITY := 9.81
const RHO0 := 1.225
const Q_REF := 0.5 * RHO0 * 75.0 * 75.0     # dynamic pressure for full control authority

# ── Type values (setup()) ───────────────────────────────────────────────────
var mass := 3000.0
var wing_area := 22.0
var aspect := 5.7
var cd0 := 0.021
var oswald := 0.78
var cl_slope := 5.2              # per radian
var alpha0 := -0.03              # zero-lift angle (cambered wing)
var x_stall := 0.31              # stall angle measured from alpha0 (rad)
var cl_max := 1.4
var engine := "prop"
var power := 770000.0            # W at the rated altitude
var rated_alt := 5000.0          # m
var prop_eff := 0.85
var prop_v0 := 40.0              # m/s: sets the static thrust (eff * power / v0)
var jet_thrust := 0.0            # N at sea level
var mcrit := 0.72                # Mach number where compressibility drag starts
var g_max := 5.0
var g_min := -2.5
var g_tol := 3.8                 # G the pilot holds without greying out
var pitch_auth := 8.0            # rad/s² of pitch the elevator can give at full authority
var roll_max := 2.1              # rad/s full-stick roll rate at medium speed
var roll_auth := 14.0
var yaw_auth := 3.0
## AI pilots stop short of the stall (negative), the player can pull a little past it
var alpha_margin := deg_to_rad(1.5)
## Player assist: rolls gently back toward wings level with the stick centred
var auto_level := 0.0

# ── Damage and engine state (set by the owner each frame, 0..1) ─────────────
var dmg_wing := 0.0
var dmg_elev := 0.0
var dmg_rudder := 0.0
var power_scale := 1.0           # engine damage and fuel

# ── State ───────────────────────────────────────────────────────────────────
var velocity := Vector3.ZERO
var pitch_rate := 0.0            # rad/s, + nose up
var roll_rate := 0.0             # rad/s, + roll right
var yaw_rate := 0.0              # rad/s, + nose right
var accel := Vector3.ZERO

# ── Outputs ─────────────────────────────────────────────────────────────────
var alpha := 0.0
var beta := 0.0
var rho := RHO0
var tas := 0.0
var ias := 0.0                   # what the airspeed indicator reads (m/s)
var mach := 0.0
var g_force := 1.0
var thrust := 0.0
var buffet := 0.0                # 0..1 shake from the stall or compressibility
var stall := 0.0                 # 0..1 how far past the stall
var spin := 0.0                  # -1..1 developed spin (sign = direction)
var is_stalling := false
var g_stress := 0.0              # pilot: 0..1.25 (1 = blacked out)
var red_stress := 0.0
var grey := 0.0                  # view greying 0..1
var blackout := 0.0              # pilot unconscious 0..1
var red := 0.0

var _t := 0.0

## Reads a type's values: aircraft_types.gd or a bomber profile
func setup(p: Dictionary) -> void:
	mass = p.mass
	wing_area = p.wing_area
	aspect = p.span * p.span / wing_area
	cd0 = p.cd0
	oswald = p.get("oswald", 0.78)
	cl_max = p.get("cl_max", 1.4)
	var a_stall : float = deg_to_rad(p.get("stall_deg", 16.0))
	# The lift curve's peak sits at the stall: cl_max = slope * x_stall * 0.875
	x_stall = a_stall - alpha0
	cl_slope = cl_max / (x_stall * 0.875)
	engine = p.get("engine", "prop")
	power = p.get("power", 770000.0)
	# Game boost: more power for a faster climb to the fight, with drag to
	# match so top speeds stay historical
	var boost : float = p.get("climb_boost", 1.0)
	power *= boost
	cd0 *= pow(boost, p.get("boost_drag", 0.9))
	rated_alt = p.get("rated_alt", 5000.0)
	prop_v0 = p.get("prop_v0", 40.0)
	jet_thrust = p.get("thrust", 0.0)
	mcrit = p.get("mcrit", 0.72)
	g_max = p.get("g_max", 5.0)
	g_min = p.get("g_min", -2.5)
	g_tol = p.get("g_tol", 3.8)
	pitch_auth = p.get("pitch_auth", 8.0)
	roll_max = p.get("roll_max", 2.1)
	roll_auth = p.get("roll_auth", 14.0)
	yaw_auth = p.get("yaw_auth", 3.0)

# ── Atmosphere ──────────────────────────────────────────────────────────────

static func density(h: float) -> float:
	h = clampf(h, -500.0, 20000.0)
	if h < 11000.0:
		return RHO0 * pow(1.0 - 2.25577e-5 * h, 4.2559)
	return 0.3639 * exp(-(h - 11000.0) / 6341.6)

static func sound_speed(h: float) -> float:
	var t := maxf(288.15 - 0.0065 * clampf(h, -500.0, 11000.0), 216.65)
	return sqrt(1.4 * 287.05 * t)

## Engine power available at height `h` at full throttle (piston engines)
func power_at(h: float) -> float:
	if h < rated_alt:
		return power * (0.86 + 0.14 * maxf(h, 0.0) / rated_alt)
	return power * pow(density(h) / density(rated_alt), 1.1)

## Thrust at full throttle, height `h`, forward speed `v`
func thrust_at(h: float, v: float) -> float:
	if engine == "jet":
		return jet_thrust * pow(density(h) / RHO0, 0.75)
	return prop_eff * power_at(h) / sqrt(v * v + prop_v0 * prop_v0)

## Lift-off speed scale: the 1 G stall speed at sea level
func stall_speed(h := 0.0) -> float:
	return sqrt(2.0 * mass * GRAVITY / (density(h) * wing_area * cl_max))

# ── Lift curve ──────────────────────────────────────────────────────────────

## Lift coefficient: linear, rounding over to cl_max at the stall, then
## falling away and blending into a flat plate.  The negative side stalls a
## little earlier.
func lift_coef(a: float) -> float:
	var x := a - alpha0
	var xs := x_stall if x >= 0.0 else x_stall * 0.8
	var ax := absf(x)
	var xk := xs * 0.75
	var top := cl_slope * xs * 0.875
	var cl : float
	if ax <= xk:
		cl = cl_slope * ax
	elif ax <= xs:
		var t := (ax - xk) / (xs - xk)
		var b := cl_slope * (xs - xk)
		cl = cl_slope * xk + b * t - b * 0.5 * t * t
	else:
		var post := top * (1.0 - 0.35 * smoothstep(0.0, 0.14, ax - xs))
		var plate := 1.05 * absf(sin(2.0 * minf(ax, PI * 0.5)))
		cl = lerpf(post, plate, smoothstep(xs + 0.14, xs + 0.6, ax))
	return cl * signf(x)

## Angle of attack that gives lift coefficient `cl` (inverse of the curve
## below the stall; anything beyond is clamped by the caller)
func alpha_for_cl(cl: float) -> float:
	var xs := x_stall if cl >= 0.0 else x_stall * 0.8
	var xk := xs * 0.75
	var c := absf(cl)
	var ck := cl_slope * xk
	var x : float
	if c <= ck:
		x = c / cl_slope
	else:
		var b := cl_slope * (xs - xk)
		x = xk + (xs - xk) * (1.0 - sqrt(maxf(1.0 - 2.0 * (c - ck) / b, 0.0)))
	return alpha0 + x * signf(cl)

# ── Step ────────────────────────────────────────────────────────────────────

## Advances `body` one step.  Controls: `stick` pitch (+ back), `roll`
## (+ right), `rudder` (+ right), `throttle` 0..1.  AI pilots give `g_cmd`
## (the load factor they want) instead of the stick.  On the ground the stick
## works the elevator directly and the undercarriage (the owner) does the rest.
func step(body: Node3D, delta: float, stick: float, roll: float, rudder: float,
		throttle: float, g_cmd := NAN, on_ground := false) -> void:
	_t += delta
	var b := body.global_transform.basis
	var fwd := -b.z
	var up := b.y
	var right := b.x
	var h := body.global_position.y

	rho = density(h)
	var V := velocity.length()
	tas = V
	ias = V * sqrt(rho / RHO0)
	mach = V / sound_speed(h)
	var v_fwd := velocity.dot(fwd)
	alpha = 0.0
	beta = 0.0
	if V > 3.0:
		alpha = atan2(-velocity.dot(up), maxf(v_fwd, 3.0))
		beta = atan2(velocity.dot(right), maxf(v_fwd, 3.0))
	var q := 0.5 * rho * V * V
	var qS := q * wing_area
	var ctrl := clampf(q / Q_REF, 0.0, 1.0)
	# Compressibility stiffens the controls
	var m_over := smoothstep(mcrit, mcrit + 0.12, mach)
	ctrl *= 1.0 - 0.55 * m_over

	# ── Forces ──────────────────────────────────────────────────────────────
	var lift_mult := 1.0 - dmg_wing * 0.9
	var cl := lift_coef(alpha)
	var x := absf(alpha - alpha0)
	var xs := x_stall if alpha >= alpha0 else x_stall * 0.8
	var sep := smoothstep(xs - 0.03, xs + 0.12, x)
	var cd := cd0 + cl * cl / (PI * aspect * oswald) + 1.25 * pow(sin(minf(x, PI * 0.5)), 2.0) * sep
	if engine == "jet":
		cd += 0.022 * smoothstep(0.95, 1.15, mach)
	else:
		cd += 2.5 * pow(maxf(mach - mcrit, 0.0), 2.0)

	var vdir := velocity / V if V > 0.1 else fwd
	var lift_dir := (up - vdir * up.dot(vdir))
	lift_dir = lift_dir.normalized() if lift_dir.length_squared() > 1e-6 else up
	var lift_f := lift_dir * qS * cl * lift_mult
	var drag_f := -vdir * qS * cd if V > 1.0 else Vector3.ZERO
	var side_f := -right * qS * beta * 0.5
	thrust = thrust_at(h, maxf(v_fwd, 0.0)) * clampf(throttle, 0.0, 1.0) * power_scale
	var weight := Vector3.DOWN * mass * GRAVITY
	accel = (lift_f + drag_f + side_f + fwd * thrust + weight) / mass
	velocity += accel * delta
	g_force = (accel + Vector3.UP * GRAVITY).dot(up) / GRAVITY

	# ── Stall state ─────────────────────────────────────────────────────────
	var x_pos := alpha - alpha0                 # spins come from positive stalls
	stall = clampf((x_pos - x_stall - 0.03) / 0.1, 0.0, 1.0)
	is_stalling = x > xs + 0.035 and V > 5.0       # past the full-stick buffet: departing
	var near := smoothstep(x_stall - 0.02, x_stall + 0.02, x_pos)
	buffet = clampf(smoothstep(xs - 0.06, xs + 0.04, x) * clampf(q / Q_REF + 0.3, 0.0, 1.0)
		+ m_over * 0.6 + absf(spin) * 0.3, 0.0, 1.0)

	# ── Pilot ───────────────────────────────────────────────────────────────
	if g_force > g_tol:
		g_stress += (g_force - g_tol) * 0.11 * delta
	else:
		g_stress -= (0.05 + (g_tol - g_force) * 0.15) * delta
	g_stress = clampf(g_stress, 0.0, 1.25)
	if g_force < -1.5:
		red_stress += (-1.5 - g_force) * 0.35 * delta
	else:
		red_stress -= 0.4 * delta
	red_stress = clampf(red_stress, 0.0, 1.2)
	grey = smoothstep(0.1, 0.92, g_stress)
	blackout = smoothstep(0.92, 1.05, g_stress)
	red = smoothstep(0.1, 1.0, red_stress)
	var slack := 1.0 - maxf(blackout, smoothstep(0.85, 1.0, red_stress))
	stick *= slack
	roll *= slack
	rudder *= slack

	# ── Spin ────────────────────────────────────────────────────────────────
	if stall > 0.25:
		var asym := sin(body.global_position.x * 0.013 + body.global_position.z * 0.009) * 0.3
		var drop := signf(yaw_rate * 2.0 + roll_rate * 0.5 - beta * 2.0 + rudder + asym)
		spin += drop * (stall - 0.25) * 1.2 * delta
	if near > 0.0 and stick > 0.7:
		spin += rudder * near * 0.9 * delta          # rudder at the stall: deliberate entry
	if stall < 0.2:
		spin = move_toward(spin, 0.0, (0.8 + maxf(-stick, 0.0)) * delta)
	if spin * rudder < 0.0:
		spin = move_toward(spin, 0.0, absf(rudder) * 0.6 * delta)  # opposite rudder
	spin = clampf(spin, -1.0, 1.0)
	var sw := absf(spin)

	# ── Pitch ───────────────────────────────────────────────────────────────
	var auth_floor := maxf(ctrl, 0.15)
	var pitch_accel : float
	var lift_den := maxf(qS * lift_mult, 1.0)
	var a_hi := alpha0 + x_stall + alpha_margin
	var a_lo := alpha0 - x_stall * 0.8 - alpha_margin
	if on_ground:
		var eff_g := clampf(q / (0.5 * RHO0 * 80.0 * 80.0), 0.0, 1.5)
		pitch_accel = (stick * 2.0 - alpha) * eff_g * (1.0 - dmg_elev) \
			- pitch_rate * 3.5 * (0.5 + 0.5 * eff_g)
	else:
		var w_fp := accel.dot(lift_dir) / maxf(V, 5.0)
		var a_cmd : float
		if is_nan(g_cmd):
			var a_trim := minf(_alpha_for_g(1.0, lift_den), alpha0 + x_stall - 0.05)
			if stick >= 0.0:
				a_cmd = lerpf(a_trim, minf(_alpha_for_g(g_max, lift_den), a_hi), stick)
			else:
				a_cmd = lerpf(a_trim, maxf(_alpha_for_g(g_min, lift_den), a_lo), -stick)
		else:
			var g := lerpf(clampf(g_cmd, g_min, g_max), 1.0, 1.0 - slack)
			a_cmd = clampf(_alpha_for_g(g, lift_den), a_lo, a_hi)
		a_cmd = clampf(a_cmd, a_lo, a_hi)
		# A developed spin holds the stall while the stick stays back
		a_cmd = lerpf(a_cmd, 0.6, sw * smoothstep(0.3, 0.8, stick))
		var rate_cmd := w_fp + (a_cmd - alpha) * 6.0
		var p_auth := pitch_auth * auth_floor * (1.0 - dmg_elev * 0.8) * (1.0 - 0.6 * stall)
		pitch_accel = clampf((rate_cmd - pitch_rate) * 12.0, -p_auth, p_auth)

	# ── Roll ────────────────────────────────────────────────────────────────
	var hs_fade := 1.0 - 0.45 * smoothstep(150.0, 210.0, ias)
	var p_max := roll_max * clampf(ias / 70.0, 0.0, 1.0) * hs_fade * (1.0 - dmg_wing * 0.7) * (1.0 - 0.7 * stall)
	var p_cmd := roll * p_max - beta * 1.5 * ctrl
	if auto_level > 0.0 and absf(roll) < 0.1 and stall == 0.0:
		p_cmd += right.y * auto_level
	var roll_accel := clampf((p_cmd - roll_rate) * 10.0, -roll_auth * auth_floor, roll_auth * auth_floor)
	# Wing rock in the buffet
	roll_accel += sin(_t * 7.3) * sin(_t * 2.9 + 1.0) * buffet * 2.0 * (1.0 - sw)

	# ── Yaw ─────────────────────────────────────────────────────────────────
	var right_perp := right - vdir * right.dot(vdir)
	var r_fp := accel.dot(right_perp) / maxf(V, 5.0)
	var beta_cmd := -rudder * 0.14 * (1.0 - dmg_rudder)
	var r_cmd := r_fp + (beta - beta_cmd) * 3.0 * (1.0 - dmg_rudder * 0.7)
	var yaw_accel := clampf((r_cmd - yaw_rate) * 8.0, -yaw_auth * auth_floor, yaw_auth * auth_floor)

	pitch_rate += pitch_accel * delta
	roll_rate += roll_accel * delta
	yaw_rate += yaw_accel * delta
	if sw > 0.0:
		var k := minf(sw * 3.0 * delta, 1.0)
		roll_rate = lerpf(roll_rate, signf(spin) * 2.6, k)
		yaw_rate = lerpf(yaw_rate, signf(spin) * 1.1, k)
	pitch_rate = clampf(pitch_rate, -3.0, 3.0)
	roll_rate = clampf(roll_rate, -5.0, 5.0)
	yaw_rate = clampf(yaw_rate, -2.0, 2.0)

	# +X = pitch up; -Z = roll right; -Y = yaw right (Godot's right-hand rule)
	body.rotate_object_local(Vector3(1, 0, 0), pitch_rate * delta)
	body.rotate_object_local(Vector3(0, 0, 1), -roll_rate * delta)
	body.rotate_object_local(Vector3(0, 1, 0), -yaw_rate * delta)
	body.global_transform.basis = body.global_transform.basis.orthonormalized()
	body.global_position += velocity * delta

func _alpha_for_g(n: float, lift_den: float) -> float:
	var cl := n * mass * GRAVITY / lift_den
	var top := cl_slope * x_stall * 0.875
	# More than the wing can give: ask for everything (the caller clamps)
	if cl >= top:
		return alpha0 + x_stall * 1.5
	if cl <= -top * 0.8:
		return alpha0 - x_stall * 1.5
	return alpha_for_cl(cl)
