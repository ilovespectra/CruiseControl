public enum PridePongSide: Equatable, Sendable {
    case player
    case computer
}

/// A deterministic, normalized-coordinate Pong match used by the Pride Pong game.
public struct PridePongMatch: Equatable, Sendable {
    public static let paddleHalfHeight = 0.105
    public static let paddleX = 0.065
    public static let ballRadius = 0.018

    public private(set) var playerPaddleY = 0.5
    public private(set) var computerPaddleY = 0.5
    public private(set) var ballX = 0.5
    public private(set) var ballY = 0.5
    public private(set) var velocityX = 0.0
    public private(set) var velocityY = 0.0
    public private(set) var playerScore = 0
    public private(set) var computerScore = 0
    public private(set) var isRunning = false
    public private(set) var winner: PridePongSide?

    private var nextServeDirection = 1.0

    public init() {}

    public mutating func newGame() {
        playerScore = 0
        computerScore = 0
        winner = nil
        nextServeDirection = 1
        playerPaddleY = 0.5
        computerPaddleY = 0.5
        resetBall()
    }

    public mutating func serve() {
        guard !isRunning, winner == nil else { return }
        ballX = 0.5
        ballY = 0.5
        velocityX = 0.62 * nextServeDirection
        velocityY = nextServeDirection > 0 ? 0.24 : -0.24
        isRunning = true
    }

    public mutating func movePlayerPaddle(by amount: Double) {
        playerPaddleY = Self.clamp(playerPaddleY + amount,
                                   Self.paddleHalfHeight, 1 - Self.paddleHalfHeight)
    }

    public mutating func positionPlayerPaddle(at normalizedY: Double) {
        playerPaddleY = Self.clamp(normalizedY,
                                   Self.paddleHalfHeight, 1 - Self.paddleHalfHeight)
    }

    public mutating func step(deltaTime: Double) {
        guard isRunning, deltaTime > 0 else { return }
        let dt = min(deltaTime, 0.05)

        // The computer paddle follows the ball with a deliberate speed limit so it is beatable.
        let computerDelta = ballY - computerPaddleY
        let computerStep = 0.39 * dt
        computerPaddleY += Self.clamp(computerDelta, -computerStep, computerStep)
        computerPaddleY = Self.clamp(computerPaddleY,
                                     Self.paddleHalfHeight, 1 - Self.paddleHalfHeight)

        ballX += velocityX * dt
        ballY += velocityY * dt

        if ballY < Self.ballRadius {
            ballY = Self.ballRadius
            velocityY = abs(velocityY)
        } else if ballY > 1 - Self.ballRadius {
            ballY = 1 - Self.ballRadius
            velocityY = -abs(velocityY)
        }

        let leftContactX = Self.paddleX + Self.ballRadius
        if velocityX < 0, ballX <= leftContactX {
            if abs(ballY - playerPaddleY) <= Self.paddleHalfHeight + Self.ballRadius {
                ballX = leftContactX
                bounce(from: playerPaddleY, direction: 1)
            } else {
                awardPoint(to: .computer)
                return
            }
        }

        let rightPaddleX = 1 - Self.paddleX
        let rightContactX = rightPaddleX - Self.ballRadius
        if velocityX > 0, ballX >= rightContactX {
            if abs(ballY - computerPaddleY) <= Self.paddleHalfHeight + Self.ballRadius {
                ballX = rightContactX
                bounce(from: computerPaddleY, direction: -1)
            } else {
                awardPoint(to: .player)
            }
        }
    }

    private mutating func bounce(from paddleY: Double, direction: Double) {
        velocityX = abs(velocityX) * direction * 1.035
        let impact = (ballY - paddleY) / (Self.paddleHalfHeight + Self.ballRadius)
        velocityY = Self.clamp(velocityY + impact * 0.42, -0.78, 0.78)
    }

    private mutating func awardPoint(to side: PridePongSide) {
        switch side {
        case .player:
            playerScore += 1
            nextServeDirection = 1
            if playerScore >= 7 { winner = .player }
        case .computer:
            computerScore += 1
            nextServeDirection = -1
            if computerScore >= 7 { winner = .computer }
        }
        resetBall()
    }

    private mutating func resetBall() {
        ballX = 0.5
        ballY = 0.5
        velocityX = 0
        velocityY = 0
        isRunning = false
    }

    private static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        min(max(value, lower), upper)
    }

    // Internal deterministic setup for collision-focused unit tests.
    init(ballX: Double, ballY: Double, velocityX: Double, velocityY: Double,
         playerPaddleY: Double = 0.5, computerPaddleY: Double = 0.5,
         playerScore: Int = 0, computerScore: Int = 0, isRunning: Bool = true) {
        self.ballX = ballX
        self.ballY = ballY
        self.velocityX = velocityX
        self.velocityY = velocityY
        self.playerPaddleY = playerPaddleY
        self.computerPaddleY = computerPaddleY
        self.playerScore = playerScore
        self.computerScore = computerScore
        self.isRunning = isRunning
    }
}
