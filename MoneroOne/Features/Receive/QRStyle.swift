import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

// A QR code drawn with round dots, rounded finder patterns and a cleared
// center for the logo, in the style of Cash App's codes. CoreGraphics and
// CoreImage only, so the same file builds for the app and for a macOS test
// harness. Every shape is given in modules (one module = one cell of the
// code) so the Android app can copy the numbers.
//
// The defaults are the tested pick (2026-10-18): error correction Q, dots
// 0.80, finder radii 1.5 / 0.75 / 0.25, logo 28% with 1 module of space.
// On clean renders of Monero payloads (102-145 characters, versions 8-10)
// Apple Vision, CIDetector, zxing-cpp and WeChat read every code. Under blur,
// downscaling, JPEG, rotation, tilt, glare and noise it matches or beats the
// square code for Vision, CIDetector and zxing. Cash App's own measures
// (0.76 dots, radii 2 / 1, 30% logo) lost Vision reads under rotation and
// zxing reads under steep tilt at these denser versions.

// MARK: - Modules

/// A QR code's modules without the quiet zone: `size` x `size` cells, dark
/// is `true`, rows top to bottom.
struct QRMatrix: Equatable {
    let size: Int
    private let cells: [Bool]

    /// Error correction levels CoreImage takes. H restores about 30% of the
    /// code, Q about 25%.
    enum Correction: String {
        case low = "L", medium = "M", quartile = "Q", high = "H"
    }

    /// 1 to 40; the size is 17 + 4 x version.
    var version: Int { (size - 17) / 4 }

    subscript(row: Int, column: Int) -> Bool {
        cells[row * size + column]
    }

    private init(size: Int, cells: [Bool]) {
        self.size = size
        self.cells = cells
    }

    private static let context = CIContext(options: [.workingColorSpace: NSNull()])

    /// The modules of `string`. Nil when the text does not fit in a QR code
    /// or CoreImage's output does not read as one: the caller then draws the
    /// plain square code.
    ///
    /// Q, not H, for the styled code: an address is then version 8 (49
    /// modules) instead of 10 (57), so the dots are larger, and the cleared
    /// logo area still leaves Q room for damage. At H the smaller dots lost
    /// Vision reads when the code was rotated or tilted.
    static func make(_ string: String, correction: Correction = .quartile) -> QRMatrix? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = correction.rawValue
        guard let output = filter.outputImage else { return nil }
        // CoreImage draws one pixel per module, with a margin.
        let extent = output.extent.integral
        let width = Int(extent.width)
        let height = Int(extent.height)
        guard width >= 21, height >= 21, width <= 400, height <= 400 else { return nil }
        var gray = [UInt8](repeating: 255, count: width * height)
        gray.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            context.render(
                output,
                toBitmap: base,
                rowBytes: width,
                bounds: extent,
                format: .L8,
                colorSpace: CGColorSpaceCreateDeviceGray()
            )
        }
        return QRMatrix(gray: gray, width: width, height: height)
    }

    /// Reads a code from an 8-bit gray bitmap with one pixel per module and
    /// a margin of any width. The code is the bounding box of the dark
    /// pixels: its top-left corner is the top-left finder's corner, so the
    /// margin is never assumed. The size must be 17 + 4v and the three
    /// finder patterns must be in place. The bitmap's row order is checked
    /// too, not assumed.
    init?(gray: [UInt8], width: Int, height: Int) {
        guard width > 0, height > 0, gray.count == width * height else { return nil }
        let dark = gray.map { $0 < 128 }
        if let matrix = Self.parse(dark, width: width, height: height, flipped: false)
            ?? Self.parse(dark, width: width, height: height, flipped: true) {
            self = matrix
        } else {
            return nil
        }
    }

    private static func parse(_ dark: [Bool], width: Int, height: Int, flipped: Bool) -> QRMatrix? {
        func isDark(_ row: Int, _ column: Int) -> Bool {
            dark[(flipped ? height - 1 - row : row) * width + column]
        }
        var top = height, left = width, bottom = -1, right = -1
        for row in 0..<height {
            for column in 0..<width where isDark(row, column) {
                top = min(top, row)
                bottom = max(bottom, row)
                left = min(left, column)
                right = max(right, column)
            }
        }
        guard bottom >= 0 else { return nil }
        let size = right - left + 1
        guard size == bottom - top + 1, size >= 21, size <= 177, (size - 17) % 4 == 0 else {
            return nil
        }
        var cells = [Bool](repeating: false, count: size * size)
        for row in 0..<size {
            for column in 0..<size {
                cells[row * size + column] = isDark(top + row, left + column)
            }
        }
        let matrix = QRMatrix(size: size, cells: cells)
        let far = size - 7
        guard matrix.hasFinder(row: 0, column: 0),
              matrix.hasFinder(row: 0, column: far),
              matrix.hasFinder(row: far, column: 0),
              !matrix.hasFinder(row: far, column: far) else {
            return nil
        }
        return matrix
    }

    /// True when the 7 x 7 cells from (row, column) are a finder pattern (a
    /// dark ring, a light ring, a dark 3 x 3 center) inside a light
    /// 1-module separator.
    private func hasFinder(row: Int, column: Int) -> Bool {
        for r in -1...7 {
            for c in -1...7 {
                let y = row + r, x = column + c
                guard y >= 0, y < size, x >= 0, x < size else { continue }
                let ring = max(abs(r - 3), abs(c - 3))
                let shouldBeDark = ring == 0 || ring == 1 || ring == 3
                if self[y, x] != shouldBeDark { return false }
            }
        }
        return true
    }

    /// True for the cells of the three 7 x 7 finder patterns.
    func isFinder(row: Int, column: Int) -> Bool {
        let far = size - 7
        return (row < 7 && column < 7)
            || (row < 7 && column >= far)
            || (row >= far && column < 7)
    }
}

