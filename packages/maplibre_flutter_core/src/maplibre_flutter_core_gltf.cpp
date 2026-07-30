#include "maplibre_flutter_core_gltf.hpp"

#include <mbgl/util/rapidjson.hpp>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <fstream>
#include <limits>
#include <unordered_map>

namespace {

// GLB container constants (glTF 2.0 spec, 4.4.1 "Binary glTF Layout").
constexpr uint32_t kGlbMagic = 0x46546C67;    // "glTF"
constexpr uint32_t kChunkJson = 0x4E4F534A;   // "JSON"
constexpr uint32_t kChunkBin = 0x004E4942;    // "BIN\0"
constexpr uint32_t kGlbVersion = 2;

// glTF accessor component types.
constexpr int kByte = 5120;
constexpr int kUnsignedByte = 5121;
constexpr int kShort = 5122;
constexpr int kUnsignedShort = 5123;
constexpr int kUnsignedInt = 5125;
constexpr int kFloat = 5126;

constexpr int kTriangles = 4; // primitive.mode

// glTF sampler enums.
constexpr int kClampToEdge = 33071;
constexpr int kNearest = 9728;
constexpr int kNearestMipmapNearest = 9984;
constexpr int kNearestMipmapLinear = 9986;

// mbgl's IndexVector is uint16-based, so this is a hard ceiling.
constexpr size_t kMaxVertices = 65535;

using mbgl::JSValue;

// A resolved accessor: where its data lives and how to walk it.
struct Accessor {
  const uint8_t *data = nullptr;
  size_t count = 0;
  size_t stride = 0; // bytes between consecutive elements
  int componentType = 0;
  int components = 0; // 1 for SCALAR, 2 for VEC2, 3 for VEC3...
};

int componentSize(int componentType) {
  switch (componentType) {
    case kByte:
    case kUnsignedByte:
      return 1;
    case kShort:
    case kUnsignedShort:
      return 2;
    case kUnsignedInt:
    case kFloat:
      return 4;
    default:
      return 0;
  }
}

int typeComponents(const std::string &type) {
  if (type == "SCALAR") return 1;
  if (type == "VEC2") return 2;
  if (type == "VEC3") return 3;
  if (type == "VEC4") return 4;
  if (type == "MAT4") return 16;
  return 0;
}

const JSValue *member(const JSValue &v, const char *name) {
  if (!v.IsObject()) return nullptr;
  const auto it = v.FindMember(name);
  return it != v.MemberEnd() ? &it->value : nullptr;
}

// Resolve accessor `index` down through its bufferView into the BIN chunk.
bool resolveAccessor(const JSValue &root, size_t index,
                     const std::vector<uint8_t> &bin, Accessor &out,
                     std::string &error) {
  const auto *accessors = member(root, "accessors");
  if (accessors == nullptr || !accessors->IsArray() ||
      index >= accessors->Size()) {
    error = "accessor " + std::to_string(index) + " out of range";
    return false;
  }
  const JSValue &acc = (*accessors)[static_cast<rapidjson::SizeType>(index)];

  const auto *typeV = member(acc, "type");
  const auto *compV = member(acc, "componentType");
  const auto *countV = member(acc, "count");
  if (typeV == nullptr || !typeV->IsString() || compV == nullptr ||
      !compV->IsInt() || countV == nullptr || !countV->IsUint()) {
    error = "accessor is missing type/componentType/count";
    return false;
  }
  out.componentType = compV->GetInt();
  out.components = typeComponents(typeV->GetString());
  out.count = countV->GetUint();
  const int csize = componentSize(out.componentType);
  if (out.components == 0 || csize == 0) {
    error = "unsupported accessor type/componentType";
    return false;
  }

  // Sparse accessors would silently give wrong geometry, so reject them.
  if (member(acc, "sparse") != nullptr) {
    error = "sparse accessors are not supported";
    return false;
  }

  const auto *bvV = member(acc, "bufferView");
  if (bvV == nullptr || !bvV->IsUint()) {
    // Spec-legal (means all zeros) but never useful for us.
    error = "accessor without a bufferView is not supported";
    return false;
  }
  const auto *bufferViews = member(root, "bufferViews");
  if (bufferViews == nullptr || !bufferViews->IsArray() ||
      bvV->GetUint() >= bufferViews->Size()) {
    error = "bufferView out of range";
    return false;
  }
  const JSValue &bv =
      (*bufferViews)[static_cast<rapidjson::SizeType>(bvV->GetUint())];

  // GLB: every buffer we support is the single BIN chunk (buffer 0, no uri).
  const auto *bufV = member(bv, "buffer");
  if (bufV != nullptr && bufV->IsUint() && bufV->GetUint() != 0) {
    error = "only the GLB BIN chunk (buffer 0) is supported";
    return false;
  }

  const size_t bvOffset =
      member(bv, "byteOffset") != nullptr && member(bv, "byteOffset")->IsUint()
          ? member(bv, "byteOffset")->GetUint()
          : 0;
  const size_t bvLength =
      member(bv, "byteLength") != nullptr && member(bv, "byteLength")->IsUint()
          ? member(bv, "byteLength")->GetUint()
          : 0;
  const size_t accOffset =
      member(acc, "byteOffset") != nullptr && member(acc, "byteOffset")->IsUint()
          ? member(acc, "byteOffset")->GetUint()
          : 0;

  const size_t elementSize = static_cast<size_t>(csize) * out.components;
  const size_t bvStride =
      member(bv, "byteStride") != nullptr && member(bv, "byteStride")->IsUint()
          ? member(bv, "byteStride")->GetUint()
          : 0;
  out.stride = bvStride != 0 ? bvStride : elementSize;

  // Bounds-check against the BIN chunk before handing out a pointer: a truncated
  // or hostile file must not be able to walk us off the end of the buffer.
  if (bvOffset > bin.size() || bvLength > bin.size() - bvOffset) {
    error = "bufferView exceeds the BIN chunk";
    return false;
  }
  if (out.count > 0) {
    const size_t span = accOffset + out.stride * (out.count - 1) + elementSize;
    if (span > bvLength) {
      error = "accessor exceeds its bufferView";
      return false;
    }
  }
  out.data = bin.data() + bvOffset + accOffset;
  return true;
}

float readFloatComponent(const Accessor &a, size_t element, int component) {
  const uint8_t *p = a.data + a.stride * element +
                     static_cast<size_t>(componentSize(a.componentType)) *
                         component;
  switch (a.componentType) {
    case kFloat: {
      float f;
      std::memcpy(&f, p, sizeof(f));
      return f;
    }
    // Normalized integer UVs are common in size-optimised exports.
    case kUnsignedByte:
      return static_cast<float>(*p) / 255.0f;
    case kUnsignedShort: {
      uint16_t v;
      std::memcpy(&v, p, sizeof(v));
      return static_cast<float>(v) / 65535.0f;
    }
    default:
      return 0.0f;
  }
}

uint32_t readIndex(const Accessor &a, size_t element) {
  const uint8_t *p = a.data + a.stride * element;
  switch (a.componentType) {
    case kUnsignedByte:
      return *p;
    case kUnsignedShort: {
      uint16_t v;
      std::memcpy(&v, p, sizeof(v));
      return v;
    }
    case kUnsignedInt: {
      uint32_t v;
      std::memcpy(&v, p, sizeof(v));
      return v;
    }
    default:
      return 0;
  }
}

// Column-major 4x4, matching glTF's `matrix` layout.
using Mat4 = std::array<double, 16>;

constexpr Mat4 identity() {
  return {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1};
}

Mat4 multiply(const Mat4 &a, const Mat4 &b) { // a * b
  Mat4 r{};
  for (int c = 0; c < 4; ++c) {
    for (int row = 0; row < 4; ++row) {
      double sum = 0;
      for (int k = 0; k < 4; ++k) {
        sum += a[static_cast<size_t>(k * 4 + row)] *
               b[static_cast<size_t>(c * 4 + k)];
      }
      r[static_cast<size_t>(c * 4 + row)] = sum;
    }
  }
  return r;
}

// Compose a node's local transform: either an explicit `matrix`, or TRS.
Mat4 nodeLocalTransform(const JSValue &node) {
  const auto *m = member(node, "matrix");
  if (m != nullptr && m->IsArray() && m->Size() == 16) {
    Mat4 out{};
    for (rapidjson::SizeType i = 0; i < 16; ++i) {
      out[i] = (*m)[i].GetDouble();
    }
    return out;
  }

  Mat4 out = identity();
  const auto *t = member(node, "translation");
  const auto *r = member(node, "rotation");
  const auto *s = member(node, "scale");

  // T * R * S, per the glTF spec.
  Mat4 translation = identity();
  if (t != nullptr && t->IsArray() && t->Size() == 3) {
    translation[12] = (*t)[0].GetDouble();
    translation[13] = (*t)[1].GetDouble();
    translation[14] = (*t)[2].GetDouble();
  }

  Mat4 rotation = identity();
  if (r != nullptr && r->IsArray() && r->Size() == 4) {
    // glTF quaternion order is (x, y, z, w).
    const double x = (*r)[0].GetDouble();
    const double y = (*r)[1].GetDouble();
    const double z = (*r)[2].GetDouble();
    const double w = (*r)[3].GetDouble();
    rotation[0] = 1 - 2 * (y * y + z * z);
    rotation[1] = 2 * (x * y + z * w);
    rotation[2] = 2 * (x * z - y * w);
    rotation[4] = 2 * (x * y - z * w);
    rotation[5] = 1 - 2 * (x * x + z * z);
    rotation[6] = 2 * (y * z + x * w);
    rotation[8] = 2 * (x * z + y * w);
    rotation[9] = 2 * (y * z - x * w);
    rotation[10] = 1 - 2 * (x * x + y * y);
  }

  Mat4 scale = identity();
  if (s != nullptr && s->IsArray() && s->Size() == 3) {
    scale[0] = (*s)[0].GetDouble();
    scale[5] = (*s)[1].GetDouble();
    scale[10] = (*s)[2].GetDouble();
  }

  out = multiply(translation, multiply(rotation, scale));
  return out;
}

std::array<double, 3> transformPoint(const Mat4 &m,
                                     const std::array<float, 3> &p) {
  const double x = p[0], y = p[1], z = p[2];
  return {m[0] * x + m[4] * y + m[8] * z + m[12],
          m[1] * x + m[5] * y + m[9] * z + m[13],
          m[2] * x + m[6] * y + m[10] * z + m[14]};
}

// Resolved base-colour material state for one primitive.
struct Material {
  int imageIndex = -1;
  bool blended = false;
  std::array<float, 4> factor = {1.0f, 1.0f, 1.0f, 1.0f};
  bool wrapRepeatU = true;
  bool wrapRepeatV = true;
  bool filterLinear = true;
  // KHR_texture_transform, baked into UVs at load time (see applyUvTransform).
  bool hasUvTransform = false;
  std::array<double, 2> uvOffset = {0.0, 0.0};
  std::array<double, 2> uvScale = {1.0, 1.0};
  double uvRotation = 0.0;
};

// KHR_texture_transform: matrix = translation * rotation * scale, applied to
// vec3(uv, 1). Expanded from the extension spec's column-major mat3 form.
std::array<float, 2> applyUvTransform(const Material &m,
                                      const std::array<float, 2> &uv) {
  if (!m.hasUvTransform) {
    return uv;
  }
  const double c = std::cos(m.uvRotation);
  const double s = std::sin(m.uvRotation);
  const double u = uv[0], v = uv[1];
  return {static_cast<float>(c * m.uvScale[0] * u + s * m.uvScale[1] * v +
                             m.uvOffset[0]),
          static_cast<float>(-s * m.uvScale[0] * u + c * m.uvScale[1] * v +
                             m.uvOffset[1])};
}

struct Loader {
  const JSValue &root;
  const std::vector<uint8_t> &bin;
  MblMeshData &out;
  std::string &error;
  bool boundsInitialised = false;
  // glTF image index -> index into out.images, so an image shared by many
  // materials is decoded exactly once.
  std::vector<int> imageSlot;

