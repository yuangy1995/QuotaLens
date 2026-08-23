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
        "v\(marketingVersion)"
    }

    private static func bundleString(forKey key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
