import Darwin
import Foundation

/// Makes macOS check permissions against iMessage MCP itself, whichever app started it.
///
/// macOS checks Full Disk Access and Automation against the "responsible" process: normally
/// the app at the top of the process tree. When Cursor, Codex, VS Code or Terminal start this
/// server, that is them, so the grant on iMessage MCP would be ignored and the user would have
/// to give their editor or terminal access to the whole disk. The Claude app avoids this by
/// starting servers through its `disclaimer` helper. We do the same thing ourselves: relaunch
/// this executable with responsibility disclaimed, pass stdin/stdout/stderr straight through,
/// and exit with the child's status.
public enum Responsibility {
    static let marker = "IMESSAGE_MCP_DISCLAIMED"

    private typealias SetDisclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32

    /// Returns only if relaunching was not possible or already happened (in the child).
    public static func becomeResponsibleProcess(executable: String) {
        if getenv(marker) != nil { return }
        // Private but long-standing libsystem call, used by LLDB, Chromium and Qt for the same reason.
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim")
        else { return }
        let setDisclaim = unsafeBitCast(symbol, to: SetDisclaim.self)

        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { return }
        defer { posix_spawnattr_destroy(&attributes) }
        guard setDisclaim(&attributes, 1) == 0 else { return }

        setenv(marker, "1", 1)
        let argv: [UnsafeMutablePointer<CChar>?] = CommandLine.arguments.map { strdup($0) } + [nil]
        var pid: pid_t = 0
        let status = posix_spawn(&pid, executable, nil, &attributes, argv, environ)
        if status != 0 {
            unsetenv(marker)
            return  // carry on in this process; at worst permissions are checked as before
        }
        child = pid
        // The client stops us with SIGTERM or SIGINT; pass it on so the child does not linger.
        for signalNumber in [SIGTERM, SIGINT, SIGHUP] {
            signal(signalNumber) { received in
                if Responsibility.child > 0 { kill(Responsibility.child, received) }
            }
        }
        var result: Int32 = 0
        while waitpid(pid, &result, 0) == -1 && errno == EINTR {}
        // WIFEXITED / WEXITSTATUS / WTERMSIG, which Swift does not import.
        let signaled = result & 0x7f
        exit(signaled == 0 ? (result >> 8) & 0xff : 128 + signaled)
    }

    nonisolated(unsafe) static var child: pid_t = 0
}
