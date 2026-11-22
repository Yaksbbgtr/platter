// SPDX-License-Identifier: GPL-3.0-or-later
// Everything people can customize: font, colours and sizes. Saved by the app and handed to the widget.

import SwiftUI

struct Style: Codable, Equatable {
    /// "@rounded", "@system", "@serif", "@mono", or the name of an installed font family.
    var font = "@rounded"
    // Colours are "RRGGBB"; nil means automatic.
    var accent: String?
    var text: String?
    var vinyl: String?
    var metal: String?
    /// The plinth colour of the "My Color" style.
    var plinth = "2F5D62"
    // Sizes are multipliers of the standard size.
    var textSize = 1.0
    var buttonSize = 1.0
    var labelSize = 1.0
    var barSize = 1.0
    var fullScreenDeck = 1.0

    static let textRange = 0.75...1.4, buttonRange = 0.7...1.35, labelRange = 0.7...1.5, barRange = 0.5...2.5, deckRange = 0.6...1.15

    init() {}

    /// Styles saved before an option existed simply lack it; keep its default. Sizes are kept in range.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func size(_ key: CodingKeys, _ range: ClosedRange<Double>) -> Double {
            let v = (try? c.decodeIfPresent(Double.self, forKey: key)) ?? nil
            return v.map { min(max($0, range.lowerBound), range.upperBound) } ?? 1
        }
        func color(_ key: CodingKeys) -> String? { (try? c.decodeIfPresent(String.self, forKey: key)) ?? nil }
        font = color(.font) ?? font
        accent = color(.accent); text = color(.text); vinyl = color(.vinyl); metal = color(.metal)
        plinth = color(.plinth) ?? plinth
        textSize = size(.textSize, Self.textRange)
        buttonSize = size(.buttonSize, Self.buttonRange)
        labelSize = size(.labelSize, Self.labelRange)
        barSize = size(.barSize, Self.barRange)
        fullScreenDeck = size(.fullScreenDeck, Self.deckRange)
    }

    func font(_ size: CGFloat, _ weight: Font.Weight) -> Font {
        switch font {
        case "@rounded": return .system(size: size, weight: weight, design: .rounded)
        case "@system": return .system(size: size, weight: weight)
        case "@serif": return .system(size: size, weight: weight, design: .serif)
        case "@mono": return .system(size: size, weight: weight, design: .monospaced)
        default: return .custom(font, fixedSize: size).weight(weight)
        }
    }

    static let builtInFonts = [("@rounded", "Rounded"), ("@system", "Standard"), ("@serif", "Serif"), ("@mono", "Typewriter (Mono)")]
    static let featuredFonts = ["Avenir Next", "Futura", "Helvetica Neue", "Gill Sans", "Optima", "Didot", "Baskerville", "Georgia",
                                "American Typewriter", "Copperplate", "DIN Condensed", "Marker Felt", "Chalkduster", "Bradley Hand", "Snell Roundhand"]
}

extension PlatformColor {
    convenience init?(hex: String?) {
        guard let hex, hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
        let r = CGFloat((v >> 16) & 0xFF) / 255, g = CGFloat((v >> 8) & 0xFF) / 255, b = CGFloat(v & 0xFF) / 255
        #if os(macOS)
        self.init(srgbRed: r, green: g, blue: b, alpha: 1)
        #else
        self.init(red: r, green: g, blue: b, alpha: 1)
        #endif
    }

    var rgb: (CGFloat, CGFloat, CGFloat) {
        #if os(macOS)
        let c = usingColorSpace(.sRGB) ?? self
        #else
        let c = self
        #endif
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (min(1, max(0, r)), min(1, max(0, g)), min(1, max(0, b)))
    }
    var hex: String {
        let (r, g, b) = rgb
        return String(format: "%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }
    /// Perceived brightness, 0…1.
    var luminance: CGFloat { let (r, g, b) = rgb; return 0.299 * r + 0.587 * g + 0.114 * b }
}
