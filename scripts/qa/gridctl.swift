// Sends a DEBUG-build automation command to a running GRID. Usage: gridctl '<json>'
import Foundation
let json = CommandLine.arguments.dropFirst().joined(separator: " ")
DistributedNotificationCenter.default().postNotificationName(
    Notification.Name("local.grid.debug"), object: json, userInfo: nil, deliverImmediately: true)
RunLoop.current.run(until: Date().addingTimeInterval(0.05))
