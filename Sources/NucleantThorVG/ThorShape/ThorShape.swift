//
//  ThorShape.swift
//  thorvg-pyswiftkit
//
import CThorVG
// import simd — SIMD2/SIMDScalar are Swift-stdlib builtins now; unneeded
// unless/until this file starts using simd's math ops.

public protocol ThorShape: ThorPaint {
    var base: Tvg_Paint { get set }
    
    func addTo<C: ThorCanvas>(canvas: C) -> Tvg_Result
    
    
}

extension ThorShape {
    public func addTo<C: ThorCanvas>(canvas: C) -> Tvg_Result {
        canvas.add(shape: self)
    }
}

public extension ThorShape {
    func reset() -> Tvg_Result { tvg_shape_reset(base) }
    
    // move_to
    func move_to(x: Float, y: Float) -> Tvg_Result { tvg_shape_move_to(base, x, y) }
    func move_to<F>(x: F, y: F) -> Tvg_Result where F: BinaryFloatingPoint { tvg_shape_move_to(base, .init(x), .init(y)) }
    func move_to<I>(x: I, y: I) -> Tvg_Result where I: BinaryInteger { tvg_shape_move_to(base, .init(x), .init(y)) }
    func move_to(pos: SIMD2<Float>) -> Tvg_Result { tvg_shape_move_to(base, pos.x, pos.y) }
    func move_to<F: BinaryFloatingPoint & SIMDScalar>(pos: SIMD2<F>) -> Tvg_Result { tvg_shape_move_to(base, .init(pos.x), .init(pos.y)) }
    
    func line_to(x: Float, y: Float) -> Tvg_Result { tvg_shape_line_to(base, x, y) }
    func line_to<F>(x: F, y: F) -> Tvg_Result where F: BinaryFloatingPoint { tvg_shape_line_to(base, .init(x), .init(y)) }
    func line_to(pos: SIMD2<Float>) -> Tvg_Result { tvg_shape_line_to(base, pos.x, pos.y) }
    func line_to<F: BinaryFloatingPoint & SIMDScalar>(pos: SIMD2<F>) -> Tvg_Result { tvg_shape_line_to(base, .init(pos.x), .init(pos.y)) }
    
    func cubic_to(cx1: Float, cy1: Float, cx2: Float, cy2: Float, x: Float, y: Float) -> Tvg_Result { tvg_shape_cubic_to(base, cx1, cy1, cx2, cy2, x, y) }
    func cubic_to<F>(cx1: F, cy1: F, cx2: F, cy2: F, x: F, y: F) -> Tvg_Result where F: BinaryFloatingPoint { tvg_shape_cubic_to(base, .init(cx1), .init(cy1), .init(cx2), .init(cy2), .init(x), .init(y)) }
    func cubic_to(cp1: SIMD2<Float>, cp2: SIMD2<Float>, to pos: SIMD2<Float>) -> Tvg_Result { tvg_shape_cubic_to(base, cp1.x, cp1.y, cp2.x, cp2.y, pos.x, pos.y) }
    func cubic_to<F: BinaryFloatingPoint & SIMDScalar>(cp1: SIMD2<F>, cp2: SIMD2<F>, to pos: SIMD2<F>) -> Tvg_Result { tvg_shape_cubic_to(base, .init(cp1.x), .init(cp1.y), .init(cp2.x), .init(cp2.y), .init(pos.x), .init(pos.y)) }

