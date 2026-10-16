shader_type spatial;
// Town buildings (MultiMesh).  Vertex alpha tags each part:
//   a > 0.9   wall   -> tinted by the instance's wall colour (INSTANCE_CUSTOM.rgb)
//   0.5..0.9  roof   -> slate / tile picked from INSTANCE_CUSTOM.a
//   < 0.5     fixed  -> windows, chimneys, stone: vertex colour as authored
// INSTANCE_CUSTOM.a also seeds a small per-building brightness jitter.
// `appear` (per tile material) dissolves a tile's buildings in with an
// ordered dither; the same dither fades them out toward the draw distance.

render_mode diffuse_lambert, specular_disabled, cull_back;

uniform float appear = 1.0;              // per tile (each tile has its own material)
uniform float fade_start = 6200.0;
uniform float fade_end = 8000.0;

varying vec3 vcol;
varying float vtag;
varying vec4 custom;

void vertex() {
	vcol = COLOR.rgb;
	vtag = COLOR.a;
	custom = INSTANCE_CUSTOM;
}

vec3 roof_color(float a) {
	float k = floor(fract(a) * 5.0);
	if (k < 1.0) return vec3(0.36, 0.38, 0.42);      // Welsh slate
	if (k < 2.0) return vec3(0.29, 0.30, 0.33);      // dark, sooty slate
	if (k < 3.0) return vec3(0.42, 0.42, 0.44);      // weathered slate
	if (k < 4.0) return vec3(0.60, 0.33, 0.24);      // red clay tile
	return vec3(0.50, 0.33, 0.25);                   // brown tile
}

// 4x4 Bayer matrix threshold
float bayer(vec2 p) {
	ivec2 i = ivec2(mod(p, 4.0));
	int m[16] = int[](0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5);
	return (float(m[i.y * 4 + i.x]) + 0.5) / 16.0;
}

void fragment() {
	float vis = appear * (1.0 - smoothstep(fade_start, fade_end, length(VERTEX)));
	if (bayer(FRAGCOORD.xy) >= vis) discard;

	float jitter = 0.93 + 0.14 * fract(custom.a * 37.0);
	vec3 col = vcol;
	if (vtag > 0.9) col = vcol * custom.rgb * jitter;
	else if (vtag > 0.5) col = vcol * roof_color(custom.a) * (0.95 + 0.1 * fract(custom.a * 11.0));
	ALBEDO = pow(clamp(col, 0.0, 1.0), vec3(2.2));    // colours are authored in sRGB
	// A little self-light keeps shaded brick warm instead of sky-blue
	EMISSION = ALBEDO * 0.16;
	ROUGHNESS = 1.0;
}
