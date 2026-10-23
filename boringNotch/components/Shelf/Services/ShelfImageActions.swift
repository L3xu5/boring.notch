import AppKit
import Foundation

@MainActor
enum ShelfImageActions {
    private static var sliderHandlerAssoc = AssociatedObject<AnyObject>()
    @MainActor
    static func removeBackground() {
        let selected = ShelfSelectionModel.shared.selectedItems(in: ShelfStateViewModel.shared.items)
        let imageURLs = selected.compactMap { $0.fileURL }.filter { ImageProcessingService.shared.isImageFile($0) }

        guard let imageURL = imageURLs.first else { return }

        Task {
            do {
                let resultURL = try await imageURL.accessSecurityScopedResource { url in
                    try await ImageProcessingService.shared.removeBackground(from: url)
                }

                if let resultURL = resultURL {
                    await ShelfStateViewModel.shared.addGeneratedFile(at: resultURL)
                }
            } catch {
                print("❌ Failed to remove background: \(error.localizedDescription)")
                await showErrorAlert(title: "Background Removal Failed", message: error.localizedDescription)
            }
        }
    }

    @MainActor
    static func createPDF() {
        let selected = ShelfSelectionModel.shared.selectedItems(in: ShelfStateViewModel.shared.items)
        let imageURLs = selected.compactMap { $0.fileURL }.filter { ImageProcessingService.shared.isImageFile($0) }

        guard !imageURLs.isEmpty else { return }

        Task {
            do {
                let resultURL = try await imageURLs.accessSecurityScopedResources { urls in
                    try await ImageProcessingService.shared.createPDF(from: urls)
                }

                if let resultURL = resultURL {
                    await ShelfStateViewModel.shared.addGeneratedFile(at: resultURL)
                }
            } catch {
                print("❌ Failed to create PDF: \(error.localizedDescription)")
                await showErrorAlert(title: "PDF Creation Failed", message: error.localizedDescription)
            }
        }
    }

