shader_type spatial;
// Low-poly Kent / Pas-de-Calais ground: flat-shaded facets, flat-coloured
// patchwork fields with hedge lines, woods, towns, faceted chalk cliffs and
// shingle beaches.  Normals come from screen-space derivatives, so every
// triangle reads as a crisp facet.
// Vertex COLOR.r = "shore" factor from the cliff ribbon (1 at the waterline),
// COLOR.g = 1 on LOD skirts.

render_mode cull_back, diffuse_lambert, specular_disabled;

uniform sampler2D landuse : filter_linear, repeat_disable;   // r woods, g town, b downland
uniform vec4 lu_rect = vec4(0.0, 0.0, 6000.0, 48.0);          // world min x, min z, size, texels
global uniform vec2 world_origin;                             // floating origin (see world_origin.gd)
uniform sampler2D water_tex : filter_linear, repeat_disable;  // (edge distance + 64) / 255
uniform vec4 water_rect = vec4(0.0, 0.0, 6000.0, 64.0);
uniform bool has_water = false;
uniform float buildings_shown = 0.0;   // 3D buildings present: hide the painted roofs
uniform vec3  airfields[4];          // xy = world centre, z = radius (unused: far away)
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

// ── Street layout: must match scenes/world/geo/streets.gd ────────────────────
const float DIST_CELL = 900.0;

uint uhash(ivec2 c, uint s) {
	uint h = (uint(c.x) * 0x8da6b343u) ^ (uint(c.y) * 0xd8163841u) ^ (s * 0xcb1ab31fu);
	h ^= h >> 16u;
	h *= 0x7feb352du;
	h ^= h >> 15u;
	h *= 0x846ca68bu;
	h ^= h >> 16u;
	return h;
}
float fhash(ivec2 c, uint s) {
	return float(uhash(c, s) & 0xffffffu) / 16777216.0;
}
vec2 site(ivec2 c) {
	return (vec2(c) + 0.15 + 0.7 * vec2(fhash(c, 11u), fhash(c, 12u))) * DIST_CELL;
}
// District containing p: id, site and distance to the district border
void district(vec2 p, out ivec2 id, out vec2 dsite, out float border) {
	ivec2 n = ivec2(floor(p / DIST_CELL));
	float best = 1e20;
	id = n;
	dsite = vec2(0.0);
	for (int j = -1; j <= 1; j++)
	for (int i = -1; i <= 1; i++) {
		ivec2 c = n + ivec2(i, j);
		vec2 s = site(c);
		float d = dot(p - s, p - s);
		if (d < best) { best = d; id = c; dsite = s; }
	}
	vec2 mr = dsite - p;
	border = 1e20;
	for (int j = -1; j <= 1; j++)
	for (int i = -1; i <= 1; i++) {
		if (i == 0 && j == 0) continue;
		vec2 r = site(id + ivec2(i, j)) - p;
		border = min(border, dot(0.5 * (mr + r), normalize(r - mr)));
	}
}
float street_w(float k) {
	return mod(k, 4.0) < 0.5 ? 14.0 : 8.0;      // mod() matches GDScript posmod()
}

