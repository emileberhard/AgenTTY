import Foundation
import GhosttyKit
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

enum GhosttyRuntimeCallbacks {
    private enum URLPayloadDecodeError: Error {
        case missingPointer
        case emptyPayload
        case emptyURL
    }

    nonisolated static func wakeup(_ userdata: UnsafeMutableRawPointer?) {
        guard let userdata = unsafe userdata else { return }
        let retainedRuntime = unsafe Unmanaged<GhosttyRuntime>.fromOpaque(userdata).retain()
        let retainedRuntimeAddress = unsafe UInt(bitPattern: retainedRuntime.toOpaque())
        Task { @MainActor in
            guard
                let resolvedUserdata = unsafe UnsafeMutableRawPointer(bitPattern: retainedRuntimeAddress)
            else {
                return
            }
            let runtime = unsafe Unmanaged<GhosttyRuntime>.fromOpaque(resolvedUserdata).takeRetainedValue()
            runtime.handleWakeupFromRuntimeCallback()
        }
    }

    nonisolated static func action(
        app: ghostty_app_t?,
        target: ghostty_target_s,
        action: ghostty_action_s
    ) -> Bool {
        _ = unsafe app
        _ = unsafe target

        switch unsafe action.tag {
        case GHOSTTY_ACTION_RENDERER_HEALTH:
            let status = unsafe action.action.renderer_health != GHOSTTY_RENDERER_HEALTH_UNHEALTHY
                ? "healthy"
                : "unhealthy"
            EsmaLog.ghostty.info("ghostty action renderer_health=\(status, privacy: .public)")
        case GHOSTTY_ACTION_SHOW_ON_SCREEN_KEYBOARD:
            EsmaLog.ghostty.info("ghostty action show_on_screen_keyboard")
        case GHOSTTY_ACTION_MOUSE_OVER_LINK:
            unsafe handleMouseOverLinkAction(action.action.mouse_over_link)
        case GHOSTTY_ACTION_OPEN_URL:
            return unsafe handleOpenURLAction(action.action.open_url)
        case GHOSTTY_ACTION_RENDER:
            EsmaLog.ghostty.debug("ghostty action render request")
        default:
            break
        }
        return false
    }

    nonisolated private static func handleOpenURLAction(_ action: ghostty_action_open_url_s) -> Bool {
        let actionKind = unsafe openURLActionKindDescription(action.kind)
        let candidateURL: String
        switch unsafe decodeURLPayload(pointer: action.url, length: Int(action.len)) {
        case .success(let value):
            candidateURL = value
        case .failure(.missingPointer):
            EsmaLog.ghostty.error("ghostty action open_url missing URL pointer kind=\(actionKind, privacy: .public)")
            return false
        case .failure(.emptyPayload):
            EsmaLog.ghostty.error("ghostty action open_url missing URL bytes kind=\(actionKind, privacy: .public)")
            return false
        case .failure(.emptyURL):
            EsmaLog.ghostty.error("ghostty action open_url resolved empty URL kind=\(actionKind, privacy: .public)")
            return false
        }
        EsmaLog.ghostty.info(
            "ghostty action open_url received kind=\(actionKind, privacy: .public) \(urlSummary(for: candidateURL), privacy: .public)"
        )

        Task { @MainActor in
            Self.openExternalURL(candidateURL, actionKind: actionKind)
        }
        return true
    }

    nonisolated private static func handleMouseOverLinkAction(_ action: ghostty_action_mouse_over_link_s) {
        guard EsmaDiagnostics.verboseLoggingEnabled else { return }

        let candidateURL: String
        switch unsafe decodeURLPayload(pointer: action.url, length: Int(action.len)) {
        case .success(let value):
            candidateURL = value
        case .failure(.missingPointer):
            EsmaLog.ghostty.debug("ghostty action mouse_over_link cleared")
            return
        case .failure(.emptyPayload):
            EsmaLog.ghostty.debug("ghostty action mouse_over_link empty payload")
            return
        case .failure(.emptyURL):
            EsmaLog.ghostty.debug("ghostty action mouse_over_link empty URL")
            return
        }

        EsmaLog.ghostty.debug(
            "ghostty action mouse_over_link \(urlSummary(for: candidateURL), privacy: .public)"
        )
    }

