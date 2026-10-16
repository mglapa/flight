shader_type canvas_item;
// A window onto the baked north-up map image (data/europe/map.png):
// a circle for the minimap or a rounded rectangle for the full map.

uniform sampler2D map_tex : filter_linear, repeat_disable;
uniform vec2 tex_size = vec2(3080.0, 2600.0);
uniform vec2 centre_px = vec2(1540.0, 1300.0);   // map pixel at the window centre
uniform vec2 half_extent = vec2(50.0, 50.0);     // map pixels from centre to edge
uniform bool circle = true;
uniform float corner = 0.03;                     // rectangle corner radius (UV)
uniform vec4 outside : source_color = vec4(0.20, 0.34, 0.47, 1.0);

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float aa = fwidth(p.x) * 1.5;
	float mask;
	if (circle) {
		mask = 1.0 - smoothstep(1.0 - aa, 1.0, length(p));
	} else {
		vec2 q = abs(p) - (1.0 - corner);
		float d = length(max(q, 0.0)) - corner;
		mask = 1.0 - smoothstep(-aa, 0.0, d);
	}
	vec2 uv = (centre_px + p * half_extent) / tex_size;
	vec3 col = texture(map_tex, uv).rgb;
	if (uv.x < 0.0 || uv.y < 0.0 || uv.x > 1.0 || uv.y > 1.0) col = outside.rgb;
	if (circle) col *= 0.82 + 0.18 * (1.0 - smoothstep(0.6, 1.0, length(p)));   // soft vignette
	COLOR = vec4(col, mask * 0.96);
}
