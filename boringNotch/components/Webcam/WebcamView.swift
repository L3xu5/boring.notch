//
//  WebcamView.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 19/08/24.
//

import AVFoundation
import Defaults
import SwiftUI

struct CameraPreviewView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var webcamManager: WebcamManager
    
    @State private var previewConsumer: UUID?
    private var previewIsActive: Bool { vm.notchState == .open && vm.isCameraExpanded }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let reference = webcamManager.sessionReference {
                    CameraPreviewLayerView(session: reference.session)
                        .scaleEffect(x: -1, y: 1)
                        .clipShape(RoundedRectangle(cornerRadius: Defaults[.mirrorShape] == .rectangle ? !Defaults[.cornerRadiusScaling] ? MusicPlayerImageSizes.cornerRadiusInset.closed : MusicPlayerImageSizes.cornerRadiusInset.opened : 100))
                        .frame(width: geometry.size.width, height: geometry.size.width)
                        .opacity(webcamManager.isSessionRunning ? 1 : 0)
                }

                if !webcamManager.isSessionRunning {
                    ZStack {
                        RoundedRectangle(cornerRadius: Defaults[.mirrorShape] == .rectangle ? !Defaults[.cornerRadiusScaling] ? MusicPlayerImageSizes.cornerRadiusInset.closed : 12 : 100)
                            .fill(Color(red: 20/255, green: 20/255, blue: 20/255))
                            .strokeBorder(.white.opacity(0.04), lineWidth: 1)
                            .frame(width: geometry.size.width, height: geometry.size.width)
                        VStack(spacing: 8) {
                            Image(systemName: webcamManager.authorizationStatus == .denied ? "exclamationmark.triangle" : "web.camera")
                                .foregroundStyle(.gray)
                                .font(.system(size: geometry.size.width/3.5))
                            Text(webcamManager.authorizationStatus == .denied ? "Access Denied" : "Mirror")
                                .font(.caption2)
                                .foregroundColor(.gray)
                        }
                    }
                }
            }
            .onTapGesture {
                handleCameraTap()
            }
            .onAppear { synchronizePreviewLease() }
            .onChange(of: previewIsActive) { _, _ in synchronizePreviewLease() }
            .onDisappear { releasePreviewLease() }
        }
        .aspectRatio(1, contentMode: .fit)
    }
    
    private func handleCameraTap() { vm.toggleCameraPreview() }

    private func synchronizePreviewLease() {
        if previewIsActive {
            if previewConsumer == nil { previewConsumer = webcamManager.acquirePreviewConsumer() }
        } else { releasePreviewLease() }
    }
    private func releasePreviewLease() {
        guard let consumer = previewConsumer else { return }
        previewConsumer = nil
        webcamManager.releasePreviewConsumer(consumer)
    }

}

struct CameraPreviewLayerView: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.frame = view.bounds
        previewLayer.videoGravity = .resizeAspectFill
        view.layer = previewLayer
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let previewLayer = nsView.layer as? AVCaptureVideoPreviewLayer else { return }
        if previewLayer.session !== session { previewLayer.session = session }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = nsView.bounds
        CATransaction.commit()
    }
}

#Preview {
    CameraPreviewView(webcamManager: .shared)
}
