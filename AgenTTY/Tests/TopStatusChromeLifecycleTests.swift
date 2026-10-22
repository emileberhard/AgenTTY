import Observation
import SwiftUI
import UIKit
import XCTest
@testable import AgenTTY_iOS

@MainActor
final class TopStatusChromeLifecycleTests: XCTestCase {
    func testObservableReferenceStateDefaultValueIsRecreatedDuringRootViewUpdates() {
        let counter = ReferenceStateLifetimeCounter()

        exerciseHostedLifecycle(
            scales: [1.0, 0.94, 1.08, 0.88, 1.0],
            makeRootView: { scale in
                ReferenceStateProbeView(scale: scale, counter: counter)
            }
        )

        XCTAssertGreaterThan(
            counter.initCount,
            1,
            "Reference-type @State defaults are created repeatedly as SwiftUI reinitializes transient view values."
        )
        XCTAssertGreaterThan(counter.deinitCount, 0)
    }

    func testDeferredReferenceInitializationAvoidsTransientReferenceChurn() {
        let counter = ReferenceStateLifetimeCounter()

        exerciseHostedLifecycle(
            scales: [1.0, 0.94, 1.08, 0.88, 1.0],
            makeRootView: { scale in
                DeferredReferenceStateProbeView(scale: scale, counter: counter)
            }
        )

        XCTAssertEqual(
            counter.initCount,
            1,
            "Deferring reference creation out of the @State default avoids repeated transient allocations."
        )
        XCTAssertLessThanOrEqual(counter.deinitCount, 1)
    }

    private func exerciseHostedLifecycle<Content: View>(
        scales: [CGFloat],
        makeRootView: (CGFloat) -> Content
    ) {
        precondition(!scales.isEmpty)
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first
        else {
            XCTFail("Expected a UIWindowScene while running hosted SwiftUI lifecycle tests.")
            return
        }

        autoreleasepool {
            let window = UIWindow(windowScene: windowScene)
            let controller = UIHostingController(rootView: makeRootView(scales[0]))
            window.rootViewController = controller
            window.makeKeyAndVisible()
            pumpMainRunLoop()

            for scale in scales.dropFirst() {
                controller.rootView = makeRootView(scale)
                NotificationCenter.default.post(
                    name: UIDevice.batteryStateDidChangeNotification,
                    object: nil
                )
                pumpMainRunLoop()
            }

            window.isHidden = true
            window.rootViewController = nil
            pumpMainRunLoop(iterations: 2)
        }

        pumpMainRunLoop(iterations: 2)
    }

    private func pumpMainRunLoop(iterations: Int = 1) {
        for _ in 0..<iterations {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }
}

private final class ReferenceStateLifetimeCounter {
    var initCount = 0
    var deinitCount = 0
}

@Observable
private final class ReferenceStateProbeModel {
    var updateCount = 0

    @ObservationIgnored
    private let counter: ReferenceStateLifetimeCounter

    init(counter: ReferenceStateLifetimeCounter) {
        self.counter = counter
        counter.initCount += 1
    }

    deinit {
        counter.deinitCount += 1
    }
}

private struct ReferenceStateProbeView: View {
    let scale: CGFloat

    @State private var model: ReferenceStateProbeModel

    init(scale: CGFloat, counter: ReferenceStateLifetimeCounter) {
        self.scale = scale
        _model = State(wrappedValue: ReferenceStateProbeModel(counter: counter))
    }

    var body: some View {
        GeometryReader { _ in
            Text("\(model.updateCount)")
                .scaleEffect(scale)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryStateDidChangeNotification)) { _ in
            model.updateCount += 1
        }
    }
}

private struct DeferredReferenceStateProbeView: View {
    let scale: CGFloat
    let counter: ReferenceStateLifetimeCounter

    @State private var model: ReferenceStateProbeModel?

    var body: some View {
        GeometryReader { _ in
            Text("\(model?.updateCount ?? 0)")
                .scaleEffect(scale)
        }
        .task {
            if model == nil {
                model = ReferenceStateProbeModel(counter: counter)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryStateDidChangeNotification)) { _ in
            model?.updateCount += 1
        }
    }
}
