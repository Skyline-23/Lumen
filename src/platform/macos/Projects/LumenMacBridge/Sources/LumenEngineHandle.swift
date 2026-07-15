import Foundation

/// Owns a Rust/C allocation without allowing its raw pointer to cross an actor boundary.
final class LumenEngineHandle: Sendable {
    typealias Destructor = @Sendable (OpaquePointer) -> Void

    private let address: UInt
    private let destructor: Destructor

    init(_ pointer: OpaquePointer, destructor: @escaping Destructor) {
        address = UInt(bitPattern: pointer)
        self.destructor = destructor
    }

    deinit {
        destructor(rawValue)
    }

    var rawValue: OpaquePointer {
        guard let pointer = OpaquePointer(bitPattern: address) else {
            preconditionFailure("Lumen engine handle lost its pointer value")
        }
        return pointer
    }
}
