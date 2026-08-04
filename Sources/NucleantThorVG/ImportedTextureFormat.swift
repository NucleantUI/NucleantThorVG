//
//  ImportedTextureFormat.swift
//  NucleantThorVG
//
//  The two Vulkan formats every "import ThorVG's wgpu target as a VkImage"
//  path uses. They are separate values for a reason, and conflating them is
//  what makes a colour inversion appear each time a new platform is brought up.
//
//  A single mental model covers all of them:
//
//      image  = how the bytes are actually laid out  -> follows the target
//      view   = how the composite wants to read them -> always BGRA
//
//  The swap, where one is needed, happens at the *view*, by reinterpreting the
//  same memory. Nothing else in the chain moves.
//

import NucleantVulkan
import CVulkan

/// Format of the memory a `WgpuContext.Target` actually holds — the byte order
/// ThorVG writes, since its wg backend adopts the target's format
/// (tvgWg_target_format.patch). Derived from `WgpuContext.targetPixelOrder` so
/// the VkImage declaration cannot drift from the texture it is imported over:
/// change the target format there and every import path follows.
var importedTextureFormat: VkFormat {
    switch WgpuContext.targetPixelOrder {
    case .rgba8Unorm: VK_FORMAT_R8G8B8A8_UNORM
    case .bgra8Unorm: VK_FORMAT_B8G8R8A8_UNORM
    }
}

/// Format the imported image is *viewed* through — BGRA on every platform,
/// deliberately.
///
/// This is the engine's convention rather than a property of the texture:
/// `VulkanRenderEngine.chooseSurfaceFormat()` prefers `VK_FORMAT_B8G8R8A8_UNORM`
/// and the composite pipeline samples assuming it. So the view is the single
/// point where a target that isn't BGRA gets reinterpreted back, and it is a
/// constant — if a platform ever looks inverted, the answer is
/// `WgpuContext.targetPixelOrder` above, never this.
let compositeSampleFormat: VkFormat = VK_FORMAT_B8G8R8A8_UNORM
