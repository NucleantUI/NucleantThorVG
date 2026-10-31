//
//  VulkanRenderEngine+Thor+Wasm.swift
//  NucleantThorVG
//
//  The ThorVG side of the engine on WebAssembly — the browser mirror of the
//  Apple path in VulkanRenderEngine+Thor.swift. ThorVG's wg engine draws into
//  a `WgpuContext` target, and the node's VkImage is made over that texture
//  with no copy: `VkImportWebGPUTextureInfoNUCLEANT`
//  (VK_NUCLEANT_webgpu_objects) where Apple chains
//  `VkImportMetalTextureInfoEXT`. In the browser both are on the page's one
//  GPUDevice, so the texture ThorVG renders into *is* the image the
//  composite samples.
//
#if os(WASI)
import NucleantVulkan
import CVulkan
import CThorVG

extension VulkanRenderDevice {

    /// A self-contained ThorVG render target: a texture on the page's device,
    /// a `Tvg_Canvas` targeting it, and a `ThorShaderNode` whose VkImage is
    /// that texture. Callers append the returned node themselves. Pass
    /// `adopting` to target a caller-owned canvas at the new texture instead
    /// of creating one.
    public func makeThorWidgetNode(
        adopting canvasBase: Tvg_Canvas? = nil,
        width:  Int,
        height: Int
    ) -> ThorShaderNode<RenderNode>? {
        guard let wgpu = WgpuContext.shared else {
            print("VulkanRenderDevice: no WgpuContext — thor node unbuildable")
            return nil
        }
        guard let target = wgpu.makeTarget(width: width, height: height) else {
            print("VulkanRenderDevice: wgpu target creation failed")
            return nil
        }
        guard let canvas = canvasBase ?? tvg_wgcanvas_create(TVG_ENGINE_OPTION_DEFAULT) else {
            print("VulkanRenderDevice: tvg_wgcanvas_create failed")
            target.release()
            return nil
        }

        // Storage (compute post shader) support needs both sides to agree:
        // the target carries StorageBinding, and the image may carry STORAGE.
        let storageCapable = target.storageCapable && supportsBgraStorage(physicalDevice)

        guard let node = try? makeThorNode(
            canvas: canvas,
            importingWebGPUTexture: target.nativeWebGPUTexture(),
            width: width,
            height: height,
            storageCapable: storageCapable
        ) else {
            print("VulkanRenderDevice: makeThorNode(importingWebGPUTexture:) failed")
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
            print("VulkanRenderDevice: tvg_wgcanvas_set_target failed (\(result))")
            target.release()
            return nil
        }

        node.waitForExternalCompletion = { wgpu.waitForGPUCompletion() }
        // The node owns the target now — released after its VkImage is freed.
        node.releaseExternal = { target.release() }
        return node
    }

