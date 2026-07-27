//
//  PictureProtocol.swift
//  SwiftyThorVG
//
import CThorVG
// import simd — SIMD2/SIMDScalar are Swift-stdlib builtins now; unneeded
// unless/until this file starts using simd's math ops.

public enum TvgMimeType: String {
    case svg
    case tvg
    case lottie
    case png
    case jpg
    case jpeg
    case webp
    
    /// Bruges hvis du vil have den fulde IANA-streng (valgfrit for ThorVG)
    public var fullMimeType: String {
        switch self {
        case .svg:    return "image/svg+xml"
        case .lottie: return "application/json"
        case .tvg:    return "application/octet-stream"
        case .png:    return "image/png"
        case .jpg, .jpeg: return "image/jpeg"
        case .webp:   return "image/webp"
        }
    }
}


public protocol ThorPicture: ThorPaint {
    var base: Tvg_Paint { get set }

    func load(path: String) -> Tvg_Result

    func load_raw(_ data: [UInt32], w: UInt32, h: UInt32, cs: Tvg_Colorspace, copy: Bool) -> Tvg_Result
    func load_raw(_ data: [UInt32], size: SIMD2<UInt32>, cs: Tvg_Colorspace, copy: Bool) -> Tvg_Result

    func load_data(_ data: [UInt8], mimetype: TvgMimeType, rpath: String?, copy: Bool) -> Tvg_Result
    func load_data(_ string: String, mimetype: TvgMimeType, rpath: String?, copy: Bool) -> Tvg_Result

    func set_size(w: Float, h: Float) -> Tvg_Result
    func set_size<F: BinaryFloatingPoint>(w: F, h: F) -> Tvg_Result
    func set_size<I: BinaryInteger>(w: I, h: I) -> Tvg_Result
    func set_size(_ size: SIMD2<Float>) -> Tvg_Result
    func set_size<F: BinaryFloatingPoint & SIMDScalar>(_ size: SIMD2<F>) -> Tvg_Result
    func get_size() -> SIMD2<Float>
    func get_size<F: BinaryFloatingPoint & SIMDScalar>() -> SIMD2<F>

    func set_origin(x: Float, y: Float) -> Tvg_Result
    func set_origin<F: BinaryFloatingPoint>(x: F, y: F) -> Tvg_Result
    func set_origin<I: BinaryInteger>(x: I, y: I) -> Tvg_Result
    func set_origin(_ pos: SIMD2<Float>) -> Tvg_Result
    func set_origin<F: BinaryFloatingPoint & SIMDScalar>(_ pos: SIMD2<F>) -> Tvg_Result
    func get_origin() -> SIMD2<Float>
    func get_origin<F: BinaryFloatingPoint & SIMDScalar>() -> SIMD2<F>

    func get_paint(id: UInt32) -> Tvg_Paint?
}

public extension ThorPicture {

    // Tvg_Result tvg_picture_load(Tvg_Paint picture, const char* path)
    // Tvg_Result tvg_picture_load_raw(Tvg_Paint picture, const uint32_t* data, uint32_t w, uint32_t h, Tvg_Colorspace cs, bint copy)
    // Tvg_Result tvg_picture_load_data(Tvg_Paint picture, const char* data, uint32_t size, const char* mimetype, const char* rpath, bint copy)
    // Tvg_Result tvg_picture_set_size(Tvg_Paint picture, float w, float h)
    // Tvg_Result tvg_picture_get_size(const Tvg_Paint picture, float* w, float* h)
    // Tvg_Result tvg_picture_set_origin(Tvg_Paint picture, float x, float y)
    // Tvg_Result tvg_picture_get_origin(const Tvg_Paint picture, float* x, float* y)
    // Tvg_Paint  tvg_picture_get_paint(Tvg_Paint picture, uint32_t id)

    // load
    func load(path: String) -> Tvg_Result { tvg_picture_load(base, path) }

