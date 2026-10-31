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
        let node = try #require(engine.renderDevice.makeThorWidgetNode(width: 32, height: 16))
        defer { node.destroyResources(engine.renderDevice) }
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
        let node = try #require(engine.renderDevice.makeThorWidgetNode(width: 16, height: 16))
        defer { node.destroyResources(engine.renderDevice) }

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
        let node = try #require(engine.renderDevice.makeThorWidgetNode(width: 8, height: 8))
        defer { node.destroyResources(engine.renderDevice) }
        let oldImage = node.image

        #expect(engine.renderDevice.resizeThorNode(node, id: 1, width: 24, height: 12))
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
        let node = try #require(engine.renderDevice.makeThorWidgetNode(width: 32, height: 24))
        let shape = TestRect()
        shape.append_rect(x: 4, y: 4, w: 24, h: 16)
        shape.set_fill_color(r: 255, g: 128, b: 0)
        node.canvas.add(shape: shape)

        engine.append(ThorSlot(id: 1, context: .thor(node)))
        // One frame: a ThorVG canvas draws again only after something on it
        // changed (a second draw of an unchanged canvas is refused).
        engine.drawFrame(1.0 / 60.0)
        engine.waitForPreviousFrame()
        #expect(engine.renderDevice.readable.contains(1))
        // The window only shows the node; its maker frees it (and its target).
        engine.remove(id: 1)
        node.destroyResources(engine.renderDevice)
    }
}
#endif