    // from thorvg-cython but is same layout
    //     Tvg_Paint  tvg_shape_new()
    //     Tvg_Result tvg_shape_cubic_to(Tvg_Paint paint, float cx1, float cy1, float cx2, float cy2, float x, float y)
    //     Tvg_Result tvg_shape_close(Tvg_Paint paint)
    //     Tvg_Result tvg_shape_append_rect(Tvg_Paint paint, float x, float y, float w, float h, float rx, float ry, bint cw)
    //     Tvg_Result tvg_shape_append_circle(Tvg_Paint paint, float cx, float cy, float rx, float ry, bint cw)
    //     Tvg_Result tvg_shape_append_path(Tvg_Paint paint, const Tvg_Path_Command* cmds, uint32_t cmdCnt, const Tvg_Point* pts, uint32_t ptsCnt)
    //     Tvg_Result tvg_shape_get_path(const Tvg_Paint paint, const Tvg_Path_Command** cmds, uint32_t* cmdsCnt, const Tvg_Point** pts, uint32_t* ptsCnt)
    //     Tvg_Result tvg_shape_set_stroke_width(Tvg_Paint paint, float width)
    //     Tvg_Result tvg_shape_get_stroke_width(const Tvg_Paint paint, float* width)
    //     Tvg_Result tvg_shape_set_stroke_color(Tvg_Paint paint, uint8_t r, uint8_t g, uint8_t b, uint8_t a)
    //     Tvg_Result tvg_shape_get_stroke_color(const Tvg_Paint paint, uint8_t* r, uint8_t* g, uint8_t* b, uint8_t* a)
    //     Tvg_Result tvg_shape_set_stroke_gradient(Tvg_Paint paint, Tvg_Gradient grad)
    //     Tvg_Result tvg_shape_get_stroke_gradient(const Tvg_Paint paint, Tvg_Gradient* grad)
    //     Tvg_Result tvg_shape_set_stroke_dash(Tvg_Paint paint, const float* dashPattern, uint32_t cnt, float offset)
    //     Tvg_Result tvg_shape_get_stroke_dash(const Tvg_Paint paint, const float** dashPattern, uint32_t* cnt, float* offset)
    //     Tvg_Result tvg_shape_set_stroke_cap(Tvg_Paint paint, Tvg_Stroke_Cap cap)
    //     Tvg_Result tvg_shape_get_stroke_cap(const Tvg_Paint paint, Tvg_Stroke_Cap* cap)
    //     Tvg_Result tvg_shape_set_stroke_join(Tvg_Paint paint, Tvg_Stroke_Join join)
    //     Tvg_Result tvg_shape_get_stroke_join(const Tvg_Paint paint, Tvg_Stroke_Join* join)
    //     Tvg_Result tvg_shape_set_stroke_miterlimit(Tvg_Paint paint, float miterlimit)
    //     Tvg_Result tvg_shape_get_stroke_miterlimit(const Tvg_Paint paint, float* miterlimit)
    //     Tvg_Result tvg_shape_set_trimpath(Tvg_Paint paint, float begin, float end, bint simultaneous)
    //     Tvg_Result tvg_shape_set_fill_color(Tvg_Paint paint, uint8_t r, uint8_t g, uint8_t b, uint8_t a)
    //     Tvg_Result tvg_shape_get_fill_color(const Tvg_Paint paint, uint8_t* r, uint8_t* g, uint8_t* b, uint8_t* a)
    //     Tvg_Result tvg_shape_set_fill_rule(Tvg_Paint paint, Tvg_Fill_Rule rule)
    //     Tvg_Result tvg_shape_get_fill_rule(const Tvg_Paint paint, Tvg_Fill_Rule* rule)
    //     Tvg_Result tvg_shape_set_paint_order(Tvg_Paint paint, bint strokeFirst)
    //     Tvg_Result tvg_shape_set_gradient(Tvg_Paint paint, Tvg_Gradient grad)
    //     Tvg_Result tvg_shape_get_gradient(const Tvg_Paint paint, Tvg_Gradient* grad)

    // close
    func close() -> Tvg_Result { tvg_shape_close(base) }

