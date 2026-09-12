import Foundation

/// Turns a Sixel payload into pixels.
///
/// Sixel is what `img2sixel`, `chafa -f sixel`, `lsix` and gnuplot emit, and
/// it long predates anyone sending base64 PNGs down a pty. Each data character
/// carries six vertical pixels as a bitmask — `?` is 0x3F and is all six off,
/// `~` is 0x7E and is all six on — so a band of six rows is written left to
/// right, then `-` starts the next band.
///
/// Unset pixels are left transparent rather than filled with a background
/// colour. The alternative needs the terminal's current background, which this
/// module cannot see, and transparent is what makes a Sixel drawn over a
/// themed terminal look like it belongs there instead of carrying a black box
/// around with it.
enum SixelDecoder {

    /// One colour register. Sixel gives 256 of them; a program that names a
    /// higher one is out of spec and is clamped rather than refused, because
    /// dropping the whole picture over one bad index helps nobody.
    private static let registerCount = 256

    /// The most a payload may be. A Sixel expands enormously — one byte is six
    /// pixels — so the ceiling that matters is on the decoded side, but a
    /// payload this long has already gone wrong.
    static let maximumPayload = 4 << 20

    struct Bitmap {
        var rgba: [UInt8]
        var width: Int
        var height: Int
    }

    static func decode(_ bytes: [UInt8]) -> Bitmap? {
        guard !bytes.isEmpty, bytes.count <= maximumPayload else { return nil }

        // Pass one works out how big the picture is, so pass two can allocate
        // once. Growing an RGBA buffer as it went would mean re-laying out
        // every row each time, and a Sixel arrives as one payload anyway.
        guard let extent = measure(bytes) else { return nil }
        let width = extent.width
        let height = extent.height
        guard width > 0, height > 0,
              width <= InlineImageStore.maximumPixelSide,
              height <= InlineImageStore.maximumPixelSide,
              width * height * 4 <= InlineImageStore.maximumImageBytes else { return nil }

        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        var palette = defaultPalette()
        var colour = 0
        var x = 0
        var bandTop = 0
        var index = 0

        func number(_ i: inout Int) -> Int? {
            var value = 0
            var any = false
            while i < bytes.count, bytes[i] >= 0x30, bytes[i] <= 0x39 {
                // Bounded so a run of digits cannot overflow into nonsense.
                if value < 1 << 24 { value = value * 10 + Int(bytes[i] - 0x30) }
                any = true
                i += 1
            }
            return any ? value : nil
        }

        while index < bytes.count {
            let byte = bytes[index]
            switch byte {
            case UInt8(ascii: "#"):
                index += 1
                guard let register = number(&index) else { break }
                colour = register % registerCount
                // `#Pc;Pu;Px;Py;Pz` defines the register; `#Pc` alone selects
                // one already defined.
                guard index < bytes.count, bytes[index] == UInt8(ascii: ";") else { break }
                index += 1
                let system = number(&index) ?? 2
                var components: [Int] = []
                for _ in 0..<3 {
                    guard index < bytes.count, bytes[index] == UInt8(ascii: ";") else { break }
                    index += 1
                    components.append(number(&index) ?? 0)
                }
                guard components.count == 3 else { break }
                palette[colour] = system == 1
                    ? fromHLS(hue: components[0], lightness: components[1], saturation: components[2])
                    : fromRGB(components[0], components[1], components[2])

            case UInt8(ascii: "!"):
                index += 1
                let count = number(&index) ?? 1
                guard index < bytes.count else { break }
                let data = bytes[index]
                index += 1
                guard data >= 0x3F, data <= 0x7E else { break }
                // A repeat count is attacker-controlled; clamping it to what
                // is left of the row is what keeps a `!999999999?` from
                // spinning for a minute writing nothing.
                let run = min(max(count, 0), max(0, width - x))
                for _ in 0..<run {
                    put(&rgba, width: width, height: height, x: x, bandTop: bandTop,
                        bits: data - 0x3F, colour: palette[colour])
                    x += 1
                }
                continue

            case 0x3F...0x7E:
                if x < width {
                    put(&rgba, width: width, height: height, x: x, bandTop: bandTop,
                        bits: byte - 0x3F, colour: palette[colour])
                }
                x += 1
                index += 1
                continue

            case UInt8(ascii: "$"):
                x = 0
                index += 1
                continue

            case UInt8(ascii: "-"):
                x = 0
                bandTop += 6
                index += 1
                continue

            case UInt8(ascii: "\""):
                // Raster attributes were already read in pass one.
                index += 1
                _ = number(&index)
                for _ in 0..<3 {
                    guard index < bytes.count, bytes[index] == UInt8(ascii: ";") else { break }
                    index += 1
                    _ = number(&index)
                }
                continue

            default:
                index += 1
                continue
            }
        }

        return Bitmap(rgba: rgba, width: width, height: height)
    }

    /// Writes one data character's six vertical pixels.
    private static func put(_ rgba: inout [UInt8], width: Int, height: Int,
                            x: Int, bandTop: Int, bits: UInt8, colour: (UInt8, UInt8, UInt8)) {
        guard x >= 0, x < width else { return }
        for bit in 0..<6 where bits & (1 << UInt8(bit)) != 0 {
            let y = bandTop + bit
            guard y >= 0, y < height else { continue }
            let offset = (y * width + x) * 4
            rgba[offset] = colour.0
            rgba[offset + 1] = colour.1
            rgba[offset + 2] = colour.2
            rgba[offset + 3] = 255
        }
    }

