import AppKit
import SwiftUI

enum LumenAuthenticationField: Hashable {
    case ownerName
    case newPassword
    case passwordConfirmation
    case loginPassword
    case factoryResetConfirmation
}

struct LumenAuthenticationPalette {
    let heroBackground: Color
    let formBackground: Color
    let primaryText: Color
    let secondaryText: Color
    let tertiaryText: Color
    let amberGlow: Color
    let coralGlow: Color
    let mintGlow: Color
    let tint: Color
    let watermarkOpacity: Double

    init(colorScheme: ColorScheme) {
        if colorScheme == .dark {
            heroBackground = Color(red: 0.075, green: 0.072, blue: 0.058)
            formBackground = Color(red: 0.055, green: 0.058, blue: 0.07)
            primaryText = Color.white.opacity(0.94)
            secondaryText = Color.white.opacity(0.66)
            tertiaryText = Color.white.opacity(0.43)
            amberGlow = Color(red: 1.0, green: 0.66, blue: 0.10).opacity(0.34)
            coralGlow = Color(red: 1.0, green: 0.33, blue: 0.22).opacity(0.22)
            mintGlow = Color(red: 0.20, green: 0.78, blue: 0.68).opacity(0.16)
            tint = Color(red: 1.0, green: 0.42, blue: 0.20)
            watermarkOpacity = 0.075
        } else {
            heroBackground = Color(red: 1.0, green: 0.985, blue: 0.94)
            formBackground = Color(red: 0.995, green: 0.992, blue: 0.98)
            primaryText = Color(red: 0.08, green: 0.075, blue: 0.06)
            secondaryText = Color.black.opacity(0.58)
            tertiaryText = Color.black.opacity(0.42)
            amberGlow = Color(red: 1.0, green: 0.77, blue: 0.16).opacity(0.72)
            coralGlow = Color(red: 1.0, green: 0.39, blue: 0.28).opacity(0.28)
            mintGlow = Color(red: 0.22, green: 0.86, blue: 0.76).opacity(0.24)
            tint = Color(red: 0.94, green: 0.34, blue: 0.14)
            watermarkOpacity = 0.045
        }
    }
}

@MainActor
enum LumenAuthenticationInputSource {
    static func selectEnglishForCurrentField() -> Bool {
        guard let inputContext = NSTextInputContext.current else {
            return false
        }
        inputContext.allowedInputSourceLocales = ["en"]
        guard let englishInputSource = inputContext.keyboardInputSources?.first else {
            return false
        }
        if inputContext.selectedKeyboardInputSource != englishInputSource {
            inputContext.selectedKeyboardInputSource = englishInputSource
        }
        return true
    }
}
