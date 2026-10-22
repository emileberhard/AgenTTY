import SwiftUI
import VisionKit

enum PairingQRCodeScannerError: LocalizedError {
    case unsupported
    case unavailable
    case unreadableCode

    var errorDescription: String? {
        switch self {
        case .unsupported:
            "QR scanning is not supported on this device."
        case .unavailable:
            "QR scanning is currently unavailable. Check camera access and try again."
        case .unreadableCode:
            "The scanned QR code did not contain a valid AgenTTY pairing code."
        }
    }
}

@safe
struct PairingQRCodeScannerView: UIViewControllerRepresentable {
    let onPayload: @MainActor (String) -> Void
    let onError: @MainActor (Error) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPayload: onPayload, onError: onError)
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true
        )
        controller.delegate = context.coordinator

        Task { @MainActor in
            do {
                try controller.startScanning()
            } catch {
                onError(error)
            }
        }

        return controller
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private var didFinish = false
        private let onPayload: @MainActor (String) -> Void
        private let onError: @MainActor (Error) -> Void

        init(
            onPayload: @escaping @MainActor (String) -> Void,
            onError: @escaping @MainActor (Error) -> Void
        ) {
            self.onPayload = onPayload
            self.onError = onError
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            guard !didFinish else { return }

            for item in addedItems {
                guard case .barcode(let barcode) = item,
                      let payload = barcode.payloadStringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !payload.isEmpty else {
                    continue
                }

                didFinish = true
                Task { @MainActor in
                    dataScanner.stopScanning()
                    onPayload(payload)
                }
                return
            }
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable
        ) {
            guard !didFinish else { return }
            didFinish = true
            Task { @MainActor in
                onError(error)
            }
        }
    }
}
