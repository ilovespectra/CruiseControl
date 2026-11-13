import Foundation

public enum NotchPlacement {
    public static func pillX(screenMinX: Double, screenMaxX: Double, pillWidth: Double,
                             notchLeftWidth: Double?, notchRightWidth: Double?,
                             sideIsRight: Bool, dropdownWidthRatio: Double = 2.75) -> Double {
        guard let notchLeftWidth, let notchRightWidth,
              notchLeftWidth > 0, notchRightWidth > 0,
              notchLeftWidth + notchRightWidth < screenMaxX - screenMinX else {
            return sideIsRight ? screenMaxX - pillWidth : screenMinX
        }
        let notchMinX = screenMinX + notchLeftWidth
        let notchMaxX = screenMaxX - notchRightWidth
        let halfDropdown = (notchMaxX - notchMinX) * dropdownWidthRatio / 2
        let notchMidX = (notchMinX + notchMaxX) / 2
        let x = sideIsRight ? notchMidX + halfDropdown : notchMidX - halfDropdown - pillWidth
        return min(max(x, screenMinX), screenMaxX - pillWidth)
    }
}
