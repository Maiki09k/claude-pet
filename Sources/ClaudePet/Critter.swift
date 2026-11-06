import SwiftUI

enum Palette {
    /// Clawd's orange, the colour Claude Code draws him in.
    static let clawd = Color(hex: 0xD77757)
    static let eye = Color(hex: 0x111010)
    static let body = Color(hex: 0xD97757)
    static let light = Color(hex: 0xF4A887)
    static let cheek = Color(hex: 0xF07F72)
    static let cream = Color(hex: 0xFFE7C7)
    static let mint = Color(hex: 0x7BD8A8)
    static let night = Color(hex: 0x9AA6FF)
    static let amber = Color(hex: 0xF5C04E)
    static let alarm = Color(hex: 0xFF6B5E)
    static let sweat = Color(hex: 0x8FD3FF)
    static let whatsapp = Color(hex: 0x25D366)
    /// WhatsApp's dark theme: panel, incoming bubble and secondary text.
    static let waPanel = Color(hex: 0x111B21)
    static let waBubble = Color(hex: 0x202C33)
    static let waMuted = Color(hex: 0x8696A0)
    /// Maik's own bubble.
    static let waOutgoing = Color(hex: 0x005C4B)
    static let join = Color(hex: 0x3C82F6)
    /// Codex's colour, as orange is Claude's.
    static let codex = Color(hex: 0x4F7DF9)
    static let codexLight = Color(hex: 0x9DB8FF)
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

/// Where Clawd is on the top edge of the card and what his legs are doing.
struct CritterPose: Equatable {
    /// 0 is the left end of the walkable edge, 1 the right end.
    var x: CGFloat = 0.35
    var facing: CGFloat = 1
    var moving = false
    /// Distance walked so far, drives the leg cycle.
    var stride: CGFloat = 0
    /// Arrived at his spot for asking or sleeping.
    var settled = false
}

/// Walks Clawd around. It keeps its state between frames, so a mood change
/// turns the walk around smoothly instead of making the sprite jump.
final class Critter {
    private(set) var pose = CritterPose()
    private var target: CGFloat = 0.35
    private var restUntil: TimeInterval?
    private var last: TimeInterval?
    private var random = SplitMix(seed: 0xC1A0DE)

    func step(at time: TimeInterval, mood: Mood, track: CGFloat) -> CritterPose {
        let dt = min(max(time - (last ?? time), 0), 0.25)
        last = time

        let speed: CGFloat
        var rest: ClosedRange<Double> = 0...0
        var anchor: CGFloat?
        switch mood {
        case .working: speed = 72; rest = 0.15...0.7
        case .done: speed = 36; rest = 0.5...1.4
        case .idle: speed = 16; rest = 1.5...5
        case .asking: speed = 64; anchor = 1    // hurries over to the status pill
        case .sleeping: speed = 18; anchor = 0  // shuffles home to the left corner
        }
        if let anchor {
            target = anchor
            restUntil = nil
        }

        let distance = (target - pose.x) * track
        if abs(distance) < 0.5 {
            pose.x = target
            pose.moving = false
            pose.settled = anchor != nil
            if anchor == nil {
                if let until = restUntil {
                    if time >= until {
                        pickTarget()
                        restUntil = nil
                    }
                } else {
                    restUntil = time + random.next(in: rest)
                }
            }
        } else {
            let travel = min(abs(distance), speed * CGFloat(dt))
            let direction: CGFloat = distance > 0 ? 1 : -1
            pose.x += direction * travel / track
            pose.facing = direction
            pose.stride += travel
            pose.moving = true
            pose.settled = false
        }
        return pose
    }

    private func pickTarget() {
        var next = CGFloat(random.next(in: 0...1))
        // Never just shuffle on the spot.
        if abs(next - pose.x) < 0.15 { next = pose.x > 0.5 ? next * 0.5 : 0.5 + next * 0.5 }
        target = next
    }
}

struct SplitMix {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next(in range: ClosedRange<Double>) -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return range.lowerBound + Double(z >> 11) / Double(1 << 53) * (range.upperBound - range.lowerBound)
    }
}

