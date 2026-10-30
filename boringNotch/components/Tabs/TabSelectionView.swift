//
//  TabSelectionView.swift
//  boringNotch
//
//  Created by Hugo Persson on 2024-08-25.
//

import Defaults
import SwiftUI

struct TabModel: Identifiable {
    var id: NotchViews { view }
    let label: String
    let icon: String
    let view: NotchViews
}

struct TabSelectionView: View {
    @EnvironmentObject private var vm: BoringViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @ObservedObject var musicManager = MusicManager.shared
    @ObservedObject private var shelf = ShelfStateViewModel.shared
    @Default(.enableLyrics) var enableLyrics
    @Default(.boringShelf) private var shelfEnabled
    @Namespace var animation

    // The source may provide the exact recording's plain text without synchronized lines.
    private var tabs: [TabModel] {
        var result = [TabModel(label: "Home", icon: "house.fill", view: .home)]
        if enableLyrics, !musicManager.syncedLyrics.isEmpty || !musicManager.currentLyrics.isEmpty {
            result.append(TabModel(label: "Lyrics", icon: "quote.bubble.fill", view: .lyrics))
        }
        if shelfEnabled { result.append(TabModel(label: "Shelf", icon: "tray.fill", view: .shelf)) }
        return result
    }

    var body: some View {
        HStack(spacing: 0) {
            if coordinator.alwaysShowTabs || tabs.contains(where: { $0.view == .lyrics }) || (shelfEnabled && !shelf.isEmpty) {
            ForEach(tabs) { tab in
                    TabButton(label: tab.label, icon: tab.icon, selected: vm.currentView == tab.view) {
                        withAnimation(reduceMotion ? nil : .smooth) {
                            vm.currentView = tab.view
                        }
                    }
                    .frame(height: 26)
                    .foregroundStyle(tab.view == vm.currentView ? .white : .gray)
                    .background {
                        if tab.view == vm.currentView {
                            Capsule()
                                .fill(Color(nsColor: .secondarySystemFill))
                                .matchedGeometryEffect(id: "capsule", in: animation)
                        } else {
                            Capsule()
                                .fill(Color.clear)
                                .matchedGeometryEffect(id: "capsule", in: animation)
                                .hidden()
                        }
                    }
            }
            }
        }
        .clipShape(Capsule())
        .onAppear { validateSelection() }
        .onChange(of: tabs.map(\.id)) { _, _ in validateSelection() }
        .onChange(of: coordinator.alwaysShowTabs) { _, showing in
            if !showing && !tabs.contains(where: { $0.view == .lyrics }) && shelf.isEmpty {
                vm.currentView = .home
            }
        }
    }

    private func validateSelection() {
        if !tabs.contains(where: { $0.view == vm.currentView }) { vm.currentView = .home }
    }
}

#Preview {
    BoringHeader().environmentObject(BoringViewModel())
}
