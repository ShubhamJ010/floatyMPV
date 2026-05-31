//
//  MPVPointers.swift
//  floatyMPV
//

import Cocoa
import OpenGL.GL
import OpenGL.GL3

/// Looks up an OpenGL function pointer by name via the OpenGL framework bundle.
/// Required by mpv's OpenGL render context initialization.
func mpvGetOpenGLFunc(_ ctx: UnsafeMutableRawPointer?, _ name: UnsafePointer<Int8>?) -> UnsafeMutableRawPointer? {
    let symbolName: CFString = CFStringCreateWithCString(kCFAllocatorDefault, name, kCFStringEncodingASCII)
    guard let addr = CFBundleGetFunctionPointerForName(
        CFBundleGetBundleWithIdentifier("com.apple.opengl" as CFString),
        symbolName
    ) else {
        return nil
    }
    return addr
}

/// Callback invoked by mpv when a new video frame is available for rendering.
/// Bridges into the `ViewLayer` update cycle.
func mpvUpdateCallback(_ ctx: UnsafeMutableRawPointer?) {
    guard let ctx = ctx else { return }
    let layer: ViewLayer = bridge(ptr: ctx)
    layer.update()
}

/// Unsafe pointer bridging helpers for mpv C API callbacks.
/// These perform raw pointer conversions that are safe because mpv
/// guarantees the context pointer lifetime matches the associated object.

func bridge<T: AnyObject>(ptr: UnsafeRawPointer) -> T {
    return Unmanaged<T>.fromOpaque(ptr).takeUnretainedValue()
}

/// Creates a mutable raw pointer from an object reference for passing
/// to C callbacks that accept a `void *` context.
func mutableRawPointerOf<T: AnyObject>(obj: T) -> UnsafeMutableRawPointer {
    return UnsafeMutableRawPointer(Unmanaged.passUnretained(obj).toOpaque())
}