  void growBounds(const std::array<float, 3> &p) {
    for (size_t k = 0; k < 3; ++k) {
      if (!boundsInitialised) {
        out.minPosition[k] = out.maxPosition[k] = p[k];
      } else {
        out.minPosition[k] = std::min(out.minPosition[k], p[k]);
        out.maxPosition[k] = std::max(out.maxPosition[k], p[k]);
      }
    }
    boundsInitialised = true;
  }

  // Decode a glTF image once and return its slot in out.images, or -1.
  int resolveImage(size_t gltfImageIndex) {
    const auto *images = member(root, "images");
    if (images == nullptr || !images->IsArray() ||
        gltfImageIndex >= images->Size()) {
      return -1;
    }
    if (imageSlot.empty()) {
      imageSlot.assign(images->Size(), -2); // -2 = not yet attempted
    }
    if (imageSlot[gltfImageIndex] != -2) {
      return imageSlot[gltfImageIndex];
    }
    imageSlot[gltfImageIndex] = -1;

    const JSValue &img =
        (*images)[static_cast<rapidjson::SizeType>(gltfImageIndex)];
    // GLB-embedded images only; external/data-URI images are out of scope.
    const auto *bvV = member(img, "bufferView");
    if (bvV == nullptr || !bvV->IsUint()) {
      return -1;
    }
    const auto *bufferViews = member(root, "bufferViews");
    if (bufferViews == nullptr || !bufferViews->IsArray() ||
        bvV->GetUint() >= bufferViews->Size()) {
      return -1;
    }
    const JSValue &bv =
        (*bufferViews)[static_cast<rapidjson::SizeType>(bvV->GetUint())];
    const size_t off =
        member(bv, "byteOffset") != nullptr && member(bv, "byteOffset")->IsUint()
            ? member(bv, "byteOffset")->GetUint()
            : 0;
    const size_t len =
        member(bv, "byteLength") != nullptr && member(bv, "byteLength")->IsUint()
            ? member(bv, "byteLength")->GetUint()
            : 0;
    if (off > bin.size() || len > bin.size() - off || len == 0) {
      return -1;
    }

    // Best-effort: a model with one unreadable texture still loads and renders
    // that part with its baseColorFactor tint.
    try {
      auto decoded = std::make_shared<mbgl::PremultipliedImage>(
          mbgl::decodeImage(std::string(
              reinterpret_cast<const char *>(bin.data() + off), len)));
      out.images.push_back(std::move(decoded));
      imageSlot[gltfImageIndex] = static_cast<int>(out.images.size() - 1);
    } catch (const std::exception &) {
      imageSlot[gltfImageIndex] = -1;
    }
    return imageSlot[gltfImageIndex];
  }

