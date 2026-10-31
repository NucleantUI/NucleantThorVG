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


extension VulkanRenderDevice {

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
            print("VulkanRenderDevice: no WgpuContext — thor node unbuildable")
            return nil
        }
        guard let target = wgpu.makeTarget(width: width, height: height) else {
            print("VulkanRenderDevice: wgpu target creation failed")
            return nil
        }
        guard let mtlTexture = target.nativeMetalTexture() else {
            print("VulkanRenderDevice: wgpuTextureGetNativeMetalTexture returned null")
            target.release()
            return nil
        }
        guard let canvas = canvasBase ?? tvg_wgcanvas_create(TVG_ENGINE_OPTION_DEFAULT) else {
            print("VulkanRenderDevice: tvg_wgcanvas_create failed")
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
            print("VulkanRenderDevice: makeThorNode(importingMetalTexture:) failed")
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

        // Same fire-and-forget caveat as any external writer: wgpuQueueSubmit
        // only proves ThorVG's blit was queued, not finished.
        node.waitForExternalCompletion = { wgpu.waitForGPUCompletion() }
        // The node owns the target now — released after its VkImage is freed.
        node.releaseExternal = { target.release() }
        return node
    }

    /// Just the imported VkImage + view + memory from an existing
    /// `id<MTLTexture>` (via VK_EXT_metal_objects) — no copy, the composite
    /// samples the exact GPU memory ThorVG drew into. Extracted so both node
    /// creation (`makeThorNode`) and in-place resize (`resizeThorNode`) mint
    /// the image the same way. `mtlTexture` is the raw `id<MTLTexture>`
    /// pointer, format BGRA8Unorm, matching `width`/`height`.
    /// `VkImportMetalTextureInfoEXT` has an Objective-C field that doesn't
    /// import into this plain-C target, so its 32-byte layout is laid out by
    /// hand: sType@0, pNext@8, plane@16, mtlTexture@24 — the same shape as
    /// `VkMetalSurfaceCreateInfoEXT`.
    func makeImportedImage(
        mtlTexture:     UnsafeMutableRawPointer,
        width:          Int,
        height:         Int,
        storageCapable: Bool = false
    ) throws -> (image: VkImage, view: VkImageView, memory: VkDeviceMemory?) {
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
            imageInfo.format        = importedTextureFormat
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

        return (image, view, memory)
    }

    /// Create a `ThorShaderNode` whose VkImage is *imported* from an existing
    /// `id<MTLTexture>` (via VK_EXT_metal_objects) rather than allocated. The
    /// image itself is minted by `makeImportedImage`; this wraps it in a node
    /// bound to `canvas`.
    func makeThorNode(
        canvas:               Tvg_Canvas,
        importingMetalTexture mtlTexture: UnsafeMutableRawPointer,
        width:                Int,
        height:               Int,
        storageCapable:       Bool = false
    ) throws -> ThorShaderNode<RenderNode> {
        let created = try makeImportedImage(
            mtlTexture:     mtlTexture,
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

    /// Resize an existing ThorVG node **in place**: mint a new wgpu target +
    /// imported VkImage at the new size, point the node's own ThorVG canvas at
    /// it, and swap the new GPU handles into the *same* `ThorShaderNode`. The
    /// node keeps its identity — its id, its composite slot, its z-order, its
    /// Observation registration — so nothing above needs rebinding; only the
    /// backing image changes. A resize must not remake the node (that's for
    /// widget add/remove or a canvas swap). The old image/view/memory and wgpu
    /// target are freed once the work in flight is done with them
    /// (`releaseAfterInFlightWork`). Returns false — node untouched, still at
    /// the old size — on any failure, so the widget stays visible instead of
    /// going dark.
    ///
    /// `id` is the node's composite slot id: it is unpublished until the
    /// node's next draw leaves the new image readable, and every window's
    /// composite set rebuilds from the new view on its own.
    @discardableResult
    public func resizeThorNode(
        _ node: ThorShaderNode<RenderNode>,
        id:     Int,
        width:  Int,
        height: Int
    ) -> Bool {
        guard width > 0, height > 0,
              node.width != UInt32(width) || node.height != UInt32(height)
        else { return true }   // already that size — nothing to do

        guard let wgpu = WgpuContext.shared else {
            print("VulkanRenderDevice: no WgpuContext — thor node unresizable")
            return false
        }
        guard let target = wgpu.makeTarget(width: width, height: height) else {
            print("VulkanRenderDevice: wgpu target creation failed (resize)")
            return false
        }
        guard let mtlTexture = target.nativeMetalTexture() else {
            print("VulkanRenderDevice: wgpuTextureGetNativeMetalTexture returned null (resize)")
            target.release()
            return false
        }

        // New image at the new size — built before the old one is touched, so a
        // failure here leaves the node drawing at the old size. Keep the node's
        // fixed storage capability so the post shader's assumptions still hold.
        let created: (image: VkImage, view: VkImageView, memory: VkDeviceMemory?)
        do {
            created = try makeImportedImage(
                mtlTexture:     mtlTexture,
                width:          width,
                height:         height,
                storageCapable: node.storageCapable
            )
        } catch {
            print("VulkanRenderDevice: imported image (resize) failed: \(error)")
            target.release()
            return false
        }

        // Point the node's own ThorVG canvas at the new target — same
        // `Tvg_Canvas`, so its paints and any Python-held capsules stay valid.
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

        // Hold the old handles: a frame still in flight may be sampling them.
        let oldImage   = node.image
        let oldView    = node.imageView
        let oldMemory  = node.memory
        let oldRelease = node.releaseExternal

        // Swap the new backing into the existing node.
        node.image                     = created.image
        node.imageView                 = created.view
        node.memory                    = created.memory
        node.width                     = UInt32(width)
        node.height                    = UInt32(height)
        // Imported image starts life in GENERAL (makeImportedImage's barrier).
        node.currentLayout             = VK_IMAGE_LAYOUT_GENERAL
        node.waitForExternalCompletion = { wgpu.waitForGPUCompletion() }
        node.releaseExternal           = { target.release() }
        node.dirty                     = true

        // Old backing + its wgpu target: freed once the work that may still
        // sample it, in any window, is done, without stalling on the whole
        // device going idle. ThorVG's last write into it was already waited
        // for (the node's `waitForExternalCompletion`). Retarget-then-release
        // order, same as node teardown.
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


/// Whether MoltenVK exposes storage-image use on linear-tiled BGRA8 — the
/// exact image shape `makeThorNode(importingMetalTexture:)` creates. Gates
/// canvas post-shader support on the Vulkan side. Local to this file because
/// the engine core's equivalent is private.
private func supportsLinearBgraStorage(_ physicalDevice: VkPhysicalDevice) -> Bool {
    var props = VkFormatProperties()
    vkGetPhysicalDeviceFormatProperties(physicalDevice, VK_FORMAT_B8G8R8A8_UNORM, &props)
    return (props.linearTilingFeatures & VkFormatFeatureFlags(VK_FORMAT_FEATURE_STORAGE_IMAGE_BIT.rawValue)) != 0
}
#elseif os(Linux) || os(Android) || os(Windows)
import NucleantVulkan
import CVulkan
import CThorVG
#if os(Windows)
import WinSDK
#endif

extension VulkanRenderDevice {

    /// Linux/Android mirror of the Apple `makeThorWidgetNode(adopting:width:height:)`
    /// above: a wgpu texture, a `Tvg_Canvas` targeting it, and a
    /// `ThorShaderNode` importing that texture's memory as a VkImage — zero
    /// copy, via `VK_KHR_external_memory_fd` instead of `VK_EXT_metal_objects`.
    /// Windows is the same with an NT handle (`VK_KHR_external_memory_win32`)
    /// in place of the fd.
    /// Android shares this path by default rather than importing an
    /// AHardwareBuffer: both go through wgpu's Vulkan backend, so both export
    /// the same fd. The AHardwareBuffer path exists as an opt-in build only
    /// (`NUCLEANT_ANDROID_USE_AHARDWAREBUFFER` in Package.swift) for cases the
    /// fd path can't cover — e.g. an emulator whose virtualized Vulkan driver
    /// doesn't expose VK_KHR_external_memory_fd. No storage-capable (canvas
    /// post shader) support yet on either path — see the comment on
    /// `WgpuContext.Target.exportedFd`.
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
        #if os(Android) && NUCLEANT_ANDROID_USE_AHARDWAREBUFFER
        guard let hardwareBuffer = target.nativeAndroidHardwareBuffer() else {
            print("VulkanRenderDevice: wgpu target has no AHardwareBuffer — device may lack "
                  + "VK_ANDROID_external_memory_android_hardware_buffer")
            target.release()
            return nil
        }
        #elseif os(Windows)
        guard let handle = target.nativeVulkanExportedWin32Handle() else {
            print("VulkanRenderDevice: wgpu target has no exported handle — driver may lack "
                  + "VK_KHR_external_memory_win32")
            target.release()
            return nil
        }
        #else
        guard let fd = target.nativeVulkanExportedFd() else {
            print("VulkanRenderDevice: wgpu target has no exported fd — driver may lack VK_KHR_external_memory_fd")
            target.release()
            return nil
        }
        #endif
        guard let canvas = canvasBase ?? tvg_wgcanvas_create(TVG_ENGINE_OPTION_DEFAULT) else {
            print("VulkanRenderDevice: tvg_wgcanvas_create failed")
            target.release()
            return nil
        }

        // Re-adopting an existing canvas (Android minimize/resume rebuilding
        // the whole engine, retargeting the same Tvg_Canvas onto a fresh
        // wgpu target): tvg_wgcanvas_set_target below refuses with
        // TVG_RESULT_INSUFFICIENT_CONDITION unless the canvas's internal
        // status is Synced — draw()/sync() every frame should already leave
        // it there, but sync() unconditionally drives status back to Synced
        // regardless of what it actually is (tvgCanvas.h's Impl::sync), so
        // forcing it here is the correct, cheap way to guarantee the
        // precondition rather than trust an inference about render-thread
        // shutdown timing. A no-op on the freshly-created (canvasBase == nil)
        // path, since a brand new canvas already starts Synced.
        if canvasBase != nil {
            _ = tvg_canvas_sync(canvas)
        }

        #if os(Android) && NUCLEANT_ANDROID_USE_AHARDWAREBUFFER
        let built = try? makeThorNode(
            canvas: canvas,
            importingHardwareBuffer: hardwareBuffer,
            width: width,
            height: height
        )
        #elseif os(Windows)
        let built = try? makeThorNode(
            canvas: canvas,
            importingWin32Handle: handle,
            width: width,
            height: height
        )
        #else
        let built = try? makeThorNode(
            canvas: canvas,
            importingFd: fd,
            width: width,
            height: height
        )
        #endif
        guard let node = built else {
            print("VulkanRenderDevice: importing thor node failed")
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
        node.releaseExternal = { target.release() }
        return node
    }

    #if os(Android) && NUCLEANT_ANDROID_USE_AHARDWAREBUFFER
    /// The Android counterpart of `makeImportedImage(fd:)`, opt-in build only
    /// (see `ANDROID_USE_AHARDWAREBUFFER` in Package.swift).
    ///
    /// Two things differ from the fd path beyond the handle type. The
    /// allocation size and permitted memory types come from
    /// `vkGetAndroidHardwareBufferPropertiesANDROID` rather than the image's
    /// own requirements — the buffer already exists and dictates both. And the
    /// entry point is resolved through `vkGetDeviceProcAddr`: it is an
    /// extension function, absent unless the device enabled
    /// VK_ANDROID_external_memory_android_hardware_buffer.
    ///
    /// The caller keeps its AHardwareBuffer reference; importing does not
    /// consume it, unlike an fd.
    func makeImportedImage(
        hardwareBuffer: UnsafeMutableRawPointer,
        width:  Int,
        height: Int
    ) throws -> (image: VkImage, view: VkImageView, memory: VkDeviceMemory?) {
        typealias GetPropsFn = @convention(c) (
            VkDevice?, UnsafeRawPointer?,
            UnsafeMutablePointer<VkAndroidHardwareBufferPropertiesANDROID>?
        ) -> VkResult

        guard let symbol = vkGetDeviceProcAddr(device, "vkGetAndroidHardwareBufferPropertiesANDROID")
        else {
            throw VulkanEngineError.memory
        }
        let getProperties = unsafeBitCast(symbol, to: GetPropsFn.self)

        var properties = VkAndroidHardwareBufferPropertiesANDROID()
        properties.sType = VK_STRUCTURE_TYPE_ANDROID_HARDWARE_BUFFER_PROPERTIES_ANDROID
        guard getProperties(device, UnsafeRawPointer(hardwareBuffer), &properties) == VK_SUCCESS
        else {
            throw VulkanEngineError.memory
        }

        // Same creation parameters as the exporting image, as the spec
        // requires — matching what the wgpu side built.
        var externalMemoryInfo = VkExternalMemoryImageCreateInfo()
        externalMemoryInfo.sType = VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO
        externalMemoryInfo.handleTypes = VkExternalMemoryHandleTypeFlags(
            VK_EXTERNAL_MEMORY_HANDLE_TYPE_ANDROID_HARDWARE_BUFFER_BIT_ANDROID.rawValue
        )

        var image: VkImage?
        let imageResult: VkResult = withUnsafePointer(to: &externalMemoryInfo) { extPtr in
            var imageInfo = VkImageCreateInfo()
            imageInfo.sType         = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO
            imageInfo.pNext         = UnsafeRawPointer(extPtr)
            imageInfo.imageType     = VK_IMAGE_TYPE_2D
            imageInfo.format        = importedTextureFormat
            imageInfo.extent        = VkExtent3D(width: UInt32(width), height: UInt32(height), depth: 1)
            imageInfo.mipLevels     = 1
            imageInfo.arrayLayers   = 1
            imageInfo.samples       = VK_SAMPLE_COUNT_1_BIT
            imageInfo.tiling        = VK_IMAGE_TILING_OPTIMAL
            // SAMPLED only: this image is never a copy source/dest, only
            // sampled during compositing. Adding Transfer{Src,Dst} would ask
            // for more than wgpu's own export granted the underlying
            // AHardwareBuffer (GPU_SAMPLED_IMAGE | GPU_COLOR_OUTPUT, no CPU_*
            // bits — see makeTarget's matching comment in WgpuContext.swift),
            // which is exactly what pushes the buffer onto a slow
            // CPU-visible path on some drivers.
            imageInfo.usage         = VkImageUsageFlags(
                VK_IMAGE_USAGE_SAMPLED_BIT.rawValue
            )
            imageInfo.sharingMode   = VK_SHARING_MODE_EXCLUSIVE
            imageInfo.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED
            return vkCreateImage(device, &imageInfo, nil, &image)
        }
        guard imageResult == VK_SUCCESS, let image else {
            throw VulkanEngineError.image
        }

        let dedicatedInfo = UnsafeMutablePointer<VkMemoryDedicatedAllocateInfo>.allocate(capacity: 1)
        defer { dedicatedInfo.deallocate() }
        dedicatedInfo.pointee = VkMemoryDedicatedAllocateInfo()
        dedicatedInfo.pointee.sType = VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO
        dedicatedInfo.pointee.image = image

        let importInfo = UnsafeMutablePointer<VkImportAndroidHardwareBufferInfoANDROID>.allocate(capacity: 1)
        defer { importInfo.deallocate() }
        importInfo.pointee = VkImportAndroidHardwareBufferInfoANDROID()
        importInfo.pointee.sType = VK_STRUCTURE_TYPE_IMPORT_ANDROID_HARDWARE_BUFFER_INFO_ANDROID
        importInfo.pointee.pNext = UnsafeRawPointer(dedicatedInfo)
        importInfo.pointee.buffer = OpaquePointer(hardwareBuffer)

        var memory: VkDeviceMemory?
        var allocInfo = VkMemoryAllocateInfo()
        allocInfo.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO
        allocInfo.pNext = UnsafeRawPointer(importInfo)
        // From the buffer, not the image: the allocation already exists.
        allocInfo.allocationSize = properties.allocationSize
        allocInfo.memoryTypeIndex = findMemoryType(
            typeFilter: properties.memoryTypeBits,
            properties: VkMemoryPropertyFlags(VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT.rawValue)
        )
        guard vkAllocateMemory(device, &allocInfo, nil, &memory) == VK_SUCCESS, let memory else {
            vkDestroyImage(device, image, nil)
            throw VulkanEngineError.memory
        }
        vkBindImageMemory(device, image, memory, 0)

        var view: VkImageView?
        var viewInfo = VkImageViewCreateInfo()
        viewInfo.sType    = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO
        viewInfo.image    = image
        viewInfo.viewType = VK_IMAGE_VIEW_TYPE_2D
        // Same format the image was actually created with (importedTextureFormat,
        // RGBA — see WgpuContext.targetPixelOrder's Android/AHardwareBuffer
        // comment), not compositeSampleFormat. ThorVG's wg backend adopts
        // the target's format (tvgWg_target_format.patch), so the bytes it
        // writes are already correct RGBA when targetPixelOrder is
        // .rgba8Unorm. Viewing them through compositeSampleFormat (always
        // BGRA) would reinterpret those already-correct bytes as swapped —
        // that reinterpretation is only a no-op on platforms where
        // targetPixelOrder is already .bgra8Unorm (image format ==
        // compositeSampleFormat). Matching the view format to the image and
        // leaving the component mapping at identity (the default) is what
        // makes this correct for both cases.
        viewInfo.format   = importedTextureFormat
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

        return (image, view, memory)
    }
    #endif

    #if os(Windows)
    /// The Windows `makeImportedImage(fd:)`: the VkImage + view + memory
    /// imported from an NT handle exported via `VK_KHR_external_memory_win32`.
    /// Everything but the handle type and its import struct is the fd path's.
    ///
    /// Unlike an fd, the handle is not consumed by the import (Vulkan spec: an
    /// NT handle stays the application's), so it is closed here once the
    /// import is done, whether it succeeded or not — the driver keeps its own
    /// reference to the memory.
    func makeImportedImage(
        win32Handle handle: HANDLE,
        width:  Int,
        height: Int
    ) throws -> (image: VkImage, view: VkImageView, memory: VkDeviceMemory?) {
        defer { CloseHandle(handle) }

        var externalMemoryInfo = VkExternalMemoryImageCreateInfo()
        externalMemoryInfo.sType = VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO
        externalMemoryInfo.handleTypes = VkExternalMemoryHandleTypeFlags(
            VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_WIN32_BIT.rawValue
        )

        var image: VkImage?
        let imageResult: VkResult = withUnsafePointer(to: &externalMemoryInfo) { extPtr in
            var imageInfo = VkImageCreateInfo()
            imageInfo.sType         = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO
            imageInfo.pNext         = UnsafeRawPointer(extPtr)
            imageInfo.imageType     = VK_IMAGE_TYPE_2D
            imageInfo.format        = importedTextureFormat
            imageInfo.extent        = VkExtent3D(width: UInt32(width), height: UInt32(height), depth: 1)
            imageInfo.mipLevels     = 1
            imageInfo.arrayLayers   = 1
            imageInfo.samples       = VK_SAMPLE_COUNT_1_BIT
            imageInfo.tiling        = VK_IMAGE_TILING_OPTIMAL
            imageInfo.usage         = VkImageUsageFlags(
                VK_IMAGE_USAGE_SAMPLED_BIT.rawValue |
                VK_IMAGE_USAGE_TRANSFER_SRC_BIT.rawValue |
                VK_IMAGE_USAGE_TRANSFER_DST_BIT.rawValue
            )
            imageInfo.sharingMode   = VK_SHARING_MODE_EXCLUSIVE
            imageInfo.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED
            return vkCreateImage(device, &imageInfo, nil, &image)
        }
        guard imageResult == VK_SUCCESS, let image else {
            throw VulkanEngineError.image
        }

        var requirements = VkMemoryRequirements()
        vkGetImageMemoryRequirements(device, image, &requirements)

        let dedicatedInfo = UnsafeMutablePointer<VkMemoryDedicatedAllocateInfo>.allocate(capacity: 1)
        defer { dedicatedInfo.deallocate() }
        dedicatedInfo.pointee = VkMemoryDedicatedAllocateInfo()
        dedicatedInfo.pointee.sType = VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO
        dedicatedInfo.pointee.image = image

        let importInfo = UnsafeMutablePointer<VkImportMemoryWin32HandleInfoKHR>.allocate(capacity: 1)
        defer { importInfo.deallocate() }
        importInfo.pointee = VkImportMemoryWin32HandleInfoKHR()
        importInfo.pointee.sType = VK_STRUCTURE_TYPE_IMPORT_MEMORY_WIN32_HANDLE_INFO_KHR
        importInfo.pointee.pNext = UnsafeRawPointer(dedicatedInfo)
        importInfo.pointee.handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_WIN32_BIT
        importInfo.pointee.handle = handle

        var memory: VkDeviceMemory?
        var allocInfo = VkMemoryAllocateInfo()
        allocInfo.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO
        allocInfo.pNext = UnsafeRawPointer(importInfo)
        allocInfo.allocationSize = requirements.size
        allocInfo.memoryTypeIndex = findMemoryType(
            typeFilter: requirements.memoryTypeBits,
            properties: VkMemoryPropertyFlags(VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT.rawValue)
        )
        guard vkAllocateMemory(device, &allocInfo, nil, &memory) == VK_SUCCESS, let memory else {
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

        // As the fd path: GENERAL, never UNDEFINED, so the driver may not
        // discard what wgpu writes.
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

    /// The Windows `makeThorNode(importingFd:)`.
    func makeThorNode(
        canvas:       Tvg_Canvas,
        importingWin32Handle handle: HANDLE,
        width:        Int,
        height:       Int
    ) throws -> ThorShaderNode<RenderNode> {
        let created = try makeImportedImage(win32Handle: handle, width: width, height: height)
        return ThorShaderNode(
            canvas:             ThorVulkanCanvas(base: canvas),
            width:              UInt32(width),
            height:             UInt32(height),
            image:              created.image,
            imageView:          created.view,
            memory:             created.memory,
            isExternallyBacked: true,
            storageCapable:     false
        )
    }
    #else
    /// Just the imported VkImage + view + memory from a POSIX fd exported via
    /// `VK_KHR_external_memory_fd` — the Linux mirror of
    /// `makeImportedImage(mtlTexture:)`. Unlike the Metal struct,
    /// `VkImportMemoryFdInfoKHR`/`VkExternalMemoryImageCreateInfo` are plain
    /// value types with no ObjC fields, so they import into Swift cleanly —
    /// no manual byte-layout needed, just heap-stable storage for the pNext
    /// chain across the call (`defer`-deallocated after `vkAllocateMemory`
    /// returns, same as everywhere else in this file).
    ///
    /// `fd` is consumed on a *successful* import (Vulkan spec: ownership
    /// transfers to the driver); on failure the caller still owns it.
    func makeImportedImage(
        fd:     Int32,
        width:  Int,
        height: Int
    ) throws -> (image: VkImage, view: VkImageView, memory: VkDeviceMemory?) {
        // Must match the exporting image's creation parameters (Vulkan spec
        // requirement for VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT): same
        // format/extent/mip/array/sample counts and tiling as wgpu-hal's own
        // texture creation, which always uses OPTIMAL tiling.
        var externalMemoryInfo = VkExternalMemoryImageCreateInfo()
        externalMemoryInfo.sType = VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO
        externalMemoryInfo.handleTypes = VkExternalMemoryHandleTypeFlags(
            VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT.rawValue
        )

        var image: VkImage?
        let imageResult: VkResult = withUnsafePointer(to: &externalMemoryInfo) { extPtr in
            var imageInfo = VkImageCreateInfo()
            imageInfo.sType         = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO
            imageInfo.pNext         = UnsafeRawPointer(extPtr)
            imageInfo.imageType     = VK_IMAGE_TYPE_2D
            imageInfo.format        = importedTextureFormat
            imageInfo.extent        = VkExtent3D(width: UInt32(width), height: UInt32(height), depth: 1)
            imageInfo.mipLevels     = 1
            imageInfo.arrayLayers   = 1
            imageInfo.samples       = VK_SAMPLE_COUNT_1_BIT
            imageInfo.tiling        = VK_IMAGE_TILING_OPTIMAL
            imageInfo.usage         = VkImageUsageFlags(
                VK_IMAGE_USAGE_SAMPLED_BIT.rawValue |
                VK_IMAGE_USAGE_TRANSFER_SRC_BIT.rawValue |
                VK_IMAGE_USAGE_TRANSFER_DST_BIT.rawValue
            )
            imageInfo.sharingMode   = VK_SHARING_MODE_EXCLUSIVE
            imageInfo.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED
            return vkCreateImage(device, &imageInfo, nil, &image)
        }
        guard imageResult == VK_SUCCESS, let image else {
            throw VulkanEngineError.image
        }

        var requirements = VkMemoryRequirements()
        vkGetImageMemoryRequirements(device, image, &requirements)

        let dedicatedInfo = UnsafeMutablePointer<VkMemoryDedicatedAllocateInfo>.allocate(capacity: 1)
        defer { dedicatedInfo.deallocate() }
        dedicatedInfo.pointee = VkMemoryDedicatedAllocateInfo()
        dedicatedInfo.pointee.sType = VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO
        dedicatedInfo.pointee.image = image

        let importInfo = UnsafeMutablePointer<VkImportMemoryFdInfoKHR>.allocate(capacity: 1)
        defer { importInfo.deallocate() }
        importInfo.pointee = VkImportMemoryFdInfoKHR()
        importInfo.pointee.sType = VK_STRUCTURE_TYPE_IMPORT_MEMORY_FD_INFO_KHR
        importInfo.pointee.pNext = UnsafeRawPointer(dedicatedInfo)
        importInfo.pointee.handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT
        importInfo.pointee.fd = fd

        var memory: VkDeviceMemory?
        var allocInfo = VkMemoryAllocateInfo()
        allocInfo.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO
        allocInfo.pNext = UnsafeRawPointer(importInfo)
        allocInfo.allocationSize = requirements.size
        allocInfo.memoryTypeIndex = findMemoryType(
            typeFilter: requirements.memoryTypeBits,
            properties: VkMemoryPropertyFlags(VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT.rawValue)
        )
        guard vkAllocateMemory(device, &allocInfo, nil, &memory) == VK_SUCCESS, let memory else {
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

        // Same reasoning as the Metal path: transition to GENERAL, never
        // UNDEFINED, so the driver isn't told it may discard content already
        // (or about to be) written by wgpu's blit.
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

    #if os(Android) && NUCLEANT_ANDROID_USE_AHARDWAREBUFFER
    /// Android mirror of `makeThorNode(importingFd:)`, opt-in build only.
    func makeThorNode(
        canvas:        Tvg_Canvas,
        importingHardwareBuffer buffer: UnsafeMutableRawPointer,
        width:         Int,
        height:        Int
    ) throws -> ThorShaderNode<RenderNode> {
        let created = try makeImportedImage(hardwareBuffer: buffer, width: width, height: height)
        return ThorShaderNode(
            canvas:             ThorVulkanCanvas(base: canvas),
            width:              UInt32(width),
            height:             UInt32(height),
            image:              created.image,
            imageView:          created.view,
            memory:             created.memory,
            isExternallyBacked: true,
            storageCapable:     false
        )
    }
    #endif

    /// Create a `ThorShaderNode` whose VkImage is *imported* from a POSIX fd
    /// (via `VK_KHR_external_memory_fd`) rather than allocated — the
    /// Linux/Android mirror of `makeThorNode(importingMetalTexture:)`.
    func makeThorNode(
        canvas:       Tvg_Canvas,
        importingFd fd: Int32,
        width:        Int,
        height:       Int
    ) throws -> ThorShaderNode<RenderNode> {
        let created = try makeImportedImage(fd: fd, width: width, height: height)
        return ThorShaderNode(
            canvas:             ThorVulkanCanvas(base: canvas),
            width:              UInt32(width),
            height:             UInt32(height),
            image:              created.image,
            imageView:          created.view,
            memory:             created.memory,
            isExternallyBacked: true,
            storageCapable:     false
        )
    }
    #endif

    /// Linux/Android mirror of `resizeThorNode` above: mint a new wgpu target +
    /// imported VkImage at the new size via the fd-import path instead of
    /// Metal, and swap it into the same `ThorShaderNode`. See the Apple
    /// version for the full rationale (identity, the slot's readable flag) —
    /// this only differs in how the new backing is created and imported.
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
        #if os(Android) && NUCLEANT_ANDROID_USE_AHARDWAREBUFFER
        guard let hardwareBuffer = target.nativeAndroidHardwareBuffer() else {
            print("VulkanRenderDevice: wgpu target has no AHardwareBuffer (resize)")
            target.release()
            return false
        }
        #elseif os(Windows)
        guard let handle = target.nativeVulkanExportedWin32Handle() else {
            print("VulkanRenderDevice: wgpu target has no exported handle (resize)")
            target.release()
            return false
        }
        #else
        guard let fd = target.nativeVulkanExportedFd() else {
            print("VulkanRenderDevice: wgpu target has no exported fd (resize)")
            target.release()
            return false
        }
        #endif

        let created: (image: VkImage, view: VkImageView, memory: VkDeviceMemory?)
        do {
            #if os(Android) && NUCLEANT_ANDROID_USE_AHARDWAREBUFFER
            created = try makeImportedImage(
                hardwareBuffer: hardwareBuffer, width: width, height: height
            )
            #elseif os(Windows)
            created = try makeImportedImage(win32Handle: handle, width: width, height: height)
            #else
            created = try makeImportedImage(fd: fd, width: width, height: height)
            #endif
        } catch {
            print("VulkanRenderDevice: imported image (resize) failed: \(error)")
            target.release()
            return false
        }

        // Same precondition as the bind path in makeThorWidgetNode: set_target
        // fails with TVG_RESULT_INSUFFICIENT_CONDITION unless the canvas's
        // internal status is Synced. Forcing it here too, not just at bind.
        _ = tvg_canvas_sync(node.canvas.base)

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
            vkDeviceWaitIdle(device)
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

        vkDeviceWaitIdle(device)

        node.image                     = created.image
        node.imageView                 = created.view
        node.memory                    = created.memory
        node.width                     = UInt32(width)
        node.height                    = UInt32(height)
        node.currentLayout             = VK_IMAGE_LAYOUT_GENERAL
        node.waitForExternalCompletion = { wgpu.waitForGPUCompletion() }
        node.releaseExternal           = { target.release() }
        node.dirty                     = true

        vkDestroyImageView(device, oldView, nil)
        vkDestroyImage(device, oldImage, nil)
        if let oldMemory { vkFreeMemory(device, oldMemory, nil) }
        oldRelease?()

        // The new image isn't in SHADER_READ_ONLY until the node's next draw.
        readable.remove(id)
        return true
    }
}
#endif