    /// How wide and tall the picture is.
    ///
    /// The raster attributes are a hint, not the truth: they are optional, and
    /// a payload that draws past them is not rare. Taking the larger of the
    /// declared and the drawn extent is what keeps a picture from being
    /// clipped by its own header.
    private static func measure(_ bytes: [UInt8]) -> (width: Int, height: Int)? {
        var x = 0
        var maxX = 0
        var bands = 1
        var declared: (width: Int, height: Int)?
        var index = 0

        func number(_ i: inout Int) -> Int? {
            var value = 0
            var any = false
            while i < bytes.count, bytes[i] >= 0x30, bytes[i] <= 0x39 {
                if value < 1 << 24 { value = value * 10 + Int(bytes[i] - 0x30) }
                any = true
                i += 1
            }
            return any ? value : nil
        }

        while index < bytes.count {
            switch bytes[index] {
            case UInt8(ascii: "\""):
                index += 1
                var fields: [Int] = []
                fields.append(number(&index) ?? 0)
                for _ in 0..<3 {
                    guard index < bytes.count, bytes[index] == UInt8(ascii: ";") else { break }
                    index += 1
                    fields.append(number(&index) ?? 0)
                }
                if fields.count == 4, fields[2] > 0, fields[3] > 0 {
                    declared = (fields[2], fields[3])
                }

            case UInt8(ascii: "#"):
                index += 1
                _ = number(&index)
                while index < bytes.count, bytes[index] == UInt8(ascii: ";") {
                    index += 1
                    _ = number(&index)
                }

            case UInt8(ascii: "!"):
                index += 1
                let count = number(&index) ?? 1
                guard index < bytes.count else { break }
                if bytes[index] >= 0x3F, bytes[index] <= 0x7E {
                    // Clamped for the same reason the fill pass clamps: a
                    // declared run of a billion must not decide the width.
                    x += min(max(count, 0), InlineImageStore.maximumPixelSide)
                    maxX = max(maxX, x)
                }
                index += 1

            case 0x3F...0x7E:
                x += 1
                maxX = max(maxX, x)
                index += 1

            case UInt8(ascii: "$"):
                x = 0
                index += 1

            case UInt8(ascii: "-"):
                x = 0
                bands += 1
                index += 1

            default:
                index += 1
            }
        }

        let drawn = (width: maxX, height: bands * 6)
        guard let declared else {
            return drawn.width > 0 ? drawn : nil
        }
        return (max(declared.width, drawn.width), max(declared.height, drawn.height))
    }

    // MARK: - Colour

    /// Sixel colour components are percentages, not 0–255.
    private static func fromRGB(_ r: Int, _ g: Int, _ b: Int) -> (UInt8, UInt8, UInt8) {
        func scale(_ v: Int) -> UInt8 { UInt8(min(max(v, 0), 100) * 255 / 100) }
        return (scale(r), scale(g), scale(b))
    }

    /// Sixel's HLS, which is not anyone else's: hue is in degrees with 0 at
    /// blue rather than red, and lightness comes before saturation.
    private static func fromHLS(hue: Int, lightness: Int, saturation: Int) -> (UInt8, UInt8, UInt8) {
        let h = Double((hue % 360 + 360) % 360)
        let l = Double(min(max(lightness, 0), 100)) / 100
        let s = Double(min(max(saturation, 0), 100)) / 100
        guard s > 0 else {
            let v = UInt8(l * 255)
            return (v, v, v)
        }
        let c = (1 - abs(2 * l - 1)) * s
        // The 240-degree rotation is what puts blue at zero.
        let hp = ((h + 240).truncatingRemainder(dividingBy: 360)) / 60
        let xComponent = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
        var rgb: (Double, Double, Double)
        switch Int(hp) {
        case 0: rgb = (c, xComponent, 0)
        case 1: rgb = (xComponent, c, 0)
        case 2: rgb = (0, c, xComponent)
        case 3: rgb = (0, xComponent, c)
        case 4: rgb = (xComponent, 0, c)
        default: rgb = (c, 0, xComponent)
        }
        let m = l - c / 2
        func byte(_ v: Double) -> UInt8 { UInt8(min(max((v + m) * 255, 0), 255)) }
        return (byte(rgb.0), byte(rgb.1), byte(rgb.2))
    }

    /// The VT340's sixteen colours, repeated to fill the register file. A
    /// program that draws before defining anything gets these; nearly all of
    /// them define their own first.
    private static func defaultPalette() -> [(UInt8, UInt8, UInt8)] {
        let base: [(UInt8, UInt8, UInt8)] = [
            (0, 0, 0),       (51, 51, 204),   (204, 35, 35),   (51, 204, 51),
            (204, 51, 204),  (51, 204, 204),  (204, 204, 51),  (135, 135, 135),
            (66, 66, 66),    (84, 84, 153),   (153, 66, 66),   (86, 153, 86),
            (153, 86, 153),  (86, 153, 153),  (153, 153, 86),  (204, 204, 204),
        ]
        var palette: [(UInt8, UInt8, UInt8)] = []
        palette.reserveCapacity(registerCount)
        while palette.count < registerCount {
            palette.append(base[palette.count % base.count])
        }
        return palette
    }
}