  Material resolveMaterial(const JSValue &prim) {
    Material mat;
    const auto *matV = member(prim, "material");
    if (matV == nullptr || !matV->IsUint()) {
      return mat;
    }
    const auto *materials = member(root, "materials");
    if (materials == nullptr || !materials->IsArray() ||
        matV->GetUint() >= materials->Size()) {
      return mat;
    }
    const JSValue &m =
        (*materials)[static_cast<rapidjson::SizeType>(matV->GetUint())];
    if (const auto *am = member(m, "alphaMode");
        am != nullptr && am->IsString()) {
      mat.blended = std::string(am->GetString()) == "BLEND";
    }
    const auto *pbr = member(m, "pbrMetallicRoughness");
    if (pbr == nullptr) {
      return mat;
    }

    if (const auto *f = member(*pbr, "baseColorFactor");
        f != nullptr && f->IsArray() && f->Size() == 4) {
      for (rapidjson::SizeType i = 0; i < 4; ++i) {
        mat.factor[i] = static_cast<float>((*f)[i].GetDouble());
      }
      if (mat.factor[3] < 1.0f) {
        mat.blended = true;
      }
    }

    const auto *texRef = member(*pbr, "baseColorTexture");
    if (texRef == nullptr) {
      return mat;
    }

    if (const auto *ext = member(*texRef, "extensions")) {
      if (const auto *tt = member(*ext, "KHR_texture_transform")) {
        mat.hasUvTransform = true;
        if (const auto *o = member(*tt, "offset");
            o != nullptr && o->IsArray() && o->Size() == 2) {
          mat.uvOffset = {(*o)[0].GetDouble(), (*o)[1].GetDouble()};
        }
        if (const auto *sc = member(*tt, "scale");
            sc != nullptr && sc->IsArray() && sc->Size() == 2) {
          mat.uvScale = {(*sc)[0].GetDouble(), (*sc)[1].GetDouble()};
        }
        if (const auto *r = member(*tt, "rotation");
            r != nullptr && r->IsNumber()) {
          mat.uvRotation = r->GetDouble();
        }
      }
    }

    const auto *texIdx = member(*texRef, "index");
    const auto *textures = member(root, "textures");
    if (texIdx == nullptr || !texIdx->IsUint() || textures == nullptr ||
        !textures->IsArray() || texIdx->GetUint() >= textures->Size()) {
      return mat;
    }
    const JSValue &tex =
        (*textures)[static_cast<rapidjson::SizeType>(texIdx->GetUint())];

    // Honour the sampler's wrap/filter. glTF's DEFAULT wrap is REPEAT, so an
    // absent sampler must stay repeating.
    if (const auto *sampV = member(tex, "sampler");
        sampV != nullptr && sampV->IsUint()) {
      if (const auto *samplers = member(root, "samplers");
          samplers != nullptr && samplers->IsArray() &&
          sampV->GetUint() < samplers->Size()) {
        const JSValue &samp =
            (*samplers)[static_cast<rapidjson::SizeType>(sampV->GetUint())];
        if (const auto *w = member(samp, "wrapS"); w != nullptr && w->IsInt()) {
          mat.wrapRepeatU = w->GetInt() != kClampToEdge;
        }
        if (const auto *w = member(samp, "wrapT"); w != nullptr && w->IsInt()) {
          mat.wrapRepeatV = w->GetInt() != kClampToEdge;
        }
        // mbgl exposes only Nearest/Linear, so any mipmapped-nearest mode maps to
        // Nearest and everything else to Linear.
        if (const auto *f = member(samp, "magFilter");
            f != nullptr && f->IsInt()) {
          const int mode = f->GetInt();
          mat.filterLinear = mode != kNearest &&
                             mode != kNearestMipmapNearest &&
                             mode != kNearestMipmapLinear;
        }
      }
    }

    if (const auto *srcV = member(tex, "source");
        srcV != nullptr && srcV->IsUint()) {
      mat.imageIndex = resolveImage(srcV->GetUint());
    }
    return mat;
  }