    nonisolated private static func decodeURLPayload(
        pointer: UnsafePointer<CChar>?,
        length: Int
    ) -> Result<String, URLPayloadDecodeError> {
        guard let payloadPointer = unsafe pointer else {
            return .failure(.missingPointer)
        }
        guard length > 0 else {
            return .failure(.emptyPayload)
        }

        let bytes = unsafe UnsafeRawBufferPointer(
            start: UnsafeRawPointer(payloadPointer),
            count: length
        )
        let rawURL = unsafe String(decoding: bytes, as: UTF8.self)
        let candidateURL = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidateURL.isEmpty else {
            return .failure(.emptyURL)
        }

        return .success(candidateURL)
    }

    @MainActor
    private static func openExternalURL(_ candidateURL: String, actionKind: String) {
        guard
            let parsedURL = URL(string: candidateURL),
            let scheme = parsedURL.scheme,
            !scheme.isEmpty
        else {
            EsmaLog.ghostty.error(
                "ghostty action open_url rejected invalid URL kind=\(actionKind, privacy: .public)"
            )
            return
        }

        #if os(iOS)
        EsmaLog.ghostty.info("ghostty action open_url dispatch scheme=\(scheme, privacy: .public) kind=\(actionKind, privacy: .public)")
        UIApplication.shared.open(parsedURL, options: [:]) { didOpen in
            if didOpen {
                EsmaLog.ghostty.info("ghostty action open_url succeeded scheme=\(scheme, privacy: .public)")
            } else {
                EsmaLog.ghostty.error("ghostty action open_url failed scheme=\(scheme, privacy: .public)")
            }
        }
        #elseif os(macOS)
        let didOpen = NSWorkspace.shared.open(parsedURL)
        if didOpen {
            EsmaLog.ghostty.info("ghostty action open_url succeeded scheme=\(scheme, privacy: .public)")
        } else {
            EsmaLog.ghostty.error("ghostty action open_url failed scheme=\(scheme, privacy: .public)")
        }
        #endif
    }

    nonisolated private static func openURLActionKindDescription(_ kind: ghostty_action_open_url_kind_e) -> String {
        switch kind {
        case GHOSTTY_ACTION_OPEN_URL_KIND_TEXT:
            "text"
        case GHOSTTY_ACTION_OPEN_URL_KIND_HTML:
            "html"
        default:
            "unknown"
        }
    }

    nonisolated private static func urlSummary(for candidateURL: String) -> String {
        guard let parsedURL = URL(string: candidateURL) else {
            return "len=\(candidateURL.utf8.count) parse=failed"
        }

        let scheme = parsedURL.scheme ?? "none"
        let host = parsedURL.host ?? "none"
        let hasQuery = parsedURL.query != nil
        return "scheme=\(scheme) host=\(host) has_query=\(hasQuery) len=\(candidateURL.utf8.count)"
    }

    nonisolated static func closeSurface(userdata: UnsafeMutableRawPointer?, processAlive: Bool) {
        _ = unsafe userdata
        _ = processAlive
    }
}

nonisolated func ghosttyRuntimeWakeupCallback(_ userdata: UnsafeMutableRawPointer?) {
    unsafe GhosttyRuntimeCallbacks.wakeup(userdata)
}

nonisolated func ghosttyRuntimeActionCallback(
    _ app: ghostty_app_t?,
    _ target: ghostty_target_s,
    _ action: ghostty_action_s
) -> Bool {
    unsafe GhosttyRuntimeCallbacks.action(app: app, target: target, action: action)
}

nonisolated func ghosttyRuntimeCloseSurfaceCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ processAlive: Bool
) {
    unsafe GhosttyRuntimeCallbacks.closeSurface(userdata: userdata, processAlive: processAlive)
}