// MARK: - Style

/// The look of a styled code. Lengths are in modules.
struct QRStyle: Equatable {
    enum LogoShape: Equatable {
        /// A round logo (the Monero mark): the cleared area is round too.
        case circle
        /// A square logo (an app icon): the cleared area is square.
        case square
    }

    /// Data, timing and alignment modules: filled circles this wide.
    /// 1 makes neighbors touch. Cash App: 0.76. Below 0.8, Vision missed
    /// rotated and tilted codes more often than with the square code.
    var dotDiameter: CGFloat = 0.8

    // The finder patterns (the three corner squares) keep their exact
    // cells: a 7 x 7 ring 1 module thick, a 1-module light gap, a 3 x 3
    // center. Only the corners round, so scanners still find the
    // 1:1:3:1:1 ratio along the center lines.

    /// Corner radius of the ring's outer edge, at most 3.5. Cash App: 2,
    /// which cost zxing its reads of codes tilted 40 degrees.
    var finderOuterRadius: CGFloat = 1.5
    /// Corner radius of the ring's inner edge (the 5 x 5 hole), at most
    /// 2.5. Cash App: 1.
    var finderInnerRadius: CGFloat = 0.75
    /// Corner radius of the 3 x 3 center, at most 1.5. Cash App: 0.25.
    var finderCenterRadius: CGFloat = 0.25

    /// The logo's width as a fraction of the code's width (quiet zone not
    /// included); 0 for no logo. Rounded to a whole odd number of modules,
    /// so the logo sits on the module grid like Cash App's (11 of 37,
    /// 30%). The Monero mark is drawn this wide, with no disc behind it.
    var logoFraction: CGFloat = 0.28
    /// Empty space around the logo: every cell closer than this to the
    /// logo's edge is cleared, never drawn under the logo. Cash App: 1.
    var logoPadding: CGFloat = 1
    var logoShape: LogoShape = .circle

    /// Cash App's code as measured from a screenshot (version 5, 37
    /// modules). For comparison only: the defaults above are the pick.
    static let cashApp = QRStyle(
        dotDiameter: 0.76,
        finderOuterRadius: 2,
        finderInnerRadius: 1,
        finderCenterRadius: 0.25,
        logoFraction: 0.3,
        logoPadding: 1,
        logoShape: .square
    )
}

// MARK: - Drawing

enum QRStyledCode {
    /// The smallest code that gets a logo: version 5 (37 modules), the size
    /// of Cash App's code. Smaller codes have too little error correction
    /// for the cleared center: with the logo, versions 1 to 3 failed every
    /// decoder in tests. Every Monero address is version 8 or larger.
    static let minimumLogoCodeSize = 37

    /// The logo's width in modules: the odd number nearest to the style's
    /// fraction of the code, or 0 (no logo, nothing cleared).
    static func logoModules(size: Int, style: QRStyle) -> Int {
        guard style.logoFraction > 0, size >= minimumLogoCodeSize else { return 0 }
        let exact = style.logoFraction * CGFloat(size)
        let odd = Int(((exact - 1) / 2).rounded()) * 2 + 1
        return max(1, min(odd, size - 16))
    }

