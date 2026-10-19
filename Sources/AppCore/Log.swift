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
}