// ── River water: faceted wave panels like the sea (see sea.gdshader) ─────────
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
vec2 ripple_grad(vec2 p, float wl) {
	vec2 g = vec2(0.0);
	float amp = 1.0;
	for (int i = 0; i < 3; i++) {
		float fi = float(i);
		float ang = 0.9 + sin(fi * 2.4) * 0.8;
		vec2 dir = vec2(cos(ang), sin(ang));
		float k = 6.2831 / wl;
		float ph = dot(p, dir) * k - TIME * sqrt(9.8 * k) * 0.6 + fi * 1.7;
		g += amp * k * cos(ph) * dir;
		amp *= 0.6;
		wl *= 0.55;
	}
	return g;
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
	vec2 xz = wpos.xz + world_origin;                          // world position
	float px = max(length(fwidth(wpos.xz)), 0.05);            // metres per pixel

	// Texel centres sit on the tile edges, so neighbouring tiles match
	vec2 luv = (xz - lu_rect.xy) / lu_rect.z * ((lu_rect.w - 1.0) / lu_rect.w) + 0.5 / lu_rect.w;
	vec4 lu = texture(landuse, luv);
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

	// ── Towns: districts of street grids with rows of roofs along the streets,
	// main roads on district borders; average colour once blocks are sub-pixel
	if (lu.g > 0.05) {
		float town = smoothstep(0.27, 0.31, lu.g + warp.y * 0.4);
		ivec2 did;
		vec2 dsite;
		float border;
		district(xz, did, dsite, border);
		float ang = fhash(did, 13u) * PI * 0.5;
		vec2 dir = vec2(cos(ang), sin(ang));
		float su = 95.0 + 70.0 * fhash(did, 14u);
		float sv = su * (1.0 + 0.6 * fhash(did, 15u));
		vec2 rel = xz - dsite;
		float qu = dot(rel, dir) / su - fhash(did, 16u);
		float qv = dot(rel, vec2(-dir.y, dir.x)) / sv - fhash(did, 17u);
		float ku = round(qu);
		float kv = round(qv);
		float eu = abs(qu - ku) * su - street_w(ku) * 0.5;
		float ev = abs(qv - kv) * sv - street_w(kv) * 0.5;
		float road = min(min(eu, ev), border - 7.0);

		// Building plots in a strip along the nearer street
		bool on_u = eu < ev;
		float along = on_u ? qv * sv : qu * su;
		float plot = floor(along / 18.0);
		ivec2 pid = ivec2(int(on_u ? ku : kv) * 2 + (on_u ? 0 : 1), int(plot));
		float front = min(eu, ev);
		float strip = 10.0 + 10.0 * lu.g;
		// Painted roofs stand in for houses only beyond the 3D building range
		float built = step(front, strip) * step(fhash(pid + did * 97, 31u), 0.35 + lu.g * 0.6)
			* max(smoothstep(4.0, 7.0, px), 1.0 - buildings_shown);
		vec3 roof = mix(vec3(0.39, 0.40, 0.43), vec3(0.58, 0.34, 0.26), step(0.62, fhash(pid, 32u)));
		vec3 garden = vec3(0.50, 0.56, 0.40);
		vec3 town_col = mix(garden, roof, built);
		float park = smoothstep(0.82, 0.85, vnoise(xz / 260.0 + 9.1));
		town_col = mix(town_col, vec3(0.40, 0.53, 0.31), park * (1.0 - built));
		float asphalt = 1.0 - smoothstep(-px * 0.5, px * 0.5, road);
		town_col = mix(town_col, vec3(0.50, 0.50, 0.48), asphalt);
		// Sub-pixel blocks: blend to the district's average colour
		vec3 avg = mix(garden, vec3(0.46, 0.40, 0.38), (0.35 + lu.g * 0.6) * 0.3);
		avg = mix(avg, vec3(0.50, 0.50, 0.48), 0.12);
		town_col = mix(town_col, avg, smoothstep(6.0, 24.0, px));
		col = mix(col, town_col, town);
	}

	// ── Rivers and lakes: flat, rippled water with sea-style facets ─────────
	float water = 0.0;
	vec3 water_n = vec3(0.0, 1.0, 0.0);
	if (has_water) {
		vec2 wuv = (xz - water_rect.xy) / water_rect.z * ((water_rect.w - 1.0) / water_rect.w) + 0.5 / water_rect.w;
		float e = texture(water_tex, wuv).r * 255.0 - 64.0;
		// Coarse tiles can't resolve a 100 m river: widen it to stay visible
		float texel = water_rect.z / water_rect.w;
		float thr = clamp(texel * 0.45 - 60.0, 0.0, 120.0);
		water = 1.0 - smoothstep(thr - px * 0.7, thr + px * 0.7, e);
		if (water > 0.0) {
			// Two panel sizes, the larger taking over with distance
			float facet = 14.0;
			vec2 g = vec2(0.0);
			float rem = 1.0;
			for (int i = 0; i < 2; i++) {
				vec2 c = tri_centre(xz / facet) * facet;
				vec2 gi = ripple_grad(c, facet * 3.3) * 2.4 * sqrt(facet / 14.0);
				gi += (vec2(hash12(c), hash12(c + 7.7)) - 0.5) * 0.1;
				float wgt = (i == 1) ? 1.0 : 1.0 - smoothstep(facet * 0.05, facet * 0.3, px);
				g += gi * wgt * rem;
				rem *= 1.0 - wgt;
				facet *= 5.0;
			}
			water_n = normalize(vec3(-g.x, 1.0, -g.y));
			// River colour: greener and siltier than the Channel, paler at the banks
			float depth = clamp(-e / 40.0, 0.0, 1.0);
			vec3 wcol = mix(vec3(0.33, 0.47, 0.42), vec3(0.17, 0.33, 0.33), depth);
			wcol *= 0.97 + 0.06 * hash12(floor(xz / 50.0));
			// Sky reflection toward grazing angles, as on the sea
			vec3 vdir = normalize(CAMERA_POSITION_WORLD - wpos);
			float rim = pow(1.0 - clamp(dot(water_n, vdir), 0.0, 1.0), 4.0);
			wcol = mix(wcol, vec3(0.62, 0.74, 0.86), rim * 0.55);
			col = mix(col, wcol, water);
		}
		// Muddy banks just outside the water
		col = mix(col, col * vec3(0.82, 0.80, 0.74), (1.0 - smoothstep(0.0, 6.0 + px, e)) * (1.0 - water));
	}

	// ── Airfield: mown grass ─────────────────────────────────────────────────
	float af = 0.0;
	float mow = 0.0;
	for (int i = 0; i < 4; i++) {
		vec2 d = xz - airfields[i].xy;
		float a = 1.0 - smoothstep(airfields[i].z * 0.55, airfields[i].z * 0.56, length(d));
		if (a > af) {
			af = a;
			mow = step(0.5, fract(d.x / 60.0));       // mown stripes
		}
	}
	col = mix(col, vec3(0.42, 0.60, 0.27) * (0.96 + 0.06 * mow), af);

	// ── Shingle beaches ──────────────────────────────────────────────────────
	if (shore > 0.1) {
		vec3 shingle = h < 1.2 ? vec3(0.56, 0.54, 0.47) : vec3(0.80, 0.75, 0.62);
		col = mix(col, shingle, step(0.3, shore));
	}

	// ── Chalk cliff faces: white with posterised strata ──────────────────────
	if (skirt < 0.5 && fn_w.y < 0.62 && water < 0.5) {
		float band = mod(floor(h / 9.0 + hash12(floor(xz / 60.0)) * 0.5), 3.0);
		vec3 chalk = vec3(0.96, 0.95, 0.90) - band * vec3(0.035, 0.035, 0.03);
		if (h < 6.0) chalk = vec3(0.62, 0.66, 0.56);             // algae-stained foot
		col = chalk;
	}

	// Sea floor rubble (seen through shallow water)
	if (h < -0.5) col = vec3(0.64, 0.68, 0.58);

	// Water is lit as level water, not by the terrain triangle beneath it
	if (water > 0.0) {
		vec3 nw = normalize(mix(fn_w, water_n, water));
		NORMAL = normalize((VIEW_MATRIX * vec4(nw, 0.0)).xyz);
	}

	// Palette above is authored in sRGB; ALBEDO is linear
	ALBEDO = pow(col, vec3(2.2));
	ROUGHNESS = 1.0;
}