    // load_raw
    func load_raw(_ data: [UInt32], w: UInt32, h: UInt32, cs: Tvg_Colorspace = TVG_COLORSPACE_ARGB8888S, copy: Bool = true) -> Tvg_Result {
        data.withUnsafeBufferPointer { ptr in
            tvg_picture_load_raw(base, ptr.baseAddress, w, h, cs, copy)
        }
    }
    func load_raw(_ data: [UInt32], size: SIMD2<UInt32>, cs: Tvg_Colorspace = TVG_COLORSPACE_ARGB8888S, copy: Bool = true) -> Tvg_Result {
        data.withUnsafeBufferPointer { ptr in
            tvg_picture_load_raw(base, ptr.baseAddress, size.x, size.y, cs, copy)
        }
    }

    // load_data
    func load_data(_ data: [UInt8], mimetype: TvgMimeType, rpath: String? = nil, copy: Bool = true) -> Tvg_Result {
        data.withUnsafeBytes { buf in
            tvg_picture_load_data(base, buf.baseAddress?.assumingMemoryBound(to: CChar.self), UInt32(data.count), mimetype.rawValue, rpath, copy)
        }
    }
    func load_data(_ string: String, mimetype: TvgMimeType, rpath: String? = nil, copy: Bool = true) -> Tvg_Result {
        string.withCString { cStr in
            tvg_picture_load_data(base, cStr, UInt32(string.utf8.count), mimetype.rawValue, rpath, copy)
        }
    }

    // set_size / get_size
    func set_size(w: Float, h: Float) -> Tvg_Result { tvg_picture_set_size(base, w, h) }
    func set_size<F: BinaryFloatingPoint>(w: F, h: F) -> Tvg_Result { tvg_picture_set_size(base, .init(w), .init(h)) }
    func set_size<I: BinaryInteger>(w: I, h: I) -> Tvg_Result { tvg_picture_set_size(base, .init(w), .init(h)) }
    func set_size(_ size: SIMD2<Float>) -> Tvg_Result { tvg_picture_set_size(base, size.x, size.y) }
    func set_size<F: BinaryFloatingPoint & SIMDScalar>(_ size: SIMD2<F>) -> Tvg_Result { tvg_picture_set_size(base, .init(size.x), .init(size.y)) }
    func get_size() -> SIMD2<Float> {
        var w: Float = 0
        var h: Float = 0
        tvg_picture_get_size(base, &w, &h)
        return SIMD2(w, h)
    }
    func get_size<F: BinaryFloatingPoint & SIMDScalar>() -> SIMD2<F> {
        var w: Float = 0
        var h: Float = 0
        tvg_picture_get_size(base, &w, &h)
        return SIMD2(F(w), F(h))
    }

    // set_origin / get_origin
    func set_origin(x: Float, y: Float) -> Tvg_Result { tvg_picture_set_origin(base, x, y) }
    func set_origin<F: BinaryFloatingPoint>(x: F, y: F) -> Tvg_Result { tvg_picture_set_origin(base, .init(x), .init(y)) }
    func set_origin<I: BinaryInteger>(x: I, y: I) -> Tvg_Result { tvg_picture_set_origin(base, .init(x), .init(y)) }
    func set_origin(_ pos: SIMD2<Float>) -> Tvg_Result { tvg_picture_set_origin(base, pos.x, pos.y) }
    func set_origin<F: BinaryFloatingPoint & SIMDScalar>(_ pos: SIMD2<F>) -> Tvg_Result { tvg_picture_set_origin(base, .init(pos.x), .init(pos.y)) }
    func get_origin() -> SIMD2<Float> {
        var x: Float = 0
        var y: Float = 0
        tvg_picture_get_origin(base, &x, &y)
        return SIMD2(x, y)
    }
    func get_origin<F: BinaryFloatingPoint & SIMDScalar>() -> SIMD2<F> {
        var x: Float = 0
        var y: Float = 0
        tvg_picture_get_origin(base, &x, &y)
        return SIMD2(F(x), F(y))
    }

    // get_paint
    func get_paint(id: UInt32) -> Tvg_Paint? { tvg_picture_get_paint(base, id) }
}
