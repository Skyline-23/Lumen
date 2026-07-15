import AppKit
import SwiftUI

struct LumenBrandMark: View {
    var body: some View {
        Group {
            if let url = Bundle.main.url(forResource: "icon", withExtension: "svg"),
               let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(463.0 / 398.0, contentMode: .fit)
            } else {
                Color.clear
            }
        }
        .accessibilityHidden(true)
    }
}
