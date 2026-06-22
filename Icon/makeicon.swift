// Generates a 1024x1024 app icon PNG. Usage: swift makeicon.swift <out.png>
import AppKit

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let S: CGFloat = 1024
let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
ctx.clear(CGRect(x: 0, y: 0, width: S, height: S))

let inset: CGFloat = 100
let rect = CGRect(x: inset, y: inset, width: S - 2*inset, height: S - 2*inset)
let radius: CGFloat = (S - 2*inset) * 0.2237
let squircle = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: NSColor(white: 0, alpha: 0.30).cgColor)
NSColor.white.setFill(); squircle.fill()
ctx.restoreGState()

ctx.saveGState(); squircle.addClip()
NSGradient(colors: [NSColor(calibratedRed: 0.18, green: 0.55, blue: 0.98, alpha: 1),
                    NSColor(calibratedRed: 0.06, green: 0.30, blue: 0.78, alpha: 1)])!.draw(in: rect, angle: -90)
NSGradient(colors: [NSColor(white: 1, alpha: 0.22), NSColor(white: 1, alpha: 0.0)])!
    .draw(in: CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height/2), angle: -90)
ctx.restoreGState()

let padRect = CGRect(x: (S-560)/2, y: (S-410)/2 - 6, width: 560, height: 410)
let padPath = NSBezierPath(roundedRect: padRect, xRadius: 46, yRadius: 46)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 22, color: NSColor(white: 0, alpha: 0.35).cgColor)
NSColor.white.setFill(); padPath.fill()
ctx.restoreGState()

let scrRect = padRect.insetBy(dx: 30, dy: 30)
let scrPath = NSBezierPath(roundedRect: scrRect, xRadius: 22, yRadius: 22)
ctx.saveGState(); scrPath.addClip()
NSGradient(colors: [NSColor(calibratedRed: 0.10, green: 0.42, blue: 0.92, alpha: 1),
                    NSColor(calibratedRed: 0.05, green: 0.26, blue: 0.66, alpha: 1)])!.draw(in: scrRect, angle: -90)
ctx.restoreGState()

if let plane = NSImage(systemSymbolName: "airplane", accessibilityDescription: nil) {
    let conf = NSImage.SymbolConfiguration(pointSize: 220, weight: .semibold)
    let p = plane.withSymbolConfiguration(conf) ?? plane
    let tinted = NSImage(size: p.size); tinted.lockFocus()
    NSColor.white.set(); let r = CGRect(origin: .zero, size: p.size)
    p.draw(in: r); r.fill(using: .sourceAtop); tinted.unlockFocus()
    let scale = min(scrRect.width*0.62/p.size.width, scrRect.height*0.62/p.size.height)
    let dw = p.size.width*scale, dh = p.size.height*scale
    tinted.draw(in: CGRect(x: scrRect.midX - dw/2, y: scrRect.midY - dh/2, width: dw, height: dh))
}

img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
