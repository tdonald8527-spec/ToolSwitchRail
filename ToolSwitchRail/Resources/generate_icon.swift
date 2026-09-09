import AppKit
import CoreGraphics

let size = CGSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()

guard let ctx = NSGraphicsContext.current?.cgContext else {
    fatalError("Cannot get CGContext")
}

// Clear
ctx.clear(CGRect(origin: .zero, size: size))

// macOS App Icon Squircle:
// Standard grid: 824x824 squircle centered at (512, 512)
let squircleRect = CGRect(x: 100, y: 100, width: 824, height: 824)
let cornerRadius: CGFloat = 185

// Drop Shadow under the squircle
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -24), blur: 38, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.50))
let shadowPath = CGPath(roundedRect: squircleRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
ctx.addPath(shadowPath)
ctx.setFillColor(CGColor(red: 0.07, green: 0.08, blue: 0.10, alpha: 1.0))
ctx.fillPath()
ctx.restoreGState()

// Clip to squircle for the body
ctx.saveGState()
let squirclePath = CGPath(roundedRect: squircleRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
ctx.addPath(squirclePath)
ctx.clip()

// 1. Background Gradient: Deep Slate to Dark Velvet Obsidian
let colorSpace = CGColorSpaceCreateDeviceRGB()
let bgColors = [
    CGColor(red: 0.13, green: 0.15, blue: 0.20, alpha: 1.0), // Top
    CGColor(red: 0.06, green: 0.07, blue: 0.09, alpha: 1.0)  // Bottom
] as CFArray
let bgLocations: [CGFloat] = [0.0, 1.0]
if let bgGradient = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: bgLocations) {
    ctx.drawLinearGradient(bgGradient,
                           start: CGPoint(x: 512, y: squircleRect.maxY),
                           end: CGPoint(x: 512, y: squircleRect.minY),
                           options: [])
}

// 2. Ambient glow behind the app window
let ambientColors = [
    CGColor(red: 0.16, green: 0.38, blue: 0.85, alpha: 0.28),
    CGColor(red: 0.35, green: 0.20, blue: 0.70, alpha: 0.12),
    CGColor(red: 0.05, green: 0.08, blue: 0.15, alpha: 0.0)
] as CFArray
if let ambGrad = CGGradient(colorsSpace: colorSpace, colors: ambientColors, locations: [0.0, 0.45, 1.0]) {
    ctx.drawRadialGradient(ambGrad,
                           startCenter: CGPoint(x: 480, y: 520),
                           startRadius: 40,
                           endCenter: CGPoint(x: 480, y: 520),
                           endRadius: 420,
                           options: [])
}

// 3. SEAMLESS DOCKED WINDOW SETUP
// Tool Switch Rail core feature: The Rail is docked seamlessly (0-seam) against the managed App Window!
let dockTotalY: CGFloat = 200
let dockTotalH: CGFloat = 624
let railW: CGFloat = 138
let windowW: CGFloat = 480
let dockTotalW = railW + windowW // 618 pt
let dockStartX = (1024 - dockTotalW) / 2 // 203 pt

let railRect = CGRect(x: dockStartX, y: dockTotalY, width: railW, height: dockTotalH)
let windowRect = CGRect(x: dockStartX + railW, y: dockTotalY, width: windowW, height: dockTotalH)

// Unified drop shadow for both docked panels
let combinedPath = CGMutablePath()
// Left rail has rounded top-left and bottom-left
// Right window has rounded top-right and bottom-right
combinedPath.addRoundedRect(in: CGRect(x: dockStartX, y: dockTotalY, width: dockTotalW, height: dockTotalH),
                            cornerWidth: 28,
                            cornerHeight: 28)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 32, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.65))
ctx.addPath(combinedPath)
ctx.setFillColor(CGColor(red: 0.10, green: 0.12, blue: 0.16, alpha: 1.0))
ctx.fillPath()
ctx.restoreGState()

// ----------------------
// RIGHT: MANAGED APP WINDOW
// ----------------------
ctx.saveGState()
// Clip right window with rounded right corners
let winPath = CGMutablePath()
let winR: CGFloat = 26
winPath.move(to: CGPoint(x: windowRect.minX, y: windowRect.minY))
winPath.addLine(to: CGPoint(x: windowRect.maxX - winR, y: windowRect.minY))
winPath.addArc(tangent1End: CGPoint(x: windowRect.maxX, y: windowRect.minY),
               tangent2End: CGPoint(x: windowRect.maxX, y: windowRect.minY + winR),
               radius: winR)
