//
//  Tokens.swift
//  ConduitDesign
//
//  SwiftUI bindings for the generated design tokens. The values come from
//  Shared/Design/tokens.json; this file only decides how a Mac renders them.
//

import AppKit
import SwiftUI

/// A colour with a light and a dark value, resolved by the view's appearance.
public nonisolated struct ColorToken: Sendable, Hashable {
    public let light: UInt32
    public let dark: UInt32

    public init(light: UInt32, dark: UInt32) {
        self.light = light
        self.dark = dark
    }

    public var color: Color { Color(nsColor: nsColor) }

    public var nsColor: NSColor {
        let light = light, dark = dark
        return NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(rgb: isDark ? dark : light)
        }
    }
}

public nonisolated struct TypeRole: Sendable, Hashable {
    public enum Weight: Sendable, Hashable {
        case regular, medium, semibold, bold
    }

    public let size: CGFloat
    public let weight: Weight

    public init(size: CGFloat, weight: Weight) {
        self.size = size
        self.weight = weight
    }

    public var font: Font {
        .system(size: size, weight: fontWeight)
    }

    private var fontWeight: Font.Weight {
        switch weight {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        }
    }
}

public nonisolated struct FeatureToken: Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    /// SF Symbol name.
    public let symbol: String

    public init(id: String, title: String, symbol: String) {
        self.id = id
        self.title = title
        self.symbol = symbol
    }
}

private extension NSColor {
    nonisolated convenience init(rgb: UInt32) {
        self.init(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                  green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255,
                  alpha: 1)
    }
}