    /// The VkImage + view + memory over an existing texture (via
    /// VK_NUCLEANT_webgpu_objects) — no copy, the composite samples the very
    /// texture ThorVG drew into. Used by both node creation and in-place
    /// resize, like `makeImportedImage(mtlTexture:)` on Apple. The texture is
    /// BGRA8Unorm (`WgpuContext.targetPixelOrder`) at `width × height`.
    func makeImportedImage(
        webGPUTexture:  UnsafeMutableRawPointer,
        width:          Int,
        height:         Int,
        storageCapable: Bool = false
    ) throws -> (image: VkImage, view: VkImageView, memory: VkDeviceMemory?) {
        var importInfo = VkImportWebGPUTextureInfoNUCLEANT()
        importInfo.sType = VK_STRUCTURE_TYPE_IMPORT_WEBGPU_TEXTURE_INFO_NUCLEANT
        importInfo.texture = webGPUTexture

        var image: VkImage?
        let imageResult: VkResult = withUnsafePointer(to: &importInfo) { importPtr in
            var imageInfo = VkImageCreateInfo()
            imageInfo.sType         = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO
            imageInfo.pNext         = UnsafeRawPointer(importPtr)
            imageInfo.imageType     = VK_IMAGE_TYPE_2D
            imageInfo.format        = importedTextureFormat
            imageInfo.extent        = VkExtent3D(width: UInt32(width), height: UInt32(height), depth: 1)
            imageInfo.mipLevels     = 1
            imageInfo.arrayLayers   = 1
            imageInfo.samples       = VK_SAMPLE_COUNT_1_BIT
            imageInfo.tiling        = VK_IMAGE_TILING_OPTIMAL
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

        // Bound like any image; the texture is its storage.
        var requirements = VkMemoryRequirements()
        vkGetImageMemoryRequirements(device, image, &requirements)
        var memory: VkDeviceMemory?
        var allocInfo = VkMemoryAllocateInfo()
        allocInfo.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO
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
        viewInfo.format   = compositeSampleFormat
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

        // Content lives in the texture (or will, once ThorVG draws) — GENERAL,
        // never UNDEFINED, so nothing is told it may discard it.
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

        return (image, view, memory)
    }

    /// A `ThorShaderNode` whose VkImage is made over an existing texture
    /// rather than allocated, bound to `canvas`.
    func makeThorNode(
        canvas:                 Tvg_Canvas,
        importingWebGPUTexture texture: UnsafeMutableRawPointer,
        width:                  Int,
        height:                 Int,
        storageCapable:         Bool = false
    ) throws -> ThorShaderNode<RenderNode> {
        let created = try makeImportedImage(
            webGPUTexture:  texture,
            width:          width,
            height:         height,
            storageCapable: storageCapable
        )
        return ThorShaderNode(
            canvas:             ThorVulkanCanvas(base: canvas),
            width:              UInt32(width),
            height:             UInt32(height),
            image:              created.image,
            imageView:          created.view,
            memory:             created.memory,
            isExternallyBacked: true,
            storageCapable:     storageCapable
        )
    }

    /// Resize a ThorVG node **in place**: a new target and image at the new
    /// size, the node's own canvas pointed at it, and the new handles swapped
    /// into the same `ThorShaderNode` — see the Apple version for why the
    /// node keeps its identity. False leaves the node as it was.
    @discardableResult
    public func resizeThorNode(
        _ node: ThorShaderNode<RenderNode>,
        id:     Int,
        width:  Int,
        height: Int
    ) -> Bool {
        guard width > 0, height > 0,
              node.width != UInt32(width) || node.height != UInt32(height)
        else { return true }

        guard let wgpu = WgpuContext.shared else {
            print("VulkanRenderDevice: no WgpuContext — thor node unresizable")
            return false
        }
        guard let target = wgpu.makeTarget(width: width, height: height) else {
            print("VulkanRenderDevice: wgpu target creation failed (resize)")
            return false
        }

        let created: (image: VkImage, view: VkImageView, memory: VkDeviceMemory?)
        do {
            created = try makeImportedImage(
                webGPUTexture:  target.nativeWebGPUTexture(),
                width:          width,
                height:         height,
                storageCapable: node.storageCapable
            )
        } catch {
            print("VulkanRenderDevice: imported image (resize) failed: \(error)")
            target.release()
            return false
        }

        let result = tvg_wgcanvas_set_target(
            node.canvas.base,
            wgpu.devicePointer,
            wgpu.instancePointer,
            target.texturePointer,
            UInt32(width),
            UInt32(height),
            TVG_COLORSPACE_ABGR8888S,
            1
        )
        guard result == TVG_RESULT_SUCCESS else {
            print("VulkanRenderDevice: tvg_wgcanvas_set_target failed on resize (\(result))")
            // Nothing has used the new image but its layout barrier, which
            // `makeImportedImage` already waited for.
            vkDestroyImageView(device, created.view, nil)
            vkDestroyImage(device, created.image, nil)
            if let m = created.memory { vkFreeMemory(device, m, nil) }
            target.release()
            return false
        }

        let oldImage   = node.image
        let oldView    = node.imageView
        let oldMemory  = node.memory
        let oldRelease = node.releaseExternal

        node.image                     = created.image
        node.imageView                 = created.view
        node.memory                    = created.memory
        node.width                     = UInt32(width)
        node.height                    = UInt32(height)
        node.currentLayout             = VK_IMAGE_LAYOUT_GENERAL
        node.waitForExternalCompletion = { wgpu.waitForGPUCompletion() }
        node.releaseExternal           = { target.release() }
        node.dirty                     = true

        // Freed once the work that may still sample the old image is done.
        let device = device
        releaseAfterInFlightWork {
            vkDestroyImageView(device, oldView, nil)
            vkDestroyImage(device, oldImage, nil)
            if let oldMemory { vkFreeMemory(device, oldMemory, nil) }
            oldRelease?()
        }

        // The new image isn't in SHADER_READ_ONLY until the node's next draw.
        readable.remove(id)
        return true
    }
}

/// Whether BGRA8 images may be storage images on this device — the page's
/// WebGPU device has that with its BGRA8UnormStorage feature.
private func supportsBgraStorage(_ physicalDevice: VkPhysicalDevice) -> Bool {
    var props = VkFormatProperties()
    vkGetPhysicalDeviceFormatProperties(physicalDevice, VK_FORMAT_B8G8R8A8_UNORM, &props)
    return (props.optimalTilingFeatures & VkFormatFeatureFlags(VK_FORMAT_FEATURE_STORAGE_IMAGE_BIT.rawValue)) != 0
}
#endif