    @MainActor
    static func showConversionDialog() {
        let selected = ShelfSelectionModel.shared.selectedItems(in: ShelfStateViewModel.shared.items)
        let imageURLs = selected.compactMap { $0.fileURL }.filter { ImageProcessingService.shared.isImageFile($0) }

        guard let imageURL = imageURLs.first else { return }

        // Create and show conversion options dialog with better layout
        let alert = NSAlert()
        alert.messageText = "Convert Image"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Convert")
        alert.addButton(withTitle: "Cancel")

        // Create accessory view with better spacing and organization
        let accessoryView = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 180))
        accessoryView.wantsLayer = true

        // MARK: Format Row
        let formatLabel = NSTextField(labelWithString: "Format:")
        formatLabel.frame = NSRect(x: 0, y: 145, width: 100, height: 20)
        formatLabel.font = .systemFont(ofSize: 12, weight: .medium)
        accessoryView.addSubview(formatLabel)

        let formatPopup = NSPopUpButton(frame: NSRect(x: 120, y: 140, width: 250, height: 28))
        formatPopup.addItems(withTitles: ["PNG", "JPEG", "HEIC", "TIFF", "BMP"])
        formatPopup.selectItem(at: 0)
        formatPopup.font = .systemFont(ofSize: 12)
        accessoryView.addSubview(formatPopup)

        // MARK: Image Size Row
        let imageSizeLabel = NSTextField(labelWithString: "Image Size:")
        imageSizeLabel.frame = NSRect(x: 0, y: 105, width: 100, height: 20)
        imageSizeLabel.font = .systemFont(ofSize: 12, weight: .medium)
        accessoryView.addSubview(imageSizeLabel)

        let imageSizePopup = NSPopUpButton(frame: NSRect(x: 120, y: 100, width: 160, height: 28))
        imageSizePopup.addItems(withTitles: ["Actual Size", "Large", "Medium", "Small", "Custom..."])
        imageSizePopup.selectItem(at: 0)
        imageSizePopup.font = .systemFont(ofSize: 12)
        accessoryView.addSubview(imageSizePopup)

        // Custom size field (initially hidden)
        let customSizeField = NSTextField(frame: NSRect(x: 285, y: 103, width: 85, height: 22))
        customSizeField.placeholderString = "e.g., 1920"
        customSizeField.font = .systemFont(ofSize: 12)
        customSizeField.isHidden = true
        accessoryView.addSubview(customSizeField)

        // MARK: Preserve Metadata Checkbox
        let metadataCheckbox = NSButton(checkboxWithTitle: "Preserve Metadata", target: nil, action: nil)
        metadataCheckbox.frame = NSRect(x: 120, y: 65, width: 200, height: 20)
        metadataCheckbox.font = .systemFont(ofSize: 12)
        metadataCheckbox.state = .on
        accessoryView.addSubview(metadataCheckbox)

        // MARK: Separator line
        let separatorLine = NSView(frame: NSRect(x: 0, y: 50, width: 380, height: 1))
        separatorLine.wantsLayer = true
        separatorLine.layer?.backgroundColor = NSColor.separatorColor.cgColor
        accessoryView.addSubview(separatorLine)

        // MARK: Format-specific options (shown/hidden based on format selection)
        let qualityRow = NSView(frame: NSRect(x: 0, y: 15, width: 380, height: 30))
        qualityRow.wantsLayer = true

        let qualityLabel = NSTextField(labelWithString: "Compression:")
        qualityLabel.frame = NSRect(x: 0, y: 7, width: 100, height: 20)
        qualityLabel.font = .systemFont(ofSize: 12, weight: .medium)
        qualityRow.addSubview(qualityLabel)

        let qualitySlider = NSSlider(frame: NSRect(x: 120, y: 12, width: 200, height: 20))
        qualitySlider.minValue = 0.0
        qualitySlider.maxValue = 1.0
        qualitySlider.doubleValue = 0.85
        accessoryView.addSubview(qualitySlider)

        let qualityValueLabel = NSTextField(labelWithString: "85%")
        qualityValueLabel.frame = NSRect(x: 325, y: 7, width: 55, height: 20)
        qualityValueLabel.font = .systemFont(ofSize: 12)
        qualityValueLabel.alignment = .left
        accessoryView.addSubview(qualityValueLabel)

        // Update quality label and hide/show compression row based on format
        let updateQualityLabel = {
            let value = Int(qualitySlider.doubleValue * 100)
            qualityValueLabel.stringValue = "\(value)%"
        }

        let updateCompressionVisibility = {
            let formatIndex = formatPopup.indexOfSelectedItem
            let showCompression = formatIndex == 1 || formatIndex == 2 // JPEG or HEIC
            qualitySlider.isHidden = !showCompression
            qualityValueLabel.isHidden = !showCompression
            qualityLabel.isHidden = !showCompression
        }

        let updateCustomSizeVisibility = {
            let sizeIndex = imageSizePopup.indexOfSelectedItem
            customSizeField.isHidden = sizeIndex != 4 // Show only for "Custom..."
        }

        // Create a target object to handle slider value changes
        class SliderHandler: NSObject {
            let updateLabel: () -> Void
            let updateVisibility: () -> Void
            let updateCustomSize: () -> Void
            init(updateLabel: @escaping () -> Void, updateVisibility: @escaping () -> Void, updateCustomSize: @escaping () -> Void) {
                self.updateLabel = updateLabel
                self.updateVisibility = updateVisibility
                self.updateCustomSize = updateCustomSize
            }
            @objc func sliderChanged(_ sender: NSSlider) {
                updateLabel()
            }
            @objc func formatChanged(_ sender: NSPopUpButton) {
                updateVisibility()
            }
            @objc func sizeChanged(_ sender: NSPopUpButton) {
                updateCustomSize()
            }
        }

        let handler = SliderHandler(updateLabel: updateQualityLabel, updateVisibility: updateCompressionVisibility, updateCustomSize: updateCustomSizeVisibility)
        qualitySlider.target = handler
        qualitySlider.action = #selector(SliderHandler.sliderChanged(_:))
        qualitySlider.isContinuous = true

        formatPopup.target = handler
        formatPopup.action = #selector(SliderHandler.formatChanged(_:))

        imageSizePopup.target = handler
        imageSizePopup.action = #selector(SliderHandler.sizeChanged(_:))

        updateCompressionVisibility()
        updateQualityLabel()
        updateCustomSizeVisibility()

        // Keep the handler alive using the `AssociatedObject` helper instead of a magic string key
        sliderHandlerAssoc[accessoryView] = handler

        alert.accessoryView = accessoryView

        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            // Get selected options
            let formatIndex = formatPopup.indexOfSelectedItem
            let format: ImageConversionOptions.ImageFormat
            switch formatIndex {
            case 0: format = .png
            case 1: format = .jpeg
            case 2: format = .heic
            case 3: format = .tiff
            case 4: format = .bmp
            default: format = .png
            }

            let quality = qualitySlider.doubleValue

            // Get max dimension based on image size selection
            let maxDimension: CGFloat? = {
                let sizeIndex = imageSizePopup.indexOfSelectedItem
                switch sizeIndex {
                case 0: return nil // Actual Size
                case 1: return 1280 // Large
                case 2: return 640  // Medium
                case 3: return 320  // Small
                case 4: // Custom (user-specified)
                    let text = customSizeField.stringValue.trimmingCharacters(in: .whitespaces)
                    guard !text.isEmpty, let value = Double(text), value > 0 else { return nil }
                    return CGFloat(value)
                default: return nil
                }
            }()

            let removeMetadata = metadataCheckbox.state == .off // Note: we invert this

            let options = ImageConversionOptions(
                format: format,
                compressionQuality: quality,
                maxDimension: maxDimension,
                removeMetadata: removeMetadata
            )

            Task {
                do {
                    let resultURL = try await imageURL.accessSecurityScopedResource { url in
                        try await ImageProcessingService.shared.convertImage(from: url, options: options)
                    }

                    if let resultURL = resultURL {
                        await ShelfStateViewModel.shared.addGeneratedFile(at: resultURL)
                    }
                } catch {
                    print("❌ Failed to convert image: \(error.localizedDescription)")
                    showErrorAlert(title: "Image Conversion Failed", message: error.localizedDescription)
                }
            }
        }
    }

    @MainActor
    private static func showErrorAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
