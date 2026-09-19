#if !os(iOS)   // see main.swift: the console tool runs on macOS and Linux
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// The one `ioctl` this tool makes, with its platform difference kept here.
///
/// `ioctl` is variadic in C, so Swift sees a different signature on each libc:
/// Darwin's overlay takes the request as `UInt` and the pointer as a vararg,
/// while musl's — what the static Linux SDK builds against — wants the request
/// widened explicitly. swift-argument-parser branches the same way.
enum TerminalWindow {
    static func size() -> winsize? {
        var window = winsize()
        #if canImport(Musl)
        let status = ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &window)
        #else
        let status = ioctl(STDOUT_FILENO, TIOCGWINSZ, &window)
        #endif
        return status == 0 ? window : nil
    }
}
#endif
