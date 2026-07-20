//
//  AnimationProtocol.swift
//  SwiftyThorVG
//
import CThorVG


public protocol AnimationProtocol {
    var base: Tvg_Animation { get set }
    
    associatedtype Value: BinaryFloatingPoint
    
    var frame: Value { get set }
    var total_frame: Value { get }
    var duration: Value { get }
    var segment: Range<Value> { get set }
    
}

extension AnimationProtocol where Value == Float {
    public var frame: Float {
        get {
            var no: Float = 0
            tvg_animation_get_frame(base, &no)
            return no
        }
        set {
            tvg_animation_set_frame(base, newValue)
        }
    }
    
    public var total_frame: Float {
        var cnt: Float = 0
        tvg_animation_get_total_frame(base, &cnt)
        return cnt
    }
    
    public var duration: Float {
        var dur: Float = 0
        tvg_animation_get_duration(base, &dur)
        return dur
    }
    
    public var segment: Range<Float> {
        get {
            var start: Float = 0
            var end: Float = 0
            tvg_animation_get_segment(base, &start, &end)
            return start..<end
        }
        set {
            tvg_animation_set_segment(base, newValue.lowerBound, newValue.upperBound)
        }
    }
}
