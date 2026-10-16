#!/usr/bin/env python3
"""Bake real-world geography for the campaign map into data/europe/.

Inputs (downloaded and cached on first run):
  * AWS Terrain Tiles, Terrarium encoding, zoom 9 (~190 m at 51 N):
    elevation on land and bathymetry at sea.
  * Natural Earth 10 m: land, minor islands, urban areas, populated places.

Outputs (read by scenes/world/geo/geo_data.gd):
  meta.json         projection, grid extent and resolution
  elevation.bin     int16 metres (sea negative), zlib
  coastdist.bin     int16 signed distance to the coast in metres (+ inland), zlib
  town.bin          uint8 town density 0..255, zlib
  coast.bin         smoothed coastline polylines, land on the LEFT in game axes, zlib
  rivers.bin        river centrelines with widths, zlib
  lakedist.bin      int16 signed distance to lake shores in metres (- inside), zlib
  map.png           north-up colour map for the in-game map (MAP_RES per pixel)
  places.json       named towns and cities with population

Game axes: +X = west, +Z = north (so east is -X), metres, centred on Dover.
The projection is azimuthal equidistant about Dover, so distances measured
from Dover are exact and local shapes are true.

Usage:  python3 -I tools/bake_europe.py --cache <download dir> [--out data/europe]
"""

import argparse
import io
import json
import math
import os
import struct
import sys
import time
import urllib.request
import zlib

import numpy as np
from PIL import Image, ImageDraw, ImageFilter
from scipy import ndimage
from shapely.geometry import box, shape, LineString, MultiLineString
from shapely.geometry.polygon import orient

R_EARTH = 6371008.8
LAT0, LON0 = 51.1279, 1.3134          # Dover Castle: the game origin
# Grid extent in projected metres (east / north), then flipped to game X
EAST_MIN, EAST_MAX = -560_000.0, 980_000.0     # Cornwall .. east of Berlin
NORTH_MIN, NORTH_MAX = -370_000.0, 930_000.0   # south of Paris .. Orkney (all of Great Britain)
RES = 250.0
ZOOM = 9

NE_BASE = "https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/"
NE_FILES = ["ne_10m_land", "ne_10m_minor_islands", "ne_10m_urban_areas",
            "ne_10m_populated_places_simple", "ne_10m_rivers_lake_centerlines",
            "ne_10m_rivers_europe", "ne_10m_lakes", "ne_10m_lakes_europe"]
MAP_RES = 500.0
TERRARIUM = "https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png"


# ---------------------------------------------------------------------------
# Projection
# ---------------------------------------------------------------------------

def forward(lat, lon):
    """lat/lon degrees -> (east, north) metres, azimuthal equidistant."""
    p0, l0 = math.radians(LAT0), math.radians(LON0)
    p, l = np.radians(lat), np.radians(lon)
    cos_c = np.sin(p0) * np.sin(p) + np.cos(p0) * np.cos(p) * np.cos(l - l0)
    c = np.arccos(np.clip(cos_c, -1.0, 1.0))
    k = np.where(c > 1e-9, c / np.sin(np.maximum(c, 1e-12)), 1.0)
    east = R_EARTH * k * np.cos(p) * np.sin(l - l0)
    north = R_EARTH * k * (np.cos(p0) * np.sin(p) - np.sin(p0) * np.cos(p) * np.cos(l - l0))
    return east, north


def inverse(east, north):
    """(east, north) metres -> lat/lon degrees."""
    p0, l0 = math.radians(LAT0), math.radians(LON0)
    rho = np.hypot(east, north)
    c = rho / R_EARTH
    safe = np.maximum(rho, 1e-9)
    lat = np.arcsin(np.clip(np.cos(c) * np.sin(p0) + north * np.sin(c) * np.cos(p0) / safe, -1, 1))
    lon = l0 + np.arctan2(east * np.sin(c), rho * np.cos(p0) * np.cos(c) - north * np.sin(p0) * np.sin(c))
    return np.degrees(lat), np.degrees(lon)


# ---------------------------------------------------------------------------
# Downloads
# ---------------------------------------------------------------------------

