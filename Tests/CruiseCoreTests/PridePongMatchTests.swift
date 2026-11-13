import Testing
@testable import CruiseCore

struct PridePongMatchTests {
    @Test func testNewMatchIsCenteredAndWaitingForServe() {
        let match = PridePongMatch()
        #expect(match.ballX == 0.5)
        #expect(match.ballY == 0.5)
        #expect(match.playerScore == 0)
        #expect(match.computerScore == 0)
        #expect(!match.isRunning)
    }

    @Test func testServeStartsMatchAndPausedStepDoesNotMoveBall() {
        var match = PridePongMatch()
        match.step(deltaTime: 1)
        #expect(match.ballX == 0.5)
        match.serve()
        #expect(match.isRunning)
        #expect(match.velocityX != 0)
        let x = match.ballX
        match.step(deltaTime: 1.0 / 60.0)
        #expect(match.ballX != x)
    }

    @Test func testPlayerPaddleMovementStaysInsideCourt() {
        var match = PridePongMatch()
        match.movePlayerPaddle(by: -10)
        #expect(match.playerPaddleY == PridePongMatch.paddleHalfHeight)
        match.positionPlayerPaddle(at: 4)
        #expect(match.playerPaddleY == 1 - PridePongMatch.paddleHalfHeight)
    }

    @Test func testBallReflectsFromTopAndBottomBoundaries() {
        var match = PridePongMatch(ballX: 0.5, ballY: 0.02, velocityX: 0.2,
                                   velocityY: -0.5)
        match.step(deltaTime: 0.05)
        #expect(match.ballY == PridePongMatch.ballRadius)
        #expect(match.velocityY > 0)
    }

    @Test func testPlayerPaddleReturnsBallIntoPlay() {
        var match = PridePongMatch(ballX: 0.08, ballY: 0.5, velocityX: -0.3,
                                   velocityY: 0, playerPaddleY: 0.5)
        match.step(deltaTime: 0.02)
        #expect(match.velocityX > 0)
        #expect(match.playerScore == 0)
        #expect(match.isRunning)
    }

    @Test func testMissAwardsComputerAndPausesForNextServe() {
        var match = PridePongMatch(ballX: 0.08, ballY: 0.2, velocityX: -0.3,
                                   velocityY: 0, playerPaddleY: 0.8)
        match.step(deltaTime: 0.02)
        #expect(match.computerScore == 1)
        #expect(!match.isRunning)
        #expect(match.ballX == 0.5)
    }

    @Test func testFirstToSevenWinsAndNewGameResetsScore() {
        var match = PridePongMatch(ballX: 0.08, ballY: 0.2, velocityX: -0.3,
                                   velocityY: 0, playerPaddleY: 0.8,
                                   computerPaddleY: 0.5, computerScore: 6)
        match.step(deltaTime: 0.02)
        #expect(match.computerScore == 7)
        #expect(match.winner == .computer)
        #expect(!match.isRunning)
        match.newGame()
        #expect(match.computerScore == 0)
        #expect(match.winner == nil)
    }
}
