#if !os(iOS)   // see main.swift: the console tool runs on macOS and Linux
import BleatKit

/// A QR code encoder in plain Swift, for the platforms without CoreImage.
///
/// Ported from Project Nayuki's QR Code generator (MIT licence,
/// https://www.nayuki.io/page/qr-code-generator-library), cut down to what
/// pairing needs: **byte mode only**, a caller-chosen correction level that is
/// never boosted, and the smallest version that fits. A `bleat://` URL is
/// lowercase and punctuated, so it would encode in byte mode anyway.
///
/// **Linux uses it; macOS keeps `CIQRCodeGenerator`.** It compiles on macOS
/// deliberately and without a platform branch, so the test suite can hold it
/// against CoreImage module for module — the only place an oracle exists. The
/// iOS app never links `BleatProcess`, so none of this ships in it.
///
/// The matrix it returns has **no quiet zone**; `QRCodeGenerator` adds it, the
/// way it pads CoreImage's single module.
public enum QREncoder {

    public enum Correction: Int, Sendable, CaseIterable {
        // The order is the index into the tables below; `formatBits` is the
        // value the spec writes into the symbol, which is a different order.
        case low, medium, quartile, high

        var formatBits: Int {
            switch self {
            case .low: 1
            case .medium: 0
            case .quartile: 3
            case .high: 2
            }
        }
    }

    /// Encodes `text` as UTF-8 bytes, or nil when it exceeds version 40.
    public static func matrix(for text: String, correction: Correction = .low) -> QRMatrix? {
        encode(text, correction, mask: nil)
    }

    /// `mask` forces one of the eight, for the tests: it lets everything but
    /// the mask choice be compared against CoreImage exactly.
    static func encode(_ text: String, _ correction: Correction, mask: Int?) -> QRMatrix? {
        let bytes = Array(text.utf8)
        guard let version = (1...40).first(where: { fits(bytes.count, version: $0, correction) })
        else { return nil }

        var symbol = Symbol(version: version, correction: correction)
        symbol.drawFunctionPatterns()
        symbol.drawCodewords(symbol.addErrorCorrection(to: dataCodewords(bytes, version, correction)))
        if let mask {
            symbol.applyMask(mask)
            symbol.drawFormatBits(mask: mask)
        } else {
            symbol.applyBestMask()
        }
        return QRMatrix(size: symbol.size, modules: symbol.modules)
    }

    // MARK: - Data

    /// Byte mode's character count field: 8 bits up to version 9, 16 after.
    static func countBits(_ version: Int) -> Int { version <= 9 ? 8 : 16 }

    static func fits(_ count: Int, version: Int, _ correction: Correction) -> Bool {
        guard count < 1 << countBits(version) else { return false }
        return 4 + countBits(version) + count * 8 <= dataCodewordCount(version, correction) * 8
    }

    /// Mode, count, bytes, terminator, then the alternating pad bytes.
    static func dataCodewords(_ bytes: [UInt8], _ version: Int, _ correction: Correction) -> [UInt8] {
        var bits = BitBuffer()
        bits.append(0b0100, count: 4)
        bits.append(bytes.count, count: countBits(version))
        for byte in bytes { bits.append(Int(byte), count: 8) }

        let capacity = dataCodewordCount(version, correction) * 8
        bits.append(0, count: min(4, capacity - bits.count))
        bits.append(0, count: (8 - bits.count % 8) % 8)
        var pad = 0xEC
        while bits.count < capacity {
            bits.append(pad, count: 8)
            pad ^= 0xEC ^ 0x11
        }
        return bits.bytes
    }

    /// Modules left for data and error correction once every function
    /// pattern is placed. Includes remainder bits.
    static func rawDataModules(_ version: Int) -> Int {
        var result = (16 * version + 128) * version + 64
        if version >= 2 {
            let alignments = version / 7 + 2
            result -= (25 * alignments - 10) * alignments - 55
            if version >= 7 { result -= 36 }
        }
        return result
    }

    static func dataCodewordCount(_ version: Int, _ correction: Correction) -> Int {
        rawDataModules(version) / 8
            - eccCodewordsPerBlock[correction.rawValue][version]
            * errorCorrectionBlocks[correction.rawValue][version]
    }

