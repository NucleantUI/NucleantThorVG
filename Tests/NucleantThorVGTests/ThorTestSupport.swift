//
//  ThorTestSupport.swift
//  NucleantThorVGTests
//
//  What the GPU suites share — ThorWebGPUTests (the browser) and
//  ThorWin32Tests (Windows): a composite slot for one ThorVG node, a shape to
//  draw, and the node's texels read back through Vulkan.
//
#if os(WASI) || os(Windows)
import Testing
import Observation
import CThorVG
import CVulkan
import NucleantVulkan
@testable import NucleantThorVG

/// A test's own paint: a ThorVG shape it owns.
final class TestRect: ThorShapeObject {
    var base: Tvg_Paint

    init() {
        base = tvg_shape_new()
    }
}

/// One rect on `canvas`, drawn and synced — what ThorShaderNode.update does
/// each frame before the composite samples the image.
@discardableResult
func draw(
    _ canvas: ThorVulkanCanvas,
    rect: (x: Float, y: Float, w: Float, h: Float),
    color: (r: UInt8, g: UInt8, b: UInt8),
    sourceLocation: SourceLocation = #_sourceLocation
) throws -> TestRect {
    let shape = TestRect()
    shape.append_rect(x: rect.x, y: rect.y, w: rect.w, h: rect.h)
    shape.set_fill_color(r: color.r, g: color.g, b: color.b)
    try #require(canvas.add(shape: shape) == TVG_RESULT_SUCCESS, sourceLocation: sourceLocation)
    try #require(canvas.draw() == TVG_RESULT_SUCCESS, sourceLocation: sourceLocation)
    try #require(canvas.sync() == TVG_RESULT_SUCCESS, sourceLocation: sourceLocation)
    return shape
}

/// `image`'s texels through a host-visible buffer on the engine's device.
func readPixels(_ engine: VulkanRenderEngine<ThorSlot>, _ image: VkImage, width: Int, height: Int) -> [UInt8] {
    let byteCount = width * height * 4
    var bufferInfo = VkBufferCreateInfo()
    bufferInfo.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO
    bufferInfo.size = VkDeviceSize(byteCount)
    bufferInfo.usage = VkBufferUsageFlags(VK_BUFFER_USAGE_TRANSFER_DST_BIT.rawValue)
    bufferInfo.sharingMode = VK_SHARING_MODE_EXCLUSIVE
    var buffer: VkBuffer?
    vkCreateBuffer(engine.device, &bufferInfo, nil, &buffer)
    defer { vkDestroyBuffer(engine.device, buffer, nil) }

    var requirements = VkMemoryRequirements()
    vkGetBufferMemoryRequirements(engine.device, buffer, &requirements)
    var allocInfo = VkMemoryAllocateInfo()
    allocInfo.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO
    allocInfo.allocationSize = requirements.size
    allocInfo.memoryTypeIndex = hostVisibleMemoryType(engine.physicalDevice, requirements.memoryTypeBits)
    var memory: VkDeviceMemory?
    vkAllocateMemory(engine.device, &allocInfo, nil, &memory)
    defer { vkFreeMemory(engine.device, memory, nil) }
    vkBindBufferMemory(engine.device, buffer, memory, 0)

    engine.oneTimeSubmit { cmd in
        var region = VkBufferImageCopy()
        region.imageSubresource = VkImageSubresourceLayers(
            aspectMask: VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT.rawValue), mipLevel: 0, baseArrayLayer: 0, layerCount: 1)
        region.imageExtent = VkExtent3D(width: UInt32(width), height: UInt32(height), depth: 1)
        vkCmdCopyImageToBuffer(cmd, image, VK_IMAGE_LAYOUT_GENERAL, buffer, 1, &region)
    }

    var out = [UInt8](repeating: 0, count: byteCount)
    var mapped: UnsafeMutableRawPointer?
    vkMapMemory(engine.device, memory, 0, VkDeviceSize(byteCount), 0, &mapped)
    if let mapped {
        out.withUnsafeMutableBytes { $0.baseAddress?.copyMemory(from: mapped, byteCount: byteCount) }
    }
    vkUnmapMemory(engine.device, memory)
    return out
}

func hostVisibleMemoryType(_ physicalDevice: VkPhysicalDevice, _ typeBits: UInt32) -> UInt32 {
    var properties = VkPhysicalDeviceMemoryProperties()
    vkGetPhysicalDeviceMemoryProperties(physicalDevice, &properties)
    // As flags (UInt32): the bits' raw values are Int32 on Windows.
    let wanted = VkMemoryPropertyFlags(VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT.rawValue)
        | VkMemoryPropertyFlags(VK_MEMORY_PROPERTY_HOST_COHERENT_BIT.rawValue)
    return withUnsafeBytes(of: properties.memoryTypes) { raw in
        let types = raw.bindMemory(to: VkMemoryType.self)
        for index in 0..<Int(properties.memoryTypeCount)
        where typeBits & (1 << index) != 0 && types[index].propertyFlags & wanted == wanted {
            return UInt32(index)
        }
        return 0
    }
}

func expectPixel(
    _ pixels: [UInt8], _ width: Int, _ x: Int, _ y: Int, _ expected: [UInt8], sourceLocation: SourceLocation = #_sourceLocation
) {
    let i = (y * width + x) * 4
    let actual = Array(pixels[i..<i + 4])
    let close = zip(actual, expected).allSatisfy { abs(Int($0) - Int($1)) <= 1 }
    #expect(close, "pixel \(x),\(y): \(actual), expected \(expected)", sourceLocation: sourceLocation)
}

/// The smallest composite slot the engine can drive: one ThorVG node.
@Observable
final class ThorSlot: RenderContainerNode, @unchecked Sendable {
    enum Context: RenderNodeContext {
        case thor(ThorShaderNode<ThorSlot>)
    }

    let id: Int
    let context: Context
    var needsRender = true

    init(id: Int, context: Context) {
        self.id = id
        self.context = context
    }

    func observeContext() {
        if case .thor(let node) = context { observe(node) }
    }

    func update(engine: Engine, cmd: VkCommandBuffer) {
        if case .thor(let node) = context { node.update(engine, slot: self, cmd: cmd) }
    }

    func destroyResources(engine: Engine) {
        if case .thor(let node) = context { node.destroyResources(engine) }
    }

    func getImageView() -> VkImageView? {
        if case .thor(let node) = context { return node.imageView }
        return nil
    }
}
#endif
