import AVFoundation
import SwiftUI

struct WebsitePairingScannerView: View {
    let onPairingURL: (URL) -> Void
    let onCancel: () -> Void
    @State private var cameraDenied = false
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            WebsiteQRScannerRepresentable { value in
                guard let url = URL(string: value), url.scheme == "shuttlx", url.host == "website-pair" else { return }
                onPairingURL(url)
            } onPermissionDenied: { cameraDenied = true }
                .ignoresSafeArea()
            VStack {
                HStack {
                    Button("Cancel", action: onCancel).buttonStyle(.borderedProminent)
                    Spacer()
                }.padding()
                Spacer()
                VStack(spacing: 6) {
                    Text(cameraDenied ? "Camera access is needed to scan the Watch QR code." : "Scan the QR code shown on your Watch")
                        .font(.headline).multilineTextAlignment(.center)
                    if cameraDenied {
                        Text("Enable Camera in Settings, then return to ShuttlX.").font(.caption).multilineTextAlignment(.center)
                    }
                }.padding(14).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18)).padding()
            }
        }
        .preferredColorScheme(.dark)
    }
}

private struct WebsiteQRScannerRepresentable: UIViewControllerRepresentable {
    let onValue: (String) -> Void
    let onPermissionDenied: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onValue: onValue, onPermissionDenied: onPermissionDenied) }
    func makeUIViewController(context: Context) -> ScannerViewController {
        let controller = ScannerViewController()
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: ScannerViewController, context: Context) {}
    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        let onValue: (String) -> Void
        let onPermissionDenied: () -> Void
        private var delivered = false
        init(onValue: @escaping (String) -> Void, onPermissionDenied: @escaping () -> Void) { self.onValue = onValue; self.onPermissionDenied = onPermissionDenied }
        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard !delivered, let value = (metadataObjects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
            delivered = true
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            onValue(value)
        }
        func denied() { onPermissionDenied() }
    }
}

private final class ScannerViewController: UIViewController {
    weak var delegate: (any AVCaptureMetadataOutputObjectsDelegate)?
    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: configure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted { self?.configure() } else if let coordinator = self?.delegate as? WebsiteQRScannerRepresentable.Coordinator { coordinator.denied() }
                }
            }
        default:
            if let coordinator = delegate as? WebsiteQRScannerRepresentable.Coordinator { coordinator.denied() }
        }
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); preview?.frame = view.bounds }
    override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); if !session.isRunning { DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() } } }
    override func viewWillDisappear(_ animated: Bool) { super.viewWillDisappear(animated); if session.isRunning { session.stopRunning() } }
    private func configure() {
        guard let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(delegate, queue: .main)
        output.metadataObjectTypes = [.qr]
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer.insertSublayer(layer, at: 0); preview = layer
    }
}
