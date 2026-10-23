import SwiftUI

struct ClosedBatteryActivityView: View {
    @EnvironmentObject private var vm: BoringViewModel
    @ObservedObject private var battery = BatteryStatusViewModel.shared

    var body: some View {
        HStack(spacing: 0) {
            Text(battery.statusText).font(.subheadline).foregroundStyle(.white)
            Rectangle().fill(.black).frame(width: vm.closedNotchSize.width + 10)
            BoringBatteryView(
                batteryWidth: 30, isCharging: battery.isCharging,
                isInLowPowerMode: battery.isInLowPowerMode, isPluggedIn: battery.isPluggedIn,
                levelBattery: battery.levelBattery, isForNotification: true
            )
            .frame(width: 76, alignment: .trailing)
        }
        .frame(height: vm.effectiveClosedNotchHeight)
    }
}
