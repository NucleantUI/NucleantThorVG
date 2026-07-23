//
//  ThorShaderNode.swift
//  PyNucleantUI
//
import NucleantVulkan
import CVulkan
import Observation

public protocol VulkanThorRenderNode: VulkanRenderNode {
    associatedtype CanvasSurface: ThorGPUCanvas
    var canvas: CanvasSurface { get }
    var width:  UInt32        { get }
    var height: UInt32        { get }
}
/// The engine's single node type: a ThorVG GPU canvas rendering into a
/// VkImage, plus an optional compute shader post-process. Conforms to
/// `VulkanThorRenderNode`, so it also works as the concrete `B` of
/// `RenderNodeEnum` / `renderFrame`.
///
/// `@Observable` so the owning `RenderNode` slot can track the mutable
/// render-affecting state (`dirty`, the compute trio) — canvas-side code
/// keeps writing `node.dirty = true` and the slot notices on its own.
@Observable
public final class ThorShaderNode<C: RenderContainerNode>: VulkanThorRenderNode , @unchecked Sendable {
    
    
    public typealias ContainerNode = C
    public typealias Engine = VulkanRenderEngine<C>

    public var canvas: ThorVulkanCanvas
    public let width:  UInt32
    public let height: UInt32

    public let image:                VkImage
    public let imageView:            VkImageView
    /// The allocation backing `image` — the engine binds but never frees
    /// it, so the node carries the handle for whoever tears the node down
    /// (resize, detach). For imported textures this is the import
    /// allocation, not memory the engine really owns.
    public let memory:               VkDeviceMemory?
    public var computePipeline:      VkPipeline?
    public var computeLayout:        VkPipelineLayout?
    public var computeDescriptorSet: VkDescriptorSet?
    public var dirty:                Bool = true

    /// True when `image` is imported external memory (e.g. a Metal texture
    /// another API rendered into via VK_EXT_metal_objects) rather than an
    /// image this engine itself drew into. Only affects the very first
    /// barrier: such an image starts life in GENERAL (set at import time),
    /// not COLOR_ATTACHMENT_OPTIMAL, and GENERAL is safe as a source for
    /// any prior access without permitting the driver to discard content.
    public let isExternallyBacked: Bool

    /// True when `image` was created with STORAGE usage (and, for imported
    /// Metal textures, the underlying MTLTexture has shaderWrite), so a
    /// compute post shader may bind it as a storage image. Canvas post
    /// shaders check this before building their pipeline.
    public let storageCapable: Bool

    /// The image's actual current Vulkan-tracked layout, updated after
    /// every barrier `update(_:cmd:)` records. Barriers must declare the
    /// layout the image is *really* in — declaring a stale one (e.g.
    /// re-asserting the import-time GENERAL on frame 2, when the previous
    /// barrier already moved it to SHADER_READ_ONLY_OPTIMAL) is exactly the
    /// oldLayout/actual-layout mismatch that lets a driver skip or
    /// mis-schedule the cache operations a transition depends on.
    var currentLayout: VkImageLayout

    /// For externally-backed nodes: blocks until the writer's GPU queue has
    /// actually finished, not just submitted, its work. `tvg_canvas_sync()`
    /// only proves ThorVG's blit was *queued* on wgpu-native's Metal queue
    /// (`wgpuQueueSubmit` is fire-and-forget, no fence) — without this,
    /// Vulkan's composite pass can read the shared image before Metal's
    /// GPU has actually written to it: two independent queues racing on
    /// the same memory with nothing ordering them.
    public var waitForExternalCompletion: (() -> Void)?

    /// Drops the wgpu render target this node's image was imported from.
    /// The node owns that target (the "belongs in the ShaderNode" contract):
    /// its VkImage aliases the target's Metal memory, so the target must
    /// outlive the image and be released only after `destroyResources` frees
    /// it. The closure captures the wgpu `Target` (and its release), keeping
    /// all webgpu types inside the factory that built the node — the node
    /// itself never names one.
    public var releaseExternal: (() -> Void)?

    public init(
        canvas:               ThorVulkanCanvas,
        width:                UInt32,
        height:               UInt32,
        image:                VkImage,
        imageView:            VkImageView,
        memory:               VkDeviceMemory?   = nil,
        isExternallyBacked:   Bool              = false,
        storageCapable:       Bool              = false,
        computePipeline:      VkPipeline?       = nil,
        computeLayout:        VkPipelineLayout? = nil,
        computeDescriptorSet: VkDescriptorSet?  = nil
    ) {
        self.canvas               = canvas
        self.width                = width
        self.height               = height
        self.image                = image
        self.imageView            = imageView
        self.memory               = memory
        self.isExternallyBacked   = isExternallyBacked
        self.storageCapable       = storageCapable
        self.currentLayout        = isExternallyBacked ? VK_IMAGE_LAYOUT_GENERAL : VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL
        self.computePipeline      = computePipeline
        self.computeLayout        = computeLayout
        self.computeDescriptorSet = computeDescriptorSet
    }
}