    /// True when the logo clears this cell: the cell comes closer than the
    /// padding to the logo's edge.
    static func isCleared(row: Int, column: Int, size: Int, style: QRStyle) -> Bool {
        let logo = logoModules(size: size, style: style)
        guard logo > 0 else { return false }
        let center = Double(size) / 2
        // The cell's nearest point to the code's center, per axis.
        let dx = max(abs(Double(column) + 0.5 - center) - 0.5, 0)
        let dy = max(abs(Double(row) + 0.5 - center) - 0.5, 0)
        let reach = Double(logo) / 2 + Double(style.logoPadding)
        switch style.logoShape {
        case .circle: return dx * dx + dy * dy < reach * reach
        case .square: return max(dx, dy) < reach
        }
    }

    /// Where the logo goes in a code drawn `side` wide (y down).
    static func logoRect(matrix: QRMatrix, style: QRStyle, side: CGFloat) -> CGRect {
        let logo = CGFloat(logoModules(size: matrix.size, style: style))
        let module = side / CGFloat(matrix.size)
        let origin = (CGFloat(matrix.size) - logo) / 2 * module
        return CGRect(x: origin, y: origin, width: logo * module, height: logo * module)
    }

    /// The dark shapes of the code in a `side` x `side` square, y down,
    /// no quiet zone. Fill it with the even-odd rule: the finder rings are a
    /// rounded square with a rounded hole.
    static func path(matrix: QRMatrix, style: QRStyle, side: CGFloat) -> CGPath {
        let n = matrix.size
        let module = side / CGFloat(n)
        let dot = min(max(style.dotDiameter, 0.1), 1) * module
        let path = CGMutablePath()
        for row in 0..<n {
            for column in 0..<n where matrix[row, column] {
                if matrix.isFinder(row: row, column: column) { continue }
                if isCleared(row: row, column: column, size: n, style: style) { continue }
                path.addEllipse(in: CGRect(
                    x: (CGFloat(column) + 0.5) * module - dot / 2,
                    y: (CGFloat(row) + 0.5) * module - dot / 2,
                    width: dot,
                    height: dot
                ))
            }
        }
        for (row, column) in [(0, 0), (0, n - 7), (n - 7, 0)] {
            let outer = CGRect(
                x: CGFloat(column) * module,
                y: CGFloat(row) * module,
                width: 7 * module,
                height: 7 * module
            )
            addRoundedSquare(to: path, outer, radius: style.finderOuterRadius * module)
            addRoundedSquare(to: path, outer.insetBy(dx: module, dy: module),
                             radius: style.finderInnerRadius * module)
            addRoundedSquare(to: path, outer.insetBy(dx: 2 * module, dy: 2 * module),
                             radius: style.finderCenterRadius * module)
        }
        return path
    }

    private static func addRoundedSquare(to path: CGMutablePath, _ rect: CGRect, radius: CGFloat) {
        let r = min(max(radius, 0), rect.width / 2)
        if r > 0 {
            path.addRoundedRect(in: rect, cornerWidth: r, cornerHeight: r)
        } else {
            path.addRect(rect)
        }
    }

    /// The code as a bitmap `pixelWidth` square: black on white, with
    /// `quietZone` modules of white around it and `logo` drawn in the
    /// cleared center.
    static func image(
        matrix: QRMatrix,
        style: QRStyle,
        pixelWidth: Int,
        quietZone: CGFloat = 4,
        logo: CGImage? = nil
    ) -> CGImage? {
        guard pixelWidth > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: pixelWidth,
                height: pixelWidth,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else {
            return nil
        }
        let width = CGFloat(pixelWidth)
        let total = CGFloat(matrix.size) + 2 * quietZone
        let side = width * CGFloat(matrix.size) / total
        let inset = width * quietZone / total
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: width))
        // y down, like the path.
        context.translateBy(x: inset, y: width - inset)
        context.scaleBy(x: 1, y: -1)
        context.addPath(path(matrix: matrix, style: style, side: side))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fillPath(using: .evenOdd)
        let rect = logoRect(matrix: matrix, style: style, side: side)
        if let logo, !rect.isEmpty {
            context.saveGState()
            context.translateBy(x: rect.minX, y: rect.maxY)
            context.scaleBy(x: 1, y: -1)
            context.interpolationQuality = .high
            context.draw(logo, in: CGRect(origin: .zero, size: rect.size))
            context.restoreGState()
        }
        return context.makeImage()
    }
}
