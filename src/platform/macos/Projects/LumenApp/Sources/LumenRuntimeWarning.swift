import SwiftUI

enum LumenRuntimeEventDisposition: Int {
    case raised
    case cleared
}

struct LumenRuntimeWarning: Identifiable, Equatable {
    let code: Int
    let message: String

    var id: Int { code }
}

struct LumenRuntimeWarningBanner: View {
    let warning: LumenRuntimeWarning

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(LumenCopy.Diagnostics.runtimeWarning)
                    .font(.caption.weight(.semibold))
                Text(warning.message)
                    .font(.caption)
                    .textSelection(.enabled)
            }
        } icon: {
            LumenAssetIconView(.warning)
                .frame(width: 16, height: 16)
        }
        .foregroundStyle(.orange)
        .fixedSize(horizontal: false, vertical: true)
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.11), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}
