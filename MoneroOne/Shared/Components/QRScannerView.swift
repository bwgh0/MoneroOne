import SwiftUI
import AVFoundation

struct QRScannerView: UIViewControllerRepresentable {
    let onCodeScanned: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> QRScannerViewController {
        let controller = QRScannerViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: QRScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCodeScanned: onCodeScanned, dismiss: dismiss)
    }

    class Coordinator: NSObject, QRScannerViewControllerDelegate {
        let onCodeScanned: (String) -> Void
        let dismiss: DismissAction

        init(onCodeScanned: @escaping (String) -> Void, dismiss: DismissAction) {
            self.onCodeScanned = onCodeScanned
            self.dismiss = dismiss
        }

        func didScanCode(_ code: String) {
            onCodeScanned(code)
            dismiss()
        }

        func didFailWithError(_ error: Error) {
            dismiss()
        }
    }
}

protocol QRScannerViewControllerDelegate: AnyObject {
    func didScanCode(_ code: String)
    func didFailWithError(_ error: Error)
}

class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    weak var delegate: QRScannerViewControllerDelegate?

    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var hasScanned = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupCamera()
        setupOverlay()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        hasScanned = false
        if captureSession?.isRunning == false {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.captureSession?.startRunning()
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if captureSession?.isRunning == true {
            captureSession?.stopRunning()
        }
    }

    private func setupCamera() {
        guard let videoCaptureDevice = AVCaptureDevice.default(for: .video) else {
            delegate?.didFailWithError(ScannerError.noCameraAvailable)
            return
        }

        let videoInput: AVCaptureDeviceInput
        do {
            videoInput = try AVCaptureDeviceInput(device: videoCaptureDevice)
        } catch {
            delegate?.didFailWithError(error)
            return
        }

        captureSession = AVCaptureSession()
        guard let captureSession = captureSession else { return }

        if captureSession.canAddInput(videoInput) {
            captureSession.addInput(videoInput)
        } else {
            delegate?.didFailWithError(ScannerError.inputNotSupported)
            return
        }

        let metadataOutput = AVCaptureMetadataOutput()
        if captureSession.canAddOutput(metadataOutput) {
            captureSession.addOutput(metadataOutput)
            metadataOutput.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
            metadataOutput.metadataObjectTypes = [.qr]
        } else {
            delegate?.didFailWithError(ScannerError.outputNotSupported)
            return
        }

        previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
        previewLayer?.frame = view.layer.bounds
        previewLayer?.videoGravity = .resizeAspectFill
        if let layer = previewLayer {
            view.layer.addSublayer(layer)
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.captureSession?.startRunning()
        }
    }

    private func setupOverlay() {
        // Semi-transparent overlay
        let overlayView = UIView(frame: view.bounds)
        overlayView.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        overlayView.isUserInteractionEnabled = false
        view.addSubview(overlayView)

        // Clear scanning area
        let scanSize: CGFloat = 250
        let scanRect = CGRect(
            x: (view.bounds.width - scanSize) / 2,
            y: (view.bounds.height - scanSize) / 2,
            width: scanSize,
            height: scanSize
        )

        let path = UIBezierPath(rect: overlayView.bounds)
        let scanPath = UIBezierPath(roundedRect: scanRect, cornerRadius: 12)
        path.append(scanPath)
        path.usesEvenOddFillRule = true

        let maskLayer = CAShapeLayer()
        maskLayer.path = path.cgPath
        maskLayer.fillRule = .evenOdd
        overlayView.layer.mask = maskLayer

        // Corner markers
        let cornerLength: CGFloat = 30
        let cornerWidth: CGFloat = 4
        let cornerColor = UIColor.orange

        let corners: [(CGPoint, CGFloat, CGFloat)] = [
            (CGPoint(x: scanRect.minX, y: scanRect.minY), 1, 1),   // Top-left
            (CGPoint(x: scanRect.maxX, y: scanRect.minY), -1, 1),  // Top-right
            (CGPoint(x: scanRect.minX, y: scanRect.maxY), 1, -1),  // Bottom-left
            (CGPoint(x: scanRect.maxX, y: scanRect.maxY), -1, -1)  // Bottom-right
        ]

        for (point, xDir, yDir) in corners {
            // Horizontal line
            let hLine = UIView(frame: CGRect(
                x: xDir > 0 ? point.x : point.x - cornerLength,
                y: yDir > 0 ? point.y : point.y - cornerWidth,
                width: cornerLength,
                height: cornerWidth
            ))
            hLine.backgroundColor = cornerColor
            view.addSubview(hLine)

            // Vertical line
            let vLine = UIView(frame: CGRect(
                x: xDir > 0 ? point.x : point.x - cornerWidth,
                y: yDir > 0 ? point.y : point.y - cornerLength,
                width: cornerWidth,
                height: cornerLength
            ))
            vLine.backgroundColor = cornerColor
            view.addSubview(vLine)
        }

        // Instruction label
        let label = UILabel()
        label.text = "Scan Monero Address"
        label.textColor = .white
        label.font = .systemFont(ofSize: 16, weight: .medium)
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.topAnchor.constraint(equalTo: view.topAnchor, constant: scanRect.minY - 50)
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.layer.bounds
    }

    // MARK: - AVCaptureMetadataOutputObjectsDelegate

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !hasScanned else { return }

        if let metadataObject = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
           let stringValue = metadataObject.stringValue {

            // Parse monero: URI or plain address
            let address = parseMoneroURI(stringValue)

            hasScanned = true
            AudioServicesPlaySystemSound(SystemSoundID(kSystemSoundID_Vibrate))
            delegate?.didScanCode(address)
        }
    }

    private func parseMoneroURI(_ string: String) -> String {
        // Handle monero: URI format
        // monero:ADDRESS?tx_amount=AMOUNT&recipient_name=NAME&tx_description=DESC
        if string.lowercased().hasPrefix("monero:") {
            let withoutScheme = String(string.dropFirst(7))
            if let questionIndex = withoutScheme.firstIndex(of: "?") {
                return String(withoutScheme[..<questionIndex])
            }
            return withoutScheme
        }
        return string
    }
}

enum ScannerError: LocalizedError {
    case noCameraAvailable
    case inputNotSupported
    case outputNotSupported

    var errorDescription: String? {
        switch self {
        case .noCameraAvailable:
            return "No camera available on this device"
        case .inputNotSupported:
            return "Camera input not supported"
        case .outputNotSupported:
            return "QR scanning not supported"
        }
    }
}

#Preview {
    QRScannerView { code in
        print("Scanned: \(code)")
    }
}
