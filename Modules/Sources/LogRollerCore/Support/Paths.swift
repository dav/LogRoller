import Foundation

public enum LogRollerPaths {
    public static func defaultStorageRoot() -> URL {
        let base = URL.applicationSupportDirectory.appending(path: "LogRoller", directoryHint: .isDirectory)
        return base.appending(path: "runs", directoryHint: .isDirectory)
    }
}
