shader_type spatial;
// Low-poly cloud: flat-shaded facets, vertex-colour gradient from grey base
// to white top, with some self-illumination so shaded sides stay soft.

render_mode diffuse_lambert, specular_disabled, cull_back;

uniform float self_light = 0.3;
global uniform vec4 sky_tint;   // dims and warms the self-light with the time of day

varying vec3 col;

void vertex() {
	col = pow(COLOR.rgb, vec3(2.2));   // vertex colours are authored in sRGB
}

void fragment() {
	ALBEDO = col * mix(vec3(1.0), sky_tint.rgb, 0.75);
	EMISSION = col * self_light * sky_tint.rgb;
	ROUGHNESS = 1.0;
}