/// Clawd on the card's top edge. Drawn into a strip as wide as the window whose
/// bottom part overlaps the card, so the shadow lands on the card.
struct CritterView: View {
    let pose: CritterPose
    let mood: Mood
    let time: TimeInterval
    var pokeAge: TimeInterval = .infinity
    var sweating = false

    var body: some View {
        Canvas { context, _ in
            CritterPainter(pose: pose, mood: mood, t: time, pokeAge: pokeAge, sweating: sweating).paint(context)
        }
    }
}

struct CritterPainter {
    let pose: CritterPose
    let mood: Mood
    let t: TimeInterval
    let pokeAge: TimeInterval
    let sweating: Bool

    /// One quadrant of a terminal cell. Cells are twice as tall as wide, so are the quadrants.
    static let pw: CGFloat = 2.5
    static let ph: CGFloat = 5
    static let columns = 18
    static let ground = WidgetMetrics.band
    /// Keeps the feet on the straight part of the edge, clear of the rounded corners.
    static let trackStart = WidgetMetrics.margin + 30
    static let track = WidgetMetrics.card.width - 60 - CGFloat(columns) * pw

    /// Clawd as the Claude Code start screen draws him, " ▐▛███▛█ / ▝▜██████▀ / ▝▝   ▝▝ ",
    /// unpacked into quadrants: # body, E eye hole, A arm, L leg.
    static let sprite = [
        "...#############..",
        "...##E#######E##..",
        ".AA#############AA",
        "...#############..",
        "...L.L.......L.L..",
    ]
    static let eyes = [5, 13]
    static let legs = [3, 5, 13, 15]

    /// Claude Code's thinking spinner · ✢ ✳ ✶ ✻ ✽, grown and shrunk again.
    static let spinner: [[String]] = [
        [".....", ".....", "..X..", ".....", "....."],
        [".....", "..X..", ".XXX.", "..X..", "....."],
        [".....", ".X.X.", "..X..", ".X.X.", "....."],
        ["..X..", "..X..", "XXXXX", "..X..", "..X.."],
        ["X.X.X", ".XXX.", "XXXXX", ".XXX.", "X.X.X"],
        ["..X..", "..X..", "XXXXX", "..X..", "..X.."],
        [".....", ".X.X.", "..X..", ".X.X.", "....."],
        [".....", "..X..", ".XXX.", "..X..", "....."],
    ]
    static let question = [".XX.", "X..X", "..X.", ".X..", "....", ".X.."]
    static let heart = ["XX.XX", "XXXXX", ".XXX.", "..X.."]
    static let zee = ["XXXXX", "...X.", "..X..", ".X...", "XXXXX"]
    static let plus = [".X.", "XXX", ".X."]
    static let cross = ["X.X", ".X.", "X.X"]

    var pw: CGFloat { Self.pw }
    var ph: CGFloat { Self.ph }
    var poked: Bool { pokeAge < 1.2 }
    var asleep: Bool { mood == .sleeping && pose.settled }
    var cheering: Bool { mood == .done || poked }
    var blinking: Bool { t.truncatingRemainder(dividingBy: 4.2) > 4.05 }
    /// Which pair of legs is down; alternates every few points walked.
    var legBeat: Int { Int(pose.stride / 6) % 2 }
    var width: CGFloat { CGFloat(Self.columns) * pw }
    var centerOffset: CGFloat { 9 * pw }

    /// Top left corner of the sprite for a pose at rest, feet on the card edge.
    static func origin(for pose: CritterPose) -> CGPoint {
        CGPoint(x: (trackStart + pose.x * track).rounded(), y: ground - 5 * ph)
    }

    func paint(_ ctx: GraphicsContext) {
        var lift: CGFloat = 0
        if pose.moving, legBeat == 1 { lift = 1 }
        if mood == .done, !pose.moving { lift = hop(period: 0.8, height: 6) }
        if pokeAge < 0.45 { lift = max(lift, sin(pokeAge / 0.45 * .pi) * 8) }

        let base = Self.origin(for: pose)
        // Asleep he lies flat, legs tucked in.
        let origin = CGPoint(x: base.x, y: (base.y - lift + (asleep ? ph : 0)).rounded())

        drawShadow(ctx, origin, lift: lift)
        drawClawd(ctx, origin)
        if sweating, !asleep { drawSweat(ctx, origin) }

        switch mood {
        case .working:
            drawSpinner(ctx, origin)
            if pose.moving { drawDust(ctx, origin) }
        case .asking:
            drawQuestion(ctx, origin)
        case .done:
            drawSparkles(ctx, origin)
        case .sleeping where asleep:
            drawZees(ctx, origin)
        default:
            break
        }
        if poked { drawHeart(ctx, origin) }
    }