    // MARK: - The symbol

    struct Symbol {
        let version: Int
        let correction: Correction
        let size: Int
        /// Row-major, top row first — `QRMatrix`'s layout.
        var modules: [Bool]
        var isFunction: [Bool]

        init(version: Int, correction: Correction) {
            self.version = version
            self.correction = correction
            size = version * 4 + 17
            modules = Array(repeating: false, count: size * size)
            isFunction = Array(repeating: false, count: size * size)
        }

        subscript(x: Int, y: Int) -> Bool {
            get { modules[y * size + x] }
            set { modules[y * size + x] = newValue }
        }

        mutating func setFunction(_ x: Int, _ y: Int, _ dark: Bool) {
            self[x, y] = dark
            isFunction[y * size + x] = true
        }

        mutating func drawFunctionPatterns() {
            for i in 0..<size {
                setFunction(6, i, i % 2 == 0)
                setFunction(i, 6, i % 2 == 0)
            }
            drawFinder(3, 3)
            drawFinder(size - 4, 3)
            drawFinder(3, size - 4)

            let positions = alignmentPositions
            let last = positions.count - 1
            for (i, x) in positions.enumerated() {
                for (j, y) in positions.enumerated() {
                    // The three corners that already hold a finder.
                    if (i == 0 && j == 0) || (i == 0 && j == last) || (i == last && j == 0) { continue }
                    drawAlignment(x, y)
                }
            }
            // Reserved now, written for real once the mask is chosen.
            drawFormatBits(mask: 0)
            drawVersion()
        }

        mutating func drawFinder(_ x: Int, _ y: Int) {
            for dy in -4...4 {
                for dx in -4...4 {
                    let distance = max(abs(dx), abs(dy))
                    let (xx, yy) = (x + dx, y + dy)
                    if (0..<size).contains(xx), (0..<size).contains(yy) {
                        setFunction(xx, yy, distance != 2 && distance != 4)
                    }
                }
            }
        }

        mutating func drawAlignment(_ x: Int, _ y: Int) {
            for dy in -2...2 {
                for dx in -2...2 {
                    setFunction(x + dx, y + dy, max(abs(dx), abs(dy)) != 1)
                }
            }
        }

        var alignmentPositions: [Int] {
            guard version > 1 else { return [] }
            let count = version / 7 + 2
            let step = (version * 8 + count * 3 + 5) / (count * 4 - 4) * 2
            var result = [6]
            var position = size - 7
            while result.count < count {
                result.insert(position, at: 1)
                position -= step
            }
            return result
        }

        mutating func drawFormatBits(mask: Int) {
            let data = correction.formatBits << 3 | mask
            var remainder = data
            for _ in 0..<10 { remainder = (remainder << 1) ^ ((remainder >> 9) * 0x537) }
            let bits = (data << 10 | remainder) ^ 0x5412

            // Around the top-left finder.
            for i in 0...5 { setFunction(8, i, bit(bits, i)) }
            setFunction(8, 7, bit(bits, 6))
            setFunction(8, 8, bit(bits, 7))
            setFunction(7, 8, bit(bits, 8))
            for i in 9..<15 { setFunction(14 - i, 8, bit(bits, i)) }
            // Split between the other two.
            for i in 0..<8 { setFunction(size - 1 - i, 8, bit(bits, i)) }
            for i in 8..<15 { setFunction(8, size - 15 + i, bit(bits, i)) }
            setFunction(8, size - 8, true)
        }

        mutating func drawVersion() {
            guard version >= 7 else { return }
            var remainder = version
            for _ in 0..<12 { remainder = (remainder << 1) ^ ((remainder >> 11) * 0x1F25) }
            let bits = version << 12 | remainder
            for i in 0..<18 {
                let (a, b) = (size - 11 + i % 3, i / 3)
                setFunction(a, b, bit(bits, i))
                setFunction(b, a, bit(bits, i))
            }
        }