extension ThorShaderNode {
    public func update(_ engine: Engine, slot: ContainerNode, cmd: VkCommandBuffer) {
        // let id = ObjectIdentifier(node).hashValue
        // ^ replaced: the slot carries the canvas-owned id.
        let id = slot.id
        // guard node.dirty else { return }
        // ^ the dirty marker moved up to the slot — Observation on the
        //   shader node feeds it (see RenderNode.observe).
        guard slot.needsRender else { return }
        let drawResult = canvas.draw()
        let syncResult = drawResult == TVG_RESULT_SUCCESS ? canvas.sync() : drawResult
        guard drawResult == TVG_RESULT_SUCCESS, syncResult == TVG_RESULT_SUCCESS else {
            if engine.warnedFailedNodes.insert(id).inserted {
                print("VulkanRenderEngine: thor node \(id) failed rendering (draw: \(drawResult), sync: \(syncResult)) — logged once; this repeats every frame if nothing is ever painted into the node's canvas")
            }
            return
        }
        engine.warnedFailedNodes.remove(id)
        // node.dirty = false
        // ^ must NOT write back to the shader node: the slot observes it,
        //   so an engine-side write would fire onChange and re-mark the
        //   slot dirty — a permanent redraw loop. The engine consumes the
        //   slot's flag only.
        // slot.needsRender = false
        // ^ deliberately NOT cleared for now: nothing drives per-frame
        //   updates yet (tetris side isn't wired up), so slots stay
        //   permanently dirty and every node redraws every frame — which
        //   is also the intended leak-amplifier mode while leaks are
        //   hunted. Re-enable clearing once the canvas side really drives
        //   updates through the Observation chain.
       waitForExternalCompletion?()

        // Barriers must declare the layout the image is *really* in right
        // now — node.currentLayout, not an assumption. An externally-backed
        // image's writer (Metal, via wgpu-native) never goes through our
        // Vulkan command stream, so on its very first draw the only
        // trustworthy claim is GENERAL (set at import time): valid as a
        // source for any prior access, and — unlike UNDEFINED — never
        // permits the driver to discard content. On every frame after
        // that, currentLayout correctly reflects where the previous
        // barrier below actually left it.
        let priorLayout  = currentLayout
        let priorAccess: VkAccessFlags = isExternallyBacked
            ? VkAccessFlags(VK_ACCESS_MEMORY_WRITE_BIT.rawValue) | VkAccessFlags(VK_ACCESS_MEMORY_READ_BIT.rawValue)
            : VkAccessFlags(VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT.rawValue)

        if let pipeline = computePipeline,
           let layout   = computeLayout,
           let ds       = computeDescriptorSet {

            engineImageBarrier(
                cmd,
                image:     image,
                srcLayout: priorLayout,
                srcAccess: priorAccess,
                srcStage:  VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
                dstLayout: VK_IMAGE_LAYOUT_GENERAL,
                dstAccess: VkAccessFlags(VK_ACCESS_SHADER_READ_BIT.rawValue) | VkAccessFlags(VK_ACCESS_SHADER_WRITE_BIT.rawValue),
                dstStage:  VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT
            )
            vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, pipeline)
            var descSet: VkDescriptorSet? = ds
            vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, layout, 0, 1, &descSet, 0, nil)
            vkCmdDispatch(cmd, (width + 7) / 8, (height + 7) / 8, 1)
            engineImageBarrier(
                cmd,
                image:     image,
                srcLayout: VK_IMAGE_LAYOUT_GENERAL,
                srcAccess: VkAccessFlags(VK_ACCESS_SHADER_WRITE_BIT.rawValue),
                srcStage:  VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
                dstLayout: VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                dstAccess: VkAccessFlags(VK_ACCESS_SHADER_READ_BIT.rawValue),
                dstStage:  VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT
            )
        } else {
            engineImageBarrier(
                cmd,
                image:     image,
                srcLayout: priorLayout,
                srcAccess: priorAccess,
                srcStage:  VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
                dstLayout: VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                dstAccess: VkAccessFlags(VK_ACCESS_SHADER_READ_BIT.rawValue),
                dstStage:  VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT
            )
        }
        currentLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
        engine.readable.insert(id)
    }

    /// Free the image/view/memory this node owns. The wgpu texture an
    /// externally-backed image was imported from, and the `Tvg_Canvas`
    /// handed out to Python, are borrowed — the owning canvas releases
    /// those (after retargeting ThorVG away from the texture), not this.
    public func destroyResources(_ engine: Engine) {
        vkDeviceWaitIdle(engine.device)
        vkDestroyImageView(engine.device, imageView, nil)
        vkDestroyImage(engine.device, image, nil)
        if let memory {
            vkFreeMemory(engine.device, memory, nil)
        }
        // Only now, with the aliasing VkImage gone, is it safe to drop the
        // wgpu target backing it.
        releaseExternal?()
    }
}

