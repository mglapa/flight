shader_type spatial;
// Translucent cloud forms: cirrus streaks, cirrostratus veil, rain shafts.

render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled;

uniform vec3 color : source_color = vec3(1.0);
uniform float alpha = 0.5;
uniform bool fade_bottom = false;   // rain shafts thin out toward the ground
uniform float height = 1000.0;
global uniform vec4 sky_tint;       // unshaded, so the time of day tints it directly
uniform bool vertex_alpha = false;  // cirrus: soft edges from vertex alpha

varying float local_y;
varying float v_alpha;

void vertex() {
	local_y = VERTEX.y;
	v_alpha = vertex_alpha ? COLOR.a : 1.0;
}

void fragment() {
	float a = alpha * v_alpha;
	if (fade_bottom)
		a *= 0.35 + 0.65 * smoothstep(-0.5 * height, 0.1 * height, local_y);
	ALBEDO = color * sky_tint.rgb;
	ALPHA = a;
}
