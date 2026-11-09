import AppKit
import Foundation

let destination = CommandLine.arguments[1]
let logoURL = URL(fileURLWithPath: "src/Scruffy/Resources/scruffy-app-icon.png")
guard let logo = NSImage(contentsOf: logoURL) else { fatalError("Scruffy app icon missing") }
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
// The approved bright app tile is already composed; only resize for icon packaging.
logo.draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024))
image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: destination))
