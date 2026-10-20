import os

/// Unified logging categories. View with:
/// `make logs`, or `/usr/bin/log stream --predicate 'subsystem == "com.franklinperez.Pankapture"' --level debug`
public enum Log {
    public static let subsystem = "com.franklinperez.Pankapture"

    public static let app = Logger(subsystem: subsystem, category: "app")
    public static let capture = Logger(subsystem: subsystem, category: "capture")
    public static let hotkeys = Logger(subsystem: subsystem, category: "hotkeys")
    public static let permissions = Logger(subsystem: subsystem, category: "permissions")
    public static let output = Logger(subsystem: subsystem, category: "output")
    public static let overlay = Logger(subsystem: subsystem, category: "overlay")
    public static let recording = Logger(subsystem: subsystem, category: "recording")
    public static let editor = Logger(subsystem: subsystem, category: "editor")
    public static let library = Logger(subsystem: subsystem, category: "library")
    public static let updates = Logger(subsystem: subsystem, category: "updates")

    /// Signposts for performance budgets (PRD §6.1). View in Instruments → os_signpost.
    public static let signposter = OSSignposter(subsystem: subsystem, category: .pointsOfInterest)
}
