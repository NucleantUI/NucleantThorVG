//
//  ThorWin32Tests.swift
//  NucleantThorVGTests
//
//  ThorVG's wg engine on Windows: it draws through wgpu-native's own Vulkan
//  device into a `WgpuContext` target, whose memory the engine's device
//  imports as the node's VkImage (an NT handle, VK_KHR_external_memory_win32)
//  — so what ThorVG drew is read back through the engine with no copy in
//  between. The engine runs on a Win32 window, as an app's does.
//
//  Needs a Vulkan driver with VK_KHR_external_memory_win32: a GPU's own
//  driver has it. CI's Windows machines have no GPU, and Mesa's software
//  driver (lavapipe) the workflow registers there has no NT-handle export,
//  so on those the suite is skipped rather than failed.
//
#if os(Windows)
import Testing
import WinSDK
import CThorVG
import CVulkan
import NucleantVulkan
@testable import NucleantThorVG

/// On the main actor, the thread that owns the window, as in an app.
@MainActor
@Suite(
    .serialized,
    .enabled(if: Win32Driver.exportsMemory, "no Vulkan driver here exports memory as an NT handle (VK_KHR_external_memory_win32)")
)
struct ThorWin32Tests {

    let window: TestWindow

    init() throws {
        _ = tvg_engine_init(0)
        window = try TestWindow(width: 64, height: 48)
    }

    func makeEngine() throws -> VulkanRenderEngine<ThorSlot> {
        let window = window
        return try VulkanRenderEngine<ThorSlot>(
            win32Instance: window.instance,
            win32Window: window.hwnd,
            getExtent: { window.extent }
        )
    }

    @Test func widgetNodeHoldsWhatThorVGDrew() throws {
        let engine = try makeEngine()
        let node = try #require(engine.makeThorWidgetNode(width: 32, height: 16))
        defer { node.destroyResources(engine) }
        #expect(node.isExternallyBacked)

        try draw(node.canvas, rect: (0, 0, 16, 16), color: (255, 0, 0))
        // wgpu's device draws, the engine's reads: wait for the first.
        node.waitForExternalCompletion?()

        // BGRA bytes: red on the left half, untouched (clear) on the right.
        let pixels = readPixels(engine, node.image, width: 32, height: 16)
        expectPixel(pixels, 32, 4, 8, [0, 0, 255, 255])
        expectPixel(pixels, 32, 12, 2, [0, 0, 255, 255])
        expectPixel(pixels, 32, 24, 8, [0, 0, 0, 0])
    }

    @Test func redrawReplacesTheTargetsContent() throws {
        let engine = try makeEngine()
        let node = try #require(engine.makeThorWidgetNode(width: 16, height: 16))
        defer { node.destroyResources(engine) }

        let shape = try draw(node.canvas, rect: (0, 0, 16, 16), color: (255, 0, 0))
        // Recolored in place, then drawn again into the same texture.
        tvg_shape_set_fill_color(shape.base, 0, 0, 255, 255)
        #expect(node.canvas.update() == TVG_RESULT_SUCCESS)
        #expect(node.canvas.draw() == TVG_RESULT_SUCCESS)
        #expect(node.canvas.sync() == TVG_RESULT_SUCCESS)
        node.waitForExternalCompletion?()

        let pixels = readPixels(engine, node.image, width: 16, height: 16)
        expectPixel(pixels, 16, 8, 8, [255, 0, 0, 255])
    }

    @Test func resizedNodeDrawsAtTheNewSize() throws {
        let engine = try makeEngine()
        let node = try #require(engine.makeThorWidgetNode(width: 8, height: 8))
        defer { node.destroyResources(engine) }
        let oldImage = node.image

        #expect(engine.resizeThorNode(node, id: 1, width: 24, height: 12))
        #expect(node.width == 24)
        #expect(node.height == 12)
        #expect(node.image != oldImage)

        try draw(node.canvas, rect: (12, 0, 12, 12), color: (0, 255, 0))
        node.waitForExternalCompletion?()
        let pixels = readPixels(engine, node.image, width: 24, height: 12)
        expectPixel(pixels, 24, 4, 6, [0, 0, 0, 0])
        expectPixel(pixels, 24, 20, 6, [0, 255, 0, 255])
    }

    @Test func engineCompositesAThorNode() throws {
        let engine = try makeEngine()
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

/// Whether a Vulkan driver here has VK_KHR_external_memory_win32, which the
/// wg engine's target needs: wgpu-native's device exports the texture's
/// memory as an NT handle and the engine's device imports it. Asked of every
/// device the loader finds, before any engine exists.
enum Win32Driver {
    static let exportsMemory: Bool = {
        var appInfo = VkApplicationInfo()
        appInfo.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO
        appInfo.apiVersion = (1 << 22) | (2 << 12) // Vulkan 1.2
        var created: VkInstance?
        let result = withUnsafePointer(to: &appInfo) { app in
            var info = VkInstanceCreateInfo()
            info.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO
            info.pApplicationInfo = app
            return vkCreateInstance(&info, nil, &created)
        }
        guard result == VK_SUCCESS, let instance = created else { return false }
        defer { vkDestroyInstance(instance, nil) }

        var deviceCount: UInt32 = 0
        vkEnumeratePhysicalDevices(instance, &deviceCount, nil)
        var devices = [VkPhysicalDevice?](repeating: nil, count: Int(deviceCount))
        vkEnumeratePhysicalDevices(instance, &deviceCount, &devices)
        return devices.compactMap { $0 }.contains { device in
            var count: UInt32 = 0
            vkEnumerateDeviceExtensionProperties(device, nil, &count, nil)
            var extensions = [VkExtensionProperties](repeating: VkExtensionProperties(), count: Int(count))
            vkEnumerateDeviceExtensionProperties(device, nil, &count, &extensions)
            return extensions.contains { properties in
                var name = properties.extensionName
                return withUnsafeBytes(of: &name) { raw in
                    String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
                } == "VK_KHR_external_memory_win32"
            }
        }
    }()
}

/// A top-level window of the system STATIC class (nothing to register), never
/// shown — a surface needs a window, not a visible one.
final class TestWindow {
    let instance: HINSTANCE
    let hwnd: HWND

    init(width: Int32, height: Int32) throws {
        let module = try #require(GetModuleHandleW(nil))
        let window = "STATIC".withCString(encodedAs: UTF16.self) { className in
            "NucleantThorVGTests".withCString(encodedAs: UTF16.self) { title in
                CreateWindowExW(0, className, title, 0, 0, 0, width, height, nil, nil, module, nil)
            }
        }
        instance = module
        hwnd = try #require(window)
    }

    /// The client area, in pixels.
    var extent: VkExtent2D {
        var rect = RECT()
        GetClientRect(hwnd, &rect)
        return VkExtent2D(width: UInt32(max(rect.right - rect.left, 0)),
                          height: UInt32(max(rect.bottom - rect.top, 0)))
    }

    deinit {
        DestroyWindow(hwnd)
    }
}
#endif
