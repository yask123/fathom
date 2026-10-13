// Prints the CGWindowID of an app's main window (largest on-screen, normal layer). Used for QA screenshots.
//   winid Fathom          by owner name
//   winid --pid 1234      by process id (leaves other instances alone)
import CoreGraphics
import Foundation

let args = CommandLine.arguments
let byPid = args.count > 2 && args[1] == "--pid" ? Int(args[2]) : nil
let owner = args.count > 1 && byPid == nil ? args[1] : "Fathom"
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
let mine = list.filter { w in
    guard (w[kCGWindowLayer as String] as? Int) == 0 else { return false }
    if let pid = byPid { return (w[kCGWindowOwnerPID as String] as? Int) == pid }
    return (w[kCGWindowOwnerName as String] as? String) == owner
}
let best = mine.max { a, b in
    let ra = a[kCGWindowBounds as String] as? [String: CGFloat] ?? [:], rb = b[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
    return (ra["Width"] ?? 0) * (ra["Height"] ?? 0) < (rb["Width"] ?? 0) * (rb["Height"] ?? 0)
}
if let id = best?[kCGWindowNumber as String] as? Int { print(id) } else { exit(1) }
