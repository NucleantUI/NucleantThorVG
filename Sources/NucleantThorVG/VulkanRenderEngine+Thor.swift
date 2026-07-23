//
//  VulkanRenderEngine+Thor.swift
//  NucleantThorVG
//
//  The ThorVG side of the engine, mirroring NucleantSkia's extension: a
//  wgpu-backed render target ThorVG draws into, imported (zero-copy) as the
//  node's VkImage via VK_EXT_metal_objects. All ThorVG lives here so the
//  engine core stays ThorVG-free; all raw webgpu lives in the engine's
//  `WgpuContext`, which hands this file only opaque pointers — so this file
//  never imports CWgpu either.
//
#if os(macOS) || os(iOS)
import NucleantVulkan
import CVulkan
import CThorVG


extension VulkanRenderEngine {

    /// Build a whole self-contained ThorVG render target: a wgpu texture, a
    /// `Tvg_Canvas` targeting it, and a `ThorShaderNode` importing that
    /// texture's Metal memory as a VkImage — the zero-copy path. Callers
    /// append the returned node themselves. Pass `adopting` to target a
    /// caller-owned canvas at the new texture instead of creating one, so the
    /// canvas instance already handed to Python stays the one the node draws.
    public func makeThorWidgetNode(
        adopting canvasBase: Tvg_Canvas? = nil,
        width:  Int,
        height: Int
    ) -> ThorShaderNode<RenderNode>? {
        guard let wgpu = WgpuContext.shared else {
            print("VulkanRenderEngine: no WgpuContext — thor node unbuildable")
            return nil
        }
        guard let target = wgpu.makeTarget(width: width, height: height) else {
            print("VulkanRenderEngine: wgpu target creation failed")
            return nil
        }
        guard let mtlTexture = target.nativeMetalTexture() else {
            print("VulkanRenderEngine: wgpuTextureGetNativeMetalTexture returned null")
            target.release()
            return nil
        }
        guard let canvas = canvasBase ?? tvg_wgcanvas_create(TVG_ENGINE_OPTION_DEFAULT) else {
            print("VulkanRenderEngine: tvg_wgcanvas_create failed")
            target.release()
            return nil
        }

        // Storage (compute post shader) support needs both sides of the shared
        // texture to agree: wgpu created the MTLTexture with shaderWrite, and
        // MoltenVK exposes storage on linear BGRA8 so the import may carry
        // STORAGE usage.
        let storageCapable = target.storageCapable && supportsLinearBgraStorage(physicalDevice)

        guard let node = try? makeThorNode(
            canvas: canvas,
            importingMetalTexture: mtlTexture,
            width: width,
            height: height,
            storageCapable: storageCapable
        ) else {
            print("VulkanRenderEngine: makeThorNode(importingMetalTexture:) failed")
            target.release()
            return nil
        }

        let result = tvg_wgcanvas_set_target(
            canvas,
            wgpu.devicePointer,
            wgpu.instancePointer,
            target.texturePointer,
            UInt32(width),
            UInt32(height),
            TVG_COLORSPACE_ABGR8888S,
            1
        )
        guard result == TVG_RESULT_SUCCESS else {
            print("VulkanRenderEngine: tvg_wgcanvas_set_target failed (\(result))")
            target.release()
            return nil
        }

        // Same fire-and-forget caveat as any external writer: wgpuQueueSubmit
        // only proves ThorVG's blit was queued, not finished.
        node.waitForExternalCompletion = { wgpu.waitForGPUCompletion() }
        // The node owns the target now — released after its VkImage is freed.
        node.releaseExternal = { target.release() }
        return node
    }

