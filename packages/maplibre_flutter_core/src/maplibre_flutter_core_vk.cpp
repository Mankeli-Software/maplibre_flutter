// Implementation of the Windows Vulkan->D3D11 zero-copy presenter (see
// maplibre_flutter_core_vk.h). Compiled only on Windows (CMakeLists adds it to the shim
// sources under WIN32 and links d3d11/dxgi).
//
// Per ring slot we create a shared D3D11 texture (DXGI_FORMAT_B8G8R8A8_UNORM,
// D3D11_RESOURCE_MISC_SHARED -> a legacy/KMT shared handle via IDXGIResource::
// GetSharedHandle, which is what ANGLE's EGL_D3D_TEXTURE_2D_SHARE_HANDLE_ANGLE path
// consumes), then IMPORT that texture into Vulkan as an external-memory VkImage
// (VK_KHR_external_memory_win32, handle type eD3D11TextureKmt, dedicated allocation). To
// present we blit mbgl's just-rendered color image (R8G8B8A8 -> the BGRA dst; blitImage
// converts by logical channel so colours stay correct; Y flipped to match the CPU path)
// into the next slot via mbgl's Context::submitOneTimeCommand, which submits with a fence
// and WAITS for GPU completion before we publish the slot's shared handle (the analog of
// the GL path's glFinish). A ring of N slots keeps the producer from overwriting a slot
// the raster-thread consumer may still be sampling (there is no keyed mutex — ANGLE's
// legacy share-handle path never Acquire/Release-s one).
//
// The D3D11 device is pinned to the SAME adapter as mbgl's Vulkan device (matched by
// VkPhysicalDeviceIDProperties.deviceLUID -> IDXGIFactory4::EnumAdapterByLuid), so the
// shared handle is valid across the two devices and Flutter's own ANGLE device (default
// adapter; same GPU on a single-GPU box) can re-open it.
#include "maplibre_flutter_core_vk.h"

#if defined(_WIN32)

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif

// mbgl's Vulkan headers set up <vulkan/vulkan.hpp> with the dynamic dispatcher
// (VULKAN_HPP_DISPATCH_LOADER_DYNAMIC) + VK_USE_PLATFORM_WIN32_KHR (for the Win32
// external-memory structs) + VMA. Every vk:: call takes the backend's dispatcher.
#include <mbgl/vulkan/renderer_backend.hpp>
#include <mbgl/vulkan/context.hpp>
#include <mbgl/vulkan/renderable_resource.hpp>
#include <mbgl/gfx/renderer_backend.hpp>

#include <d3d11.h>
#include <dxgi1_4.h>

#include <cstdio>
#include <cstring>
#include <vector>

namespace {

constexpr uint32_t kRingSize = 3;
// Free a retired ring only after this many presents — once the producer has cycled past
// every slot the raster thread could still be sampling.
constexpr uint64_t kRetireAfterPresents = kRingSize;

struct Slot {
  ID3D11Texture2D *tex = nullptr; // shared D3D11 texture (BGRA8)
  HANDLE shared = nullptr;        // legacy DXGI shared handle (owned by `tex`)
  vk::Image image{};              // Vulkan view of the shared texture (imported)
  vk::DeviceMemory memory{};      // imported external memory backing `image`
};

struct RetiredRing {
  Slot slots[kRingSize];
  uint64_t destroyAfter = 0;
};

} // namespace

struct MblVkPresenter {
  // mbgl Vulkan backend (borrowed) + cached handles.
  mbgl::vulkan::RendererBackend *backend = nullptr;
  mbgl::gfx::RendererBackend *gfxBackend = nullptr;
  vk::Device device{};
  vk::PhysicalDevice physicalDevice{};
  int32_t graphicsQueueIndex = -1;

  // LUID-matched D3D11 device (owns the shared textures).
  IDXGIFactory4 *factory = nullptr;
  IDXGIAdapter1 *adapter = nullptr;
  ID3D11Device *d3dDevice = nullptr;
  ID3D11DeviceContext *d3dContext = nullptr;

  uint32_t width = 0;
  uint32_t height = 0;
  uint64_t generation = 0;
  uint64_t presentCount = 0;
  uint32_t nextSlot = 0;
  Slot ring[kRingSize];
  std::vector<RetiredRing> retired;

