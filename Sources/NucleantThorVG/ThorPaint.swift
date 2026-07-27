//
//  PaintProtocol.swift
//  SwiftyThorVG
//
import CThorVG
// import simd — SIMD2/SIMDScalar are Swift-stdlib builtins now; unneeded
// unless/until this file starts using simd's math ops.

public protocol ThorPaint {
    var base: Tvg_Paint { get set }

    @discardableResult func ref() -> UInt16
    @discardableResult func unref(free: Bool) -> UInt16
    func get_ref() -> UInt16

    func set_visible(_ visible: Bool) -> Tvg_Result
    func get_visible() -> Bool

    func scale(_ factor: Float) -> Tvg_Result
    func scale<F: BinaryFloatingPoint>(_ factor: F) -> Tvg_Result
    func rotate(_ degree: Float) -> Tvg_Result
    func rotate<F: BinaryFloatingPoint>(_ degree: F) -> Tvg_Result
    func translate(x: Float, y: Float) -> Tvg_Result
    func translate<F: BinaryFloatingPoint>(x: F, y: F) -> Tvg_Result
    func translate(_ pos: SIMD2<Float>) -> Tvg_Result
    func translate<F: BinaryFloatingPoint & SIMDScalar>(_ pos: SIMD2<F>) -> Tvg_Result

    func set_transform(_ m: Tvg_Matrix) -> Tvg_Result
    func get_transform() -> Tvg_Matrix

    func set_opacity(_ opacity: UInt8) -> Tvg_Result
    func get_opacity() -> UInt8

    func duplicate() -> Tvg_Paint?

    func intersects(x: Int32, y: Int32, w: Int32, h: Int32) -> Bool
    func get_aabb() -> (x: Float, y: Float, w: Float, h: Float)
    func get_obb() -> [Tvg_Point]

    func set_mask_method(target: Tvg_Paint, method: Tvg_Mask_Method) -> Tvg_Result
    func get_mask_method(target: Tvg_Paint) -> Tvg_Mask_Method

    func set_clip(_ clipper: Tvg_Paint) -> Tvg_Result
    func get_clip() -> Tvg_Paint?
    func get_parent() -> Tvg_Paint?

    func get_type() -> Tvg_Type
    func set_blend_method(_ method: Tvg_Blend_Method) -> Tvg_Result
}

public extension ThorPaint {

    // uint16_t   tvg_paint_ref(Tvg_Paint paint)
    // uint16_t   tvg_paint_unref(Tvg_Paint paint, bint free)
    // uint16_t   tvg_paint_get_ref(const Tvg_Paint paint)
    // Tvg_Result tvg_paint_set_visible(Tvg_Paint paint, bint visible)
    // bint       tvg_paint_get_visible(const Tvg_Paint paint)
    // Tvg_Result tvg_paint_scale(Tvg_Paint paint, float factor)
    // Tvg_Result tvg_paint_rotate(Tvg_Paint paint, float degree)
    // Tvg_Result tvg_paint_translate(Tvg_Paint paint, float x, float y)
    // Tvg_Result tvg_paint_set_transform(Tvg_Paint paint, const Tvg_Matrix* m)
    // Tvg_Result tvg_paint_get_transform(Tvg_Paint paint, Tvg_Matrix* m)
    // Tvg_Result tvg_paint_set_opacity(Tvg_Paint paint, uint8_t opacity)
    // Tvg_Result tvg_paint_get_opacity(const Tvg_Paint paint, uint8_t* opacity)
    // Tvg_Paint  tvg_paint_duplicate(Tvg_Paint paint)
    // bint       tvg_paint_intersects(Tvg_Paint paint, int32_t x, int32_t y, int32_t w, int32_t h)
    // Tvg_Result tvg_paint_get_aabb(Tvg_Paint paint, float* x, float* y, float* w, float* h)
    // Tvg_Result tvg_paint_get_obb(Tvg_Paint paint, Tvg_Point* pt4)
    // Tvg_Result tvg_paint_set_mask_method(Tvg_Paint paint, Tvg_Paint target, Tvg_Mask_Method method)
    // Tvg_Result tvg_paint_get_mask_method(const Tvg_Paint paint, const Tvg_Paint target, Tvg_Mask_Method* method)
    // Tvg_Result tvg_paint_set_clip(Tvg_Paint paint, Tvg_Paint clipper)
    // Tvg_Paint  tvg_paint_get_clip(const Tvg_Paint paint)
    // Tvg_Paint  tvg_paint_get_parent(const Tvg_Paint paint)
    // Tvg_Result tvg_paint_get_type(const Tvg_Paint paint, Tvg_Type* type)
    // Tvg_Result tvg_paint_set_blend_method(Tvg_Paint paint, Tvg_Blend_Method method)

