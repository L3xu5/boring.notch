import AppKit

/// Discovery is an AppKit query, not a hidden picker interaction. It needs neither a dummy
/// window nor a continuation/timeout that can outlive its caller.
@MainActor
struct ShareServiceFinder {
    func findApplicableServices(for items: [Any]) async -> [NSSharingService] {
        NSSharingService.sharingServices(forItems: items)
    }
}