  // The exact dispatcher type is mbgl's alias (VULKAN_HPP_DISPATCH_LOADER_DYNAMIC_TYPE);
  // name it via that alias rather than vk::detail::... so it matches across vulkan.hpp
  // versions. Every vk:: call below takes this as its trailing dispatcher argument.
  const mbgl::vulkan::DispatchLoaderDynamic &disp() const {
    return backend->getDispatcher();
  }

  void destroySlot(Slot &s) {
    if (s.image) {
      device.destroyImage(s.image, nullptr, disp());
      s.image = vk::Image{};
    }
    if (s.memory) {
      device.freeMemory(s.memory, nullptr, disp());
      s.memory = vk::DeviceMemory{};
    }
    if (s.tex != nullptr) {
      s.tex->Release();
      s.tex = nullptr;
    }
    s.shared = nullptr; // owned by tex; freed with it
  }
};

namespace {

// Picks a memory type that is both allowed for the imported handle (handleProps) and
// valid for the image (memReq), preferring device-local. Returns UINT32_MAX on none.
uint32_t pickMemoryType(const MblVkPresenter *p, uint32_t typeBits) {
  const auto memProps = p->physicalDevice.getMemoryProperties(p->disp());
  for (uint32_t i = 0; i < memProps.memoryTypeCount; ++i) {
    if ((typeBits & (1u << i)) &&
        (memProps.memoryTypes[i].propertyFlags &
         vk::MemoryPropertyFlagBits::eDeviceLocal)) {
      return i;
    }
  }
  for (uint32_t i = 0; i < memProps.memoryTypeCount; ++i) {
    if (typeBits & (1u << i)) {
      return i;
    }
  }
  return UINT32_MAX;
}

// Allocates one ring slot: a shared D3D11 BGRA texture, its legacy DXGI shared handle,
// and a Vulkan image importing that texture's memory. Returns false on failure.
bool buildSlot(MblVkPresenter *p, Slot &s, uint32_t w, uint32_t h) {
  // 1. Shared D3D11 texture (BGRA8 — ANGLE's share-handle path only accepts B8G8R8A8).
  D3D11_TEXTURE2D_DESC desc = {};
  desc.Width = w;
  desc.Height = h;
  desc.MipLevels = 1;
  desc.ArraySize = 1;
  desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
  desc.SampleDesc.Count = 1;
  desc.SampleDesc.Quality = 0;
  desc.Usage = D3D11_USAGE_DEFAULT;
  desc.BindFlags = D3D11_BIND_SHADER_RESOURCE | D3D11_BIND_RENDER_TARGET;
  desc.CPUAccessFlags = 0;
  desc.MiscFlags = D3D11_RESOURCE_MISC_SHARED; // legacy/KMT shared handle
  if (FAILED(p->d3dDevice->CreateTexture2D(&desc, nullptr, &s.tex)) ||
      s.tex == nullptr) {
    return false;
  }

  IDXGIResource *res = nullptr;
  if (FAILED(s.tex->QueryInterface(__uuidof(IDXGIResource),
                                   reinterpret_cast<void **>(&res))) ||
      res == nullptr) {
    return false;
  }
  HRESULT hr = res->GetSharedHandle(&s.shared);
  res->Release();
  if (FAILED(hr) || s.shared == nullptr) {
    return false;
  }

  // 2. Import the D3D11 texture into Vulkan as a dedicated, OPTIMAL, BGRA8 image.
  try {
    vk::ExternalMemoryImageCreateInfo extImg;
    extImg.handleTypes = vk::ExternalMemoryHandleTypeFlagBits::eD3D11TextureKmt;

    vk::ImageCreateInfo ici;
    ici.pNext = &extImg;
    ici.imageType = vk::ImageType::e2D;
    ici.format = vk::Format::eB8G8R8A8Unorm;
    ici.extent = vk::Extent3D(w, h, 1);
    ici.mipLevels = 1;
    ici.arrayLayers = 1;
    ici.samples = vk::SampleCountFlagBits::e1;
    ici.tiling = vk::ImageTiling::eOptimal; // D3D11 owns the tiling; never LINEAR
    ici.usage = vk::ImageUsageFlagBits::eTransferDst;
    ici.sharingMode = vk::SharingMode::eExclusive;
    ici.initialLayout = vk::ImageLayout::eUndefined;
    s.image = p->device.createImage(ici, nullptr, p->disp());

    const vk::MemoryRequirements memReq =
        p->device.getImageMemoryRequirements(s.image, p->disp());
    const vk::MemoryWin32HandlePropertiesKHR handleProps =
        p->device.getMemoryWin32HandlePropertiesKHR(
            vk::ExternalMemoryHandleTypeFlagBits::eD3D11TextureKmt, s.shared,
            p->disp());
    const uint32_t typeBits =
        memReq.memoryTypeBits & handleProps.memoryTypeBits;
    const uint32_t memTypeIndex = pickMemoryType(p, typeBits);
    if (memTypeIndex == UINT32_MAX) {
      // No memory type can back the imported handle. The common cause is a GPU/driver
      // that does not support importing the LEGACY D3D11 shared handle that Flutter's
      // ANGLE consumer requires (VK_EXTERNAL_MEMORY_HANDLE_TYPE_D3D11_TEXTURE_KMT_BIT) —
      // e.g. Intel iGPUs, which only expose the NT-handle import. Fall back to the CPU
      // present path. Discrete NVIDIA/AMD GPUs typically do support the legacy import.
      fprintf(stderr,
              "maplibre_flutter_core: Vulkan cannot import the D3D11 legacy shared "
              "handle on this GPU (memReqBits=0x%x handleBits=0x%x); using CPU "
              "readback.\n",
              memReq.memoryTypeBits, handleProps.memoryTypeBits);
      return false;
    }

    // Dedicated allocation is required for imported D3D11 textures.
    vk::MemoryDedicatedAllocateInfo dedicated;
    dedicated.image = s.image;
    vk::ImportMemoryWin32HandleInfoKHR importInfo;
    importInfo.pNext = &dedicated;
    importInfo.handleType =
        vk::ExternalMemoryHandleTypeFlagBits::eD3D11TextureKmt;
    importInfo.handle = s.shared; // MUST be the KMT handle; name stays null
    vk::MemoryAllocateInfo allocInfo;
    allocInfo.pNext = &importInfo;
    allocInfo.allocationSize = memReq.size;
    allocInfo.memoryTypeIndex = memTypeIndex;
    s.memory = p->device.allocateMemory(allocInfo, nullptr, p->disp());
    p->device.bindImageMemory(s.image, s.memory, 0, p->disp());
  } catch (const std::exception &e) {
    fprintf(stderr,
            "maplibre_flutter_core: Vulkan import of D3D11 texture failed: %s\n",
            e.what());
    return false;
  } catch (...) {
    fprintf(stderr,
            "maplibre_flutter_core: Vulkan import of D3D11 texture failed.\n");
    return false;
  }
  return true;
}

void reapRetired(MblVkPresenter *p) {
  for (auto it = p->retired.begin(); it != p->retired.end();) {
    if (p->presentCount >= it->destroyAfter) {
      for (auto &s : it->slots) {
        p->destroySlot(s);
      }
      it = p->retired.erase(it);
    } else {
      ++it;
    }
  }
}

} // namespace

