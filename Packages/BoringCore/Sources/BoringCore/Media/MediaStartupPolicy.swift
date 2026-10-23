public enum MediaStartupPolicy {
    public static func isIsolatedPreview(debugBuild: Bool, bundleIdentifier: String?, arguments: [String]) -> Bool {
        debugBuild && bundleIdentifier == "local.boringnotch.preview" && arguments.contains("--ui-snapshot")
    }
    public static func shouldStartAutomatically(firstLaunch: Bool, isolatedPreview: Bool) -> Bool {
        !firstLaunch && !isolatedPreview
    }
}
