import Foundation
import GhosttyKit

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

enum GhosttyRuntimeClipboard {
    nonisolated static func read(
        userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        state: UnsafeMutableRawPointer?
    ) {
        guard let userdata = unsafe userdata else { return }
        let retainedView = unsafe Unmanaged<AnyObject>.fromOpaque(userdata).retain()
        let retainedUserdataAddress = unsafe UInt(bitPattern: retainedView.toOpaque())
        let stateAddress = unsafe state.map { UInt(bitPattern: $0) }
        let requestedLocation = location

        Task { @MainActor in
            guard
                let resolvedUserdata = unsafe UnsafeMutableRawPointer(bitPattern: retainedUserdataAddress)
            else {
                return
            }
            let view = unsafe Unmanaged<AnyObject>.fromOpaque(resolvedUserdata).takeRetainedValue()
            let resolvedState = unsafe stateAddress.flatMap(UnsafeMutableRawPointer.init(bitPattern:))
            guard let surface = unsafe resolveSurface(from: view) else { return }

            #if os(macOS)
            let text: String
            switch requestedLocation {
            case GHOSTTY_CLIPBOARD_SELECTION:
                text = NSPasteboard(name: .find).string(forType: .string) ?? ""
            default:
                text = NSPasteboard.general.string(forType: .string) ?? ""
            }
            #elseif os(iOS)
            let text = UIPasteboard.general.string ?? ""
            #endif

            // Swift 6.2 requires the outer acknowledgement; remove this split when releases use Swift 6.4+.
            #if compiler(<6.4)
            unsafe text.withCString { ptr in
                unsafe ghostty_surface_complete_clipboard_request(surface, ptr, resolvedState, false)
            }
            #else
            text.withCString { ptr in
                unsafe ghostty_surface_complete_clipboard_request(surface, ptr, resolvedState, false)
            }
            #endif
        }
    }

    nonisolated static func confirmRead(
        userdata: UnsafeMutableRawPointer?,
        string: UnsafePointer<CChar>?,
        state: UnsafeMutableRawPointer?,
        request: ghostty_clipboard_request_e
    ) {
        _ = request
        guard let userdata = unsafe userdata, let string = unsafe string else { return }

        let copiedText = unsafe String(cString: string)
        let retainedView = unsafe Unmanaged<AnyObject>.fromOpaque(userdata).retain()
        let retainedUserdataAddress = unsafe UInt(bitPattern: retainedView.toOpaque())
        let stateAddress = unsafe state.map { UInt(bitPattern: $0) }

        Task { @MainActor in
            guard
                let resolvedUserdata = unsafe UnsafeMutableRawPointer(bitPattern: retainedUserdataAddress)
            else {
                return
            }
            let view = unsafe Unmanaged<AnyObject>.fromOpaque(resolvedUserdata).takeRetainedValue()
            let resolvedState = unsafe stateAddress.flatMap(UnsafeMutableRawPointer.init(bitPattern:))
            guard let surface = unsafe resolveSurface(from: view) else { return }

            #if compiler(<6.4)
            unsafe copiedText.withCString { copiedCString in
                unsafe ghostty_surface_complete_clipboard_request(surface, copiedCString, resolvedState, true)
            }
            #else
            copiedText.withCString { copiedCString in
                unsafe ghostty_surface_complete_clipboard_request(surface, copiedCString, resolvedState, true)
            }
            #endif
        }
    }

    nonisolated static func write(
        userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        content: UnsafePointer<ghostty_clipboard_content_s>?,
        len: Int,
        confirm: Bool
    ) {
        _ = unsafe userdata
        _ = location
        guard !confirm else { return }
        guard let content = unsafe content, len > 0 else { return }

        guard let text = unsafe extractPlainText(from: content, count: len) else { return }
        Task { @MainActor in
            #if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            #elseif os(iOS)
            UIPasteboard.general.string = text
            #endif
        }
    }

    nonisolated private static func extractPlainText(
        from content: UnsafePointer<ghostty_clipboard_content_s>,
        count: Int
    ) -> String? {
        let items = unsafe UnsafeBufferPointer(start: content, count: count)
        for index in 0..<items.count {
            let item = unsafe items[index]
            guard let mime = unsafe item.mime else { continue }
            if unsafe String(cString: mime) == "text/plain" {
                guard let itemData = unsafe item.data else { continue }
                return unsafe String(cString: itemData)
            }
        }
        return nil
    }

    @MainActor
    private static func resolveSurface(from view: AnyObject) -> ghostty_surface_t? {
        guard let provider = view as? GhosttySurfaceProvider else { return nil }
        return unsafe provider.ghosttySurface
    }
}

nonisolated func ghosttyRuntimeClipboardReadCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ location: ghostty_clipboard_e,
    _ state: UnsafeMutableRawPointer?
) {
    unsafe GhosttyRuntimeClipboard.read(userdata: userdata, location: location, state: state)
}

nonisolated func ghosttyRuntimeClipboardConfirmReadCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ string: UnsafePointer<CChar>?,
    _ state: UnsafeMutableRawPointer?,
    _ request: ghostty_clipboard_request_e
) {
    unsafe GhosttyRuntimeClipboard.confirmRead(userdata: userdata, string: string, state: state, request: request)
}

nonisolated func ghosttyRuntimeClipboardWriteCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ location: ghostty_clipboard_e,
    _ content: UnsafePointer<ghostty_clipboard_content_s>?,
    _ len: Int,
    _ confirm: Bool
) {
    unsafe GhosttyRuntimeClipboard.write(
        userdata: userdata,
        location: location,
        content: content,
        len: len,
        confirm: confirm
    )
}