        /// Splits the data into blocks, appends each block's Reed–Solomon
        /// codewords, and interleaves the lot.
        func addErrorCorrection(to data: [UInt8]) -> [UInt8] {
            let blockCount = errorCorrectionBlocks[correction.rawValue][version]
            let eccLength = eccCodewordsPerBlock[correction.rawValue][version]
            let raw = rawDataModules(version) / 8
            let shortBlocks = blockCount - raw % blockCount
            let shortLength = raw / blockCount

            let divisor = ReedSolomon.divisor(degree: eccLength)
            var blocks: [[UInt8]] = []
            var offset = 0
            for index in 0..<blockCount {
                let length = shortLength - eccLength + (index < shortBlocks ? 0 : 1)
                var block = Array(data[offset..<(offset + length)])
                offset += length
                let ecc = ReedSolomon.remainder(block, divisor: divisor)
                // A placeholder so every block has the same shape; skipped below.
                if index < shortBlocks { block.append(0) }
                blocks.append(block + ecc)
            }

            var result: [UInt8] = []
            for i in 0..<blocks[0].count {
                for (j, block) in blocks.enumerated()
                where i != shortLength - eccLength || j >= shortBlocks {
                    result.append(block[i])
                }
            }
            return result
        }

        /// The zigzag: two columns at a time from the right, alternately up and
        /// down, skipping the vertical timing column.
        mutating func drawCodewords(_ data: [UInt8]) {
            var index = 0
            var right = size - 1
            while right >= 1 {
                if right == 6 { right = 5 }
                for vertical in 0..<size {
                    for j in 0..<2 {
                        let x = right - j
                        let upward = (right + 1) & 2 == 0
                        let y = upward ? size - 1 - vertical : vertical
                        if !isFunction[y * size + x], index < data.count * 8 {
                            self[x, y] = bit(Int(data[index >> 3]), 7 - (index & 7))
                            index += 1
                        }
                    }
                }
                right -= 2
            }
        }

        mutating func applyMask(_ mask: Int) {
            for y in 0..<size {
                for x in 0..<size where !isFunction[y * size + x] {
                    let invert = switch mask {
                    case 0: (x + y) % 2 == 0
                    case 1: y % 2 == 0
                    case 2: x % 3 == 0
                    case 3: (x + y) % 3 == 0
                    case 4: (x / 3 + y / 2) % 2 == 0
                    case 5: x * y % 2 + x * y % 3 == 0
                    case 6: (x * y % 2 + x * y % 3) % 2 == 0
                    default: ((x + y) % 2 + x * y % 3) % 2 == 0
                    }
                    if invert { self[x, y].toggle() }
                }
            }
        }

        /// Tries all eight masks and keeps the one the spec's penalty rules
        /// score lowest — the same choice any conforming encoder makes.
        mutating func applyBestMask() {
            var best = 0
            var lowest = Int.max
            for mask in 0..<8 {
                applyMask(mask)
                drawFormatBits(mask: mask)
                let score = penalty()
                if score < lowest {
                    lowest = score
                    best = mask
                }
                applyMask(mask)   // XOR, so applying it again undoes it
            }
            applyMask(best)
            drawFormatBits(mask: best)
        }

        // MARK: Penalty

        func penalty() -> Int {
            var result = 0
            for y in 0..<size { result += linePenalty { self[$0, y] } }
            for x in 0..<size { result += linePenalty { self[x, $0] } }

            for y in 0..<(size - 1) {
                for x in 0..<(size - 1) {
                    let colour = self[x, y]
                    if colour == self[x + 1, y], colour == self[x, y + 1], colour == self[x + 1, y + 1] {
                        result += 3
                    }
                }
            }

            let dark = modules.count(where: { $0 })
            let total = size * size
            let k = (abs(dark * 20 - total * 10) + total - 1) / total - 1
            return result + k * 10
        }

        /// Runs of five or more, and finder-like 1:1:3:1:1 patterns with light
        /// on either side, along one row or column.
        func linePenalty(_ module: (Int) -> Bool) -> Int {
            var result = 0
            var colour = false
            var run = 0
            var history = Array(repeating: 0, count: 7)
            for i in 0..<size {
                if module(i) == colour {
                    run += 1
                    if run == 5 { result += 3 } else if run > 5 { result += 1 }
                } else {
                    addHistory(run, &history)
                    if !colour { result += finderLikePatterns(history) * 40 }
                    colour = module(i)
                    run = 1
                }
            }
            if colour {
                addHistory(run, &history)
                run = 0
            }
            addHistory(run + size, &history)   // the light border past the edge
            return result + finderLikePatterns(history) * 40
        }