    private func hop(period: Double, height: CGFloat) -> CGFloat {
        let phase = t.truncatingRemainder(dividingBy: period) / period
        return phase < 0.6 ? sin(phase / 0.6 * .pi) * height : 0
    }

    // MARK: Clawd

    private func quad(_ x: Int, _ y: Int, height: CGFloat? = nil, top: CGFloat = 0) -> CGRect {
        CGRect(x: CGFloat(x) * pw, y: CGFloat(y) * ph + top, width: pw, height: height ?? ph)
    }

    private func drawClawd(_ ctx: GraphicsContext, _ origin: CGPoint) {
        var body = Path()
        for (y, row) in Self.sprite.enumerated() {
            for (x, ch) in row.enumerated() where ch == "#" || ch == "E" {
                body.addRect(quad(x, y))
            }
        }

        // Arms: down at his sides, up when cheering, the right one waving when he asks.
        let wave = Int(t * 3) % 2 == 0
        var leftArmRow = 2, rightArmRow = 2
        if cheering {
            leftArmRow = wave ? 1 : 2
            rightArmRow = wave ? 2 : 1
        } else if mood == .asking, pose.settled {
            rightArmRow = wave ? 1 : 2
        } else if pose.moving {
            // Arms swing against the legs.
            leftArmRow = legBeat == 0 ? 2 : 3
            rightArmRow = legBeat == 0 ? 3 : 2
        }
        for x in [1, 2] { body.addRect(quad(x, leftArmRow)) }
        for x in [16, 17] { body.addRect(quad(x, rightArmRow)) }

        // Legs: walking lifts one leg of each side in turn, crab style.
        if !asleep {
            for (i, x) in Self.legs.enumerated() {
                let lifted = pose.moving && (i % 2 == legBeat)
                body.addRect(quad(x, 4, height: lifted ? ph / 2 : ph))
            }
        }

        let placed = CGAffineTransform(translationX: origin.x, y: origin.y)
        ctx.fill(body.applying(placed), with: .color(Palette.clawd))

        // Eyes: the holes in the head, looking where he walks.
        var eyes = Path()
        let look: Int
        if pose.moving {
            look = pose.facing > 0 ? 1 : -1
        } else if mood == .idle {
            look = [0, 0, -1, -1, 0, 0, 1, 1][Int(t / 1.5) % 8]
        } else {
            look = 0
        }
        for x in Self.eyes {
            if asleep {
                eyes.addRect(quad(x, 1, height: ph * 0.3, top: ph * 0.6))
            } else if cheering {
                // Happy squint.
                eyes.addRect(quad(x, 1, height: ph * 0.35, top: ph * 0.2))
            } else if blinking {
                eyes.addRect(quad(x + look, 1, height: ph * 0.3, top: ph * 0.5))
            } else {
                eyes.addRect(quad(x + look, 1))
            }
        }
        ctx.fill(eyes.applying(placed), with: .color(Palette.eye))
    }

    private func drawShadow(_ ctx: GraphicsContext, _ origin: CGPoint, lift: CGFloat) {
        let shadowWidth = 38 - min(lift, 8) * 2
        let centerX = origin.x + centerOffset
        let ellipse = Path(ellipseIn: CGRect(x: centerX - shadowWidth / 2, y: Self.ground - 3, width: shadowWidth, height: 7))
        // Only the half that falls onto the card, not onto the wallpaper above it.
        var onCard = ctx
        onCard.clip(to: Path(CGRect(x: 0, y: Self.ground, width: 10_000, height: 20)))
        onCard.fill(ellipse, with: .color(.black.opacity(0.4)))
    }

