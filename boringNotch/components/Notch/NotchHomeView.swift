import Defaults
import SwiftUI

struct NotchHomeView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var webcamManager = WebcamManager.shared
    @ObservedObject var batteryModel = BatteryStatusViewModel.shared
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @Default(.showMirror) private var mirrorEnabled
    let albumArtNamespace: Namespace.ID

    var body: some View {
        Group {
            if !coordinator.firstLaunch {
                mainContent
            }
        }
        // simplified: use a straightforward opacity transition
        .transition(.opacity)
    }

    private var shouldShowCamera: Bool {
        mirrorEnabled && vm.isCameraPreviewVisible
    }

    private var mainContent: some View {
        HStack(alignment: .top, spacing: (shouldShowCamera && Defaults[.showCalendar]) ? 10 : 15) {
            MusicPlayerView(albumArtNamespace: albumArtNamespace)

            if Defaults[.showCalendar] {
                CalendarView()
                    .frame(width: shouldShowCamera ? 170 : 215)
                    .onHover { isHovering in
                        vm.isHoveringCalendar = isHovering
                    }
                    .environmentObject(vm)
                    .transition(.opacity)
            }

            if shouldShowCamera {
                CameraPreviewView(webcamManager: webcamManager)
                    .scaledToFit()
                    .transition(.identity)
            }
        }
        .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .top)), removal: .opacity))
        .blur(radius: vm.notchState == .closed ? 30 : 0)
    }
}