  // Append one primitive as one or more parts, baking `world` into its positions.
  //
  // Chunked by vertex count: a triangle's three corners are copied into the
  // current part (de-duplicated), and when the part would exceed the uint16
  // ceiling a fresh one is started. That is what lets a 500k-vertex model load —
  // the limit is per drawable, not per model — and it works uniformly for indexed
  // and non-indexed primitives.
  bool addPrimitive(const JSValue &prim, const Mat4 &world) {
    const auto *modeV = member(prim, "mode");
    if (modeV != nullptr && modeV->IsInt() && modeV->GetInt() != kTriangles) {
      // Points/lines/strips: skip rather than fail, so a model that merely
      // carries a stray non-triangle primitive still loads.
      return true;
    }

    const auto *attrs = member(prim, "attributes");
    if (attrs == nullptr) {
      error = "primitive has no attributes";
      return false;
    }
    const auto *posV = member(*attrs, "POSITION");
    if (posV == nullptr || !posV->IsUint()) {
      error = "primitive has no POSITION accessor";
      return false;
    }

    Accessor pos;
    if (!resolveAccessor(root, posV->GetUint(), bin, pos, error)) {
      return false;
    }
    if (pos.components != 3 || pos.componentType != kFloat) {
      error = "POSITION must be a float VEC3";
      return false;
    }

    std::optional<Accessor> nrm;
    if (const auto *nV = member(*attrs, "NORMAL"); nV != nullptr && nV->IsUint()) {
      Accessor a;
      if (!resolveAccessor(root, nV->GetUint(), bin, a, error)) {
        return false;
      }
      if (a.components == 3 && a.componentType == kFloat) {
        nrm = a;
      }
    }

    std::optional<Accessor> uv;
    if (const auto *uvV = member(*attrs, "TEXCOORD_0");
        uvV != nullptr && uvV->IsUint()) {
      Accessor a;
      if (!resolveAccessor(root, uvV->GetUint(), bin, a, error)) {
        return false;
      }
      if (a.components == 2 &&
          (a.componentType == kFloat || a.componentType == kUnsignedByte ||
           a.componentType == kUnsignedShort)) {
        uv = a;
      }
    }

    const Material mat = resolveMaterial(prim);

    // Triangle list of source-vertex indices.
    std::vector<uint32_t> tri;
    if (const auto *idxV = member(prim, "indices");
        idxV != nullptr && idxV->IsUint()) {
      Accessor idx;
      if (!resolveAccessor(root, idxV->GetUint(), bin, idx, error)) {
        return false;
      }
      if (idx.components != 1) {
        error = "index accessor must be SCALAR";
        return false;
      }
      tri.reserve(idx.count);
      for (size_t i = 0; i + 2 < idx.count; i += 3) {
        for (size_t k = 0; k < 3; ++k) {
          const uint32_t v = readIndex(idx, i + k);
          if (v >= pos.count) {
            error = "index " + std::to_string(v) + " out of range for POSITION";
            return false;
          }
          tri.push_back(v);
        }
      }
    } else {
      tri.reserve(pos.count);
      for (size_t i = 0; i + 2 < pos.count; i += 3) {
        tri.push_back(static_cast<uint32_t>(i));
        tri.push_back(static_cast<uint32_t>(i + 1));
        tri.push_back(static_cast<uint32_t>(i + 2));
      }
    }
    if (tri.empty()) {
      return true;
    }

    const auto readVertex = [&](uint32_t src) {
      MblMeshData::Vertex v{};
      const std::array<float, 3> raw = {readFloatComponent(pos, src, 0),
                                        readFloatComponent(pos, src, 1),
                                        readFloatComponent(pos, src, 2)};
      const auto w = transformPoint(world, raw);
      // glTF (Y-up, -Z forward, right-handed) -> map model space (X east,
      // Y south, Z up): (x, y, z) -> (-x, z, y). Determinant +1, so winding
      // survives, and glTF forward ends up facing map north. See the header.
      v.position = {static_cast<float>(-w[0]), static_cast<float>(w[2]),
                    static_cast<float>(w[1])};
      const std::array<float, 2> rawUv =
          uv.has_value() ? std::array<float, 2>{readFloatComponent(*uv, src, 0),
                                                readFloatComponent(*uv, src, 1)}
                         : std::array<float, 2>{0.5f, 0.5f};
      v.texcoords = applyUvTransform(mat, rawUv);

      if (nrm.has_value()) {
        // Rotate (do NOT translate) the normal by the node transform, then apply
        // the same glTF -> map axis change as the position. Non-uniform scale
        // would strictly need the inverse-transpose; renormalising afterwards is
        // close enough for a single diffuse term and much cheaper.
        const std::array<float, 3> rawN = {readFloatComponent(*nrm, src, 0),
                                           readFloatComponent(*nrm, src, 1),
                                           readFloatComponent(*nrm, src, 2)};
        const double nx = world[0] * rawN[0] + world[4] * rawN[1] + world[8] * rawN[2];
        const double ny = world[1] * rawN[0] + world[5] * rawN[1] + world[9] * rawN[2];
        const double nz = world[2] * rawN[0] + world[6] * rawN[1] + world[10] * rawN[2];
        double mx = -nx, my = nz, mz = ny;
        const double len = std::sqrt(mx * mx + my * my + mz * mz);
        if (len > 1e-9) {
          mx /= len;
          my /= len;
          mz /= len;
        }
        v.normal = {static_cast<float>(mx), static_cast<float>(my),
                    static_cast<float>(mz)};
      }
      return v;
    };

    MblMeshData::Part part;
    part.imageIndex = mat.imageIndex;
    part.baseColorFactor = mat.factor;
    part.wrapRepeatU = mat.wrapRepeatU;
    part.wrapRepeatV = mat.wrapRepeatV;
    part.filterLinear = mat.filterLinear;
    part.blended = mat.blended;

    // Source index -> index within the current part.
    std::unordered_map<uint32_t, uint16_t> remap;
    const auto flush = [&]() {
      if (!part.vertices.empty()) {
        out.parts.push_back(std::move(part));
      }
      part = MblMeshData::Part{};
      part.imageIndex = mat.imageIndex;
      part.baseColorFactor = mat.factor;
      part.wrapRepeatU = mat.wrapRepeatU;
      part.wrapRepeatV = mat.wrapRepeatV;
      part.filterLinear = mat.filterLinear;
      part.blended = mat.blended;
      remap.clear();
    };

    for (size_t t = 0; t + 2 < tri.size(); t += 3) {
      // Worst case this triangle adds three new vertices.
      if (part.vertices.size() + 3 > kMaxVertices) {
        flush();
      }
      for (size_t k = 0; k < 3; ++k) {
        const uint32_t src = tri[t + k];
        const auto it = remap.find(src);
        uint16_t local;
        if (it != remap.end()) {
          local = it->second;
        } else {
          local = static_cast<uint16_t>(part.vertices.size());
          const auto v = readVertex(src);
          growBounds(v.position);
          part.vertices.push_back(v);
          remap.emplace(src, local);
        }
        part.indices.push_back(local);
      }
    }
    flush();
    return true;
  }

