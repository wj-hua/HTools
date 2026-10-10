import Foundation

/// Minimal, schema-less protobuf wire-format reader.
///
/// Antigravity CLI (agy) stores its conversation data as protobuf blobs inside SQLite
/// with no published .proto schema. This decodes the generic wire format (varint /
/// fixed64 / length-delimited / fixed32) and recursively treats length-delimited
/// fields as nested messages when they look like one, which is enough to pull out the
/// couple of fields we care about (token counts, a unix timestamp). Field numbers were
/// derived by cross-referencing the open-source project Piebald-AI/splitrail and
/// verified against real ~/.gemini/antigravity-cli data on this machine.
enum AgyWireType: UInt8 {
    case varint = 0
    case fixed64 = 1
    case lengthDelimited = 2
    case fixed32 = 5
}

struct AgyField {
    let number: Int
    let wire: AgyWireType
    var varint: UInt64 = 0
    var bytes: Data = Data()
    var nested: [AgyField]?
}

enum AgyProtoReader {
    private static let maxDepth = 32

    static func parse(_ data: Data) -> [AgyField]? {
        parse(data, depth: 0)
    }

    private static func parse(_ data: Data, depth: Int) -> [AgyField]? {
        guard depth <= maxDepth else { return nil }
        var fields: [AgyField] = []
        var index = data.startIndex
        let end = data.endIndex

        while index < end {
            guard let (tag, afterTag) = readVarint(data, from: index) else { return nil }
            index = afterTag
            let number = Int(tag >> 3)
            // Wire types 3/4 (deprecated start/end group) or anything unrecognized: bail out.
            guard number > 0, let wire = AgyWireType(rawValue: UInt8(tag & 0x7)) else {
                return nil
            }

            var field = AgyField(number: number, wire: wire)
            switch wire {
            case .varint:
                guard let (v, next) = readVarint(data, from: index) else { return nil }
                field.varint = v
                index = next
            case .fixed64:
                guard data.distance(from: index, to: end) >= 8 else { return nil }
                field.bytes = data.subdata(in: index..<data.index(index, offsetBy: 8))
                index = data.index(index, offsetBy: 8)
            case .fixed32:
                guard data.distance(from: index, to: end) >= 4 else { return nil }
                field.bytes = data.subdata(in: index..<data.index(index, offsetBy: 4))
                index = data.index(index, offsetBy: 4)
            case .lengthDelimited:
                guard let (length, next) = readVarint(data, from: index) else { return nil }
                // A total-length varint that overflows Int is either corrupt data or an
                // unknown encoding; bail out instead of trapping in Int(length).
                guard length <= UInt64(Int.max) else { return nil }
                let len = Int(length)
                guard len >= 0, data.distance(from: next, to: end) >= len else { return nil }
                let sliceEnd = data.index(next, offsetBy: len)
                field.bytes = data.subdata(in: next..<sliceEnd)
                index = sliceEnd
                if let nested = parse(field.bytes, depth: depth + 1), looksLikeMessage(nested) {
                    field.nested = nested
                }
            }
            fields.append(field)
        }
        return fields
    }

    private static func looksLikeMessage(_ fields: [AgyField]) -> Bool {
        guard !fields.isEmpty else { return false }
        return fields.allSatisfy { $0.number > 0 && $0.number <= 100_000 }
    }

    private static func readVarint(_ data: Data, from start: Data.Index) -> (UInt64, Data.Index)? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        var index = start
        while index < data.endIndex {
            let byte = data[index]
            value |= UInt64(byte & 0x7F) << shift
            index = data.index(after: index)
            if byte & 0x80 == 0 { return (value, index) }
            shift += 7
            if shift >= 64 { return nil }
        }
        return nil
    }

    static func string(_ field: AgyField) -> String? {
        guard field.wire == .lengthDelimited else { return nil }
        return String(data: field.bytes, encoding: .utf8)
    }

    static func first(_ fields: [AgyField], number: Int) -> AgyField? {
        fields.first { $0.number == number }
    }
}