winPath.addLine(to: CGPoint(x: windowRect.maxX, y: windowRect.maxY - winR))
winPath.addArc(tangent1End: CGPoint(x: windowRect.maxX, y: windowRect.maxY),
               tangent2End: CGPoint(x: windowRect.maxX - winR, y: windowRect.maxY),
               radius: winR)
winPath.addLine(to: CGPoint(x: windowRect.minX, y: windowRect.maxY))
winPath.closeSubpath()

ctx.addPath(winPath)
ctx.clip()

// Window Background gradient
let winColors = [
    CGColor(red: 0.16, green: 0.18, blue: 0.23, alpha: 0.98),
    CGColor(red: 0.10, green: 0.11, blue: 0.15, alpha: 0.99)
] as CFArray
if let winGrad = CGGradient(colorsSpace: colorSpace, colors: winColors, locations: [0.0, 1.0]) {
    ctx.drawLinearGradient(winGrad,
                           start: CGPoint(x: windowRect.midX, y: windowRect.maxY),
                           end: CGPoint(x: windowRect.midX, y: windowRect.minY),
                           options: [])
}

// Window Titlebar Header line
let titleBarRect = CGRect(x: windowRect.minX, y: windowRect.maxY - 48, width: windowRect.width, height: 48)
ctx.setFillColor(CGColor(red: 0.20, green: 0.23, blue: 0.30, alpha: 0.55))
ctx.fill(titleBarRect)

// Three subtle macOS traffic dots
let dotY = windowRect.maxY - 24
let dotRadius: CGFloat = 6.0
let trafficColors = [
    CGColor(red: 0.98, green: 0.38, blue: 0.36, alpha: 0.9), // Close
    CGColor(red: 0.98, green: 0.74, blue: 0.24, alpha: 0.9), // Min
    CGColor(red: 0.32, green: 0.82, blue: 0.40, alpha: 0.9)  // Zoom
]
for (idx, col) in trafficColors.enumerated() {
    let dotX = windowRect.minX + 26 + CGFloat(idx) * 18
    ctx.setFillColor(col)
    ctx.fillEllipse(in: CGRect(x: dotX - dotRadius, y: dotY - dotRadius, width: dotRadius * 2, height: dotRadius * 2))
}

// Window Titlebar Breadcrumb / Tab
let tabRect = CGRect(x: windowRect.minX + 96, y: windowRect.maxY - 36, width: 140, height: 24)
let tabPath = CGPath(roundedRect: tabRect, cornerWidth: 6, cornerHeight: 6, transform: nil)
ctx.setFillColor(CGColor(red: 0.25, green: 0.29, blue: 0.38, alpha: 0.6))
ctx.addPath(tabPath)
ctx.fillPath()

// Window Code/Dashboard content cards & lines
let cardRect = CGRect(x: windowRect.minX + 28, y: windowRect.maxY - 250, width: windowRect.width - 56, height: 180)
let cardPath = CGPath(roundedRect: cardRect, cornerWidth: 14, cornerHeight: 14, transform: nil)
ctx.setFillColor(CGColor(red: 0.13, green: 0.15, blue: 0.20, alpha: 0.7))
ctx.addPath(cardPath)
ctx.fillPath()

// Code lines inside card
let codeColors = [
    CGColor(red: 0.24, green: 0.62, blue: 0.98, alpha: 0.85), // Cyan/Blue
    CGColor(red: 0.55, green: 0.58, blue: 0.68, alpha: 0.60),
    CGColor(red: 0.98, green: 0.65, blue: 0.22, alpha: 0.80), // Orange
    CGColor(red: 0.35, green: 0.82, blue: 0.55, alpha: 0.75)  // Green
]
let codeWidths: [CGFloat] = [210, 320, 260, 180]
for (i, w) in codeWidths.enumerated() {
    let lineRect = CGRect(x: cardRect.minX + 22, y: cardRect.maxY - 36 - CGFloat(i * 34), width: w, height: 12)
    let lineP = CGPath(roundedRect: lineRect, cornerWidth: 6, cornerHeight: 6, transform: nil)
    ctx.setFillColor(codeColors[i])
    ctx.addPath(lineP)
    ctx.fillPath()
}

