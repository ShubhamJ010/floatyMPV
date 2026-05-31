//
//  Atomic.swift
//  floatyMPV
//

import Foundation

/// A thread-safe property wrapper backed by `NSLock`.
///
/// Use for flags and values accessed from multiple threads in the
/// rendering or gesture pipelines. Keep usage minimal to avoid
/// lock contention.
@propertyWrapper
struct Atomic<Value> {
    private let lock = NSLock()
    private var value: Value

    var wrappedValue: Value {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }

    init(wrappedValue: Value) {
        self.value = wrappedValue
    }
}