    // append_rect
    func append_rect(x: Float, y: Float, w: Float, h: Float, rx: Float = 0, ry: Float = 0, cw: Bool = true) -> Tvg_Result { tvg_shape_append_rect(base, x, y, w, h, rx, ry, cw) }
    func append_rect<F: BinaryFloatingPoint>(x: F, y: F, w: F, h: F, rx: F = 0, ry: F = 0, cw: Bool = true) -> Tvg_Result { tvg_shape_append_rect(base, .init(x), .init(y), .init(w), .init(h), .init(rx), .init(ry), cw) }
    func append_rect(pos: SIMD2<Float>, size: SIMD2<Float>, radius: SIMD2<Float> = .zero, cw: Bool = true) -> Tvg_Result { tvg_shape_append_rect(base, pos.x, pos.y, size.x, size.y, radius.x, radius.y, cw) }
    func append_rect<F: BinaryFloatingPoint & SIMDScalar>(pos: SIMD2<F>, size: SIMD2<F>, radius: SIMD2<F> = .zero, cw: Bool = true) -> Tvg_Result { tvg_shape_append_rect(base, .init(pos.x), .init(pos.y), .init(size.x), .init(size.y), .init(radius.x), .init(radius.y), cw) }

    // append_circle
    func append_circle(cx: Float, cy: Float, rx: Float, ry: Float, cw: Bool = true) -> Tvg_Result { tvg_shape_append_circle(base, cx, cy, rx, ry, cw) }
    func append_circle<F: BinaryFloatingPoint>(cx: F, cy: F, rx: F, ry: F, cw: Bool = true) -> Tvg_Result { tvg_shape_append_circle(base, .init(cx), .init(cy), .init(rx), .init(ry), cw) }
    func append_circle(center: SIMD2<Float>, radius: SIMD2<Float>, cw: Bool = true) -> Tvg_Result { tvg_shape_append_circle(base, center.x, center.y, radius.x, radius.y, cw) }
    func append_circle(center: SIMD2<Float>, radius: Float, cw: Bool = true) -> Tvg_Result { tvg_shape_append_circle(base, center.x, center.y, radius, radius, cw) }
    func append_circle<F: BinaryFloatingPoint & SIMDScalar>(center: SIMD2<F>, radius: SIMD2<F>, cw: Bool = true) -> Tvg_Result { tvg_shape_append_circle(base, .init(center.x), .init(center.y), .init(radius.x), .init(radius.y), cw) }
    func append_circle<F: BinaryFloatingPoint & SIMDScalar>(center: SIMD2<F>, radius: F, cw: Bool = true) -> Tvg_Result { tvg_shape_append_circle(base, .init(center.x), .init(center.y), .init(radius), .init(radius), cw) }

    // append_path
    func append_path(cmds: [Tvg_Path_Command], pts: [Tvg_Point]) -> Tvg_Result {
        cmds.withUnsafeBufferPointer { cmdsPtr in
            pts.withUnsafeBufferPointer { ptsPtr in
                tvg_shape_append_path(base, cmdsPtr.baseAddress, UInt32(cmds.count), ptsPtr.baseAddress, UInt32(pts.count))
            }
        }
    }

    // get_path
    func get_path() -> (cmds: [Tvg_Path_Command], pts: [Tvg_Point]) {
        var cmdsPtr: UnsafePointer<Tvg_Path_Command>? = nil
        var cmdsCnt: UInt32 = 0
        var ptsPtr: UnsafePointer<Tvg_Point>? = nil
        var ptsCnt: UInt32 = 0
        tvg_shape_get_path(base, &cmdsPtr, &cmdsCnt, &ptsPtr, &ptsCnt)
        let cmds = cmdsPtr.map { Array(UnsafeBufferPointer(start: $0, count: Int(cmdsCnt))) } ?? []
        let pts  = ptsPtr.map  { Array(UnsafeBufferPointer(start: $0, count: Int(ptsCnt)))  } ?? []
        return (cmds, pts)
    }

    // stroke width
    func set_stroke_width(_ width: Float) -> Tvg_Result { tvg_shape_set_stroke_width(base, width) }
    func set_stroke_width<F: BinaryFloatingPoint>(_ width: F) -> Tvg_Result { tvg_shape_set_stroke_width(base, .init(width)) }
    func set_stroke_width<I: BinaryInteger>(_ width: I) -> Tvg_Result { tvg_shape_set_stroke_width(base, .init(width)) }
    func get_stroke_width() -> Float {
        var width: Float = 0
        tvg_shape_get_stroke_width(base, &width)
        return width
    }