    @discardableResult func ref() -> UInt16 { tvg_paint_ref(base) }
    @discardableResult func unref(free: Bool = false) -> UInt16 { tvg_paint_unref(base, free) }
    func get_ref() -> UInt16 { tvg_paint_get_ref(base) }

    func set_visible(_ visible: Bool) -> Tvg_Result { tvg_paint_set_visible(base, visible) }
    func get_visible() -> Bool { tvg_paint_get_visible(base) }

    func scale(_ factor: Float) -> Tvg_Result { tvg_paint_scale(base, factor) }
    func scale<F: BinaryFloatingPoint>(_ factor: F) -> Tvg_Result { tvg_paint_scale(base, .init(factor)) }
    func rotate(_ degree: Float) -> Tvg_Result { tvg_paint_rotate(base, degree) }
    func rotate<F: BinaryFloatingPoint>(_ degree: F) -> Tvg_Result { tvg_paint_rotate(base, .init(degree)) }
    func translate(x: Float, y: Float) -> Tvg_Result { tvg_paint_translate(base, x, y) }
    func translate<F: BinaryFloatingPoint>(x: F, y: F) -> Tvg_Result { tvg_paint_translate(base, .init(x), .init(y)) }
    func translate(_ pos: SIMD2<Float>) -> Tvg_Result { tvg_paint_translate(base, pos.x, pos.y) }
    func translate<F: BinaryFloatingPoint & SIMDScalar>(_ pos: SIMD2<F>) -> Tvg_Result { tvg_paint_translate(base, .init(pos.x), .init(pos.y)) }

    func set_transform(_ m: Tvg_Matrix) -> Tvg_Result {
        var m = m
        return tvg_paint_set_transform(base, &m)
    }
    func get_transform() -> Tvg_Matrix {
        var m = Tvg_Matrix()
        tvg_paint_get_transform(base, &m)
        return m
    }

    func set_opacity(_ opacity: UInt8) -> Tvg_Result { tvg_paint_set_opacity(base, opacity) }
    func get_opacity() -> UInt8 {
        var opacity: UInt8 = 255
        tvg_paint_get_opacity(base, &opacity)
        return opacity
    }

    func duplicate() -> Tvg_Paint? { tvg_paint_duplicate(base) }

    func intersects(x: Int32, y: Int32, w: Int32, h: Int32) -> Bool { tvg_paint_intersects(base, x, y, w, h) }
    func get_aabb() -> (x: Float, y: Float, w: Float, h: Float) {
        var x: Float = 0, y: Float = 0, w: Float = 0, h: Float = 0
        tvg_paint_get_aabb(base, &x, &y, &w, &h)
        return (x, y, w, h)
    }
    func get_obb() -> [Tvg_Point] {
        var pts = [Tvg_Point](repeating: Tvg_Point(), count: 4)
        tvg_paint_get_obb(base, &pts)
        return pts
    }

    func set_mask_method(target: Tvg_Paint, method: Tvg_Mask_Method) -> Tvg_Result { tvg_paint_set_mask_method(base, target, method) }
    func get_mask_method(target: Tvg_Paint) -> Tvg_Mask_Method {
        var method = TVG_MASK_METHOD_NONE
        tvg_paint_get_mask_method(base, target, &method)
        return method
    }

    func set_clip(_ clipper: Tvg_Paint) -> Tvg_Result { tvg_paint_set_clip(base, clipper) }
    func get_clip() -> Tvg_Paint? { tvg_paint_get_clip(base) }
    func get_parent() -> Tvg_Paint? { tvg_paint_get_parent(base) }

    func get_type() -> Tvg_Type {
        var type = TVG_TYPE_UNDEF
        tvg_paint_get_type(base, &type)
        return type
    }
    func set_blend_method(_ method: Tvg_Blend_Method) -> Tvg_Result { tvg_paint_set_blend_method(base, method) }
}

