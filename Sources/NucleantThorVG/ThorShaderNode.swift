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
public final class ThorShaderNode: VulkanThorRenderNode , @unchecked Sendable {

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

