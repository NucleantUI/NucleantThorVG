//
//  TextProtocol.swift
//  SwiftyThorVG
//
import CThorVG
import simd

public protocol ThorText: ThorPaint {
    var base: Tvg_Paint { get set }

    func set_font(_ name: String) -> Tvg_Result
    func set_size(_ size: Float) -> Tvg_Result
    func set_size<F: BinaryFloatingPoint>(_ size: F) -> Tvg_Result
    func set_text(_ utf8: String) -> Tvg_Result
    func get_text() -> String

    func align(x: Float, y: Float) -> Tvg_Result
    func align<F: BinaryFloatingPoint>(x: F, y: F) -> Tvg_Result
    func align(_ pos: SIMD2<Float>) -> Tvg_Result
    func align<F: BinaryFloatingPoint & SIMDScalar>(_ pos: SIMD2<F>) -> Tvg_Result

    func layout(w: Float, h: Float) -> Tvg_Result
    func layout<F: BinaryFloatingPoint>(w: F, h: F) -> Tvg_Result
    func layout(_ size: SIMD2<Float>) -> Tvg_Result
    func layout<F: BinaryFloatingPoint & SIMDScalar>(_ size: SIMD2<F>) -> Tvg_Result

    func wrap_mode(_ mode: Tvg_Text_Wrap) -> Tvg_Result
    func line_count() -> UInt32

    func spacing(letter: Float, line: Float) -> Tvg_Result
    func spacing<F: BinaryFloatingPoint>(letter: F, line: F) -> Tvg_Result

    func set_italic(_ shear: Float) -> Tvg_Result
    func set_italic<F: BinaryFloatingPoint>(_ shear: F) -> Tvg_Result

    func set_outline(width: Float, r: UInt8, g: UInt8, b: UInt8) -> Tvg_Result
    func set_outline(width: Float, _ color: SIMD4<UInt8>) -> Tvg_Result
    func set_outline<F: BinaryFloatingPoint>(width: F, r: UInt8, g: UInt8, b: UInt8) -> Tvg_Result

    func set_color(r: UInt8, g: UInt8, b: UInt8) -> Tvg_Result
    func set_color(_ color: SIMD4<UInt8>) -> Tvg_Result

    func set_gradient(_ grad: Tvg_Gradient) -> Tvg_Result
    func get_text_metrics() -> Tvg_Text_Metrics
}

public extension ThorText {

    // Tvg_Result tvg_text_set_font(Tvg_Paint paint, const char* name)
    // Tvg_Result tvg_text_set_size(Tvg_Paint paint, float size)
    // Tvg_Result tvg_text_set_text(Tvg_Paint paint, const char* utf8)
    // const char* tvg_text_get_text(const Tvg_Paint text)
    // Tvg_Result tvg_text_align(Tvg_Paint paint, float x, float y)
    // Tvg_Result tvg_text_layout(Tvg_Paint paint, float w, float h)
    // Tvg_Result tvg_text_wrap_mode(Tvg_Paint paint, Tvg_Text_Wrap mode)
    // uint32_t   tvg_text_line_count(Tvg_Paint text)
    // Tvg_Result tvg_text_spacing(Tvg_Paint paint, float letter, float line)
    // Tvg_Result tvg_text_set_italic(Tvg_Paint paint, float shear)
    // Tvg_Result tvg_text_set_outline(Tvg_Paint paint, float width, uint8_t r, uint8_t g, uint8_t b)
    // Tvg_Result tvg_text_set_color(Tvg_Paint paint, uint8_t r, uint8_t g, uint8_t b)
    // Tvg_Result tvg_text_set_gradient(Tvg_Paint paint, Tvg_Gradient grad)
    // Tvg_Result tvg_text_get_text_metrics(const Tvg_Paint paint, Tvg_Text_Metrics* metrics)
    // Tvg_Result tvg_font_load(const char* path)
    // Tvg_Result tvg_font_load_data(const char* name, const char* data, uint32_t size, const char* mimetype, bint copy)
    // Tvg_Result tvg_font_unload(const char* path)

    func set_font(_ name: String) -> Tvg_Result { name.withCString { tvg_text_set_font(base, $0) } }