def fetch(url, path):
    if os.path.exists(path) and os.path.getsize(path) > 0:
        return path
    os.makedirs(os.path.dirname(path), exist_ok=True)
    for attempt in range(4):
        try:
            with urllib.request.urlopen(url, timeout=60) as r:
                data = r.read()
            with open(path + ".part", "wb") as f:
                f.write(data)
            os.replace(path + ".part", path)
            return path
        except Exception as e:  # noqa: BLE001 - retry any network error
            if attempt == 3:
                raise
            print(f"  retry {url}: {e}")
            time.sleep(2 + attempt * 3)


def tile_range(lat_min, lat_max, lon_min, lon_max, z):
    n = 2 ** z
    def tx(lon):
        return int((lon + 180.0) / 360.0 * n)
    def ty(lat):
        r = math.radians(lat)
        return int((1.0 - math.asinh(math.tan(r)) / math.pi) / 2.0 * n)
    return tx(lon_min), tx(lon_max), ty(lat_max), ty(lat_min)


def load_terrarium(cache, lat_min, lat_max, lon_min, lon_max):
    x0, x1, y0, y1 = tile_range(lat_min, lat_max, lon_min, lon_max, ZOOM)
    w, h = (x1 - x0 + 1) * 256, (y1 - y0 + 1) * 256
    mosaic = np.zeros((h, w), dtype=np.float32)
    total = (x1 - x0 + 1) * (y1 - y0 + 1)
    done = 0
    for ty in range(y0, y1 + 1):
        for tx in range(x0, x1 + 1):
            path = fetch(TERRARIUM.format(z=ZOOM, x=tx, y=ty),
                         os.path.join(cache, "terrarium", str(ZOOM), str(tx), f"{ty}.png"))
            img = np.asarray(Image.open(path).convert("RGB"), dtype=np.float32)
            elev = img[..., 0] * 256.0 + img[..., 1] + img[..., 2] / 256.0 - 32768.0
            mosaic[(ty - y0) * 256:(ty - y0 + 1) * 256, (tx - x0) * 256:(tx - x0 + 1) * 256] = elev
            done += 1
            if done % 50 == 0:
                print(f"  terrain tiles {done}/{total}")
    return mosaic, x0, y0


def sample_mosaic(mosaic, x0, y0, lat, lon):
    """Bilinear sample of the web-mercator mosaic at lat/lon arrays."""
    n = 2 ** ZOOM
    px = (lon + 180.0) / 360.0 * n * 256.0 - x0 * 256.0 - 0.5
    r = np.radians(lat)
    py = (1.0 - np.arcsinh(np.tan(r)) / np.pi) / 2.0 * n * 256.0 - y0 * 256.0 - 0.5
    return ndimage.map_coordinates(mosaic, [py, px], order=1, mode="nearest")


