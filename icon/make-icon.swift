// Draws the app icon (CDJ jog wheel + USB stick) and writes a 1024px PNG.
// Usage: swift icon/make-icon.swift <out.png>
import AppKit

let S: CGFloat = 1024
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0)!
let gctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = gctx
let ctx = gctx.cgContext
let space = CGColorSpaceCreateDeviceRGB()

func col(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: a)
}
func gradient(_ stops: [(UInt32, CGFloat)]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: stops.map { col($0.0) } as CFArray,
               locations: stops.map { $0.1 })!
}
func lerp(_ a: UInt32, _ b: UInt32, _ t: CGFloat) -> CGColor {
    func ch(_ v: UInt32, _ s: UInt32) -> CGFloat { CGFloat((v >> s) & 255) }
    return CGColor(red: (ch(a, 16) + (ch(b, 16) - ch(a, 16)) * t) / 255,
                   green: (ch(a, 8) + (ch(b, 8) - ch(a, 8)) * t) / 255,
                   blue: (ch(a, 0) + (ch(b, 0) - ch(a, 0)) * t) / 255, alpha: 1)
}

// ---- icon body (macOS squircle-ish rounded square, 824pt on a 1024 canvas)
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: col(0x000000, 0.55))
ctx.addPath(bodyPath); ctx.setFillColor(col(0x0B0B16)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(bodyPath); ctx.clip()
// base gradient
ctx.drawLinearGradient(gradient([(0x241A4A, 0), (0x120F28, 0.55), (0x08080F, 1)]),
                       start: CGPoint(x: 300, y: 924), end: CGPoint(x: 724, y: 100), options: [])
// soft magenta glow bottom-right, cyan glow top-left
ctx.setBlendMode(.screen)
ctx.drawRadialGradient(gradient([(0x7A1E52, 0.0), (0x000000, 1)]),
                       startCenter: CGPoint(x: 860, y: 160), startRadius: 0,
                       endCenter: CGPoint(x: 860, y: 160), endRadius: 460, options: [])
ctx.drawRadialGradient(gradient([(0x1F8FFF, 0.0), (0x000000, 1)]),
                       startCenter: CGPoint(x: 200, y: 880), startRadius: 0,
                       endCenter: CGPoint(x: 200, y: 880), endRadius: 460, options: [])
ctx.setBlendMode(.normal)

// ---- jog platter
let c = CGPoint(x: 480, y: 560)
let R: CGFloat = 330
func circle(_ r: CGFloat, at p: CGPoint = c) -> CGPath {
    CGPath(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r), transform: nil)
}
// outer glow
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 60, color: col(0x6A5CFF, 0.8))
ctx.addPath(circle(R)); ctx.setFillColor(col(0x15152B)); ctx.fillPath()
ctx.restoreGState()

// platter face
ctx.saveGState()
ctx.addPath(circle(R)); ctx.clip()
ctx.drawLinearGradient(gradient([(0x2A2A4D, 0), (0x0F0F1F, 1)]),
                       start: CGPoint(x: c.x - R, y: c.y + R), end: CGPoint(x: c.x + R, y: c.y - R), options: [])
// grooves
ctx.setLineWidth(2)
var r: CGFloat = 150
while r < R - 24 {
    ctx.setStrokeColor(col(0xFFFFFF, 0.05 + 0.03 * CGFloat(Int(r) % 3)))
    ctx.addPath(circle(r)); ctx.strokePath()
    r += 13
}
// specular sweep
ctx.setBlendMode(.screen)
ctx.drawLinearGradient(gradient([(0x000000, 0), (0x4B4B88, 0.5), (0x000000, 1)]),
                       start: CGPoint(x: c.x - R, y: c.y + R * 0.2),
                       end: CGPoint(x: c.x + R * 0.2, y: c.y - R), options: [])
ctx.setBlendMode(.normal)
ctx.restoreGState()

// neon rim: cyan -> violet -> magenta around the circle
let rimR = R - 8
ctx.setLineWidth(18)
ctx.setLineCap(.butt)
let segs = 240
for i in 0..<segs {
    let t0 = CGFloat(i) / CGFloat(segs), t1 = (CGFloat(i) + 1.6) / CGFloat(segs)
    let tri = abs(2 * t0 - 1)                       // 0..1..0 so the ends meet
    ctx.setStrokeColor(tri < 0.5 ? lerp(0x2EE6FF, 0x8A5CFF, tri * 2) : lerp(0x8A5CFF, 0xFF3DA5, (tri - 0.5) * 2))
    ctx.addArc(center: c, radius: rimR, startAngle: t0 * 2 * .pi + .pi / 2,
               endAngle: t1 * 2 * .pi + .pi / 2, clockwise: false)
    ctx.strokePath()
}
ctx.setStrokeColor(col(0xFFFFFF, 0.25)); ctx.setLineWidth(2)
ctx.addPath(circle(R - 18)); ctx.strokePath()