// Lower stats / metrics cards
let subW: CGFloat = (windowRect.width - 70) / 2
for idx in 0..<2 {
    let subRect = CGRect(x: windowRect.minX + 28 + CGFloat(idx) * (subW + 14), y: windowRect.minY + 32, width: subW, height: 260)
    let subPath = CGPath(roundedRect: subRect, cornerWidth: 14, cornerHeight: 14, transform: nil)
    ctx.setFillColor(CGColor(red: 0.13, green: 0.15, blue: 0.20, alpha: 0.6))
    ctx.addPath(subPath)
    ctx.fillPath()

    // Decorative content inside
    let barH: CGFloat = idx == 0 ? 120 : 160
    let chartBar = CGRect(x: subRect.minX + 20, y: subRect.minY + 24, width: subRect.width - 40, height: barH)
    let chartGrad = idx == 0 ? [CGColor(red: 0.20, green: 0.60, blue: 0.95, alpha: 0.6), CGColor(red: 0.10, green: 0.30, blue: 0.60, alpha: 0.2)] :
                               [CGColor(red: 0.40, green: 0.80, blue: 0.50, alpha: 0.6), CGColor(red: 0.20, green: 0.40, blue: 0.30, alpha: 0.2)]
    if let g = CGGradient(colorsSpace: colorSpace, colors: chartGrad as CFArray, locations: [1.0, 0.0]) {
        ctx.saveGState()
        let barPath = CGPath(roundedRect: chartBar, cornerWidth: 8, cornerHeight: 8, transform: nil)
        ctx.addPath(barPath)
        ctx.clip()
        ctx.drawLinearGradient(g, start: CGPoint(x: chartBar.midX, y: chartBar.maxY), end: CGPoint(x: chartBar.midX, y: chartBar.minY), options: [])
        ctx.restoreGState()
    }
}

// Window Border Stroke
ctx.setStrokeColor(CGColor(red: 0.45, green: 0.52, blue: 0.68, alpha: 0.30))
ctx.setLineWidth(1.5)
ctx.addPath(winPath)
ctx.strokePath()
ctx.restoreGState()

// ----------------------
// LEFT: TOOL SWITCH RAIL
// ----------------------
ctx.saveGState()
let railPath = CGMutablePath()
let railR: CGFloat = 26
railPath.move(to: CGPoint(x: railRect.maxX, y: railRect.maxY))
railPath.addLine(to: CGPoint(x: railRect.minX + railR, y: railRect.maxY))
railPath.addArc(tangent1End: CGPoint(x: railRect.minX, y: railRect.maxY),
                tangent2End: CGPoint(x: railRect.minX, y: railRect.maxY - railR),
                radius: railR)
railPath.addLine(to: CGPoint(x: railRect.minX, y: railRect.minY + railR))
railPath.addArc(tangent1End: CGPoint(x: railRect.minX, y: railRect.minY),
                tangent2End: CGPoint(x: railRect.minX + railR, y: railRect.minY),
                radius: railR)
railPath.addLine(to: CGPoint(x: railRect.maxX, y: railRect.minY))
railPath.closeSubpath()

ctx.addPath(railPath)
ctx.clip()

// Rail Acrylic Body Gradient
let railColors = [
    CGColor(red: 0.20, green: 0.23, blue: 0.30, alpha: 0.98),
    CGColor(red: 0.12, green: 0.14, blue: 0.18, alpha: 0.99)
] as CFArray
if let railGrad = CGGradient(colorsSpace: colorSpace, colors: railColors, locations: [0.0, 1.0]) {
    ctx.drawLinearGradient(railGrad,
                           start: CGPoint(x: railRect.midX, y: railRect.maxY),
                           end: CGPoint(x: railRect.midX, y: railRect.minY),
                           options: [])
}

// Top Drag Handle Bar
let handleRect = CGRect(x: railRect.midX - 22, y: railRect.maxY - 22, width: 44, height: 4)
let handlePath = CGPath(roundedRect: handleRect, cornerWidth: 2, cornerHeight: 2, transform: nil)
ctx.setFillColor(CGColor(red: 0.55, green: 0.62, blue: 0.75, alpha: 0.5))
ctx.addPath(handlePath)
ctx.fillPath()

