//
//  ColorProtocol.swift
//  SwiftyThorVG
//


public protocol ThorColor: Hashable, Equatable {
    
    associatedtype Value: Hashable, Equatable, SIMDScalar
    
    var r: Value { get set }
    var g: Value { get set }
    var b: Value { get set }
    var a: Value { get set }
}

extension ThorColor {
    public func simdValue() -> SIMD4<Value> { .init(r, g, b, a) }
}


extension SIMD4: ThorColor where Scalar: Hashable & Equatable & SIMDScalar {
        
    public var r: Scalar {
        get { x }
        set { x = newValue }
    }
    public var g: Scalar {
        get { y }
        set { y = newValue }
    }
    public var b: Scalar {
        get { z }
        set { z = newValue }
    }
    public var a: Scalar {
        get { w }
        set { w = newValue }
    }
    
}
