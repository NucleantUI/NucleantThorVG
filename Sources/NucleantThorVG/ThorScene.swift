//
//  SceneProtocol.swift
//  SwiftyThorVG
//
import CThorVG
// import simd — SIMD2/SIMDScalar are Swift-stdlib builtins now; unneeded
// unless/until this file starts using simd's math ops.

public protocol ThorScene: ThorPaint {
    var base: Tvg_Paint { get set }

    func add(paint: Tvg_Paint) -> Tvg_Result
    func insert(target: Tvg_Paint, at: Tvg_Paint?) -> Tvg_Result
    func remove(paint: Tvg_Paint) -> Tvg_Result
    func clear_effects() -> Tvg_Result

    func add_effect_gaussian_blur(sigma: Double, direction: Int32, border: Int32, quality: Int32) -> Tvg_Result
    func add_effect_drop_shadow(r: UInt8, g: UInt8, b: UInt8, a: UInt8, angle: Double, distance: Double, sigma: Double, quality: Int32) -> Tvg_Result
    func add_effect_drop_shadow(_ color: SIMD4<UInt8>, angle: Double, distance: Double, sigma: Double, quality: Int32) -> Tvg_Result
    func add_effect_fill(r: UInt8, g: UInt8, b: UInt8, a: UInt8) -> Tvg_Result
    func add_effect_fill(_ color: SIMD4<UInt8>) -> Tvg_Result
    func add_effect_tint(black_r: UInt8, black_g: UInt8, black_b: UInt8, white_r: UInt8, white_g: UInt8, white_b: UInt8, intensity: Double) -> Tvg_Result
    func add_effect_tint(black: SIMD4<UInt8>, white: SIMD4<UInt8>, intensity: Double) -> Tvg_Result
    func add_effect_tritone(shadow_r: UInt8, shadow_g: UInt8, shadow_b: UInt8, midtone_r: UInt8, midtone_g: UInt8, midtone_b: UInt8, highlight_r: UInt8, highlight_g: UInt8, highlight_b: UInt8, blend: Int32) -> Tvg_Result
    func add_effect_tritone(shadow: SIMD4<UInt8>, midtone: SIMD4<UInt8>, highlight: SIMD4<UInt8>, blend: Int32) -> Tvg_Result
}

public extension ThorScene {

    // Tvg_Result tvg_scene_add(Tvg_Scene scene, Tvg_Paint paint)
    // Tvg_Result tvg_scene_insert(Tvg_Scene scene, Tvg_Paint target, Tvg_Paint at)
    // Tvg_Result tvg_scene_remove(Tvg_Scene scene, Tvg_Paint paint)
    // Tvg_Result tvg_scene_clear_effects(Tvg_Scene scene)
    // Tvg_Result tvg_scene_add_effect_gaussian_blur(Tvg_Scene scene, double sigma, int direction, int border, int quality)
    // Tvg_Result tvg_scene_add_effect_drop_shadow(Tvg_Scene scene, int r, int g, int b, int a, double angle, double distance, double sigma, int quality)
    // Tvg_Result tvg_scene_add_effect_fill(Tvg_Scene scene, int r, int g, int b, int a)
    // Tvg_Result tvg_scene_add_effect_tint(Tvg_Scene scene, int black_r, int black_g, int black_b, int white_r, int white_g, int white_b, double intensity)
    // Tvg_Result tvg_scene_add_effect_tritone(Tvg_Scene scene, int shadow_r, int shadow_g, int shadow_b, int midtone_r, int midtone_g, int midtone_b, int highlight_r, int highlight_g, int highlight_b, int blend)

    func add(paint: Tvg_Paint) -> Tvg_Result { tvg_scene_add(base, paint) }
    func insert(target: Tvg_Paint, at: Tvg_Paint? = nil) -> Tvg_Result { tvg_scene_insert(base, target, at) }
    func remove(paint: Tvg_Paint) -> Tvg_Result { tvg_scene_remove(base, paint) }
    func clear_effects() -> Tvg_Result { tvg_scene_clear_effects(base) }

    func add_effect_gaussian_blur(sigma: Double, direction: Int32 = 0, border: Int32 = 0, quality: Int32 = 100) -> Tvg_Result { tvg_scene_add_effect_gaussian_blur(base, sigma, direction, border, quality) }

    func add_effect_drop_shadow(r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255, angle: Double, distance: Double, sigma: Double, quality: Int32 = 100) -> Tvg_Result { tvg_scene_add_effect_drop_shadow(base, Int32(r), Int32(g), Int32(b), Int32(a), angle, distance, sigma, quality) }
    func add_effect_drop_shadow(_ color: SIMD4<UInt8>, angle: Double, distance: Double, sigma: Double, quality: Int32 = 100) -> Tvg_Result { tvg_scene_add_effect_drop_shadow(base, Int32(color.x), Int32(color.y), Int32(color.z), Int32(color.w), angle, distance, sigma, quality) }

    func add_effect_fill(r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255) -> Tvg_Result { tvg_scene_add_effect_fill(base, Int32(r), Int32(g), Int32(b), Int32(a)) }
    func add_effect_fill(_ color: SIMD4<UInt8>) -> Tvg_Result { tvg_scene_add_effect_fill(base, Int32(color.x), Int32(color.y), Int32(color.z), Int32(color.w)) }

    func add_effect_tint(black_r: UInt8, black_g: UInt8, black_b: UInt8, white_r: UInt8, white_g: UInt8, white_b: UInt8, intensity: Double) -> Tvg_Result { tvg_scene_add_effect_tint(base, Int32(black_r), Int32(black_g), Int32(black_b), Int32(white_r), Int32(white_g), Int32(white_b), intensity) }
    func add_effect_tint(black: SIMD4<UInt8>, white: SIMD4<UInt8>, intensity: Double) -> Tvg_Result { tvg_scene_add_effect_tint(base, Int32(black.x), Int32(black.y), Int32(black.z), Int32(white.x), Int32(white.y), Int32(white.z), intensity) }

    func add_effect_tritone(shadow_r: UInt8, shadow_g: UInt8, shadow_b: UInt8, midtone_r: UInt8, midtone_g: UInt8, midtone_b: UInt8, highlight_r: UInt8, highlight_g: UInt8, highlight_b: UInt8, blend: Int32 = 0) -> Tvg_Result { tvg_scene_add_effect_tritone(base, Int32(shadow_r), Int32(shadow_g), Int32(shadow_b), Int32(midtone_r), Int32(midtone_g), Int32(midtone_b), Int32(highlight_r), Int32(highlight_g), Int32(highlight_b), blend) }
    func add_effect_tritone(shadow: SIMD4<UInt8>, midtone: SIMD4<UInt8>, highlight: SIMD4<UInt8>, blend: Int32 = 0) -> Tvg_Result { tvg_scene_add_effect_tritone(base, Int32(shadow.x), Int32(shadow.y), Int32(shadow.z), Int32(midtone.x), Int32(midtone.y), Int32(midtone.z), Int32(highlight.x), Int32(highlight.y), Int32(highlight.z), blend) }
}

