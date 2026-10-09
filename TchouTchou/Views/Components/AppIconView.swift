import SwiftUI
import AppKit

/// Icône de l'application (celle du bundle), utilisée dans l'entête, la barre latérale et les pages.
struct AppIconView: View {
    var size: CGFloat = 22
    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
