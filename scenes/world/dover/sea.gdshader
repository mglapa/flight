shader_type spatial;
// Low-poly English Channel: faceted triangular wave panels, flat grey-green
// open water, turquoise shallows over the chalk platform and a band of surf
// at the cliff foot.

render_mode blend_mix, depth_draw_always, cull_back, diffuse_lambert, specular_disabled;

uniform sampler2D depth_tex : hint_depth_texture, filter_linear;
uniform vec3 deep_color    : source_color = vec3(0.12, 0.33, 0.42);
uniform vec3 mid_color     : source_color = vec3(0.16, 0.42, 0.48);
uniform vec3 shallow_color : source_color = vec3(0.45, 0.75, 0.70);
uniform vec3 foam_color    : source_color = vec3(0.95, 0.97, 0.96);
uniform vec3 rim_color     : source_color = vec3(0.62, 0.74, 0.86);
uniform float facet = 48.0;            // wave panel size (m)
uniform vec2 wind = vec2(0.6, 0.8);

varying vec3 wpos;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

// Gradient of a few directional wave trains, longest wavelength wl
vec2 wave_grad(vec2 p, float wl) {
	vec2 g = vec2(0.0);
	float amp = 1.0;
	float base_ang = atan(wind.y, wind.x);
	for (int i = 0; i < 3; i++) {
		float fi = float(i);
		float ang = base_ang + sin(fi * 2.4) * 0.8;
		vec2 dir = vec2(cos(ang), sin(ang));
		float k = 6.2831 / wl;
		float ph = dot(p, dir) * k - TIME * sqrt(9.8 * k) + fi * 1.7;
		g += amp * k * cos(ph) * dir;
		amp *= 0.6;
		wl *= 0.55;
	}
	return g;
}

// Centre of the triangular lattice cell containing p (simplex-style skew)
vec2 tri_centre(vec2 p) {
	const float F2 = 0.36602540378;
	const float G2 = 0.2113248654;
	vec2 i = floor(p + (p.x + p.y) * F2);
	vec2 x0 = p - (i - (i.x + i.y) * G2);
	vec2 o = x0.x > x0.y ? vec2(1.0, 0.0) : vec2(0.0, 1.0);
	vec2 c0 = i - (i.x + i.y) * G2;
	vec2 c1 = (i + o) - (i.x + i.y + 1.0) * G2;
	vec2 c2 = (i + 1.0) - (i.x + i.y + 2.0) * G2;
	return (c0 + c1 + c2) / 3.0;
}

void fragment() {
	float dist = length(wpos - CAMERA_POSITION_WORLD);
	float px = max(length(fwidth(wpos.xz)), 0.01);

	// Faceted normal: one wave slope per triangular panel.  Three panel sizes
	// take over from each other with distance so the facets reach the horizon.
	vec2 g = vec2(0.0);
	float remaining = 1.0;
	vec2 cell = wpos.xz;
	float scale = facet;
	for (int i = 0; i < 3; i++) {
		vec2 c = tri_centre(wpos.xz / scale) * scale;
		vec2 gi = wave_grad(c, scale * 3.3) * 3.5 * sqrt(scale / facet);
		gi += (vec2(hash12(c), hash12(c + 7.7)) - 0.5) * 0.12;
		float w = 1.0 - smoothstep(scale * 0.05, scale * 0.3, px);
		if (i == 2) w = 1.0;           // largest panels never fade out
		g += gi * w * remaining;
		if (remaining > 0.5) cell = c;
		remaining *= 1.0 - w;
		scale *= 5.0;
	}
	vec3 wn = normalize(vec3(-g.x, 1.0, -g.y));
	NORMAL = normalize((VIEW_MATRIX * vec4(wn, 0.0)).xyz);

	// Water thickness along the view ray from the depth buffer
	float depth = textureLod(depth_tex, SCREEN_UV, 0.0).r;
	vec4 vpos = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
	vpos.xyz /= vpos.w;
	float thick = max(length(vpos.xyz) - length(VERTEX), 0.0);
	thick = mix(60.0, thick, 1.0 - smoothstep(6000.0, 14000.0, dist));

	// Flat colour bands: shallows → mid → deep
	vec3 col = deep_color;
	col = mix(mid_color, col, step(9.0, thick));
	col = mix(shallow_color, col, step(3.0, thick));
	// Faint tint variation per panel keeps large areas alive
	col *= 0.98 + 0.04 * hash12(floor(cell / facet));

	// Surf band hugging the shore, broken up per panel and slowly pulsing
	float pulse = 0.5 + 0.5 * sin(TIME * 0.8 + hash12(floor(wpos.xz / 30.0)) * 6.28);
	float foam = step(thick, 0.8 + pulse * 1.2);
	col = mix(col, foam_color, foam);

	// Stylised sky reflection: lighter toward grazing angles
	float rim = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 4.0);
	col = mix(col, rim_color, rim * 0.55 * (1.0 - foam));

	ALBEDO = col;
	ROUGHNESS = 1.0;
	ALPHA = mix(0.8, 1.0, step(2.0, thick));
	ALPHA = max(ALPHA, foam);
}