        func addHistory(_ length: Int, _ history: inout [Int]) {
            // The first run is extended by the light border before the edge.
            let length = history[0] == 0 ? length + size : length
            history.removeLast()
            history.insert(length, at: 0)
        }

        func finderLikePatterns(_ h: [Int]) -> Int {
            let n = h[1]
            let core = n > 0 && h[2] == n && h[3] == n * 3 && h[4] == n && h[5] == n
            return (core && h[0] >= n * 4 && h[6] >= n ? 1 : 0)
                + (core && h[6] >= n * 4 && h[0] >= n ? 1 : 0)
        }
    }

    // MARK: - Reed–Solomon over GF(2⁸), polynomial 0x11D

    enum ReedSolomon {
        static func divisor(degree: Int) -> [UInt8] {
            var result = Array(repeating: UInt8(0), count: degree - 1) + [1]
            var root: UInt8 = 1
            for _ in 0..<degree {
                for j in result.indices {
                    result[j] = multiply(result[j], root)
                    if j + 1 < result.count { result[j] ^= result[j + 1] }
                }
                root = multiply(root, 0x02)
            }
            return result
        }

        static func remainder(_ data: [UInt8], divisor: [UInt8]) -> [UInt8] {
            var result = Array(repeating: UInt8(0), count: divisor.count)
            for byte in data {
                let factor = byte ^ result.removeFirst()
                result.append(0)
                for i in result.indices { result[i] ^= multiply(divisor[i], factor) }
            }
            return result
        }

        static func multiply(_ x: UInt8, _ y: UInt8) -> UInt8 {
            var z = 0
            for i in (0...7).reversed() {
                z = (z << 1) ^ ((z >> 7) * 0x11D)
                z ^= Int((y >> i) & 1) * Int(x)
            }
            return UInt8(z)
        }
    }

    // MARK: - Tables, indexed [correction][version]; version 0 is unused

    static let eccCodewordsPerBlock: [[Int]] = [
        [-1, 7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28, 28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
        [-1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28],
        [-1, 13, 22, 18, 26, 18, 24, 18, 22, 20, 24, 28, 26, 24, 20, 30, 24, 28, 28, 26, 30, 28, 30, 30, 30, 30, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
        [-1, 17, 28, 22, 16, 22, 28, 26, 26, 24, 28, 24, 28, 22, 24, 24, 30, 28, 28, 26, 28, 30, 24, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
    ]

    static let errorCorrectionBlocks: [[Int]] = [
        [-1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8, 8, 9, 9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25],
        [-1, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49],
        [-1, 1, 1, 2, 2, 4, 4, 6, 6, 8, 8, 8, 10, 12, 16, 12, 17, 16, 18, 21, 20, 23, 23, 25, 27, 29, 34, 34, 35, 38, 40, 43, 45, 48, 51, 53, 56, 59, 62, 65, 68],
        [-1, 1, 1, 2, 4, 4, 4, 5, 6, 8, 8, 11, 11, 16, 16, 18, 16, 19, 21, 25, 25, 25, 34, 30, 32, 35, 37, 40, 42, 45, 48, 51, 54, 57, 60, 63, 66, 70, 74, 77, 81],
    ]
}

private func bit(_ value: Int, _ index: Int) -> Bool { (value >> index) & 1 != 0 }

/// Appends bits most significant first and packs them into bytes.
private struct BitBuffer {
    private(set) var count = 0
    private(set) var bytes: [UInt8] = []

    mutating func append(_ value: Int, count length: Int) {
        for i in stride(from: length - 1, through: 0, by: -1) {
            if count % 8 == 0 { bytes.append(0) }
            if bit(value, i) { bytes[bytes.count - 1] |= 0x80 >> (count % 8) }
            count += 1
        }
    }
}
#endif
