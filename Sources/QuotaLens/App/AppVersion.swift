// Centralized app version metadata.

import Foundation

public enum AppVersion {
    public static var marketingVersion: String {
        bundleString(forKey: "CFBundleShortVersionString") ?? "1.0.0"
    }

    public static var buildNumber: String {
        bundleString(forKey: "CFBundleVersion") ?? "1"
    }

    public static var displayString: String {
        "v\(shortVersion(marketingVersion))"
    }

    static func shortVersion(_ version: String) -> String {
        // Build/prerelease identifiers remain in bundle metadata for updating, not in the UI.
        version.split(separator: "-", maxSplits: 1).first.map(String.init)?
            .split(separator: "+", maxSplits: 1).first.map(String.init) ?? version
    }

    private static func bundleString(forKey key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