  bool addNode(size_t index, const Mat4 &parent, int depth) {
    if (depth > 64) {
      error = "node hierarchy too deep (cycle?)";
      return false;
    }
    const auto *nodes = member(root, "nodes");
    if (nodes == nullptr || !nodes->IsArray() || index >= nodes->Size()) {
      error = "node out of range";
      return false;
    }
    const JSValue &node = (*nodes)[static_cast<rapidjson::SizeType>(index)];
    const Mat4 world = multiply(parent, nodeLocalTransform(node));

    if (const auto *meshV = member(node, "mesh");
        meshV != nullptr && meshV->IsUint()) {
      const auto *meshes = member(root, "meshes");
      if (meshes != nullptr && meshes->IsArray() &&
          meshV->GetUint() < meshes->Size()) {
        const JSValue &mesh =
            (*meshes)[static_cast<rapidjson::SizeType>(meshV->GetUint())];
        if (const auto *prims = member(mesh, "primitives");
            prims != nullptr && prims->IsArray()) {
          for (rapidjson::SizeType i = 0; i < prims->Size(); ++i) {
            if (!addPrimitive((*prims)[i], world)) return false;
          }
        }
      }
    }

    if (const auto *children = member(node, "children");
        children != nullptr && children->IsArray()) {
      for (rapidjson::SizeType i = 0; i < children->Size(); ++i) {
        if (!(*children)[i].IsUint()) continue;
        if (!addNode((*children)[i].GetUint(), world, depth + 1)) return false;
      }
    }
    return true;
  }
};

} // namespace