// jog "display" centre
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 24, color: col(0x2EE6FF, 0.6))
ctx.addPath(circle(112)); ctx.setFillColor(col(0x090912)); ctx.fillPath()
ctx.restoreGState()
ctx.setLineWidth(7); ctx.setStrokeColor(col(0x2EE6FF, 0.95))
ctx.addPath(circle(112)); ctx.strokePath()
ctx.setLineWidth(3); ctx.setStrokeColor(col(0x2EE6FF, 0.35))
ctx.addPath(circle(92)); ctx.strokePath()
// play triangle
ctx.setFillColor(col(0xFFFFFF, 0.95))
ctx.move(to: CGPoint(x: c.x - 26, y: c.y + 42))
ctx.addLine(to: CGPoint(x: c.x - 26, y: c.y - 42))
ctx.addLine(to: CGPoint(x: c.x + 46, y: c.y))
ctx.closePath(); ctx.fillPath()
// cue marker on the platter
let ma = CGFloat.pi * 0.28
let mp = CGPoint(x: c.x + cos(ma) * 238, y: c.y + sin(ma) * 238)
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 18, color: col(0xFF3DA5))
ctx.addPath(circle(17, at: mp)); ctx.setFillColor(col(0xFF3DA5)); ctx.fillPath()
ctx.restoreGState()

// ---- USB stick (bottom-right, tilted)
ctx.saveGState()
ctx.translateBy(x: 742, y: 300)
ctx.rotate(by: .pi * 0.14)
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 26, color: col(0x000000, 0.7))
let usbBody = CGPath(roundedRect: CGRect(x: -88, y: -150, width: 176, height: 232),
                     cornerWidth: 34, cornerHeight: 34, transform: nil)
ctx.addPath(usbBody); ctx.setFillColor(col(0xFF3DA5)); ctx.fillPath()
ctx.setShadow(offset: .zero, blur: 0, color: nil)
ctx.saveGState()
ctx.addPath(usbBody); ctx.clip()
ctx.drawLinearGradient(gradient([(0xFF6BB8, 0), (0xC21E7A, 1)]),
                       start: CGPoint(x: -88, y: 82), end: CGPoint(x: 88, y: -150), options: [])
ctx.setFillColor(col(0xFFFFFF, 0.18))
ctx.fill(CGRect(x: -88, y: 40, width: 60, height: 60))
ctx.restoreGState()
// label stripe
ctx.setFillColor(col(0x08080F, 0.35))
ctx.addPath(CGPath(roundedRect: CGRect(x: -52, y: -112, width: 104, height: 18), cornerWidth: 9, cornerHeight: 9, transform: nil))
ctx.fillPath()
// metal connector
let plug = CGRect(x: -60, y: 78, width: 120, height: 104)
ctx.addPath(CGPath(roundedRect: plug, cornerWidth: 10, cornerHeight: 10, transform: nil)); ctx.clip()
ctx.drawLinearGradient(gradient([(0xF4F6FA, 0), (0x9AA3B5, 1)]),
                       start: CGPoint(x: -60, y: 182), end: CGPoint(x: 60, y: 78), options: [])
ctx.resetClip()
ctx.setFillColor(col(0x2A2F3D))
ctx.fill(CGRect(x: -34, y: 138, width: 22, height: 26))
ctx.fill(CGRect(x: 12, y: 138, width: 22, height: 26))
ctx.restoreGState()

// ---- glass highlight along the top edge of the body
ctx.setBlendMode(.screen)
ctx.drawLinearGradient(gradient([(0x5A5AA0, 0), (0x000000, 1)]),
                       start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 700), options: [])
ctx.setBlendMode(.normal)
ctx.restoreGState()

// edge hairline
ctx.setLineWidth(3); ctx.setStrokeColor(col(0xFFFFFF, 0.14))
ctx.addPath(bodyPath); ctx.strokePath()

NSGraphicsContext.restoreGraphicsState()
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
