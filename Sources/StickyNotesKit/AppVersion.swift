import Foundation

/// What `scripts/build-app.sh` stamps into Info.plist. Until it has, the plist
/// holds these placeholders, and so does a run from `swift run`, which has no
/// bundle at all.
enum AppVersion {
    static let versionPlaceholder = "__APP_VERSION__"
    static let buildPlaceholder = "__BUILD_NUMBER__"

    /// "v0.9.0" for a stamped bundle, "dev" for anything else, including a
    /// bundle whose version or build number was never filled in.
    static func displayString(info: [String: Any]) -> String {
        guard let version = stamped(info["CFBundleShortVersionString"], placeholder: versionPlaceholder),
              stamped(info["CFBundleVersion"], placeholder: buildPlaceholder) != nil
        else { return "dev" }
        return "v\(version)"
    }

    private static func stamped(_ value: Any?, placeholder: String) -> String? {
        guard let text = value as? String, !text.isEmpty, text != placeholder else { return nil }
        return text
    }
}
