import SwiftUI
import UIKit

enum ShellIndicatorTextStyle {
    static let pointSize: CGFloat = 11
    static let fontWeight: Font.Weight = .regular
    static let fontDesign: Font.Design = .default
    static let minimumScaleFactor: CGFloat = 0.75
    static let uiFont = UIFont.systemFont(ofSize: pointSize, weight: .regular)

    static var font: Font {
        .system(size: pointSize, weight: fontWeight, design: fontDesign)
    }
}
