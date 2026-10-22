import Foundation
import GhosttyKit
import UIKit

enum TerminalSurfaceViewIOSCallbacks {
    nonisolated static func handlePtyInput(
        userdata: UnsafeMutableRawPointer?,
        data: UnsafePointer<CChar>?,
        len: UInt
    ) {
        guard let userdata = unsafe userdata, let data = unsafe data, len > 0 else { return }

        // Retain before hopping actors so userdata stays alive until MainActor consumption.
        let retainedView = unsafe Unmanaged<TerminalSurfaceViewIOS>.fromOpaque(userdata).retain()
        let retainedViewAddress = unsafe UInt(bitPattern: retainedView.toOpaque())
        let bytes = unsafe Data(bytes: data, count: Int(len))

        Task { @MainActor in
            guard
                let resolvedUserdata = unsafe UnsafeMutableRawPointer(bitPattern: retainedViewAddress)
            else {
                return
            }
            let view = unsafe Unmanaged<TerminalSurfaceViewIOS>.fromOpaque(resolvedUserdata).takeRetainedValue()
            view.handlePtyInputFromGhosttyCallback(bytes)
        }
    }
}

nonisolated func ghosttySurfacePtyInputCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ data: UnsafePointer<CChar>?,
    _ len: UInt
) {
    unsafe TerminalSurfaceViewIOSCallbacks.handlePtyInput(userdata: userdata, data: data, len: len)
}

struct QuantizationSignature: Equatable {
    let requestedWidthPx: Int
    let requestedHeightPx: Int
    let reportedWidthPx: Int
    let reportedHeightPx: Int
    let columns: Int
    let rows: Int
    let cellWidthPx: Int
    let cellHeightPx: Int
    let requestedRemainderWidthPx: Int
    let requestedRemainderHeightPx: Int
}

struct CanonicalShellStateSignature: Equatable {
    let windowIds: [Int]
    let activePosition: Int
}

struct SurfaceGeometry: Equatable {
    let widthPx: Int
    let heightPx: Int
    let scale: CGFloat
}

struct TerminalWindowSyncSignature: Equatable {
    let columns: Int
    let rows: Int
    let widthPx: Int
    let heightPx: Int
}
