shader_type spatial;
// Low-poly Kent / Pas-de-Calais ground: flat-shaded facets, flat-coloured
// patchwork fields with hedge lines, woods, towns, faceted chalk cliffs and
// shingle beaches.  Normals come from screen-space derivatives, so every
// triangle reads as a crisp facet.
// Vertex COLOR.r = "shore" factor from the cliff ribbon (1 at the waterline),
// COLOR.g = 1 on LOD skirts.

render_mode cull_back, diffuse_lambert, specular_disabled;

uniform sampler2D landuse : filter_linear, repeat_disable;   // r woods, g town, b downland
uniform float core_half = 48000.0;
uniform vec2  airfield = vec2(0.0);
uniform float airfield_r = 950.0;
uniform float field_size = 280.0;

varying vec3 wpos;
varying float shore;
varying float skirt;

void vertex() {
	wpos  = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	shore = COLOR.r;
	skirt = COLOR.g;
}

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}
vec2 hash22(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.xx + p3.yz) * p3.zy);
}
float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash12(i), hash12(i + vec2(1.0, 0.0)), u.x),
	           mix(hash12(i + vec2(0.0, 1.0)), hash12(i + vec2(1.0, 1.0)), u.x), u.y);
}

// Voronoi cells: returns distance to the nearest cell border, writes cell id.
float voronoi_border(vec2 x, out vec2 cell_id) {
	vec2 n = floor(x);
	vec2 f = fract(x);
	vec2 mg = vec2(0.0);
	vec2 mr = vec2(0.0);
	float md = 8.0;
	for (int j = -1; j <= 1; j++)
	for (int i = -1; i <= 1; i++) {
		vec2 g = vec2(float(i), float(j));
		vec2 r = g + hash22(n + g) * 0.8 + 0.1 - f;
		float d = dot(r, r);
		if (d < md) { md = d; mr = r; mg = g; }
	}
	md = 8.0;
	// 3x3 is enough for the border pass because cell jitter is limited
	for (int j = -1; j <= 1; j++)
	for (int i = -1; i <= 1; i++) {
		vec2 g = mg + vec2(float(i), float(j));
		vec2 r = g + hash22(n + g) * 0.8 + 0.1 - f;
		if (dot(mr - r, mr - r) > 0.00001)
			md = min(md, dot(0.5 * (mr + r), normalize(r - mr)));
	}
	cell_id = n + mg;
	return md;
}

// Late-summer 1940 palette: pasture, wheat, stubble, hay, ploughed earth
vec3 field_color(float a) {
	if (a < 0.20) return vec3(0.33, 0.52, 0.22);   // pasture
	if (a < 0.38) return vec3(0.40, 0.58, 0.25);   // fresh grass
	if (a < 0.50) return vec3(0.28, 0.46, 0.20);   // dark pasture
	if (a < 0.64) return vec3(0.78, 0.66, 0.33);   // ripe wheat
	if (a < 0.74) return vec3(0.84, 0.77, 0.52);   // stubble
	if (a < 0.86) return vec3(0.56, 0.62, 0.31);   // hay meadow
	return vec3(0.52, 0.39, 0.27);                 // ploughed
}

void fragment() {
	// Flat-shaded facet normal (world and view space)
	vec3 fn_w = normalize(cross(dFdy(wpos), dFdx(wpos)));
	if (dot(fn_w, CAMERA_POSITION_WORLD - wpos) < 0.0) fn_w = -fn_w;   // visible side
	NORMAL = normalize((VIEW_MATRIX * vec4(fn_w, 0.0)).xyz);

	float h = wpos.y;
	vec2 xz = wpos.xz;
	float px = max(length(fwidth(xz)), 0.05);                 // metres per pixel

	vec2 luv = (xz + core_half) / (2.0 * core_half);
	vec4 lu = texture(landuse, luv);
	if (luv.x < 0.0 || luv.y < 0.0 || luv.x > 1.0 || luv.y > 1.0) lu = vec4(0.0);
	vec2 warp = vec2(vnoise(xz / 900.0), vnoise(xz / 900.0 + 31.7)) - 0.5;

	// ── Patchwork fields with hedgerows ──────────────────────────────────────
	// Estates: large wavy-edged regions, each with its own field orientation
	// and shape, so the patchwork never looks like one uniform mosaic
	vec2 rid = floor(xz / 3500.0 + warp * 0.8);
	float rang = hash12(rid + 1.7) * 3.1416;
	vec2 rdir = vec2(cos(rang), sin(rang));
	float stretch = 1.0 + hash12(rid + 9.1) * 1.3;
	float fsize = field_size * (0.7 + hash12(rid + 4.4) * 0.6);
	vec2 fp = vec2(dot(xz, rdir) / (fsize * stretch), dot(xz, vec2(-rdir.y, rdir.x)) / fsize);
	fp += warp * 0.9 + rid * 17.0;
	vec2 cid;
	float border = voronoi_border(fp, cid) * fsize;          // metres to hedge

	vec3 col = field_color(hash12(cid));
	float hedge_w = 3.0;
	float hedge = 1.0 - smoothstep(hedge_w - px, hedge_w + px, border);
	hedge *= clamp(hedge_w * 1.6 / px, 0.0, 1.0);
	col = mix(col, vec3(0.17, 0.30, 0.13), hedge * 0.85);

	// ── Chalk downland along the English cliff tops ──────────────────────────
	if (lu.b > 0.01)
		col = mix(col, vec3(0.55, 0.62, 0.33), step(0.5, lu.b + warp.x * 1.1 - 0.1));

	// ── Woods ────────────────────────────────────────────────────────────────
	if (lu.r > 0.2) {
		float wood = smoothstep(0.48, 0.52, lu.r + warp.y * 0.25);
		col = mix(col, vec3(0.16, 0.30, 0.15), wood);
	}

	// ── Towns ────────────────────────────────────────────────────────────────
	if (lu.g > 0.05) {
		float town = smoothstep(0.27, 0.31, lu.g + warp.y * 0.4);
		col = mix(col, vec3(0.52, 0.58, 0.38), town);   // gardens and streets
	}

	// ── Airfield: mown grass ─────────────────────────────────────────────────
	float af = 1.0 - smoothstep(airfield_r * 0.55, airfield_r * 0.56, length(xz - airfield));
	col = mix(col, vec3(0.42, 0.60, 0.27), af);

	// ── Shingle beaches ──────────────────────────────────────────────────────
	if (shore > 0.1) {
		vec3 shingle = h < 1.2 ? vec3(0.56, 0.54, 0.47) : vec3(0.80, 0.75, 0.62);
		col = mix(col, shingle, step(0.3, shore));
	}

	// ── Chalk cliff faces: white with posterised strata ──────────────────────
	if (skirt < 0.5 && fn_w.y < 0.62) {
		float band = mod(floor(h / 9.0 + hash12(floor(xz / 60.0)) * 0.5), 3.0);
		vec3 chalk = vec3(0.96, 0.95, 0.90) - band * vec3(0.035, 0.035, 0.03);
		if (h < 6.0) chalk = vec3(0.62, 0.66, 0.56);             // algae-stained foot
		col = chalk;
	}

	// Sea floor rubble (seen through shallow water)
	if (h < -0.5) col = vec3(0.64, 0.68, 0.58);

	// Palette above is authored in sRGB; ALBEDO is linear
	ALBEDO = pow(col, vec3(2.2));
	ROUGHNESS = 1.0;
}
