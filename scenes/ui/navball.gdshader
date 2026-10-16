shader_type canvas_item;
// Attitude nav ball.  Every pixel of the disc is a point on a sphere seen
// from the cockpit: the centre is the aircraft's nose direction, screen
// right/up are the aircraft's right/up axes.  The world direction of that
// point picks the colour, so pitch, roll and heading are all exact at any
// attitude (inverted, vertical, rolling — no gimbal tricks).

uniform vec3 b_right = vec3(1.0, 0.0, 0.0);   // aircraft axes in world space
uniform vec3 b_up    = vec3(0.0, 1.0, 0.0);
uniform vec3 b_fwd   = vec3(0.0, 0.0, -1.0);

uniform vec4 sky_high    : source_color = vec4(0.16, 0.42, 0.78, 1.0);
uniform vec4 sky_low     : source_color = vec4(0.42, 0.68, 0.92, 1.0);
uniform vec4 ground_low  : source_color = vec4(0.62, 0.43, 0.25, 1.0);
uniform vec4 ground_high : source_color = vec4(0.38, 0.24, 0.13, 1.0);

float line(float dist, float width, float fw) {
	return 1.0 - smoothstep(width, width + fw * 1.5, dist);
}

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	p.y = -p.y;
	float r2 = dot(p, p);
	float edge_fw = fwidth(r2);
	float mask = 1.0 - smoothstep(1.0 - edge_fw, 1.0, r2);
	if (mask <= 0.0) discard;

	float z = sqrt(max(0.0, 1.0 - r2));
	vec3 d = normalize(p.x * b_right + p.y * b_up + z * b_fwd);

	float el = degrees(asin(clamp(d.y, -1.0, 1.0)));                   // elevation
	float hd = degrees(atan(-d.x, d.z));                                 // heading: N = +Z, E = -X
	float fw = max(fwidth(el), 0.05);

	vec3 col = d.y >= 0.0
		? mix(sky_low.rgb, sky_high.rgb, smoothstep(0.0, 70.0, el))
		: mix(ground_low.rgb, ground_high.rgb, smoothstep(0.0, 70.0, -el));

	// Pitch circles every 10°, stronger every 30°, horizon boldest
	float d10 = abs(fract(el / 10.0 + 0.5) - 0.5) * 10.0;
	float d30 = abs(fract(el / 30.0 + 0.5) - 0.5) * 30.0;
	float lines = line(d10, 0.12, fw) * 0.28 + line(d30, 0.25, fw) * 0.4;
	col = mix(col, vec3(1.0), clamp(lines, 0.0, 0.6));
	col = mix(col, vec3(1.0), line(abs(el), 0.55, fw));

	// Heading meridians every 30°, cardinal points stronger; fade at the poles
	float cos_el = cos(radians(el));
	float m30 = abs(fract(hd / 30.0 + 0.5) - 0.5) * 30.0 * cos_el;
	float m90 = abs(fract(hd / 90.0 + 0.5) - 0.5) * 90.0 * cos_el;
	float pole_fade = smoothstep(80.0, 60.0, abs(el));
	col = mix(col, vec3(1.0), (line(m30, 0.12, fw) * 0.22 + line(m90, 0.22, fw) * 0.3) * pole_fade);

	// Zenith / nadir dots
	col = mix(col, vec3(1.0), line(90.0 - abs(el), 1.6, fw) * 0.8);

	// Sphere shading: brighter in the middle, darker toward the rim
	col *= 0.62 + 0.38 * pow(z, 0.6);

	COLOR = vec4(col, mask);
}