    /// Create a `ThorShaderNode` whose VkImage is *imported* from an existing
    /// `id<MTLTexture>` (via VK_EXT_metal_objects) rather than allocated, so
    /// the composite pass reads the exact GPU memory ThorVG rendered into —
    /// no copy. `mtlTexture` is the raw `id<MTLTexture>` pointer, format
    /// BGRA8Unorm, matching `width`/`height`. `VkImportMetalTextureInfoEXT`
    /// has an Objective-C field that doesn't import into this plain-C target,
    /// so its 32-byte layout is laid out by hand: sType@0, pNext@8, plane@16,
    /// mtlTexture@24 — the same shape as `VkMetalSurfaceCreateInfoEXT`.
    func makeThorNode(
        canvas:               Tvg_Canvas,
        importingMetalTexture mtlTexture: UnsafeMutableRawPointer,
        width:                Int,
        height:               Int,
        storageCapable:       Bool = false
    ) throws -> ThorShaderNode<RenderNode> {
        let importInfo = UnsafeMutableRawPointer.allocate(byteCount: 32, alignment: MemoryLayout<UInt>.alignment)
        defer { importInfo.deallocate() }
        importInfo.initializeMemory(as: UInt8.self, repeating: 0, count: 32)
        importInfo.storeBytes(of: VK_STRUCTURE_TYPE_IMPORT_METAL_TEXTURE_INFO_EXT.rawValue, toByteOffset: 0, as: UInt32.self)
        importInfo.storeBytes(of: VK_IMAGE_ASPECT_COLOR_BIT.rawValue, toByteOffset: 16, as: UInt32.self)
        importInfo.storeBytes(of: UInt(bitPattern: mtlTexture), toByteOffset: 24, as: UInt.self)

        var externalMemoryInfo = VkExternalMemoryImageCreateInfo()
        externalMemoryInfo.sType = VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO
        externalMemoryInfo.pNext = UnsafeRawPointer(importInfo)
        externalMemoryInfo.handleTypes = VkExternalMemoryHandleTypeFlags(
            VK_EXTERNAL_MEMORY_HANDLE_TYPE_MTLTEXTURE_BIT_EXT.rawValue
        )

        var image: VkImage?
        let imageResult: VkResult = withUnsafePointer(to: &externalMemoryInfo) { extPtr in
            var imageInfo = VkImageCreateInfo()
            imageInfo.sType         = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO
            imageInfo.pNext         = UnsafeRawPointer(extPtr)
            imageInfo.imageType     = VK_IMAGE_TYPE_2D
            imageInfo.format        = VK_FORMAT_B8G8R8A8_UNORM
            imageInfo.extent        = VkExtent3D(width: UInt32(width), height: UInt32(height), depth: 1)
            imageInfo.mipLevels     = 1
            imageInfo.arrayLayers   = 1
            imageInfo.samples       = VK_SAMPLE_COUNT_1_BIT
            // LINEAR: an explicit byte layout both APIs agree on. OPTIMAL is
            // implementation-defined tiling MoltenVK owns and detiles — for an
            // imported Metal texture it doesn't own that layout.
            imageInfo.tiling        = VK_IMAGE_TILING_LINEAR
            var usage = VkImageUsageFlags(
                VK_IMAGE_USAGE_SAMPLED_BIT.rawValue |
                VK_IMAGE_USAGE_TRANSFER_SRC_BIT.rawValue |
                VK_IMAGE_USAGE_TRANSFER_DST_BIT.rawValue
            )
            if storageCapable {
                usage |= VkImageUsageFlags(VK_IMAGE_USAGE_STORAGE_BIT.rawValue)
            }
            imageInfo.usage         = usage
            imageInfo.sharingMode   = VK_SHARING_MODE_EXCLUSIVE
            imageInfo.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED
            return vkCreateImage(device, &imageInfo, nil, &image)
        }
        guard imageResult == VK_SUCCESS, let image else {
            throw VulkanEngineError.image
        }

        var requirements = VkMemoryRequirements()
        vkGetImageMemoryRequirements(device, image, &requirements)

        var memory: VkDeviceMemory?
        var allocInfo = VkMemoryAllocateInfo()
        allocInfo.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO
        allocInfo.pNext = UnsafeRawPointer(importInfo)
        allocInfo.allocationSize = requirements.size
        allocInfo.memoryTypeIndex = findMemoryType(
            typeFilter: requirements.memoryTypeBits,
            properties: VkMemoryPropertyFlags(VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT.rawValue)
        )
        guard vkAllocateMemory(device, &allocInfo, nil, &memory) == VK_SUCCESS else {
            vkDestroyImage(device, image, nil)
            throw VulkanEngineError.memory
        }
        vkBindImageMemory(device, image, memory, 0)

        var view: VkImageView?
        var viewInfo = VkImageViewCreateInfo()
        viewInfo.sType    = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO
        viewInfo.image    = image
        viewInfo.viewType = VK_IMAGE_VIEW_TYPE_2D
        viewInfo.format   = VK_FORMAT_B8G8R8A8_UNORM
        viewInfo.subresourceRange = VkImageSubresourceRange(
            aspectMask:     VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT.rawValue),
            baseMipLevel:   0, levelCount: 1,
            baseArrayLayer: 0, layerCount: 1
        )
        guard vkCreateImageView(device, &viewInfo, nil, &view) == VK_SUCCESS, let view else {
            vkFreeMemory(device, memory, nil)
            vkDestroyImage(device, image, nil)
            throw VulkanEngineError.image
        }

        // Content already lives in the imported texture (or will, once ThorVG
        // draws) — transition to GENERAL, never UNDEFINED, so the driver isn't
        // told it may discard it.
        oneTimeSubmit { cmd in
            engineImageBarrier(
                cmd,
                image:     image,
                srcLayout: VK_IMAGE_LAYOUT_UNDEFINED,
                srcAccess: 0,
                srcStage:  VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
                dstLayout: VK_IMAGE_LAYOUT_GENERAL,
                dstAccess: VkAccessFlags(VK_ACCESS_MEMORY_WRITE_BIT.rawValue) | VkAccessFlags(VK_ACCESS_MEMORY_READ_BIT.rawValue),
                dstStage:  VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT
            )
        }

        return ThorShaderNode(
            canvas:             ThorVulkanCanvas(base: canvas),
            width:              UInt32(width),
            height:             UInt32(height),
            image:              image,
            imageView:          view,
            memory:             memory,
            isExternallyBacked: true,
            storageCapable:     storageCapable
        )
    }
}


/// Whether MoltenVK exposes storage-image use on linear-tiled BGRA8 — the
/// exact image shape `makeThorNode(importingMetalTexture:)` creates. Gates
/// canvas post-shader support on the Vulkan side. Local to this file because
/// the engine core's equivalent is private.
private func supportsLinearBgraStorage(_ physicalDevice: VkPhysicalDevice) -> Bool {
    var props = VkFormatProperties()
    vkGetPhysicalDeviceFormatProperties(physicalDevice, VK_FORMAT_B8G8R8A8_UNORM, &props)
    return (props.linearTilingFeatures & VkFormatFeatureFlags(VK_FORMAT_FEATURE_STORAGE_IMAGE_BIT.rawValue)) != 0
}
#endif
