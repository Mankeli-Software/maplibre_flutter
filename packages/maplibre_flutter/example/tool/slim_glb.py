#!/usr/bin/env python3
"""Slims a .glb down to what this renderer actually consumes, and normalises it.

The renderer reads POSITION, NORMAL, TEXCOORD_0, indices and base-colour
textures. Real exports carry a lot more. The Sketchfab car this was written for is
36 MB, of which 7.8 MB is a COLOR_0 attribute that is never read.

It also fixes the two things every downloaded model gets "wrong" for map use, so
the result is correct at `scale: 1, headingDegrees: 0` instead of needing magic
numbers at every call site:

  * SCALE. Models are rarely authored in metres. `--metres` rescales so the
    model's longest horizontal axis matches a real-world size.
  * HEADING. glTF's convention is that -Z is forward, but plenty of models ignore
    it. `--yaw` spins the model so its nose really does point -Z.

Both are applied as a wrapper NODE transform rather than by rewriting vertices —
cheaper, lossless, and exactly what node transforms are for.

Usage:
  python3 tool/slim_glb.py in.glb out.glb [--metres 3.53] [--yaw 180]
"""

import argparse
import json
import struct
from pathlib import Path

KEEP_ATTRS = {"POSITION", "NORMAL", "TEXCOORD_0"}


def read_glb(path):
    d = Path(path).read_bytes()
    magic, version, _ = struct.unpack_from("<III", d, 0)
    if magic != 0x46546C67:
        raise SystemExit(f"{path}: not a .glb")
    off, js, bin_ = 12, None, b""
    while off + 8 <= len(d):
        ln, ty = struct.unpack_from("<II", d, off)
        off += 8
        if ty == 0x4E4F534A:
            js = json.loads(d[off:off + ln])
        elif ty == 0x004E4942:
            bin_ = d[off:off + ln]
        off += ln + ((4 - ln % 4) % 4)
    if js is None:
        raise SystemExit(f"{path}: no JSON chunk")
    return js, bin_


def write_glb(path, js, bin_):
    j = json.dumps(js, separators=(",", ":")).encode()
    j += b" " * ((4 - len(j) % 4) % 4)
    b = bin_ + b"\x00" * ((4 - len(bin_) % 4) % 4)
    out = b"glTF" + struct.pack("<II", 2, 12 + 8 + len(j) + 8 + len(b))
    out += struct.pack("<II", len(j), 0x4E4F534A) + j
    out += struct.pack("<II", len(b), 0x004E4942) + b
    Path(path).write_bytes(out)
    return len(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src")
    ap.add_argument("dst")
    ap.add_argument("--metres", type=float, default=None,
                    help="rescale so the longest horizontal axis is this many metres. "
                         "Note this uses the BOUNDING BOX, which on many models is "
                         "larger than the object itself (stray geometry, spread "
                         "wheels), so prefer --scale when you have a value tuned by "
                         "eye against something of known size.")
    ap.add_argument("--scale", type=float, default=None,
                    help="explicit uniform scale; overrides --metres")
    ap.add_argument("--yaw", type=float, default=0.0,
                    help="degrees to spin about the up axis so the nose faces -Z")
    args = ap.parse_args()

    js, bin_ = read_glb(args.src)
    before = Path(args.src).stat().st_size

    # 1. Drop attributes the renderer never reads.
    dropped = set()
    for mesh in js.get("meshes", []):
        for prim in mesh.get("primitives", []):
            for name in list(prim.get("attributes", {})):
                if name not in KEEP_ATTRS:
                    dropped.add(name)
                    del prim["attributes"][name]
            prim.pop("targets", None)
    js.pop("animations", None)
    js.pop("skins", None)

    # 2. Keep only accessors still referenced, and only the bufferViews they need.
    used_acc = set()
    for mesh in js.get("meshes", []):
        for prim in mesh.get("primitives", []):
            used_acc.update(prim.get("attributes", {}).values())
            if "indices" in prim:
                used_acc.add(prim["indices"])

    used_bv = {js["accessors"][a]["bufferView"]
               for a in used_acc if "bufferView" in js["accessors"][a]}
    for img in js.get("images", []):
        if "bufferView" in img:
            used_bv.add(img["bufferView"])

    # 3. Repack the BIN with only the surviving bufferViews.
    new_bin = bytearray()
    bv_map = {}
    new_views = []
    for old in sorted(used_bv):
        v = js["bufferViews"][old]
        o, ln = v.get("byteOffset", 0), v["byteLength"]
        while len(new_bin) % 4:
            new_bin.append(0)
        nv = {"buffer": 0, "byteOffset": len(new_bin), "byteLength": ln}
        for k in ("byteStride", "target"):
            if k in v:
                nv[k] = v[k]
        new_bin.extend(bin_[o:o + ln])
        bv_map[old] = len(new_views)
        new_views.append(nv)

    acc_map = {}
    new_acc = []
    for old in sorted(used_acc):
        a = dict(js["accessors"][old])
        if "bufferView" in a:
            a["bufferView"] = bv_map[a["bufferView"]]
        acc_map[old] = len(new_acc)
        new_acc.append(a)

    for mesh in js.get("meshes", []):
        for prim in mesh.get("primitives", []):
            prim["attributes"] = {k: acc_map[v]
                                  for k, v in prim["attributes"].items()}
            if "indices" in prim:
                prim["indices"] = acc_map[prim["indices"]]
    for img in js.get("images", []):
        if "bufferView" in img:
            img["bufferView"] = bv_map[img["bufferView"]]

    js["accessors"] = new_acc
    js["bufferViews"] = new_views
    js["buffers"] = [{"byteLength": len(new_bin)}]

    # 4. Wrap the scene in a node carrying scale + yaw, so the model is correct at
    #    scale 1 / heading 0. A node transform is lossless and free; rewriting
    #    every vertex would not be.
    scale = 1.0
    if args.scale:
        scale = args.scale
        print(f"explicit scale {scale}")
    elif args.metres:
        acc_min = [1e30] * 3
        acc_max = [-1e30] * 3
        for mesh in js.get("meshes", []):
            for prim in mesh.get("primitives", []):
                a = new_acc[prim["attributes"]["POSITION"]]
                if "min" in a and "max" in a:
                    for i in range(3):
                        acc_min[i] = min(acc_min[i], a["min"][i])
                        acc_max[i] = max(acc_max[i], a["max"][i])
        # glTF is Y-up, so the horizontal extents are X and Z.
        longest = max(acc_max[0] - acc_min[0], acc_max[2] - acc_min[2])
        if longest > 0:
            scale = args.metres / longest
            print(f"longest horizontal axis {longest:.3f} -> {args.metres} m "
                  f"(scale {scale:.4f})")

    scene = js.get("scene", 0)
    roots = js["scenes"][scene].get("nodes", [])
    half = (args.yaw / 2.0) * 3.14159265358979323846 / 180.0
    wrapper = {"children": list(roots),
               "rotation": [0.0, __import__("math").sin(half), 0.0,
                            __import__("math").cos(half)],
               "scale": [scale, scale, scale]}
    js["nodes"].append(wrapper)
    js["scenes"][scene]["nodes"] = [len(js["nodes"]) - 1]

    size = write_glb(args.dst, js, bytes(new_bin))
    print(f"dropped attributes: {sorted(dropped) or 'none'}")
    print(f"{before/1e6:.1f} MB -> {size/1e6:.1f} MB "
          f"({100 * size / before:.0f}%)")


if __name__ == "__main__":
    main()