bool mblLoadGlb(const std::string &path, MblMeshData &out,
                std::string &error) {
  std::ifstream file(path, std::ios::binary);
  if (!file) {
    error = "cannot open " + path;
    return false;
  }
  std::vector<uint8_t> bytes((std::istreambuf_iterator<char>(file)),
                             std::istreambuf_iterator<char>());
  if (bytes.size() < 12) {
    error = "file is too small to be a GLB";
    return false;
  }

  uint32_t magic = 0, version = 0, length = 0;
  std::memcpy(&magic, bytes.data(), 4);
  std::memcpy(&version, bytes.data() + 4, 4);
  std::memcpy(&length, bytes.data() + 8, 4);
  if (magic != kGlbMagic) {
    error = "not a binary glTF (.glb); text .gltf with external buffers is "
            "not supported";
    return false;
  }
  if (version != kGlbVersion) {
    error = "unsupported GLB version " + std::to_string(version);
    return false;
  }
  if (length > bytes.size()) {
    error = "GLB header length exceeds the file";
    return false;
  }

  std::string json;
  std::vector<uint8_t> bin;
  size_t cursor = 12;
  while (cursor + 8 <= length) {
    uint32_t chunkLength = 0, chunkType = 0;
    std::memcpy(&chunkLength, bytes.data() + cursor, 4);
    std::memcpy(&chunkType, bytes.data() + cursor + 4, 4);
    cursor += 8;
    if (chunkLength > length - cursor) {
      error = "GLB chunk length exceeds the file";
      return false;
    }
    if (chunkType == kChunkJson && json.empty()) {
      json.assign(reinterpret_cast<const char *>(bytes.data() + cursor),
                  chunkLength);
    } else if (chunkType == kChunkBin && bin.empty()) {
      bin.assign(bytes.data() + cursor, bytes.data() + cursor + chunkLength);
    }
    cursor += chunkLength;
    // Chunks are 4-byte aligned.
    cursor += (4 - (chunkLength % 4)) % 4;
  }
  if (json.empty()) {
    error = "GLB has no JSON chunk";
    return false;
  }

  mbgl::JSDocument doc;
  doc.Parse<0>(json.c_str());
  if (doc.HasParseError()) {
    error = "GLB JSON parse error: " + mbgl::formatJSONParseError(doc);
    return false;
  }

  // Anything in extensionsRequired that we do not implement would change the
  // geometry silently (Draco/meshopt decode, quantized attributes), so refuse
  // rather than render garbage. KHR_texture_transform is applied at load time.
  if (const auto *req = member(doc, "extensionsRequired");
      req != nullptr && req->IsArray()) {
    for (rapidjson::SizeType i = 0; i < req->Size(); ++i) {
      if (!req->operator[](i).IsString()) continue;
      const std::string name = req->operator[](i).GetString();
      if (name != "KHR_texture_transform") {
        error = "required glTF extension is not supported: " + name;
        return false;
      }
    }
  }

  Loader loader{doc, bin, out, error};

  // Walk the default scene if there is one, else every node that no other node
  // claims as a child (models in the wild are not always scene-complete).
  const auto *scenes = member(doc, "scenes");
  const auto *sceneV = member(doc, "scene");
  bool walked = false;
  if (scenes != nullptr && scenes->IsArray() && scenes->Size() > 0) {
    const rapidjson::SizeType sceneIndex =
        sceneV != nullptr && sceneV->IsUint() &&
                sceneV->GetUint() < scenes->Size()
            ? static_cast<rapidjson::SizeType>(sceneV->GetUint())
            : 0;
    if (const auto *roots = member((*scenes)[sceneIndex], "nodes");
        roots != nullptr && roots->IsArray()) {
      for (rapidjson::SizeType i = 0; i < roots->Size(); ++i) {
        if (!(*roots)[i].IsUint()) continue;
        if (!loader.addNode((*roots)[i].GetUint(), identity(), 0)) return false;
        walked = true;
      }
    }
  }
  if (!walked) {
    const auto *nodes = member(doc, "nodes");
    if (nodes == nullptr || !nodes->IsArray()) {
      error = "GLB has no nodes";
      return false;
    }
    std::vector<bool> isChild(nodes->Size(), false);
    for (rapidjson::SizeType i = 0; i < nodes->Size(); ++i) {
      if (const auto *ch = member((*nodes)[i], "children");
          ch != nullptr && ch->IsArray()) {
        for (rapidjson::SizeType c = 0; c < ch->Size(); ++c) {
          if ((*ch)[c].IsUint() && (*ch)[c].GetUint() < isChild.size()) {
            isChild[(*ch)[c].GetUint()] = true;
          }
        }
      }
    }
    for (rapidjson::SizeType i = 0; i < nodes->Size(); ++i) {
      if (!isChild[i] && !loader.addNode(i, identity(), 0)) return false;
    }
  }

  if (out.parts.empty()) {
    error = "GLB contained no triangle geometry";
    return false;
  }

  // Opaque geometry first, blended last. Every part writes depth, so glass drawn
  // before the bodywork behind it would cull that bodywork — looking through a
  // windscreen you would see straight out the other side of the car. Stable, so
  // authoring order is otherwise preserved.
  std::stable_partition(out.parts.begin(), out.parts.end(),
                        [](const MblMeshData::Part &p) { return !p.blended; });
  return true;
}
