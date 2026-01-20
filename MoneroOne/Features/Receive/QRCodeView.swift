import SwiftUI
import CoreImage.CIFilterBuiltins

struct QRCodeView: View {
    let content: String
    var showLogo: Bool = true

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)

            ZStack {
                // Standard QR code that actually works
                if let qrImage = generateQRImage(from: content, size: size) {
                    Image(uiImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: size, height: size)
                }

                // Logo overlay in center
                if showLogo {
                    let logoSize = size * 0.22
                    Image("MoneroSymbol")
                        .resizable()
                        .scaledToFill()
                        .frame(width: logoSize, height: logoSize)
                        .clipShape(Circle())
                }
            }
            .frame(width: size, height: size)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
    }

    private func generateQRImage(from string: String, size: CGFloat) -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()

        guard let data = string.data(using: .utf8) else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("H", forKey: "inputCorrectionLevel")

        guard let outputImage = filter.outputImage else { return nil }

        // Scale up for crisp rendering
        let scale = size / outputImage.extent.size.width
        let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else {
            return nil
        }

        return UIImage(cgImage: cgImage)
    }

    private func isInFinderPattern(row: Int, col: Int, size: Int) -> Bool {
        // Top-left finder pattern
        if row < 7 && col < 7 { return true }
        // Top-right finder pattern
        if row < 7 && col >= size - 7 { return true }
        // Bottom-left finder pattern
        if row >= size - 7 && col < 7 { return true }
        return false
    }

    private func drawFinderPattern(context: inout GraphicsContext, x: CGFloat, y: CGFloat, moduleSize: CGFloat) {
        let patternSize = moduleSize * 7
        let cornerRadius = moduleSize * 1.2

        // Outer black rounded square (7x7)
        let outerRect = CGRect(x: x, y: y, width: patternSize, height: patternSize)
        context.fill(
            RoundedRectangle(cornerRadius: cornerRadius).path(in: outerRect),
            with: .color(.black)
        )

        // Middle white rounded square (5x5, inset by 1 module)
        let middleInset = moduleSize
        let middleRect = CGRect(x: x + middleInset, y: y + middleInset,
                                width: patternSize - (middleInset * 2),
                                height: patternSize - (middleInset * 2))
        context.fill(
            RoundedRectangle(cornerRadius: cornerRadius * 0.7).path(in: middleRect),
            with: .color(.white)
        )

        // Inner black rounded square (3x3, inset by 2 modules)
        let innerInset = moduleSize * 2
        let innerRect = CGRect(x: x + innerInset, y: y + innerInset,
                               width: patternSize - (innerInset * 2),
                               height: patternSize - (innerInset * 2))
        context.fill(
            RoundedRectangle(cornerRadius: cornerRadius * 0.5).path(in: innerRect),
            with: .color(.black)
        )
    }

    private func generateQRMatrix(from string: String) -> [[Bool]]? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()

        guard let data = string.data(using: .utf8) else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("H", forKey: "inputCorrectionLevel")

        guard let outputImage = filter.outputImage else { return nil }

        guard let cgImage = context.createCGImage(outputImage, from: outputImage.extent) else {
            return nil
        }

        let width = cgImage.width
        let height = cgImage.height

        guard let pixelData = cgImage.dataProvider?.data,
              let dataPtr = CFDataGetBytePtr(pixelData) else {
            return nil
        }

        var matrix: [[Bool]] = []
        let bytesPerPixel = cgImage.bitsPerPixel / 8

        for y in 0..<height {
            var row: [Bool] = []
            for x in 0..<width {
                let pixelIndex = (y * cgImage.bytesPerRow) + (x * bytesPerPixel)
                let isBlack = dataPtr[pixelIndex] == 0
                row.append(isBlack)
            }
            matrix.append(row)
        }

        return matrix
    }
}

// MARK: - QR Code Image Generator (for sharing)

struct QRCodeRenderer {
    @MainActor
    static func renderToImage(content: String, size: CGFloat = 400) -> UIImage? {
        let renderer = ImageRenderer(content:
            QRCodeView(content: content)
                .frame(width: size, height: size)
        )
        renderer.scale = 3.0 // High resolution
        return renderer.uiImage
    }
}

#Preview {
    QRCodeView(content: "monero:888tNkZrPN6JsEgekjMnABU4TBzc2Dt29EPAvkRxbANsAnjyPbb3iQ1YBRk1UXcdRsiKc9dhwMVgN5S9cQUiyoogDavup3H")
        .frame(width: 200, height: 200)
        .padding()
        .background(Color.white)
}