    // stroke color
    func set_stroke_color(r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255) -> Tvg_Result { tvg_shape_set_stroke_color(base, r, g, b, a) }
    func set_stroke_color(_ color: SIMD4<UInt8>) -> Tvg_Result { tvg_shape_set_stroke_color(base, color.x, color.y, color.z, color.w) }
    func set_stroke_color<F: BinaryFloatingPoint & SIMDScalar>(_ color: SIMD4<F>) -> Tvg_Result {
        tvg_shape_set_stroke_color(base, UInt8(color.x * 255), UInt8(color.y * 255), UInt8(color.z * 255), UInt8(color.w * 255))
    }
    
    func set_stroke_color<C: ThorColor>(_ color: C) -> Tvg_Result where C.Value: BinaryFloatingPoint {
        tvg_shape_set_stroke_color(base, UInt8(color.r * 255), UInt8(color.g * 255), UInt8(color.b * 255), UInt8(color.a * 255))
    }
        
    func set_stroke_color<C: ThorColor>(_ color: C) -> Tvg_Result where C.Value == UInt8 {
        tvg_shape_set_stroke_color(base, color.r, color.g, color.b, color.a)
    }

    func get_stroke_color() -> SIMD4<UInt8> {
        var r: UInt8 = 0, g: UInt8 = 0, b: UInt8 = 0, a: UInt8 = 0
        tvg_shape_get_stroke_color(base, &r, &g, &b, &a)
        return SIMD4(r, g, b, a)
    }
    func get_stroke_color<F: BinaryFloatingPoint & SIMDScalar>() -> SIMD4<F> {
        var r: UInt8 = 0, g: UInt8 = 0, b: UInt8 = 0, a: UInt8 = 0
        tvg_shape_get_stroke_color(base, &r, &g, &b, &a)
        return SIMD4(F(r) / 255, F(g) / 255, F(b) / 255, F(a) / 255)
    }

    // stroke gradient
    func set_stroke_gradient(_ grad: Tvg_Gradient) -> Tvg_Result { tvg_shape_set_stroke_gradient(base, grad) }
    func get_stroke_gradient() -> Tvg_Gradient? {
        var grad: Tvg_Gradient? = nil
        tvg_shape_get_stroke_gradient(base, &grad)
        return grad
    }

    // stroke dash
    func set_stroke_dash(_ pattern: [Float], offset: Float = 0) -> Tvg_Result {
        pattern.withUnsafeBufferPointer { ptr in
            tvg_shape_set_stroke_dash(base, ptr.baseAddress, UInt32(pattern.count), offset)
        }
    }
    func get_stroke_dash() -> (pattern: [Float], offset: Float) {
        var ptr: UnsafePointer<Float>? = nil
        var cnt: UInt32 = 0
        var offset: Float = 0
        tvg_shape_get_stroke_dash(base, &ptr, &cnt, &offset)
        return (ptr.map { Array(UnsafeBufferPointer(start: $0, count: Int(cnt))) } ?? [], offset)
    }

    // stroke cap
    func set_stroke_cap(_ cap: Tvg_Stroke_Cap) -> Tvg_Result { tvg_shape_set_stroke_cap(base, cap) }
    func get_stroke_cap() -> Tvg_Stroke_Cap {
        var cap = TVG_STROKE_CAP_BUTT
        tvg_shape_get_stroke_cap(base, &cap)
        return cap
    }

    // stroke join
    func set_stroke_join(_ join: Tvg_Stroke_Join) -> Tvg_Result { tvg_shape_set_stroke_join(base, join) }
    func get_stroke_join() -> Tvg_Stroke_Join {
        var join = TVG_STROKE_JOIN_MITER
        tvg_shape_get_stroke_join(base, &join)
        return join
    }