    private func drawSweat(_ ctx: GraphicsContext, _ origin: CGPoint) {
        let phase = (t / 1.8).truncatingRemainder(dividingBy: 1)
        let alpha = phase < 0.8 ? 1 : (1 - phase) * 5
        let point = CGPoint(x: origin.x + 16 * pw + 1, y: origin.y - 2 + CGFloat(phase) * 6)
        glyph(ctx, [".X", "XX"], at: point, pixel: 2, color: Palette.sweat.opacity(alpha))
    }

    // MARK: Around Clawd

    /// Small pattern with its own pixel size.
    private func glyph(_ ctx: GraphicsContext, _ rows: [String], at point: CGPoint, pixel: CGFloat, color: Color) {
        var path = Path()
        for (y, row) in rows.enumerated() {
            for (x, ch) in row.enumerated() where ch == "X" {
                path.addRect(CGRect(x: (point.x + CGFloat(x) * pixel).rounded(), y: (point.y + CGFloat(y) * pixel).rounded(),
                                    width: pixel, height: pixel))
            }
        }
        ctx.fill(path, with: .color(color))
    }

    private func drawSpinner(_ ctx: GraphicsContext, _ origin: CGPoint) {
        let frame = Self.spinner[Int(t * 8) % Self.spinner.count]
        let point = CGPoint(x: origin.x + centerOffset - 5, y: origin.y - 14)
        glyph(ctx, frame, at: point, pixel: 2, color: Palette.clawd)
    }

    /// Little puffs kicked up behind the feet while he scurries.
    private func drawDust(_ ctx: GraphicsContext, _ origin: CGPoint) {
        let behind = pose.facing > 0 ? origin.x + 2 * pw : origin.x + 16 * pw
        for i in 0..<3 {
            let phase = (t * 3 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
            let x = behind - pose.facing * CGFloat(phase) * 10
            let y = Self.ground - 3 - CGFloat(phase) * 5
            ctx.fill(Path(CGRect(x: x.rounded(), y: y.rounded(), width: 2, height: 2)),
                     with: .color(Palette.cream.opacity((1 - phase) * 0.45)))
        }
    }

    private func drawQuestion(_ ctx: GraphicsContext, _ origin: CGPoint) {
        guard pose.settled else { return }
        let bob = CGFloat(sin(t * 2 * .pi * 0.9)) * 1.5
        glyph(ctx, Self.question, at: CGPoint(x: origin.x + centerOffset - 4, y: origin.y - 16 + bob), pixel: 2, color: Palette.amber)
    }

    private func drawSparkles(_ ctx: GraphicsContext, _ origin: CGPoint) {
        let spots: [(CGFloat, CGFloat, Double)] = [(-8, -4, 0), (width + 3, -6, 0.5), (-4, 12, 0.25)]
        for (x, y, offset) in spots {
            let phase = (t * 1.1 + offset).truncatingRemainder(dividingBy: 1)
            let color = (offset == 0.5 ? Palette.mint : Palette.cream).opacity(sin(phase * .pi))
            glyph(ctx, phase < 0.5 ? Self.plus : Self.cross, at: CGPoint(x: origin.x + x, y: origin.y + y), pixel: 2, color: color)
        }
    }

    private func drawZees(_ ctx: GraphicsContext, _ origin: CGPoint) {
        for i in 0..<2 {
            let phase = (t / 3 + Double(i) / 2).truncatingRemainder(dividingBy: 1)
            let x = origin.x + 15 * pw + CGFloat(phase) * 12
            let y = origin.y - 6 - CGFloat(phase) * 16
            glyph(ctx, Self.zee, at: CGPoint(x: x, y: y), pixel: 2, color: Palette.night.opacity(sin(phase * .pi)))
        }
    }

    private func drawHeart(_ ctx: GraphicsContext, _ origin: CGPoint) {
        let phase = min(pokeAge / 1.2, 1)
        let point = CGPoint(x: origin.x + centerOffset - 5, y: origin.y - 12 - CGFloat(phase) * 10)
        glyph(ctx, Self.heart, at: point, pixel: 2, color: Palette.cheek.opacity(1 - phase))
    }
}
