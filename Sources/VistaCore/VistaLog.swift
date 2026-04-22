// VistaLog.swift — Thin tee around NSLog that also appends to a file.
//
// macOS's unified log (os_log / NSLog) is noisy to query via `log show`
// and sometimes filters third-party process messages out entirely. A
// plain file under ~/Library/Logs/Vista/vista.log is trivially tailable
// with `tail -f` and survives across launches, which is what we actually
// need for diagnosing "nothing got indexed" reports.
//
// Call `VistaLog.log("…")` anywhere you'd have called `NSLog("…")` —
// the output still shows up in Console.app (via NSLog), just with a
// reliable on-disk copy too.

import Foundation

public enum VistaLog {

    /// Resolved lazily so VistaPaths isn't invoked during module init.
    private static let fileHandle: FileHandle? = {
        do {
            let dir = try FileManager.default.url(
                for: .libraryDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("Logs/Vista", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("vista.log")
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            handle.seekToEndOfFile()
            return handle
        } catch {
            // If we can't open the log file we still want NSLog output
            // to flow; return nil and let the write path short-circuit.
            return nil
        }
    }()

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private static let lock = NSLock()

    /// Logs to NSLog AND appends to the file sink. The prefix `vista:`
    /// keeps console filtering easy and matches existing usage across
    /// the codebase.
    public static func log(_ message: String) {
        NSLog("vista: %@", message)

        guard let handle = fileHandle else { return }
        let line = "\(formatter.string(from: Date())) vista: \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        lock.lock()
        defer { lock.unlock() }
        try? handle.write(contentsOf: data)
    }
}
