import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

let captures = URL(filePath: CommandLine.arguments[1])
let output = URL(filePath: CommandLine.arguments[2])

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(1)
}

struct Device {
    let canvas: CGSize
    let screen: CGSize
    let cornerRadius: CGFloat
    let bezel: CGFloat
    let width: CGFloat
    let top: CGFloat
    let headline: CGFloat
    let subtitle: CGFloat
}

let devices = [
    "IPHONE_DYNAMIC_ISLAND_LARGE_PROFILE": Device(canvas: CGSize(width: 1320, height: 2868), screen: CGSize(width: 440, height: 956),
                                                  cornerRadius: 62, bezel: 8, width: 0.84, top: 0.22, headline: 0.064, subtitle: 0.032),
    "IPAD_13_PROFILE": Device(canvas: CGSize(width: 2064, height: 2752), screen: CGSize(width: 1032, height: 1376),
                              cornerRadius: 30, bezel: 14, width: 0.79, top: 0.235, headline: 0.058, subtitle: 0.025),
]
let device: Device = {
    guard let device = devices[CommandLine.arguments[3]] else { fail("unknown display \(CommandLine.arguments[3])") }
    return device
}()

let slides = [
    ("01-terminal", "terminal", "Your Terminal, Anywhere", "Run Claude Code & Codex CLI from your pocket"),
    ("02-themes", "themes", "Make It Yours", "20+ terminal themes built in"),
    ("03-hosts", "hosts", "All Your Machines, One Tap", "Manage multiple SSH hosts effortlessly"),
    ("04-switch-hosts", "switch-hosts", "Switch Hosts Instantly", "Jump between machines in a swipe"),
    ("05-keys", "keys", "Secure By Design", "SSH keys in Keychain, never exposed"),
]
let tilts: [Double] = [0, -0.7, 0.5, -0.4, 0.7]

func capture(_ name: String) -> NSImage {
    let url = captures.appending(path: "\(name).png")
    guard let image = NSImage(contentsOf: url) else { fail("missing \(url.path)") }
    return image
}

struct Magnify: Layout {
    let scale: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let size = subviews[0].sizeThatFits(.unspecified)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: .unspecified)
    }
}

struct Frame: View {
    let screen: String

    var body: some View {
        let outer = RoundedRectangle(cornerRadius: device.cornerRadius + device.bezel, style: .continuous)
        let size = CGSize(width: device.screen.width + 2 * device.bezel, height: device.screen.height + 2 * device.bezel)
        ZStack {
            outer.fill(LinearGradient(colors: [Color(white: 0.44), Color(white: 0.17), Color(white: 0.1), Color(white: 0.32)],
                                      startPoint: .topLeading, endPoint: .bottomTrailing))
            outer.strokeBorder(.white.opacity(0.22), lineWidth: 0.8)
            RoundedRectangle(cornerRadius: device.cornerRadius + device.bezel - 2.5, style: .continuous).fill(.black).padding(2.5)
            Image(nsImage: capture(screen))
                .resizable()
                .interpolation(.high)
                .frame(width: device.screen.width, height: device.screen.height)
                .clipShape(RoundedRectangle(cornerRadius: device.cornerRadius, style: .continuous))
        }
        .frame(width: size.width, height: size.height)
        .magnified(device.canvas.width * device.width / size.width)
    }
}

extension View {
    func magnified(_ scale: CGFloat) -> some View {
        Magnify(scale: scale) { scaleEffect(scale, anchor: .topLeading) }
    }
}

struct Slide: View {
    let screen: String
    let headline: String
    let subtitle: String
    let tilt: Double

    var body: some View {
        let headlineSize = device.canvas.width * device.headline
        let subtitleSize = device.canvas.width * device.subtitle
        ZStack(alignment: .top) {
            LinearGradient(stops: [.init(color: Color(red: 0.027, green: 0.106, blue: 0.133), location: 0),
                                   .init(color: Color(red: 0.063, green: 0.180, blue: 0.216), location: 0.56),
                                   .init(color: Color(red: 0.157, green: 0.349, blue: 0.396), location: 1)],
                           startPoint: UnitPoint(x: 0.2, y: 0), endPoint: UnitPoint(x: 0.8, y: 1))
            RadialGradient(colors: [Color(red: 0.341, green: 0.627, blue: 0.678).opacity(0.16), .clear],
                           center: UnitPoint(x: 0.78, y: 0.04), startRadius: 0, endRadius: device.canvas.height * 0.38)
            VStack(spacing: subtitleSize * 0.58) {
                Text(headline)
                    .font(.system(size: headlineSize, weight: .bold, design: .rounded).leading(.tight))
                    .tracking(-headlineSize * 0.035)
                    .foregroundStyle(Color(red: 0.973, green: 0.984, blue: 0.988))
                    .shadow(color: .black.opacity(0.24), radius: 7, y: 3)
                Text(subtitle)
                    .font(.system(size: subtitleSize, weight: .regular, design: .rounded))
                    .foregroundStyle(Color(red: 0.894, green: 0.937, blue: 0.949).opacity(0.78))
            }
            .multilineTextAlignment(.center)
            .frame(width: device.canvas.width * 0.86)
            .padding(.top, device.canvas.height * 0.05)
            Frame(screen: screen)
                .rotationEffect(.degrees(tilt))
                .shadow(color: .black.opacity(0.44), radius: 42, y: 34)
                .offset(y: device.canvas.height * device.top)
        }
        .frame(width: device.canvas.width, height: device.canvas.height)
        .clipped()
    }
}

MainActor.assumeIsolated {
    var drawn = Set<Data>()
    for (index, (name, screen, headline, subtitle)) in slides.enumerated() {
        let renderer = ImageRenderer(content: Slide(screen: screen, headline: headline, subtitle: subtitle, tilt: tilts[index]))
        guard let rendered = renderer.cgImage,
              rendered.width == Int(device.canvas.width), rendered.height == Int(device.canvas.height),
              let rgba = CGContext(data: nil, width: rendered.width, height: rendered.height, bitsPerComponent: 8, bytesPerRow: rendered.width * 4,
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let context = CGContext(data: nil, width: rendered.width, height: rendered.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { fail("could not render \(name) at \(Int(device.canvas.width)) × \(Int(device.canvas.height))") }
        let bounds = CGRect(x: 0, y: 0, width: rendered.width, height: rendered.height)
        rgba.clear(bounds)
        rgba.draw(rendered, in: bounds)
        let pixels = UnsafeBufferPointer(start: rgba.data!.assumingMemoryBound(to: UInt8.self), count: rendered.width * rendered.height * 4)
        guard !stride(from: 3, to: pixels.count, by: 4).contains(where: { pixels[$0] != 255 }) else {
            fail("\(name) rendered with transparent pixels instead of covering its canvas")
        }
        guard drawn.insert(Data(pixels)).inserted else { fail("\(name) rendered the same pixels as an earlier slide") }
        context.draw(rendered, in: bounds)
        let url = output.appending(path: "\(name).png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            fail("could not create \(url.path)")
        }
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        guard CGImageDestinationFinalize(destination) else { fail("could not write \(url.path)") }
    }
}