# ---------------------------------------------------------------------------
# Main bake
# ---------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cache", required=True)
    ap.add_argument("--out", default=os.path.join(os.path.dirname(__file__), "..", "data", "europe"))
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)
    t0 = time.time()

    w = int(round((EAST_MAX - EAST_MIN) / RES))
    h = int(round((NORTH_MAX - NORTH_MIN) / RES))
    # Game X = -east.  Column i runs along +X (westward), row j along +Z (north).
    x_min = -EAST_MAX
    z_min = NORTH_MIN
    print(f"grid {w} x {h} at {RES:.0f} m ({w * RES / 1000:.0f} x {h * RES / 1000:.0f} km)")
    gx = x_min + np.arange(w) * RES
    gz = z_min + np.arange(h) * RES
    east = -gx[None, :].repeat(h, 0)
    north = gz[:, None].repeat(w, 1)
    lat, lon = inverse(east, north)
    lat_min, lat_max = float(lat.min()) - 0.2, float(lat.max()) + 0.2
    lon_min, lon_max = float(lon.min()) - 0.2, float(lon.max()) + 0.2
    print(f"covers lat {lat_min:.2f}..{lat_max:.2f}, lon {lon_min:.2f}..{lon_max:.2f}")

    # --- Elevation -----------------------------------------------------------
    print("elevation: Terrarium tiles")
    mosaic, mx0, my0 = load_terrarium(args.cache, lat_min, lat_max, lon_min, lon_max)
    elev = sample_mosaic(mosaic, mx0, my0, lat, lon).astype(np.float32)
    del mosaic

    # --- Natural Earth ---------------------------------------------------------
    ne = {}
    for name in NE_FILES:
        path = fetch(NE_BASE + name + ".geojson", os.path.join(args.cache, "ne", name + ".geojson"))
        with open(path, encoding="utf-8") as f:
            ne[name] = json.load(f)
    region = box(lon_min, lat_min, lon_max, lat_max)

    def to_px(xs_east, ys_north):
        # projected metres -> raster pixel coords (column, row) of the game grid
        return ((-xs_east - x_min) / RES, (ys_north - z_min) / RES)

    # Land polygons, oriented so land is on the left in lon/lat
    land_polys = []
    for name in ("ne_10m_land", "ne_10m_minor_islands"):
        for feat in ne[name]["features"]:
            g = shape(feat["geometry"])
            if not g.intersects(region):
                continue
            for poly in getattr(g, "geoms", [g]):
                if poly.intersects(region):
                    land_polys.append(orient(poly, 1.0))
    print(f"land polygons in region: {len(land_polys)}")

    # Land mask, drawn at 2x then reduced, so the 250 m mask is smooth
    ss = 2
    mask_img = Image.new("L", (w * ss, h * ss), 0)
    draw = ImageDraw.Draw(mask_img)
    clip = region.buffer(0.5)
    for poly in land_polys:
        poly = poly.intersection(clip)
        for part in getattr(poly, "geoms", [poly]):
            if part.is_empty or part.geom_type != "Polygon":
                continue
            for ring, fill in [(part.exterior, 255)] + [(r, 0) for r in part.interiors]:
                xs, ys = ring.coords.xy
                e, n = forward(np.array(ys), np.array(xs))
                c, r = to_px(e, n)
                draw.polygon(list(zip(c * ss, r * ss)), fill=fill)
    mask = np.asarray(mask_img.resize((w, h), Image.BILINEAR), dtype=np.float32) / 255.0
    land = mask >= 0.5
    print(f"land fraction {land.mean():.2f}")

    # Signed distance to the coast (+ inland), clamped
    d_land = ndimage.distance_transform_edt(land) * RES
    d_sea = ndimage.distance_transform_edt(~land) * RES
    coastdist = np.where(land, d_land - RES * 0.5, -(d_sea - RES * 0.5))
    coastdist = np.clip(coastdist, -30000, 30000).astype(np.int16)

    # Land is at least 1 m (polders included), sea at most -2 m
    elev = np.where(land, np.maximum(elev, 1.0), np.minimum(elev, -2.0))
    elev = np.clip(np.round(elev), -32000, 32000).astype(np.int16)

    # --- Coastline polylines -------------------------------------------------
    lines = []
    for poly in land_polys:
        for ring in [poly.exterior] + list(poly.interiors):
            ls = LineString(ring.coords).intersection(clip)
            for part in getattr(ls, "geoms", [ls]):
                if part.is_empty or part.geom_type != "LineString" or len(part.coords) < 2:
                    continue
                xs, ys = part.coords.xy
                e, n = forward(np.array(ys), np.array(xs))
                pts = np.stack([-e, n], axis=1)          # game (x, z)
                # Mirroring east->X flips handedness: reverse to keep land on the left
                pts = pts[::-1]
                closed = part.is_ring
                pts = chaikin(pts, closed, 2)
                if polyline_length(pts) < 400.0:
                    continue
                lines.append((pts.astype(np.float32), closed))
    print(f"coastline pieces: {len(lines)}, total {sum(polyline_length(p) for p, _ in lines) / 1000:.0f} km")

    # --- Towns ---------------------------------------------------------------
    town_img = Image.new("L", (w, h), 0)
    tdraw = ImageDraw.Draw(town_img)
    for feat in ne["ne_10m_urban_areas"]["features"]:
        g = shape(feat["geometry"])
        if not g.intersects(region):
            continue
        for part in getattr(g, "geoms", [g]):
            xs, ys = part.exterior.coords.xy
            e, n = forward(np.array(ys), np.array(xs))
            c, r = to_px(e, n)
            tdraw.polygon(list(zip(c, r)), fill=200)
    places = []
    for feat in ne["ne_10m_populated_places_simple"]["features"]:
        p = feat["properties"]
        lon_p, lat_p = feat["geometry"]["coordinates"][:2]
        if not (lat_min < lat_p < lat_max and lon_min < lon_p < lon_max):
            continue
        e, n = forward(np.array(lat_p), np.array(lon_p))
        x, z = float(-e), float(n)
        if not (x_min <= x <= x_min + w * RES and z_min <= z <= z_min + h * RES):
            continue
        pop = int(p.get("pop_max") or p.get("pop_min") or 0)
        places.append({"name": p.get("name", ""), "x": round(x, 1), "z": round(z, 1), "pop": pop})
        # A core of dense town for every place, sized by population
        radius = min(max(300.0 * (max(pop, 3000) / 10000.0) ** 0.38, 300.0), 6000.0)
        c, r = to_px(np.array(e), np.array(n))
        rr = radius / RES
        tdraw.ellipse([float(c) - rr, float(r) - rr, float(c) + rr, float(r) + rr], fill=255)
    town = np.asarray(town_img.filter(ImageFilter.GaussianBlur(1.2)), dtype=np.uint8)
    town = np.where(land, town, 0).astype(np.uint8)
    places.sort(key=lambda q: -q["pop"])
    print(f"places: {len(places)}")

    # --- Rivers --------------------------------------------------------------
    rivers = []
    for name in ("ne_10m_rivers_lake_centerlines", "ne_10m_rivers_europe"):
        for feat in ne[name]["features"]:
            props = feat["properties"]
            if "Lake" in str(props.get("featurecla", "")):
                continue                     # centrelines through lakes
            g = shape(feat["geometry"])
            if not g.intersects(region):
                continue
            width = river_width(props.get("scalerank"))
            g = g.intersection(clip)
            for part in getattr(g, "geoms", [g]):
                if part.is_empty or part.geom_type != "LineString" or len(part.coords) < 2:
                    continue
                xs, ys = part.coords.xy
                e, n = forward(np.array(ys), np.array(xs))
                pts = chaikin(np.stack([-e, n], axis=1), False, 2)
                if polyline_length(pts) < 500.0:
                    continue
                rivers.append((pts.astype(np.float32), width))
    print(f"river pieces: {len(rivers)}, total {sum(polyline_length(p) for p, _ in rivers) / 1000:.0f} km")

    # --- Lakes ---------------------------------------------------------------
    lake_img = Image.new("L", (w, h), 0)
    ldraw = ImageDraw.Draw(lake_img)
    for name in ("ne_10m_lakes", "ne_10m_lakes_europe"):
        for feat in ne[name]["features"]:
            g = shape(feat["geometry"])
            if not g.intersects(region):
                continue
            for part in getattr(g, "geoms", [g]):
                xs, ys = part.exterior.coords.xy
                e, n = forward(np.array(ys), np.array(xs))
                c, r = to_px(e, n)
                ldraw.polygon(list(zip(c, r)), fill=255)
    lake = (np.asarray(lake_img) > 127) & land
    lakedist = np.where(lake, -(ndimage.distance_transform_edt(lake) * RES - RES * 0.5),
                        ndimage.distance_transform_edt(~lake) * RES - RES * 0.5)
    lakedist = np.clip(lakedist, -3000, 3000).astype(np.int16)
    print(f"lake cells: {int(lake.sum())}")

    # --- Map image -----------------------------------------------------------
    write_map(args.out, elev, land, town, lake, rivers, places, x_min, z_min, w, h)

    # --- Write ---------------------------------------------------------------
    def write_z(name, arr):
        raw = np.ascontiguousarray(arr).tobytes()
        comp = zlib.compress(raw, 9)
        with open(os.path.join(args.out, name), "wb") as f:
            f.write(comp)
        print(f"  {name}: {len(raw) / 1e6:.1f} MB -> {len(comp) / 1e6:.1f} MB")
        return len(raw)

    sizes = {
        "elevation": write_z("elevation.bin", elev.astype("<i2")),
        "coastdist": write_z("coastdist.bin", coastdist.astype("<i2")),
        "town": write_z("town.bin", town),
        "lakedist": write_z("lakedist.bin", lakedist.astype("<i2")),
    }
    buf = io.BytesIO()
    buf.write(struct.pack("<i", len(lines)))
    for pts, closed in lines:
        buf.write(struct.pack("<ii", len(pts), 1 if closed else 0))
        buf.write(pts.astype("<f4").tobytes())
    sizes["coast"] = write_z("coast.bin", np.frombuffer(buf.getvalue(), dtype=np.uint8))
    buf = io.BytesIO()
    buf.write(struct.pack("<i", len(rivers)))
    for pts, width in rivers:
        buf.write(struct.pack("<if", len(pts), width))
        buf.write(pts.astype("<f4").tobytes())
    sizes["rivers"] = write_z("rivers.bin", np.frombuffer(buf.getvalue(), dtype=np.uint8))

    meta = {
        "projection": "azimuthal_equidistant", "lat0": LAT0, "lon0": LON0, "radius": R_EARTH,
        "axes": "x = -east, z = north (metres)",
        "x_min": x_min, "z_min": z_min, "res": RES, "width": w, "height": h,
        "raw_sizes": sizes,
        "map": {"file": "map.png", "res": MAP_RES, "east_min": EAST_MIN, "north_max": z_min + h * RES},
        "sources": ["AWS Terrain Tiles (Terrarium) z9", "Natural Earth 10m (public domain)"],
    }
    with open(os.path.join(args.out, "meta.json"), "w") as f:
        json.dump(meta, f, indent=1)
    with open(os.path.join(args.out, "places.json"), "w", encoding="utf-8") as f:
        json.dump(places, f, ensure_ascii=False, indent=0)
    print(f"done in {time.time() - t0:.0f} s")