extern "C" {

MblVkPresenter *mbl_vk_presenter_create(void *backend) {
  if (backend == nullptr) {
    return nullptr;
  }
  auto *gfxBackend = static_cast<mbgl::gfx::RendererBackend *>(backend);
  auto *vkBackend = static_cast<mbgl::vulkan::RendererBackend *>(gfxBackend);

  try {
    const auto &disp = vkBackend->getDispatcher();
    const vk::PhysicalDevice physicalDevice = vkBackend->getPhysicalDevice();

    // Query the device LUID (needs VK_KHR_get_physical_device_properties2 at the
    // 1.0 instance — enabled by the windows-vulkan-external-memory mbgl patch).
    vk::PhysicalDeviceIDProperties idProps;
    vk::PhysicalDeviceProperties2 props2;
    props2.pNext = &idProps;
    physicalDevice.getProperties2KHR(&props2, disp);
    if (!idProps.deviceLUIDValid) {
      fprintf(stderr, "maplibre_flutter_core: Vulkan device LUID invalid; no D3D "
                      "zero-copy, using CPU readback.\n");
      return nullptr;
    }

    IDXGIFactory4 *factory = nullptr;
    if (FAILED(CreateDXGIFactory1(__uuidof(IDXGIFactory4),
                                  reinterpret_cast<void **>(&factory)))) {
      return nullptr;
    }
    LUID luid;
    static_assert(sizeof(luid) == VK_LUID_SIZE, "LUID size mismatch");
    std::memcpy(&luid, idProps.deviceLUID.data(), VK_LUID_SIZE);

    IDXGIAdapter1 *adapter = nullptr;
    if (FAILED(factory->EnumAdapterByLuid(
            luid, __uuidof(IDXGIAdapter1),
            reinterpret_cast<void **>(&adapter))) ||
        adapter == nullptr) {
      factory->Release();
      fprintf(stderr, "maplibre_flutter_core: no DXGI adapter matching the Vulkan "
                      "LUID; using CPU readback.\n");
      return nullptr;
    }

    ID3D11Device *d3dDevice = nullptr;
    ID3D11DeviceContext *d3dContext = nullptr;
    // D3D_DRIVER_TYPE_UNKNOWN is required when an explicit adapter is supplied.
    HRESULT hr = D3D11CreateDevice(adapter, D3D_DRIVER_TYPE_UNKNOWN, nullptr, 0,
                                   nullptr, 0, D3D11_SDK_VERSION, &d3dDevice,
                                   nullptr, &d3dContext);
    if (FAILED(hr) || d3dDevice == nullptr) {
      adapter->Release();
      factory->Release();
      fprintf(stderr, "maplibre_flutter_core: D3D11CreateDevice on the Vulkan "
                      "adapter failed; using CPU readback.\n");
      return nullptr;
    }

    auto *p = new MblVkPresenter();
    p->backend = vkBackend;
    p->gfxBackend = gfxBackend;
    p->device = vkBackend->getDevice().get();
    p->physicalDevice = physicalDevice;
    p->graphicsQueueIndex = vkBackend->getGraphicsQueueIndex();
    p->factory = factory;
    p->adapter = adapter;
    p->d3dDevice = d3dDevice;
    p->d3dContext = d3dContext;
    return p;
  } catch (const std::exception &e) {
    fprintf(stderr, "maplibre_flutter_core: Vulkan zero-copy create failed: %s\n",
            e.what());
    return nullptr;
  } catch (...) {
    fprintf(stderr, "maplibre_flutter_core: Vulkan zero-copy create failed.\n");
    return nullptr;
  }
}

int mbl_vk_presenter_resize(MblVkPresenter *p, uint32_t width, uint32_t height) {
  if (p == nullptr || width == 0 || height == 0) {
    return 0;
  }
  if (width == p->width && height == p->height && p->ring[0].tex != nullptr) {
    return 1; // unchanged
  }

  // Retire the current ring (the raster thread may still be sampling a slot).
  if (p->ring[0].tex != nullptr) {
    RetiredRing r;
    for (uint32_t i = 0; i < kRingSize; ++i) {
      r.slots[i] = p->ring[i];
      p->ring[i] = Slot{};
    }
    r.destroyAfter = p->presentCount + kRetireAfterPresents;
    p->retired.push_back(r);
  }

  bool ok = true;
  for (uint32_t i = 0; i < kRingSize && ok; ++i) {
    ok = buildSlot(p, p->ring[i], width, height);
  }
  if (!ok) {
    for (uint32_t i = 0; i < kRingSize; ++i) {
      p->destroySlot(p->ring[i]);
    }
    return 0;
  }

  p->width = width;
  p->height = height;
  p->nextSlot = 0;
  ++p->generation;
  return 1;
}

int mbl_vk_presenter_present(MblVkPresenter *p, void **out_handle) {
  if (p == nullptr || out_handle == nullptr || p->ring[0].tex == nullptr) {
    return 0;
  }
  try {
    // mbgl's just-rendered color image. For the headless backend this is left in
    // TRANSFER_SRC_OPTIMAL after render (and the frame is GPU-complete — the headless
    // swap() already waited on the frame fence), so no source barrier is needed.
    auto &res = p->gfxBackend->getDefaultRenderable()
                    .getResource<mbgl::vulkan::SurfaceRenderableResource>();
    const vk::Image src = res.getAcquiredImage();
    if (!src) {
      return 0;
    }
    auto &ctx = p->backend->getContext<mbgl::vulkan::Context>();
    Slot &slot = p->ring[p->nextSlot];
    const auto &disp = p->disp();
    const uint32_t w = p->width;
    const uint32_t h = p->height;
    const int32_t gfxQ = p->graphicsQueueIndex;

    ctx.submitOneTimeCommand([&](const vk::UniqueCommandBuffer &cb) {
      const vk::ImageSubresourceRange range(vk::ImageAspectFlagBits::eColor, 0, 1,
                                            0, 1);
      // dst: UNDEFINED -> TRANSFER_DST_OPTIMAL (discard previous contents/owner —
      // we overwrite the whole image, so no acquire from the external queue needed).
      vk::ImageMemoryBarrier toDst;
      toDst.srcAccessMask = {};
      toDst.dstAccessMask = vk::AccessFlagBits::eTransferWrite;
      toDst.oldLayout = vk::ImageLayout::eUndefined;
      toDst.newLayout = vk::ImageLayout::eTransferDstOptimal;
      toDst.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
      toDst.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
      toDst.image = slot.image;
      toDst.subresourceRange = range;
      cb->pipelineBarrier(vk::PipelineStageFlagBits::eTopOfPipe,
                          vk::PipelineStageFlagBits::eTransfer, {}, nullptr,
                          nullptr, toDst, disp);

      // Blit mbgl's R8G8B8A8 frame into the BGRA8 dst. blitImage converts by logical
      // channel (R->R, G->G, B->B) so colours stay correct; Y is flipped to match the
      // CPU path's top-down image.
      vk::ImageBlit blit;
      blit.srcSubresource =
          vk::ImageSubresourceLayers(vk::ImageAspectFlagBits::eColor, 0, 0, 1);
      blit.srcOffsets[0] = vk::Offset3D(0, 0, 0);
      blit.srcOffsets[1] =
          vk::Offset3D(static_cast<int32_t>(w), static_cast<int32_t>(h), 1);
      blit.dstSubresource =
          vk::ImageSubresourceLayers(vk::ImageAspectFlagBits::eColor, 0, 0, 1);
      blit.dstOffsets[0] = vk::Offset3D(0, static_cast<int32_t>(h), 0);
      blit.dstOffsets[1] = vk::Offset3D(static_cast<int32_t>(w), 0, 1);
      cb->blitImage(src, vk::ImageLayout::eTransferSrcOptimal, slot.image,
                    vk::ImageLayout::eTransferDstOptimal, blit,
                    vk::Filter::eNearest, disp);

      // dst: release to the external (D3D) consumer.
      vk::ImageMemoryBarrier toExternal;
      toExternal.srcAccessMask = vk::AccessFlagBits::eTransferWrite;
      toExternal.dstAccessMask = {};
      toExternal.oldLayout = vk::ImageLayout::eTransferDstOptimal;
      toExternal.newLayout = vk::ImageLayout::eGeneral;
      toExternal.srcQueueFamilyIndex = static_cast<uint32_t>(gfxQ);
      toExternal.dstQueueFamilyIndex = VK_QUEUE_FAMILY_EXTERNAL;
      toExternal.image = slot.image;
      toExternal.subresourceRange = range;
      cb->pipelineBarrier(vk::PipelineStageFlagBits::eTransfer,
                          vk::PipelineStageFlagBits::eBottomOfPipe, {}, nullptr,
                          nullptr, toExternal, disp);
    });
    // submitOneTimeCommand waited on the fence -> the blit is GPU-complete; publish.

    *out_handle = slot.shared;
    p->nextSlot = (p->nextSlot + 1) % kRingSize;
    ++p->presentCount;
    reapRetired(p);
    return 1;
  } catch (const std::exception &e) {
    fprintf(stderr, "maplibre_flutter_core: Vulkan zero-copy present failed: %s\n",
            e.what());
    return 0;
  } catch (...) {
    fprintf(stderr, "maplibre_flutter_core: Vulkan zero-copy present failed.\n");
    return 0;
  }
}

void mbl_vk_presenter_destroy(MblVkPresenter *p) {
  if (p == nullptr) {
    return;
  }
  if (p->device) {
    p->device.waitIdle(p->disp());
  }
  for (auto &r : p->retired) {
    for (auto &s : r.slots) {
      p->destroySlot(s);
    }
  }
  for (uint32_t i = 0; i < kRingSize; ++i) {
    p->destroySlot(p->ring[i]);
  }
  if (p->d3dContext != nullptr) {
    p->d3dContext->Release();
  }
  if (p->d3dDevice != nullptr) {
    p->d3dDevice->Release();
  }
  if (p->adapter != nullptr) {
    p->adapter->Release();
  }
  if (p->factory != nullptr) {
    p->factory->Release();
  }
  delete p;
}

} // extern "C"

#endif // _WIN32
