shader_type spatial;
// Smoke, dust and fire puffs drawn by smoke_field.gd as one MultiMesh.
// Each instance is written once when emitted; its whole life (rise, drift,
// growth, fade) is animated here from INSTANCE_CUSTOM:
//   r = birth time (seconds, `now` clock)   g = life (s)
//   b = kind: 0 grey smoke, 1 black smoke, 2 fire / flash, 3 dust
//   a = rise speed (m/s)
// The transform carries the birth position and base radius.  Puffs fade
// with an ordered dither instead of alpha blending (no sorting, low-poly look).

render_mode diffuse_lambert, specular_disabled, cull_back;

uniform float now = 0.0;
uniform vec3 wind = vec3(3.0, 0.0, 1.2);

varying float v_life;     // 0..1 through the puff's life, > 1 dead
varying float v_kind;

void vertex() {
	float age = now - INSTANCE_CUSTOM.r;
	float life = max(INSTANCE_CUSTOM.g, 0.01);
	float t = age / life;
	v_life = (age < 0.0) ? 2.0 : t;
	v_kind = INSTANCE_CUSTOM.b;
	float grow = v_kind > 1.5 && v_kind < 2.5 ? 1.0 + 2.2 * sqrt(clamp(t, 0.0, 1.0))
		: 1.0 + 3.0 * sqrt(clamp(t, 0.0, 1.0));
	if (v_life > 1.0) grow = 0.0;                   // dead: collapse to a point
	VERTEX *= grow;
	// Rise slows as the puff spreads; the wind carries it
	vec3 drift = vec3(0.0, INSTANCE_CUSTOM.a * age * (1.0 - 0.35 * clamp(t, 0.0, 1.0)), 0.0) + wind * age;
	VERTEX += (inverse(mat3(MODEL_MATRIX)) * drift);
}

float bayer(vec2 p) {
	ivec2 i = ivec2(mod(p, 4.0));
	int m[16] = int[](0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5);
	return (float(m[i.y * 4 + i.x]) + 0.5) / 16.0;
}

void fragment() {
	if (v_life > 1.0) discard;
	float t = clamp(v_life, 0.0, 1.0);
	vec3 col;
	vec3 glow = vec3(0.0);
	float density;
	if (v_kind < 0.5) {            // grey smoke
		col = mix(vec3(0.46, 0.45, 0.44), vec3(0.62, 0.62, 0.62), t);
		density = 0.75 * (1.0 - t);
	} else if (v_kind < 1.5) {     // black, oily smoke
		col = mix(vec3(0.07, 0.07, 0.07), vec3(0.26, 0.25, 0.25), t);
		density = 0.95 * (1.0 - t * t);
	} else if (v_kind < 2.5) {     // fire / flash
		col = mix(vec3(1.0, 0.85, 0.45), vec3(0.6, 0.18, 0.04), t);
		glow = col * (1.0 - t) * 3.0;
		density = 1.0 - t;
	} else {                       // dust thrown up by a blast
		col = mix(vec3(0.42, 0.36, 0.28), vec3(0.56, 0.52, 0.46), t);
		density = 0.85 * (1.0 - t);
	}
	if (bayer(FRAGCOORD.xy) >= density) discard;
	// Faceted shading
	NORMAL = normalize(cross(dFdy(VERTEX), dFdx(VERTEX)));
	ALBEDO = col;
	EMISSION = glow + col * 0.12;
	ROUGHNESS = 1.0;
}
