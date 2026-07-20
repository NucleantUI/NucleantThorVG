//
//  ThorCanvas.swift
//  thorvg-pyswiftkit
//
import CThorVG

public protocol ThorCanvas {
    var base: Tvg_Canvas { get set }
    
    func add<S: ThorShape>(shape: S) -> Tvg_Result
    func add(shape: Tvg_Paint) -> Tvg_Result
    func add<T>(shapes: T) -> Tvg_Result where T: Sequence, T.Element: ThorShape
    func add<T>(shapes: T) -> Tvg_Result where T: Sequence, T.Element == Tvg_Paint
    
    func remove<S: ThorShape>(shape: S) -> Tvg_Result
    func remove(shape: Tvg_Paint) -> Tvg_Result
    func remove<T>(shapes: T) -> Tvg_Result where T: Sequence, T.Element: ThorShape
    func remove<T>(shapes: T) -> Tvg_Result where T: Sequence, T.Element == Tvg_Paint
    
    func insert<S: ThorShape, D: ThorShape>(shape: S, at target: D) -> Tvg_Result
    func insert<D: ThorShape>(shape: Tvg_Paint, at target: D) -> Tvg_Result
    func insert(shape: Tvg_Paint, at target: Tvg_Paint) -> Tvg_Result
    func insert<T, D: ThorShape>(shapes: T, at target: D) -> Tvg_Result where T: Sequence, T.Element: ThorShape
    func insert<T, D: ThorShape>(shapes: T, at target: D) -> Tvg_Result where T: Sequence, T.Element == Tvg_Paint
}


public extension ThorCanvas {
    
    func add<S: ThorShape>(shape: S) -> Tvg_Result {
        tvg_canvas_add(base, shape.base)
    }
    
    func add(shape: Tvg_Paint) -> Tvg_Result {
        tvg_canvas_add(base, shape)
    }
    
    func add<T>(shapes: T) -> Tvg_Result where T: Sequence, T.Element: ThorShape {
        for shape in shapes {
            tvg_canvas_add(base, shape.base)
        }
        return TVG_RESULT_SUCCESS
    }
    
    func add<T>(shapes: T) -> Tvg_Result where T: Sequence, T.Element == Tvg_Paint {
        for shape in shapes {
            tvg_canvas_add(base, shape)
        }
        return TVG_RESULT_SUCCESS
    }
    
    func remove<S: ThorShape>(shape: S) -> Tvg_Result {
        tvg_canvas_remove(base, shape.base)
    }
    
    
    public func remove(shape: Tvg_Paint) -> Tvg_Result {
        tvg_canvas_remove(base, shape)
    }
    
    func remove<T>(shapes: T) -> Tvg_Result where T: Sequence, T.Element: ThorShape {
        for shape in shapes {
            tvg_canvas_remove(base, shape.base)
        }
        return TVG_RESULT_SUCCESS
    }
    
    func remove<T>(shapes: T) -> Tvg_Result where T: Sequence, T.Element == Tvg_Paint {
        for shape in shapes {
            tvg_canvas_remove(base, shape)
        }
        
        return TVG_RESULT_SUCCESS
    }
    
    
    func insert<S: ThorShape, D: ThorShape>(shape: S, at target: D) -> Tvg_Result {
        tvg_canvas_insert(base, shape.base, target.base)
    }
    
    func insert<D: ThorShape>(shape: Tvg_Paint, at target: D) -> Tvg_Result {
        tvg_canvas_insert(base, shape, target.base)
    }

    
    func insert(shape: Tvg_Paint) -> Tvg_Result {
        tvg_canvas_add(base, shape)
    }
    
    func insert<T, D: ThorShape>(shapes: T, at target: D) -> Tvg_Result where T: Sequence, T.Element: ThorShape {
        for shape in shapes {
            tvg_canvas_insert(base, shape.base, target.base)
        }
        return TVG_RESULT_SUCCESS
    }
    
    func insert<T, D: ThorShape>(shapes: T, at target: D) -> Tvg_Result where T: Sequence, T.Element == Tvg_Paint {
        for shape in shapes {
            tvg_canvas_insert(base, shape, target.base)
        }
        return TVG_RESULT_SUCCESS
    }
    
    public func insert(shape: Tvg_Paint, at target: Tvg_Paint) -> Tvg_Result {
        tvg_canvas_insert(base, shape, target)
    }
    
    public func draw(clear: Bool = true) -> Tvg_Result {
        tvg_canvas_draw(base, clear)
    }
    
    public func update() -> Tvg_Result {
        tvg_canvas_update(base)
    }
    
    public func sync() -> Tvg_Result {
        tvg_canvas_sync(base)
    }
}







