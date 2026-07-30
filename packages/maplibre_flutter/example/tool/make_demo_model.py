#!/usr/bin/env python3
"""Generates the example's bundled demo vehicle, assets/models/demo_vehicle.glb.

Written rather than vendored on purpose:

  * A real-world model is large. The Sketchfab car this feature was developed
    against is 36 MB (32.8 MB of it geometry: 12.2 MB POSITION+NORMAL, 8.7 MB
    indices, 7.8 MB COLOR_0 we never read, 4.1 MB TEXCOORD_0). Committing that to
    git is permanent repository weight for a test fixture.
  * The obvious small alternatives — the Khronos sample assets — carry their own
    licences (Duck is under the SCEA Shared Source License, for instance), which
    is a needless thing to import into a plugin repo.

So this emits a few-KB model we own outright, shaped to exercise the paths that
actually broke during development rather than to look pretty:

  * TWO materials, one of them alphaMode BLEND, so part ordering is tested (glass
    drawn before bodywork used to depth-cull the bodywork).
  * A texture with UVs deliberately spanning beyond [0,1], so REPEAT wrapping is
    tested (clamping collapses such a model to one edge colour).
  * An asymmetric silhouette with a distinct front, so heading and facing errors
    are visible instead of hiding behind symmetry.
  * A node transform, so transform baking is tested.
  * Authored in METRES (about 3.8 m long), so it renders at life size at scale 1,
    and with its nose along -Z, which is glTF's forward convention.

Usage: python3 tool/make_demo_model.py
"""

import json
import struct
import zlib
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / "assets" / "models" / "demo_vehicle.glb"


def png(width, height, pixels):
    """Minimal RGBA PNG encoder (no dependencies)."""
    raw = b""
    for y in range(height):
        raw += b"\x00"  # filter: none
        for x in range(width):
            raw += bytes(pixels[y * width + x])

    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )


def make_texture():
    """A 16x16 tile: dark panel with a lighter stripe, so tiling is visible."""
    px = []
    for y in range(16):
        for x in range(16):
            if y in (0, 15) or x in (0, 15):
                px.append((30, 30, 34, 255))       # panel gap
            elif 6 <= y <= 9:
                px.append((225, 225, 235, 255))    # stripe
            else:
                px.append((190, 60, 55, 255))      # body colour
    return png(16, 16, px)


def box(cx, cy, cz, sx, sy, sz, uv_scale):
    """An axis-aligned box as 24 verts / 36 indices, +Y up, -Z forward (glTF)."""
    hx, hy, hz = sx / 2, sy / 2, sz / 2
    # (normal, four corners ccw seen from outside)
    faces = [
        ((0, 0, 1), [(-hx, -hy, hz), (hx, -hy, hz), (hx, hy, hz), (-hx, hy, hz)]),
        ((0, 0, -1), [(hx, -hy, -hz), (-hx, -hy, -hz), (-hx, hy, -hz), (hx, hy, -hz)]),
        ((1, 0, 0), [(hx, -hy, hz), (hx, -hy, -hz), (hx, hy, -hz), (hx, hy, hz)]),
        ((-1, 0, 0), [(-hx, -hy, -hz), (-hx, -hy, hz), (-hx, hy, hz), (-hx, hy, -hz)]),
        ((0, 1, 0), [(-hx, hy, hz), (hx, hy, hz), (hx, hy, -hz), (-hx, hy, -hz)]),
        ((0, -1, 0), [(-hx, -hy, -hz), (hx, -hy, -hz), (hx, -hy, hz), (-hx, -hy, hz)]),
    ]
    pos, nrm, uv, idx = [], [], [], []
    for normal, corners in faces:
        base = len(pos)
        for i, (x, y, z) in enumerate(corners):
            pos.append((x + cx, y + cy, z + cz))
            nrm.append(normal)
        # UVs run past 1.0 on purpose, so the model REQUIRES repeat wrapping.
        uv.extend([(0, 0), (uv_scale, 0), (uv_scale, uv_scale), (0, uv_scale)])
        idx.extend([base, base + 1, base + 2, base, base + 2, base + 3])
    return pos, nrm, uv, idx