// 5 Agent Tool Items:
// 1. Hermes (Amber)
// 2. Antigravity (Electric Blue - ACTIVE)
// 3. ChatGPT (Teal)
// 4. WorkBuddy (Green)
// 5. Grok Bot (Purple)
struct AgentVisual {
    let name: String
    let baseColor: CGColor
    let glowColor: CGColor
    let isActive: Bool
    let statusActive: Bool
}

let agentList: [AgentVisual] = [
    AgentVisual(name: "Hermes",
                baseColor: CGColor(red: 0.98, green: 0.62, blue: 0.18, alpha: 1.0),
                glowColor: CGColor(red: 0.98, green: 0.62, blue: 0.18, alpha: 0.4),
                isActive: false,
                statusActive: true),
    AgentVisual(name: "Antigravity",
                baseColor: CGColor(red: 0.18, green: 0.68, blue: 0.98, alpha: 1.0),
                glowColor: CGColor(red: 0.18, green: 0.68, blue: 0.98, alpha: 0.9),
                isActive: true, // Selected with glow & indicator
                statusActive: true),
    AgentVisual(name: "ChatGPT",
                baseColor: CGColor(red: 0.12, green: 0.78, blue: 0.68, alpha: 1.0),
                glowColor: CGColor(red: 0.12, green: 0.78, blue: 0.68, alpha: 0.4),
                isActive: false,
                statusActive: true),
    AgentVisual(name: "WorkBuddy",
                baseColor: CGColor(red: 0.22, green: 0.82, blue: 0.48, alpha: 1.0),
                glowColor: CGColor(red: 0.22, green: 0.82, blue: 0.48, alpha: 0.4),
                isActive: false,
                statusActive: true),
    AgentVisual(name: "Grok",
                baseColor: CGColor(red: 0.70, green: 0.40, blue: 0.98, alpha: 1.0),
                glowColor: CGColor(red: 0.70, green: 0.40, blue: 0.98, alpha: 0.4),
                isActive: false,
                statusActive: true)
]

let railContentTop = railRect.maxY - 44
let itemSpacing: CGFloat = 84

for (i, agent) in agentList.enumerated() {
    let centerY = railContentTop - 42 - CGFloat(i) * itemSpacing
    let centerX = railRect.midX
    let itemSize: CGFloat = 62
    let itemRect = CGRect(x: centerX - itemSize / 2, y: centerY - itemSize / 2, width: itemSize, height: itemSize)
    let itemPath = CGPath(roundedRect: itemRect, cornerWidth: 18, cornerHeight: 18, transform: nil)

    if agent.isActive {
        // Active Tool Background Capsule with radiant glow
        let activeBgRect = CGRect(x: railRect.minX + 8, y: centerY - 37, width: railRect.width - 16, height: 74)
        let activeBgPath = CGPath(roundedRect: activeBgRect, cornerWidth: 20, cornerHeight: 20, transform: nil)
        
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 20, color: agent.glowColor)
        ctx.setFillColor(CGColor(red: 0.28, green: 0.36, blue: 0.50, alpha: 0.5))
        ctx.addPath(activeBgPath)
        ctx.fillPath()
        ctx.restoreGState()

        // Active left edge indicator bar (macOS standard selection pill)
        let activeBar = CGRect(x: railRect.minX + 4, y: centerY - 16, width: 4.5, height: 32)
        let barPath = CGPath(roundedRect: activeBar, cornerWidth: 2.25, cornerHeight: 2.25, transform: nil)
        ctx.setFillColor(agent.baseColor)
        ctx.addPath(barPath)
        ctx.fillPath()
    }

    // App Icon Tile
    ctx.saveGState()
    ctx.setFillColor(CGColor(red: 0.22, green: 0.26, blue: 0.34, alpha: agent.isActive ? 0.9 : 0.55))
    ctx.addPath(itemPath)
    ctx.fillPath()

    // Inner Glyph Circle
    let glyphRadius: CGFloat = 16
    let glyphRect = CGRect(x: centerX - glyphRadius, y: centerY - glyphRadius, width: glyphRadius * 2, height: glyphRadius * 2)
    ctx.setFillColor(agent.baseColor)
    ctx.fillEllipse(in: glyphRect)

    // Inner subtle icon shine
    let shineRect = CGRect(x: centerX - glyphRadius + 3, y: centerY + 2, width: (glyphRadius - 3) * 2, height: glyphRadius - 4)
    ctx.setFillColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.25))
    ctx.fillEllipse(in: shineRect)

    // Status Dot (Live Telemetry Dot)
    let dotR: CGFloat = 5.0
    let dotX = itemRect.maxX - 6
    let dotY = itemRect.minY + 6
    let dotRect = CGRect(x: dotX - dotR, y: dotY - dotR, width: dotR * 2, height: dotR * 2)

    // Status Dot Glow
    ctx.saveGState()
    let dotColor = agent.isActive ? CGColor(red: 0.20, green: 0.88, blue: 0.50, alpha: 1.0) : CGColor(red: 0.20, green: 0.85, blue: 0.45, alpha: 0.9)
    ctx.setShadow(offset: .zero, blur: 8, color: dotColor)
    ctx.setFillColor(dotColor)
    ctx.fillEllipse(in: dotRect)
    ctx.restoreGState()

    ctx.restoreGState()
}

