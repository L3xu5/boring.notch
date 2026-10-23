//
//  HoverButton.swift
//  boringNotch
//
//  Created by Kraigo on 04.09.2024.
//

import SwiftUI

struct HoverButton: View {
    var icon: String
    var iconColor: Color = .primary
    var scale: Image.Scale = .medium
    var label: String? = nil
    var action: () -> Void
    var contentTransition: ContentTransition = .symbolEffect;
    
    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var actionLabel: String {
        if let label { return label }
        switch icon {
        case "shuffle": return "Shuffle"
        case "backward.fill": return "Previous track"
        case "pause.fill": return "Pause"
        case "play.fill": return "Play"
        case "forward.fill": return "Next track"
        case "repeat", "repeat.1": return "Repeat"
        case "heart", "heart.fill": return "Like track"
        case "hand.thumbsdown": return "Dislike track"
        case "gobackward.15": return "Back 15 seconds"
        case "goforward.15": return "Forward 15 seconds"
        default: return "Music control"
        }
    }

    var body: some View {
        let size = CGFloat(scale == .large ? 40 : 30)
        
        Button(action: action) {
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .frame(width: size, height: size)
                .overlay {
                    Capsule()
                        .fill(isHovering ? Color.gray.opacity(0.2) : .clear)
                        .frame(width: size, height: size)
                        .overlay {
                            Image(systemName: icon)
                                .foregroundColor(iconColor)
                                .contentTransition(contentTransition)
                                .font(scale == .large ? .largeTitle : .body)
                        }
                }
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel(actionLabel)
        .help(actionLabel)
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) {
                isHovering = hovering
            }
        }
    }
}
