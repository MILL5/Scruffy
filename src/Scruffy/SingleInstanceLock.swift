import AppKit
import Darwin

final class SingleInstanceLock {
    @MainActor private static var appLock: SingleInstanceLock?
    private let descriptor: Int32

    private init(descriptor: Int32) { self.descriptor = descriptor }
    deinit { close(descriptor) }

    static func acquire(at url: URL) throws -> SingleInstanceLock? {
        let descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            if code == EINTR { continue }
            close(descriptor)
            if code == EWOULDBLOCK { return nil }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        // Keep this inode in place: unlinking it would let another process lock a different file.
        return SingleInstanceLock(descriptor: descriptor)
    }

    @MainActor
    static func enforce() {
        do {
            let directory = try FileManager.default.url(for: .applicationSupportDirectory,
                                                        in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("Scruffy", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard let lock = try acquire(at: directory.appendingPathComponent("instance.lock")) else {
                let identifier = Bundle.main.bundleIdentifier ?? "com.richcrane.scruffy"
                NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
                    .first { $0.processIdentifier != getpid() }?.activate(options: .activateAllWindows)
                exit(EXIT_SUCCESS)
            }
            appLock = lock
        } catch {
            let alert = NSAlert()
            alert.messageText = "Scruffy couldn’t start"
            alert.informativeText = "Unable to check whether Scruffy is already running. \(error.localizedDescription)"
            alert.runModal()
            exit(EXIT_FAILURE)
        }
    }
}