def river_width(scalerank):
    """Drawn river width in metres from Natural Earth's importance rank."""
    try:
        sr = float(scalerank)
    except (TypeError, ValueError):
        sr = 10.0
    if sr <= 4:
        return 320.0
    if sr <= 6:
        return 190.0
    if sr <= 8:
        return 110.0
    if sr <= 10:
        return 60.0
    return 35.0


def write_map(out, elev, land, town, lake, rivers, places, x_min, z_min, w, h):
    """North-up colour map at MAP_RES per pixel for the in-game map."""
    k = int(MAP_RES / RES)
    el = elev[::k, ::k].astype(np.float32)
    ld = land[::k, ::k]
    tw = town[::k, ::k].astype(np.float32) / 255.0
    lk = lake[::k, ::k]
    rgb = np.zeros(el.shape + (3,), np.float32)
    depth = np.clip(-el / 120.0, 0.0, 1.0)
    sea_col = np.array([0.36, 0.55, 0.66]) * (1 - depth[..., None]) + np.array([0.18, 0.33, 0.47]) * depth[..., None]
    t = np.clip(el / 700.0, 0.0, 1.0)[..., None]
    land_col = np.array([0.55, 0.66, 0.42]) * (1 - t) + np.array([0.80, 0.76, 0.58]) * t
    rgb = np.where(ld[..., None], land_col, sea_col)
    town_col = np.array([0.62, 0.55, 0.50])
    a = np.clip((tw - 0.15) * 2.0, 0.0, 1.0)[..., None]
    rgb = rgb * (1 - a) + town_col * a
    rgb = np.where(lk[..., None], np.array([0.36, 0.55, 0.66]), rgb)
    # Coast outline
    edge = ld ^ ndimage.binary_erosion(ld)
    rgb = np.where(edge[..., None], rgb * 0.7, rgb)
    img = Image.fromarray((np.clip(rgb, 0, 1) * 255).astype(np.uint8)[::-1, ::-1])   # north up, east right
    draw = ImageDraw.Draw(img)
    mh, mw = el.shape
    def px(pts):
        c = (pts[:, 0] - x_min) / MAP_RES
        r = (pts[:, 1] - z_min) / MAP_RES
        return list(zip(mw - 1 - c, mh - 1 - r))
    for pts, width in rivers:
        draw.line(px(pts), fill=(92, 140, 168), width=2 if width >= 150 else 1)
    img.save(os.path.join(out, "map.png"), optimize=True)
    print(f"  map.png: {mw} x {mh}")


def chaikin(pts, closed, iterations):
    for _ in range(iterations):
        if closed:
            a, b = pts, np.roll(pts, -1, axis=0)
            q = 0.75 * a + 0.25 * b
            r = 0.25 * a + 0.75 * b
            pts = np.empty((len(a) * 2, 2), dtype=pts.dtype)
            pts[0::2], pts[1::2] = q, r
        else:
            a, b = pts[:-1], pts[1:]
            q = 0.75 * a + 0.25 * b
            r = 0.25 * a + 0.75 * b
            mid = np.empty((len(a) * 2, 2), dtype=pts.dtype)
            mid[0::2], mid[1::2] = q, r
            pts = np.vstack([pts[:1], mid, pts[-1:]])
    return pts


def polyline_length(pts):
    return float(np.sum(np.hypot(*np.diff(pts, axis=0).T))) if len(pts) > 1 else 0.0


if __name__ == "__main__":
    sys.exit(main())
