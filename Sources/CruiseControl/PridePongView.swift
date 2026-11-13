import Combine
import CruiseCore
import SwiftUI

@MainActor
struct PridePongView: View {
    @State private var match = PridePongMatch()
    @State private var lastTick = Date()
    @FocusState private var courtFocused: Bool
    private let timer = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 18) {
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("PRIDE PONG")
                        .font(.system(size: 27, weight: .black, design: .rounded))
                        .tracking(1.5)
                    Text("A little joy, one rally at a time.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                scoreCard(title: "YOU", score: match.playerScore, accent: Color(red: 0.25, green: 0.83, blue: 0.72))
                scoreCard(title: "COMPUTER", score: match.computerScore, accent: Color(red: 0.98, green: 0.48, blue: 0.61))
            }

            GeometryReader { proxy in
                let size = proxy.size
                ZStack {
                    prideCourt
                    Canvas { context, canvasSize in
                        let paddleWidth = max(11, canvasSize.width * 0.016)
                        let paddleHeight = canvasSize.height * PridePongMatch.paddleHalfHeight * 2
                        let ballDiameter = canvasSize.height * PridePongMatch.ballRadius * 2
                        let leftX = canvasSize.width * PridePongMatch.paddleX - paddleWidth / 2
                        let rightX = canvasSize.width * (1 - PridePongMatch.paddleX) - paddleWidth / 2
                        let leftY = canvasSize.height * match.playerPaddleY - paddleHeight / 2
                        let rightY = canvasSize.height * match.computerPaddleY - paddleHeight / 2
                        context.fill(Path(roundedRect: CGRect(x: leftX, y: leftY, width: paddleWidth, height: paddleHeight), cornerSize: CGSize(width: 8, height: 8)), with: .color(.white))
                        context.fill(Path(roundedRect: CGRect(x: rightX, y: rightY, width: paddleWidth, height: paddleHeight), cornerSize: CGSize(width: 8, height: 8)), with: .color(.white))
                        let ballRect = CGRect(x: canvasSize.width * match.ballX - ballDiameter / 2,
                                              y: canvasSize.height * match.ballY - ballDiameter / 2,
                                              width: ballDiameter, height: ballDiameter)
                        context.fill(Path(ellipseIn: ballRect.insetBy(dx: -3, dy: -3)), with: .color(.white.opacity(0.25)))
                        context.fill(Path(ellipseIn: ballRect), with: .color(.white))
                    }
                    if !match.isRunning {
                        pauseCard
                    }
                    VStack {
                        Spacer()
                        HStack(spacing: 6) {
                            Image(systemName: "hand.draw")
                            Text("Drag on your side or use W / S")
                        }
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.93))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .background(.black.opacity(0.34), in: Capsule())
                        .padding(12)
                    }
                    .allowsHitTesting(false)
                }
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(.white.opacity(0.34), lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    courtFocused = true
                    match.positionPlayerPaddle(at: value.location.y / max(size.height, 1))
                })
                .focusable()
                .focused($courtFocused)
                .onAppear { courtFocused = true }
            }
            .frame(minHeight: 300)

            HStack(spacing: 12) {
                Button(action: startOrServe) {
                    Label(primaryButtonTitle, systemImage: match.winner == nil ? "play.fill" : "arrow.counterclockwise")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                }
                .buttonStyle(.borderedProminent)
                .tint(Brand.tint)
                Button("New game", systemImage: "arrow.clockwise") {
                    match.newGame()
                    courtFocused = true
                }
                .buttonStyle(.bordered)
                Spacer(minLength: 8)
                Button("Move up", systemImage: "arrowtriangle.up.fill") {
                    match.movePlayerPaddle(by: -0.09)
                    courtFocused = true
                }
                .labelStyle(.iconOnly)
                .accessibilityLabel("Move your paddle up")
                Button("Move down", systemImage: "arrowtriangle.down.fill") {
                    match.movePlayerPaddle(by: 0.09)
                    courtFocused = true
                }
                .labelStyle(.iconOnly)
                .accessibilityLabel("Move your paddle down")
            }

            HStack(spacing: 8) {
                Text("FIRST TO 7")
                    .font(.system(size: 10, weight: .heavy, design: .rounded))
                    .tracking(1)
                    .foregroundStyle(.secondary)
                Text("·")
                    .foregroundStyle(.tertiary)
                Text("Space to serve · W / S or ↑ / ↓ to move")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 3) {
                    ForEach(Array(prideColors.enumerated()), id: \.offset) { item in
                        Capsule().fill(item.element).frame(width: 16, height: 4)
                    }
                }
                .accessibilityLabel("Rainbow pride flag colors")
            }
        }
        .padding(22)
        .frame(minWidth: 760, minHeight: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .onReceive(timer) { now in
            match.step(deltaTime: now.timeIntervalSince(lastTick))
            lastTick = now
        }
        .onKeyPress(keys: ["w", "s", .upArrow, .downArrow, .space]) { press in
            if press.key == "w" || press.key == .upArrow {
                match.movePlayerPaddle(by: -0.065)
            } else if press.key == "s" || press.key == .downArrow {
                match.movePlayerPaddle(by: 0.065)
            } else if press.key == .space {
                startOrServe()
            } else {
                return .ignored
            }
            return .handled
        }
    }

    private var prideCourt: some View {
        Canvas { context, size in
            let colors = prideColors
            let stripeHeight = size.height / CGFloat(colors.count)
            for (index, color) in colors.enumerated() {
                let rect = CGRect(x: 0, y: CGFloat(index) * stripeHeight,
                                  width: size.width, height: stripeHeight + 1)
                context.fill(Path(rect), with: .color(color))
            }
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.31)))
            var center = Path()
            center.move(to: CGPoint(x: size.width / 2, y: 0))
            center.addLine(to: CGPoint(x: size.width / 2, y: size.height))
            context.stroke(center, with: .color(.white.opacity(0.76)), style: StrokeStyle(lineWidth: 2, dash: [8, 11]))
            let circle = CGRect(x: size.width / 2 - size.height * 0.12,
                                y: size.height / 2 - size.height * 0.12,
                                width: size.height * 0.24, height: size.height * 0.24)
            context.stroke(Path(ellipseIn: circle), with: .color(.white.opacity(0.44)), lineWidth: 2)
        }
    }

    private var pauseCard: some View {
        VStack(spacing: 8) {
            Text(match.winner.map { $0 == .player ? "YOU WIN!" : "NICE TRY!" }
                 ?? (match.playerScore == 0 && match.computerScore == 0 ? "READY TO PLAY?" : "POINT!"))
                .font(.system(size: 22, weight: .black, design: .rounded))
                .tracking(1)
                .foregroundStyle(.white)
            Text(match.winner == nil ? "Press Space or tap Start / Serve" : "Press Play again for another rally")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .background(.black.opacity(0.58), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.4), lineWidth: 1))
        .shadow(color: .black.opacity(0.2), radius: 18, y: 7)
        .allowsHitTesting(false)
    }

    private func scoreCard(title: String, score: Int, accent: Color) -> some View {
        VStack(spacing: 1) {
            Text(title).font(.system(size: 9, weight: .heavy, design: .rounded)).tracking(1.1)
                .foregroundStyle(.secondary)
            Text("\(score)").font(.system(size: 26, weight: .black, design: .rounded))
                .foregroundStyle(accent)
        }
        .frame(width: 76, height: 55)
        .background(.quaternary.opacity(0.52), in: RoundedRectangle(cornerRadius: 13))
        .accessibilityElement(children: .combine)
    }

    private var primaryButtonTitle: String {
        if match.winner != nil { return "Play again" }
        return match.playerScore == 0 && match.computerScore == 0 ? "Start game" : "Serve"
    }

    private func startOrServe() {
        if match.winner != nil { match.newGame() }
        match.serve()
        courtFocused = true
    }
}

private let prideColors: [Color] = [
    Color(red: 0.89, green: 0.04, blue: 0.15),
    Color(red: 1.00, green: 0.53, blue: 0.05),
    Color(red: 1.00, green: 0.88, blue: 0.08),
    Color(red: 0.00, green: 0.60, blue: 0.32),
    Color(red: 0.00, green: 0.31, blue: 0.70),
    Color(red: 0.46, green: 0.18, blue: 0.62),
]
