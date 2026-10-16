shader_type spatial;
// Low-poly cloud: flat-shaded facets, vertex-colour gradient from grey base
// to white top, with some self-illumination so shaded sides stay soft.

render_mode diffuse_lambert, specular_disabled, cull_back;

uniform float self_light = 0.3;

varying vec3 col;

void vertex() {
	col = pow(COLOR.rgb, vec3(2.2));   // vertex colours are authored in sRGB
}

void fragment() {
	ALBEDO = col;
	EMISSION = col * self_light;
	ROUGHNESS = 1.0;
}
