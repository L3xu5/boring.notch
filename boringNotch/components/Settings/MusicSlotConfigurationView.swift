import BoringCore
import Defaults
import SwiftUI
import UniformTypeIdentifiers

struct MusicSlotConfigurationView: View {
    @Default(.musicControlSlots) private var slots
    @Default(.musicControlSlotLimit) private var slotLimit
    @State private var pendingControl: MusicControlButton?

    private var visibleCount: Int {
        min(max(slotLimit, MusicControlButton.minSlotCount), MusicControlButton.maxSlotCount)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Visible controls", selection: $slotLimit) {
                ForEach(MusicControlButton.minSlotCount...MusicControlButton.maxSlotCount, id: \.self) { count in
                    Text("\(count)").tag(count)
                }
            }
            HStack(spacing: 12) {
                ForEach(0..<visibleCount, id: \.self) { index in
                    slotMenu(at: index)
                        .onDrag { NSItemProvider(object: "slot:\(index)" as NSString) }
                        .onDrop(of: [UTType.plainText.identifier], isTargeted: nil) { providers in
                            acceptDrop(providers, at: index)
                        }
                }
            }
            Text("Choose a slot to change its control. Drag slots to reorder them.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(MusicControlButton.pickerOptions, id: \.self) { control in
                        Button {
                            if let empty = slots.prefix(visibleCount).firstIndex(of: .none) { assign(control, at: empty) }
                            else { pendingControl = control }
                        } label: {
                            VStack(spacing: 6) {
                                Image(systemName: control.iconName).font(.title3)
                                    .frame(width: 44, height: 36)
                                Text(control.label).font(.caption).multilineTextAlignment(.center)
                            }
                            .frame(width: 66, height: 64)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .help("Add \(control.label) to an empty slot. Use a slot's menu to replace an existing control.")
                        .onDrag { NSItemProvider(object: "control:\(control.rawValue)" as NSString) }
                    }
                }
            }
            HStack {
                Text("Each control can appear once.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Reset to Defaults") {
                    slots = MusicControlButton.defaultLayout
                    slotLimit = MusicControlButton.defaultLayout.count
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 6)
        .onAppear { normalizeCapacity() }
        .confirmationDialog("Choose a slot to replace", isPresented: Binding(
            get: { pendingControl != nil }, set: { if !$0 { pendingControl = nil } }
        )) {
            if let control = pendingControl {
                ForEach(0..<visibleCount, id: \.self) { index in
                    Button("Slot \(index + 1): \(slot(at: index).label)") { assign(control, at: index) }
                }
            }
            Button("Cancel", role: .cancel) { pendingControl = nil }
        }
    }

    private func slotMenu(at index: Int) -> some View {
        let control = slot(at: index)
        return Menu {
            Picker("Control", selection: Binding(get: { slot(at: index) }, set: { assign($0, at: index) })) {
                Text("Empty slot").tag(MusicControlButton.none)
                ForEach(MusicControlButton.pickerOptions, id: \.self) { option in
                    Label(option.label, systemImage: option.iconName).tag(option)
                }
            }
            Divider()
            Button("Move Left") { move(from: index, to: index - 1) }.disabled(index == 0)
            Button("Move Right") { move(from: index, to: index + 1) }.disabled(index == visibleCount - 1)
            Button("Clear Slot") { assign(.none, at: index) }.disabled(control == .none)
        } label: {
            VStack(spacing: 5) {
                Image(systemName: control == .none ? "plus" : control.iconName)
                    .font(.title3).frame(width: 38, height: 32)
                Text("\(index + 1)").font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .menuStyle(.borderlessButton)
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityLabel("Slot \(index + 1)")
        .accessibilityValue(control.label)
        .help("Slot \(index + 1): \(control.label)")
    }

    private func slot(at index: Int) -> MusicControlButton {
        slots.indices.contains(index) ? slots[index] : .none
    }

    private func normalizeCapacity() {
        if slots.count < MusicControlButton.maxSlotCount {
            slots += Array(repeating: .none, count: MusicControlButton.maxSlotCount - slots.count)
        }
        if slotLimit != visibleCount { slotLimit = visibleCount }
    }

    private func assign(_ control: MusicControlButton, at index: Int) {
        normalizeCapacity()
        guard let edited = ControlLayoutEditing.assigning(control, to: index, in: slots, empty: .none) else { return }
        slots = edited
    }

    private func move(from source: Int, to destination: Int) {
        guard (0..<visibleCount).contains(source), (0..<visibleCount).contains(destination),
              let edited = ControlLayoutEditing.moving(from: source, to: destination, in: slots) else { return }
        slots = edited
    }

    private func acceptDrop(_ providers: [NSItemProvider], at index: Int) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
        provider.loadObject(ofClass: NSString.self) { item, _ in
            guard let text = item as? String else { return }
            DispatchQueue.main.async {
                if text.hasPrefix("slot:"), let source = Int(text.dropFirst(5)) {
                    move(from: source, to: index)
                } else if text.hasPrefix("control:"), let control = MusicControlButton(rawValue: String(text.dropFirst(8))) {
                    assign(control, at: index)
                }
            }
        }
        return true
    }
}