// Bottom Appearance Switch Icon (Sun & Moon toggle)
let bottomSwitchY = railRect.minY + 44
let switchCenterX = railRect.midX
let switchRadius: CGFloat = 14
// Crescent Moon / Sun fusion icon
ctx.saveGState()
ctx.setFillColor(CGColor(red: 0.95, green: 0.80, blue: 0.35, alpha: 0.75))
let moonRect = CGRect(x: switchCenterX - switchRadius, y: bottomSwitchY - switchRadius, width: switchRadius * 2, height: switchRadius * 2)
ctx.fillEllipse(in: moonRect)
// Cut out crescent
ctx.setBlendMode(.destinationOut)
let cutRect = CGRect(x: switchCenterX - switchRadius + 7, y: bottomSwitchY - switchRadius + 4, width: switchRadius * 1.8, height: switchRadius * 1.8)
ctx.fillEllipse(in: cutRect)
ctx.restoreGState()

// Rail Left/Top/Bottom Border Stroke
ctx.setStrokeColor(CGColor(red: 0.55, green: 0.65, blue: 0.85, alpha: 0.35))
ctx.setLineWidth(1.8)
ctx.addPath(railPath)
ctx.strokePath()
ctx.restoreGState()

// 4. VERTICAL SEAM HIGHLIGHT
// The subtle 1px seam between Rail and App Window
ctx.saveGState()
ctx.setStrokeColor(CGColor(red: 0.18, green: 0.68, blue: 0.98, alpha: 0.45))
ctx.setLineWidth(1.5)
ctx.move(to: CGPoint(x: railRect.maxX, y: railRect.minY + 8))
ctx.addLine(to: CGPoint(x: railRect.maxX, y: railRect.maxY - 8))
ctx.strokePath()
ctx.restoreGState()

// 5. Squircle Outer Highlight & Glass Rim
ctx.setStrokeColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.15))
ctx.setLineWidth(2.0)
ctx.addPath(squirclePath)
ctx.strokePath()

// Top Rim Sheen
let rimPath = CGMutablePath()
rimPath.addArc(center: CGPoint(x: 512, y: squircleRect.maxY - cornerRadius),
               radius: cornerRadius,
               startAngle: .pi * 0.18,
               endAngle: .pi * 0.82,
               clockwise: false)
ctx.setStrokeColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.38))
ctx.setLineWidth(3.0)
ctx.strokePath()

ctx.restoreGState() // Unclip squircle

image.unlockFocus()

// Save 1024x1024 master PNG
let outDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let outPath = "\(outDir)/AppIcon_1024.png"
if let tiff = image.tiffRepresentation,
   let rep = NSBitmapImageRep(data: tiff),
   let pngData = rep.representation(using: .png, properties: [:]) {
    try? pngData.write(to: URL(fileURLWithPath: outPath))
    print("Saved 1024x1024 master icon to \(outPath)")
} else {
    fatalError("Failed to encode PNG")
}
