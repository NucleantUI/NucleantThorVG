//
//  ThorWebGPUTests.swift
//  NucleantThorVGTests
//
//  ThorVG's wg engine in the browser: it draws through NucleantVulkan's
//  CWgpu (webgpu.h on the page's WebGPU) into a `WgpuContext` target, and
//  the node's VkImage is that very texture (VK_NUCLEANT_webgpu_objects) —
//  so what ThorVG drew is read back through Vulkan with no copy in between.
//  Run with scripts/run_wasm_tests.py (headless Chrome).
//
#if os(WASI)
import Testing
import Observation
import CThorVG
import CVulkan
import NucleantVulkan
@testable import NucleantThorVG

@Suite(.serialized)
struct ThorWebGPUTests {

    init() {
        _ = tvg_engine_init(0)
    }

    @Test func widgetNodeHoldsWhatThorVGDrew() throws {
        let engine = try VulkanRenderEngine<ThorSlot>(canvasSelector: "#test-canvas", getSize: { (64, 48) })
        let node = try #require(engine.makeThorWidgetNode(width: 32, height: 16))
        defer { node.destroyResources(engine) }
        #expect(node.isExternallyBacked)

        try draw(node.canvas, rect: (0, 0, 16, 16), color: (255, 0, 0))

        // BGRA bytes: red on the left half, untouched (clear) on the right.
        let pixels = readPixels(engine, node.image, width: 32, height: 16)
        expectPixel(pixels, 32, 4, 8, [0, 0, 255, 255])
        expectPixel(pixels, 32, 12, 2, [0, 0, 255, 255])
        expectPixel(pixels, 32, 24, 8, [0, 0, 0, 0])
    }

    @Test func redrawReplacesTheTargetsContent() throws {
        let engine = try VulkanRenderEngine<ThorSlot>(canvasSelector: "#test-canvas", getSize: { (64, 48) })
        let node = try #require(engine.makeThorWidgetNode(width: 16, height: 16))
        defer { node.destroyResources(engine) }

        let shape = try draw(node.canvas, rect: (0, 0, 16, 16), color: (255, 0, 0))
        // Recolored in place, then drawn again into the same texture.
        tvg_shape_set_fill_color(shape.base, 0, 0, 255, 255)
        #expect(node.canvas.update() == TVG_RESULT_SUCCESS)
        #expect(node.canvas.draw() == TVG_RESULT_SUCCESS)
        #expect(node.canvas.sync() == TVG_RESULT_SUCCESS)

        let pixels = readPixels(engine, node.image, width: 16, height: 16)
        expectPixel(pixels, 16, 8, 8, [255, 0, 0, 255])
    }

    @Test func resizedNodeDrawsAtTheNewSize() throws {
        let engine = try VulkanRenderEngine<ThorSlot>(canvasSelector: "#test-canvas", getSize: { (64, 48) })
        let node = try #require(engine.makeThorWidgetNode(width: 8, height: 8))
        defer { node.destroyResources(engine) }
        let oldImage = node.image

        #expect(engine.resizeThorNode(node, id: 1, width: 24, height: 12))
        #expect(node.width == 24)
        #expect(node.height == 12)
        #expect(node.image != oldImage)

        try draw(node.canvas, rect: (12, 0, 12, 12), color: (0, 255, 0))
        let pixels = readPixels(engine, node.image, width: 24, height: 12)
        expectPixel(pixels, 24, 4, 6, [0, 0, 0, 0])
        expectPixel(pixels, 24, 20, 6, [0, 255, 0, 255])
    }

    @Test func engineCompositesAThorNode() throws {
        let engine = try VulkanRenderEngine<ThorSlot>(canvasSelector: "#test-canvas", getSize: { (64, 48) })
        let node = try #require(engine.makeThorWidgetNode(width: 32, height: 24))
        let shape = TestRect()
        shape.append_rect(x: 4, y: 4, w: 24, h: 16)
        shape.set_fill_color(r: 255, g: 128, b: 0)
        node.canvas.add(shape: shape)

        engine.append(ThorSlot(id: 1, context: .thor(node)))
        // One frame: a ThorVG canvas draws again only after something on it
        // changed (a second draw of an unchanged canvas is refused).
        engine.drawFrame(1.0 / 60.0)
        engine.waitForPreviousFrame()
        #expect(engine.readable.contains(1))
        // The slot frees the node (and its target) on removal.
        engine.remove(id: 1)
    }
}

// MARK: - Helpers

/// A test's own paint: a ThorVG shape it owns.
private final class TestRect: ThorShapeObject {
    var base: Tvg_Paint

    init() {
        base = tvg_shape_new()
    }
}

/// One rect on `canvas`, drawn and synced — what ThorShaderNode.update does
/// each frame before the composite samples the image.
@discardableResult
private func draw(
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
private func readPixels(_ engine: VulkanRenderEngine<ThorSlot>, _ image: VkImage, width: Int, height: Int) -> [UInt8] {
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

private func hostVisibleMemoryType(_ physicalDevice: VkPhysicalDevice, _ typeBits: UInt32) -> UInt32 {
    var properties = VkPhysicalDeviceMemoryProperties()
    vkGetPhysicalDeviceMemoryProperties(physicalDevice, &properties)
    let wanted = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT.rawValue | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT.rawValue
    return withUnsafeBytes(of: properties.memoryTypes) { raw in
        let types = raw.bindMemory(to: VkMemoryType.self)
        for index in 0..<Int(properties.memoryTypeCount)
        where typeBits & (1 << index) != 0 && types[index].propertyFlags & wanted == wanted {
            return UInt32(index)
        }
        return 0
    }
}

private func expectPixel(
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
