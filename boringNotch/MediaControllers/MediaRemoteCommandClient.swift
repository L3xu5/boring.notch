import Foundation

/// Optional private symbols affect command capabilities, not AX/adapter metadata availability.
final class MediaRemoteCommandClient {
    private typealias Send = @convention(c) (Int, AnyObject?) -> Void
    private typealias SetPosition = @convention(c) (Double) -> Void
    private typealias SetMode = @convention(c) (Int) -> Void
    private let bundle: CFBundle?
    private let sendFunction: Send?
    private let seekFunction: SetPosition?
    private let shuffleFunction: SetMode?
    private let repeatFunction: SetMode?
    init() {
        let bundle = CFBundleCreate(kCFAllocatorDefault, NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework"))
        self.bundle = bundle
        func pointer(_ name: String) -> UnsafeMutableRawPointer? { bundle.flatMap { CFBundleGetFunctionPointerForName($0, name as CFString) } }
        sendFunction = pointer("MRMediaRemoteSendCommand").map { unsafeBitCast($0, to: Send.self) }
        seekFunction = pointer("MRMediaRemoteSetElapsedTime").map { unsafeBitCast($0, to: SetPosition.self) }
        shuffleFunction = pointer("MRMediaRemoteSetShuffleMode").map { unsafeBitCast($0, to: SetMode.self) }
        repeatFunction = pointer("MRMediaRemoteSetRepeatMode").map { unsafeBitCast($0, to: SetMode.self) }
    }
    var canSeek: Bool { seekFunction != nil }
    var canShuffle: Bool { shuffleFunction != nil }
    var canRepeat: Bool { repeatFunction != nil }
    func send(_ command: Int) { sendFunction?(command, nil) }
    func seek(_ position: Double) { if position.isFinite { seekFunction?(max(0, position)) } }
    func shuffle(_ mode: Int) { shuffleFunction?(mode) }
    func repeatMode(_ mode: Int) { repeatFunction?(mode) }
}
