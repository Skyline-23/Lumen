import Foundation

func lumenStringFromCString(_ characters: [CChar]) -> String {
    let bytes = characters.lazy.map { UInt8(bitPattern: $0) }.prefix { $0 != 0 }
    return String(decoding: bytes, as: UTF8.self)
}