    func set_size(_ size: Float) -> Tvg_Result { tvg_text_set_size(base, size) }
    func set_size<F: BinaryFloatingPoint>(_ size: F) -> Tvg_Result { tvg_text_set_size(base, .init(size)) }

    func set_text(_ utf8: String) -> Tvg_Result { utf8.withCString { tvg_text_set_text(base, $0) } }
    func get_text() -> String { String(cString: tvg_text_get_text(base)) }

    func align(x: Float, y: Float) -> Tvg_Result { tvg_text_align(base, x, y) }
    func align<F: BinaryFloatingPoint>(x: F, y: F) -> Tvg_Result { tvg_text_align(base, .init(x), .init(y)) }
    func align(_ pos: SIMD2<Float>) -> Tvg_Result { tvg_text_align(base, pos.x, pos.y) }
    func align<F: BinaryFloatingPoint & SIMDScalar>(_ pos: SIMD2<F>) -> Tvg_Result { tvg_text_align(base, .init(pos.x), .init(pos.y)) }

    func layout(w: Float, h: Float) -> Tvg_Result { tvg_text_layout(base, w, h) }
    func layout<F: BinaryFloatingPoint>(w: F, h: F) -> Tvg_Result { tvg_text_layout(base, .init(w), .init(h)) }
    func layout(_ size: SIMD2<Float>) -> Tvg_Result { tvg_text_layout(base, size.x, size.y) }
    func layout<F: BinaryFloatingPoint & SIMDScalar>(_ size: SIMD2<F>) -> Tvg_Result { tvg_text_layout(base, .init(size.x), .init(size.y)) }

    func wrap_mode(_ mode: Tvg_Text_Wrap) -> Tvg_Result { tvg_text_wrap_mode(base, mode) }
    func line_count() -> UInt32 { tvg_text_line_count(base) }

    func spacing(letter: Float, line: Float) -> Tvg_Result { tvg_text_spacing(base, letter, line) }
    func spacing<F: BinaryFloatingPoint>(letter: F, line: F) -> Tvg_Result { tvg_text_spacing(base, .init(letter), .init(line)) }

    func set_italic(_ shear: Float) -> Tvg_Result { tvg_text_set_italic(base, shear) }
    func set_italic<F: BinaryFloatingPoint>(_ shear: F) -> Tvg_Result { tvg_text_set_italic(base, .init(shear)) }

    func set_outline(width: Float, r: UInt8, g: UInt8, b: UInt8) -> Tvg_Result { tvg_text_set_outline(base, width, r, g, b) }
    func set_outline(width: Float, _ color: SIMD4<UInt8>) -> Tvg_Result { tvg_text_set_outline(base, width, color.x, color.y, color.z) }
    func set_outline<F: BinaryFloatingPoint>(width: F, r: UInt8, g: UInt8, b: UInt8) -> Tvg_Result { tvg_text_set_outline(base, .init(width), r, g, b) }

    func set_color(r: UInt8, g: UInt8, b: UInt8) -> Tvg_Result { tvg_text_set_color(base, r, g, b) }
    func set_color(_ color: SIMD4<UInt8>) -> Tvg_Result { tvg_text_set_color(base, color.x, color.y, color.z) }

    func set_gradient(_ grad: Tvg_Gradient) -> Tvg_Result { tvg_text_set_gradient(base, grad) }

    func get_text_metrics() -> Tvg_Text_Metrics {
        var metrics = Tvg_Text_Metrics()
        tvg_text_get_text_metrics(base, &metrics)
        return metrics
    }
}

// font functions are free (not tied to a paint instance)
public func tvg_font_load_path(_ path: String) -> Tvg_Result { path.withCString { tvg_font_load($0) } }
public func tvg_font_unload_path(_ path: String) -> Tvg_Result { path.withCString { tvg_font_unload($0) } }
public func tvg_font_load_from_data(name: String, data: [UInt8], mimetype: String, copy: Bool = true) -> Tvg_Result {
    name.withCString { cName in
        data.withUnsafeBytes { buf in
            mimetype.withCString { cMime in
                tvg_font_load_data(cName, buf.baseAddress?.assumingMemoryBound(to: CChar.self), UInt32(data.count), cMime, copy)
            }
        }
    }
}

