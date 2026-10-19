shader_type canvas_item;
// What the pilot sees under G: colour drains and the view closes to a tunnel
// (grey-out), then goes dark (black-out); negative G washes it red.

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform float grey = 0.0;
uniform float black = 0.0;
uniform float red = 0.0;

void fragment() {
	vec3 c = texture(screen_tex, SCREEN_UV).rgb;
	vec2 d = (SCREEN_UV - 0.5) * vec2(SCREEN_PIXEL_SIZE.y / SCREEN_PIXEL_SIZE.x, 1.0);
	float r = length(d) * 2.0;              // 1.0 at the top and bottom edges
	float lum = dot(c, vec3(0.30, 0.59, 0.11));
	c = mix(c, vec3(lum) * 0.92, clamp(grey * 1.3, 0.0, 1.0));
	float tunnel = smoothstep(mix(1.5, 0.30, grey), mix(2.1, 0.95, grey), r) * smoothstep(0.0, 0.25, grey);
	c = mix(c, vec3(0.03), tunnel);
	c = mix(c, vec3(0.55, 0.03, 0.02) * (0.35 + 0.65 * lum), red * 0.85);
	c = mix(c, vec3(0.0), black);
	COLOR = vec4(c, 1.0);
}
