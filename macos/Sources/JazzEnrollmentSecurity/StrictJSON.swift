import Foundation

/// A structural JSON preflight that rejects duplicate object member names before Foundation
/// materializes them into a dictionary. JSONSerialization otherwise silently keeps one value,
/// which is unsafe at a signature and credential-routing boundary.
enum StrictJSON {
    static func hasUniqueObjectKeys(_ data: Data) -> Bool {
        var parser = Parser(bytes: Array(data))
        do {
            try parser.parseDocument()
            return true
        } catch {
            return false
        }
    }

    private struct Parser {
        enum ParseError: Error {
            case malformed
            case duplicateKey
            case tooDeep
        }

        let bytes: [UInt8]
        var index = 0

        mutating func parseDocument() throws {
            skipWhitespace()
            try parseValue(depth: 0)
            skipWhitespace()
            guard index == bytes.count else {
                throw ParseError.malformed
            }
        }

        private mutating func parseValue(depth: Int) throws {
            guard depth <= 128, let byte = current else {
                throw depth > 128 ? ParseError.tooDeep : ParseError.malformed
            }
            switch byte {
            case 0x7b:
                try parseObject(depth: depth + 1)
            case 0x5b:
                try parseArray(depth: depth + 1)
            case 0x22:
                _ = try parseString()
            case 0x74:
                try consumeLiteral([0x74, 0x72, 0x75, 0x65])
            case 0x66:
                try consumeLiteral([0x66, 0x61, 0x6c, 0x73, 0x65])
            case 0x6e:
                try consumeLiteral([0x6e, 0x75, 0x6c, 0x6c])
            case 0x2d, 0x30...0x39:
                try parseNumber()
            default:
                throw ParseError.malformed
            }
        }

        private mutating func parseObject(depth: Int) throws {
            try consume(0x7b)
            skipWhitespace()
            if consumeIfPresent(0x7d) {
                return
            }

            var keys = Set<String>()
            while true {
                guard current == 0x22 else {
                    throw ParseError.malformed
                }
                let key = try parseString()
                guard keys.insert(key).inserted else {
                    throw ParseError.duplicateKey
                }
                skipWhitespace()
                try consume(0x3a)
                skipWhitespace()
                try parseValue(depth: depth)
                skipWhitespace()
                if consumeIfPresent(0x7d) {
                    return
                }
                try consume(0x2c)
                skipWhitespace()
            }
        }

        private mutating func parseArray(depth: Int) throws {
            try consume(0x5b)
            skipWhitespace()
            if consumeIfPresent(0x5d) {
                return
            }
            while true {
                try parseValue(depth: depth)
                skipWhitespace()
                if consumeIfPresent(0x5d) {
                    return
                }
                try consume(0x2c)
                skipWhitespace()
            }
        }

        private mutating func parseString() throws -> String {
            let start = index
            try consume(0x22)
            while let byte = current {
                switch byte {
                case 0x22:
                    index += 1
                    let encoded = Data(bytes[start..<index])
                    guard let decoded = try? JSONDecoder().decode(String.self, from: encoded) else {
                        throw ParseError.malformed
                    }
                    return decoded
                case 0x5c:
                    index += 1
                    guard let escaped = current else {
                        throw ParseError.malformed
                    }
                    if escaped == 0x75 {
                        index += 1
                        for _ in 0..<4 {
                            guard let hex = current, Self.isHexDigit(hex) else {
                                throw ParseError.malformed
                            }
                            index += 1
                        }
                    } else {
                        guard [0x22, 0x2f, 0x5c, 0x62, 0x66, 0x6e, 0x72, 0x74]
                            .contains(escaped)
                        else {
                            throw ParseError.malformed
                        }
                        index += 1
                    }
                case 0x00...0x1f:
                    throw ParseError.malformed
                default:
                    index += 1
                }
            }
            throw ParseError.malformed
        }

        private mutating func parseNumber() throws {
            _ = consumeIfPresent(0x2d)
            guard let first = current else {
                throw ParseError.malformed
            }
            if first == 0x30 {
                index += 1
                if let next = current, (0x30...0x39).contains(next) {
                    throw ParseError.malformed
                }
            } else if (0x31...0x39).contains(first) {
                index += 1
                while let next = current, (0x30...0x39).contains(next) {
                    index += 1
                }
            } else {
                throw ParseError.malformed
            }

            if consumeIfPresent(0x2e) {
                try consumeDigits()
            }
            if current == 0x65 || current == 0x45 {
                index += 1
                if current == 0x2b || current == 0x2d {
                    index += 1
                }
                try consumeDigits()
            }
        }

        private mutating func consumeDigits() throws {
            guard let first = current, (0x30...0x39).contains(first) else {
                throw ParseError.malformed
            }
            repeat {
                index += 1
            } while current.map({ (0x30...0x39).contains($0) }) == true
        }

        private mutating func consumeLiteral(_ literal: [UInt8]) throws {
            guard
                index + literal.count <= bytes.count,
                Array(bytes[index..<(index + literal.count)]) == literal
            else {
                throw ParseError.malformed
            }
            index += literal.count
        }

        private mutating func consume(_ expected: UInt8) throws {
            guard consumeIfPresent(expected) else {
                throw ParseError.malformed
            }
        }

        private mutating func consumeIfPresent(_ expected: UInt8) -> Bool {
            guard current == expected else {
                return false
            }
            index += 1
            return true
        }

        private mutating func skipWhitespace() {
            while let byte = current, [0x20, 0x09, 0x0a, 0x0d].contains(byte) {
                index += 1
            }
        }

        private var current: UInt8? {
            index < bytes.count ? bytes[index] : nil
        }

        private static func isHexDigit(_ byte: UInt8) -> Bool {
            (0x30...0x39).contains(byte)
                || (0x41...0x46).contains(byte)
                || (0x61...0x66).contains(byte)
        }
    }
}
