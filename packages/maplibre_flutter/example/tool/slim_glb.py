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
import math
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


def decode_accessor(js, bin_, idx):
    """Reads an accessor into a list of tuples (or scalars for indices)."""
    a = js["accessors"][idx]
    bv = js["bufferViews"][a["bufferView"]]
    comp = a["componentType"]
    ncomp = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4}[a["type"]]
    fmt, size = {5120: ("b", 1), 5121: ("B", 1), 5122: ("h", 2), 5123: ("H", 2),
                 5125: ("I", 4), 5126: ("f", 4)}[comp]
    stride = bv.get("byteStride") or size * ncomp
    base = bv.get("byteOffset", 0) + a.get("byteOffset", 0)
    out = []
    for i in range(a["count"]):
        off = base + i * stride
        vals = struct.unpack_from("<" + fmt * ncomp, bin_, off)
        out.append(vals[0] if ncomp == 1 else vals)
    return out


def decimate_primitive(pos, nrm, uv, idx, cell):
    """Grid vertex-clustering decimation.

    Snap each vertex to a grid cell, keep one representative per cell (averaged
    position and normal, first UV), then rebuild triangles and drop any whose
    corners collapsed into fewer than three distinct cells. Crude next to a
    quadric-error simplifier, but dependency-free and entirely good enough for
    something drawn a hundred pixels wide.
    """
    cells = {}
    order = []
    for i, p in enumerate(pos):
        key = (round(p[0] / cell), round(p[1] / cell), round(p[2] / cell))
        e = cells.get(key)
        if e is None:
            e = {"i": len(order), "p": [0.0, 0.0, 0.0], "n": [0.0, 0.0, 0.0],
                 "uv": uv[i] if uv else (0.0, 0.0), "count": 0}
            cells[key] = e
            order.append(e)
        for k in range(3):
            e["p"][k] += p[k]
            if nrm:
                e["n"][k] += nrm[i][k]
        e["count"] += 1

    remap = {}
    for i, p in enumerate(pos):
        remap[i] = cells[(round(p[0] / cell), round(p[1] / cell),
                          round(p[2] / cell))]["i"]

    new_pos, new_nrm, new_uv = [], [], []
    for e in order:
        c = e["count"]
        new_pos.append(tuple(v / c for v in e["p"]))
        n = [v / c for v in e["n"]]
        ln = math.sqrt(sum(v * v for v in n)) or 1.0
        new_nrm.append(tuple(v / ln for v in n))
        new_uv.append(e["uv"])

    new_idx = []
    for t in range(0, len(idx) - 2, 3):
        a, b, c = (remap[idx[t]], remap[idx[t + 1]], remap[idx[t + 2]])
        if a != b and b != c and a != c:
            new_idx.extend((a, b, c))
    return new_pos, new_nrm, new_uv, new_idx


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
    ap.add_argument("--decimate", type=float, default=None,
                    help="grid cell size in MODEL units for vertex-cluster "
                         "decimation, e.g. 0.05. Vertices in the same cell are "
                         "welded and collapsed triangles dropped. A car drawn ~100 "
                         "px wide does not need 728k triangles, and triangle "
                         "count is what limits how many models you can draw. "
                         "CAVEAT: this is grid vertex-clustering, which welds "
                         "vertices across surfaces that are near each other but "
                         "not connected. It is fine for gentle reduction and "
                         "SHREDS a detailed model at aggressive settings — on the "
                         "Alto, 0.04 gives 25% of triangles and holds together, "
                         "while 0.12 gives 6% and tears panels open. For real "
                         "reduction use a quadric-error simplifier (gltfpack / "
                         "meshoptimizer); this is the dependency-free option, not "
                         "the good one.")
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

    # 2b. Decimate: decode, cluster, and rebuild every primitive from scratch.
    if args.decimate:
        new_bin2 = bytearray()
        acc2, views2 = [], []

        def add_view2(data):
            while len(new_bin2) % 4:
                new_bin2.append(0)
            off = len(new_bin2)
            new_bin2.extend(data)
            views2.append({"buffer": 0, "byteOffset": off, "byteLength": len(data)})
            return len(views2) - 1

        before_tris = after_tris = 0
        dropped_prims = 0
        for mesh in js.get("meshes", []):
            kept = []
            for prim in mesh.get("primitives", []):
                at = prim["attributes"]
                pos = decode_accessor(js, bin_, at["POSITION"])
                nrm = decode_accessor(js, bin_, at["NORMAL"]) if "NORMAL" in at else None
                uv = (decode_accessor(js, bin_, at["TEXCOORD_0"])
                      if "TEXCOORD_0" in at else None)
                idx = (decode_accessor(js, bin_, prim["indices"])
                       if "indices" in prim else list(range(len(pos))))
                before_tris += len(idx) // 3

                pos, nrm, uv, idx = decimate_primitive(
                    pos, nrm, uv, idx, args.decimate)
                after_tris += len(idx) // 3
                if not idx:
                    # Everything in this primitive collapsed into a single cell.
                    # Drop it outright — leaving an attribute-less primitive
                    # behind produces a file no loader will accept.
                    dropped_prims += 1
                    continue

                pv = add_view2(b"".join(struct.pack("<3f", *p) for p in pos))
                xs = [p[0] for p in pos]
                ys = [p[1] for p in pos]
                zs = [p[2] for p in pos]
                acc2.append({"bufferView": pv, "componentType": 5126,
                             "count": len(pos), "type": "VEC3",
                             "min": [min(xs), min(ys), min(zs)],
                             "max": [max(xs), max(ys), max(zs)]})
                newattrs = {"POSITION": len(acc2) - 1}
                if nrm:
                    nv = add_view2(b"".join(struct.pack("<3f", *n) for n in nrm))
                    acc2.append({"bufferView": nv, "componentType": 5126,
                                 "count": len(nrm), "type": "VEC3"})
                    newattrs["NORMAL"] = len(acc2) - 1
                if uv:
                    tv = add_view2(b"".join(struct.pack("<2f", *t) for t in uv))
                    acc2.append({"bufferView": tv, "componentType": 5126,
                                 "count": len(uv), "type": "VEC2"})
                    newattrs["TEXCOORD_0"] = len(acc2) - 1
                # uint32 indices: a decimated primitive can still exceed 65535,
                # and the renderer splits into uint16 chunks itself.
                iv = add_view2(b"".join(struct.pack("<I", k) for k in idx))
                acc2.append({"bufferView": iv, "componentType": 5125,
                             "count": len(idx), "type": "SCALAR"})
                prim["attributes"] = newattrs
                prim["indices"] = len(acc2) - 1
                kept.append(prim)
            mesh["primitives"] = kept

        for img in js.get("images", []):
            if "bufferView" in img:
                bv = js["bufferViews"][img["bufferView"]]
                o, ln = bv.get("byteOffset", 0), bv["byteLength"]
                img["bufferView"] = add_view2(bin_[o:o + ln])

        js["accessors"] = acc2
        js["bufferViews"] = views2
        bin_ = bytes(new_bin2)
        js["buffers"] = [{"byteLength": len(bin_)}]
        # Meshes emptied entirely would leave nodes pointing at nothing.
        js["meshes"] = [m for m in js.get("meshes", []) if m.get("primitives")]
        print(f"decimated {before_tris} -> {after_tris} triangles "
              f"({100 * after_tris / max(before_tris, 1):.1f}%), "
              f"{dropped_prims} primitives collapsed away")

    # 3. Repack the BIN with only the surviving bufferViews.
    #
    # Skipped entirely when decimating: that path rebuilt every accessor and
    # bufferView from scratch, so repacking would remap indices that no longer
    # exist.
    if not args.decimate:
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

    final_bin = bin_ if args.decimate else bytes(new_bin)
    size = write_glb(args.dst, js, final_bin)
    print(f"dropped attributes: {sorted(dropped) or 'none'}")
    print(f"{before/1e6:.1f} MB -> {size/1e6:.1f} MB "
          f"({100 * size / before:.0f}%)")


if __name__ == "__main__":
    main()