    // stroke miterlimit
    func set_stroke_miterlimit(_ miterlimit: Float) -> Tvg_Result { tvg_shape_set_stroke_miterlimit(base, miterlimit) }
    func set_stroke_miterlimit<F: BinaryFloatingPoint>(_ miterlimit: F) -> Tvg_Result { tvg_shape_set_stroke_miterlimit(base, .init(miterlimit)) }
    func set_stroke_miterlimit<I: BinaryInteger>(_ miterlimit: I) -> Tvg_Result { tvg_shape_set_stroke_miterlimit(base, .init(miterlimit)) }
    func get_stroke_miterlimit() -> Float {
        var ml: Float = 0
        tvg_shape_get_stroke_miterlimit(base, &ml)
        return ml
    }

    // trimpath
    func set_trimpath(begin: Float, end: Float, simultaneous: Bool = true) -> Tvg_Result { tvg_shape_set_trimpath(base, begin, end, simultaneous) }
    func set_trimpath<F: BinaryFloatingPoint>(begin: F, end: F, simultaneous: Bool = true) -> Tvg_Result { tvg_shape_set_trimpath(base, .init(begin), .init(end), simultaneous) }

    // fill color
    func set_fill_color(r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255) -> Tvg_Result { tvg_shape_set_fill_color(base, r, g, b, a) }
    func set_fill_color(_ color: SIMD4<UInt8>) -> Tvg_Result { tvg_shape_set_fill_color(base, color.x, color.y, color.z, color.w) }
    func set_fill_color<F: BinaryFloatingPoint & SIMDScalar>(_ color: SIMD4<F>) -> Tvg_Result { tvg_shape_set_fill_color(base, UInt8(color.x * 255), UInt8(color.y * 255), UInt8(color.z * 255), UInt8(color.w * 255)) }
    
    func set_fill_color<C: ThorColor>(_ color: C) -> Tvg_Result where C.Value: BinaryFloatingPoint {
        tvg_shape_set_fill_color(base, UInt8(color.r * 255), UInt8(color.g * 255), UInt8(color.b * 255), UInt8(color.a * 255))
    }
    
    func set_fill_color<C: ThorColor>(_ color: C) -> Tvg_Result where C.Value == UInt8 {
        tvg_shape_set_fill_color(base, color.r, color.g, color.b, color.a)
    }
    
    func get_fill_color() -> SIMD4<UInt8> {
        var r: UInt8 = 0, g: UInt8 = 0, b: UInt8 = 0, a: UInt8 = 0
        tvg_shape_get_fill_color(base, &r, &g, &b, &a)
        return SIMD4(r, g, b, a)
    }
    func get_fill_color<F: BinaryFloatingPoint & SIMDScalar>() -> SIMD4<F> {
        var r: UInt8 = 0, g: UInt8 = 0, b: UInt8 = 0, a: UInt8 = 0
        tvg_shape_get_fill_color(base, &r, &g, &b, &a)
        return SIMD4(F(r) / 255, F(g) / 255, F(b) / 255, F(a) / 255)
    }

    // fill rule
    func set_fill_rule(_ rule: Tvg_Fill_Rule) -> Tvg_Result { tvg_shape_set_fill_rule(base, rule) }
    func get_fill_rule() -> Tvg_Fill_Rule {
        var rule = TVG_FILL_RULE_NON_ZERO
        tvg_shape_get_fill_rule(base, &rule)
        return rule
    }

    // paint order
    func set_paint_order(strokeFirst: Bool) -> Tvg_Result { tvg_shape_set_paint_order(base, strokeFirst) }

    // gradient
    func set_gradient(_ grad: Tvg_Gradient) -> Tvg_Result { tvg_shape_set_gradient(base, grad) }
    func get_gradient() -> Tvg_Gradient? {
        var grad: Tvg_Gradient? = nil
        tvg_shape_get_gradient(base, &grad)
        return grad
    }
}