def main():
    # Body, then a cabin set back from the nose so the silhouette is asymmetric
    # and the front is unambiguous. Nose points -Z (glTF forward).
    body = box(0, 0.55, 0, 1.7, 0.9, 3.8, 3.0)
    cabin = box(0, 1.15, 0.35, 1.5, 0.7, 1.9, 1.0)

    prims = [body, cabin]
    buf = bytearray()
    accessors, views = [], []

    def add_view(data, target=None):
        while len(buf) % 4:
            buf.append(0)
        off = len(buf)
        buf.extend(data)
        v = {"buffer": 0, "byteOffset": off, "byteLength": len(data)}
        if target:
            v["target"] = target
        views.append(v)
        return len(views) - 1

    meshes = []
    for i, (pos, nrm, uv, idx) in enumerate(prims):
        pv = add_view(b"".join(struct.pack("<3f", *p) for p in pos), 34962)
        nv = add_view(b"".join(struct.pack("<3f", *n) for n in nrm), 34962)
        tv = add_view(b"".join(struct.pack("<2f", *t) for t in uv), 34962)
        iv = add_view(b"".join(struct.pack("<H", k) for k in idx), 34963)

        xs = [p[0] for p in pos]
        ys = [p[1] for p in pos]
        zs = [p[2] for p in pos]
        accessors.append({"bufferView": pv, "componentType": 5126, "count": len(pos),
                          "type": "VEC3", "min": [min(xs), min(ys), min(zs)],
                          "max": [max(xs), max(ys), max(zs)]})
        accessors.append({"bufferView": nv, "componentType": 5126, "count": len(nrm),
                          "type": "VEC3"})
        accessors.append({"bufferView": tv, "componentType": 5126, "count": len(uv),
                          "type": "VEC2"})
        accessors.append({"bufferView": iv, "componentType": 5123, "count": len(idx),
                          "type": "SCALAR"})
        b = i * 4
        meshes.append({"primitives": [{
            "attributes": {"POSITION": b, "NORMAL": b + 1, "TEXCOORD_0": b + 2},
            "indices": b + 3, "material": i, "mode": 4}]})

    img_view = add_view(make_texture())

    gltf = {
        "asset": {"version": "2.0", "generator": "maplibre_flutter example tool"},
        "scene": 0,
        # A node transform, so transform baking is exercised rather than assumed.
        "scenes": [{"nodes": [0]}],
        "nodes": [
            {"children": [1, 2], "translation": [0, 0, 0]},
            {"mesh": 0},
            {"mesh": 1},
        ],
        "meshes": meshes,
        "accessors": accessors,
        "bufferViews": views,
        "buffers": [{"byteLength": 0}],
        "images": [{"bufferView": img_view, "mimeType": "image/png"}],
        "samplers": [{"magFilter": 9729, "wrapS": 10497, "wrapT": 10497}],
        "textures": [{"sampler": 0, "source": 0}],
        "materials": [
            {"name": "body", "pbrMetallicRoughness": {
                "baseColorTexture": {"index": 0},
                "baseColorFactor": [1, 1, 1, 1]}},
            # Glass: BLEND, so opaque-before-blended part ordering is exercised.
            {"name": "glass", "alphaMode": "BLEND", "pbrMetallicRoughness": {
                "baseColorFactor": [0.55, 0.72, 0.85, 0.45]}},
        ],
    }

    while len(buf) % 4:
        buf.append(0)
    gltf["buffers"][0]["byteLength"] = len(buf)

    js = json.dumps(gltf, separators=(",", ":")).encode()
    js += b" " * ((4 - len(js) % 4) % 4)

    total = 12 + 8 + len(js) + 8 + len(buf)
    out = b"glTF" + struct.pack("<II", 2, total)
    out += struct.pack("<II", len(js), 0x4E4F534A) + js
    out += struct.pack("<II", len(buf), 0x004E4942) + bytes(buf)

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_bytes(out)
    print(f"wrote {OUT} ({len(out)} bytes)")


if __name__ == "__main__":
    main()
