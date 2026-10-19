shader_type sky;
// Sky for the time of day (weather.gd sets the colours): a top-to-horizon
// gradient, an orange glow along the horizon on the sun's side at dawn and
// dusk, the sun's disc and halo, and faint stars once it is dark.

uniform vec3 top_color : source_color = vec3(0.2, 0.42, 0.8);
uniform vec3 horizon_color : source_color = vec3(0.64, 0.76, 0.88);
uniform vec3 ground_color : source_color = vec3(0.10, 0.22, 0.32);
uniform vec3 glow_color : source_color = vec3(1.0, 0.45, 0.15);
uniform float glow = 0.0;                 // dawn / dusk horizon glow, 0..1
uniform vec3 sun_dir = vec3(0.0, 0.5, -0.8);   // toward the sun (also below the horizon)
uniform vec3 sun_color : source_color = vec3(1.0, 0.95, 0.86);
uniform float sun_disc = 1.0;             // 0 behind the overcast
uniform float stars = 0.0;

float hash(vec3 p) {
	p = fract(p * 0.3183099 + 0.1);
	p *= 17.0;
	return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

void sky() {
	vec3 d = EYEDIR;
	float y = d.y;
	float h = 1.0 - clamp(y, 0.0, 1.0);
	vec3 col = mix(top_color, horizon_color, pow(h, 5.0));
	vec3 sd = normalize(sun_dir);
	float c = max(dot(d, sd), 0.0);

	// Dawn / dusk: a glowing band low on the sun's side, fading up and around
	vec2 hd = normalize(d.xz + vec2(1e-5));
	vec2 hs = normalize(sd.xz + vec2(1e-5));
	float side = dot(hd, hs) * 0.5 + 0.5;
	float band = exp(-max(y, 0.0) * 7.0);
	float g = glow * band * (0.25 * side + 0.75 * pow(side, 6.0)) + glow * pow(c, 12.0) * 0.6;
	col = mix(col, glow_color, clamp(g, 0.0, 1.0) * 0.85);
	// A pinkish counter-glow opposite the sun
	col += glow_color * vec3(0.5, 0.35, 0.5) * glow * band * pow(1.0 - side, 3.0) * 0.18;

	// Below the horizon
	float below = smoothstep(0.0, -0.08, y);
	col = mix(col, mix(horizon_color, ground_color, 0.6), below);

	// Sun: halo and a disc a little larger than life
	float above = smoothstep(-0.015, 0.005, y);
	col += sun_color * pow(c, 300.0) * 1.2 * sun_disc * above;
	col += sun_color * pow(c, 24.0) * 0.12 * sun_disc;
	col += sun_color * smoothstep(0.99985, 0.99992, c) * 18.0 * sun_disc * above;

	// Stars in the dark
	if (stars > 0.0 && y > 0.0) {
		vec3 cell = floor(d * 380.0);
		float s = hash(cell);
		col += vec3(0.8, 0.85, 1.0) * step(0.9975, s) * stars * smoothstep(0.0, 0.25, y) * (s - 0.9975) * 400.0;
	}
	COLOR = col;
}
