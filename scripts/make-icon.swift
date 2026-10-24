// Draws the 1024 px app icon: two offset document panes, one highlighted line each.
// Usage: swift scripts/make-icon.swift <out.png>
import AppKit

let size = 1024.0
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
NSGradient(starting: NSColor(calibratedRed: 0.16, green: 0.20, blue: 0.32, alpha: 1),
           ending: NSColor(calibratedRed: 0.08, green: 0.10, blue: 0.18, alpha: 1))!.draw(in: tile, angle: -90)

func pane(x: Double, y: Double, accent: NSColor, line: Int) {
    let rect = NSRect(x: x, y: y, width: 360, height: 500)
    NSColor(calibratedWhite: 0.97, alpha: 1).setFill()
    NSBezierPath(roundedRect: rect, xRadius: 36, yRadius: 36).fill()
    for i in 0..<6 {
        let row = NSRect(x: x + 40, y: y + 410 - Double(i) * 70, width: i % 2 == 0 ? 280 : 220, height: 26)
        (i == line ? accent : NSColor(calibratedWhite: 0.78, alpha: 1)).setFill()
        NSBezierPath(roundedRect: row, xRadius: 13, yRadius: 13).fill()
    }
}
pane(x: 190, y: 300, accent: NSColor(calibratedRed: 0.95, green: 0.55, blue: 0.15, alpha: 1), line: 2)
pane(x: 474, y: 224, accent: NSColor(calibratedRed: 0.25, green: 0.75, blue: 0.40, alpha: 1), line: 3)
image.unlockFocus()

let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
