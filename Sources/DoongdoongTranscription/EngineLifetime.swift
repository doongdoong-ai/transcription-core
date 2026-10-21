import Foundation

/// The owner keeps a pipe writer open. SIGKILL also closes it, so the supervisor
/// can release the resident model even when Swift deinit cannot run.
enum EngineLifetime {
    static func arguments(executable: URL, arguments: [String]) -> [String] {
        let script = #"""
        "$@" < /dev/null &
        worker=$!
        trap 'kill -KILL "$worker" 2>/dev/null; wait "$worker" 2>/dev/null' EXIT
        trap 'exit 0' TERM HUP INT
        # macOS Bash 3.2 uses the same status for timeout and EOF. Block on
        # the lifetime pipe instead: normal stop or owner death closes it.
        IFS= read -r ignored
        exit 0
        """#
        return ["--noprofile", "--norc", "-c", script, "doongdoong-whisper", executable.path] + arguments
    }
}
