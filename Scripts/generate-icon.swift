// Disk Robo app icon generator — renders 1024×1024 PNG with CoreGraphics.
// Design: dark navy squircle (dashboard theme), sunburst ring motif (the app's
// signature visualization), robot head with cyan eyes and orange antenna dot.
//
// Run:  swift Scripts/generate-icon.swift
// Out:  Resources/AppIcon.icns + build/icon-work/icon_1024.png (preview)

import AppKit
import CoreGraphics

// MARK: - Canvas

let size = 1024
guard let ctx = CGContext(data: nil, width: size, height: size,
                          bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("cannot create context")
}

func deg(_ d: Double) -> CGFloat { CGFloat(d * .pi / 180) }
func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(red: r, green: g, blue: b, alpha: a)
}

// MARK: - Background squircle

let iconRect = CGRect(x: 100, y: 100, width: 824, height: 824)
let bgPath = CGPath(roundedRect: iconRect, cornerWidth: 186, cornerHeight: 186, transform: nil)

do {
    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()

    // Vertical navy gradient (top → bottom)
    let bg = CGGradient(colorsSpace: nil, colors: [
        rgb(0.13, 0.22, 0.40),   // #213A66-ish deep navy
        rgb(0.05, 0.08, 0.15),   // near-black navy
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: iconRect.maxY),
                           end: CGPoint(x: 512, y: iconRect.minY), options: [])

    // Soft blue glow behind the robot
    let glow = CGGradient(colorsSpace: nil, colors: [
        rgb(0.30, 0.55, 1.0, 0.30),
        rgb(0.30, 0.55, 1.0, 0),
    ] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 640), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 640), endRadius: 520, options: [])

    // Top sheen
    let sheen = CGGradient(colorsSpace: nil, colors: [
        rgb(1, 1, 1, 0.10),
        rgb(1, 1, 1, 0),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: 512, y: iconRect.maxY),
                           end: CGPoint(x: 512, y: 512), options: [])

    ctx.restoreGState()

    // Hairline border
    ctx.addPath(bgPath)
    ctx.setStrokeColor(rgb(1, 1, 1, 0.10))
    ctx.setLineWidth(4)
    ctx.strokePath()
}

// MARK: - Sunburst rings (the signature motif)

func arcSegment(center: CGPoint, radius: CGFloat, width: CGFloat,
                from: Double, to: Double, color: CGColor) {
    ctx.saveGState()
    ctx.setLineWidth(width)
    ctx.setLineCap(.round)
    ctx.setStrokeColor(color)
    ctx.addArc(center: center, radius: radius,
               startAngle: deg(from), endAngle: deg(to), clockwise: false)
    ctx.strokePath()
    ctx.restoreGState()
}

let ringCenter = CGPoint(x: 512, y: 512)
let blue = rgb(0.30, 0.55, 1.00)   // #4C8DFF
let cyan = rgb(0.22, 0.74, 0.97)   // #38BDF8
let orange = rgb(1.00, 0.62, 0.04) // #FF9F0A

// Ring 2 (inner, faint)
arcSegment(center: ringCenter, radius: 248, width: 28, from: -45, to: 75,
           color: rgb(0.30, 0.55, 1.0, 0.35))
arcSegment(center: ringCenter, radius: 248, width: 28, from: 95, to: 150,
           color: rgb(1, 1, 1, 0.12))

// Ring 1 (outer, dominant)
arcSegment(center: ringCenter, radius: 300, width: 46, from: -60, to: 120, color: blue)
arcSegment(center: ringCenter, radius: 300, width: 46, from: 135, to: 225, color: cyan)
arcSegment(center: ringCenter, radius: 300, width: 46, from: 240, to: 262, color: orange)

// MARK: - Robot head

let headRect = CGRect(x: 512 - 160, y: 470 - 125, width: 320, height: 250)
let headPath = CGPath(roundedRect: headRect, cornerWidth: 70, cornerHeight: 70, transform: nil)

do {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 36,
                  color: rgb(0, 0, 0, 0.45))
    let headGrad = CGGradient(colorsSpace: nil, colors: [
        rgb(0.96, 0.97, 0.99),
        rgb(0.78, 0.83, 0.90),
    ] as CFArray, locations: [0, 1])!
    ctx.addPath(headPath)
    ctx.clip()
    ctx.drawLinearGradient(headGrad, start: CGPoint(x: 512, y: headRect.maxY),
                           end: CGPoint(x: 512, y: headRect.minY), options: [])
    ctx.restoreGState()
}

// Eyes (cyan glow)
func eye(cx: CGFloat) {
    let r = CGRect(x: cx - 29, y: 505 - 35, width: 58, height: 70)
    let p = CGPath(roundedRect: r, cornerWidth: 16, cornerHeight: 16, transform: nil)
    ctx.saveGState()
    ctx.addPath(p)
    ctx.clip()
    let g = CGGradient(colorsSpace: nil, colors: [
        rgb(0.22, 0.74, 0.97),
        rgb(0.15, 0.45, 0.95),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: cx, y: r.maxY),
                           end: CGPoint(x: cx, y: r.minY), options: [])
    ctx.restoreGState()
}
eye(cx: 512 - 65)
eye(cx: 512 + 65)

// Mouth
do {
    let r = CGRect(x: 512 - 48, y: 390 - 9, width: 96, height: 18)
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: 9, cornerHeight: 9, transform: nil))
    ctx.setFillColor(rgb(0.54, 0.59, 0.66))
    ctx.fillPath()
}

// Antenna
do {
    ctx.setStrokeColor(rgb(0.78, 0.82, 0.87))
    ctx.setLineWidth(12)
    ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: 512, y: headRect.maxY))
    ctx.addLine(to: CGPoint(x: 512, y: 650))
    ctx.strokePath()

    // Glow + dot
    ctx.setFillColor(rgb(1.0, 0.62, 0.04, 0.25))
    ctx.fillEllipse(in: CGRect(x: 512 - 30, y: 668 - 30, width: 60, height: 60))
    ctx.setFillColor(orange)
    ctx.fillEllipse(in: CGRect(x: 512 - 16, y: 668 - 16, width: 32, height: 32))
}

// MARK: - Export

guard let image = ctx.makeImage() else { fatalError("no image") }

let workDir = URL(fileURLWithPath: "build/icon-work")
try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

let rep = NSBitmapImageRep(cgImage: image)
guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("png encode") }
try png.write(to: workDir.appendingPathComponent("icon_1024.png"))
print("✓ wrote build/icon-work/icon_1024.png")
