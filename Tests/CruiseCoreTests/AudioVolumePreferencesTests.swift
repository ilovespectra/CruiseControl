import Testing
@testable import CruiseCore

struct AudioVolumePreferencesTests {
    @Test func perAppGainsRemainIndependent() {
        var preferences = AudioVolumePreferences()
        preferences.setVolume(0.32, for: .heyClicky)
        preferences.setVolume(0.81, for: .visualStudioCode)

        #expect(preferences.volume(for: .heyClicky) == 0.32)
        #expect(preferences.volume(for: .visualStudioCode) == 0.81)
        #expect(preferences.hasAttenuation)
    }

    @Test func gainIsClampedAndNeverBoostsDesktopAudio() {
        var preferences = AudioVolumePreferences(heyClicky: -0.2, visualStudioCode: 1.8)
        #expect(preferences.volume(for: .heyClicky) == 0)
        #expect(preferences.volume(for: .visualStudioCode) == 1)
        #expect(!AudioVolumePreferences().hasAttenuation)
        #expect(AudioVolumeMath.clampedGain(.infinity) == 1)
    }

    @Test func scalingAppliesAttenuationAndClipsSafely() {
        #expect(AudioVolumeMath.scaledSample(0.8, gain: 0.25) == 0.2)
        #expect(AudioVolumeMath.scaledSample(-0.8, gain: 0.25) == -0.2)
        #expect(AudioVolumeMath.scaledSample(1.2, gain: 1) == 1)
        #expect(AudioVolumeMath.scaledSample(-1.2, gain: 1) == -1)
        #expect(AudioVolumeMath.scaledSample(0.8, gain: 0) == 0)
    }

    @Test func onlyTheNamedAppsProcessesAreEligible() {
        #expect(AudioVolumeTarget.heyClicky.matches(bundleIdentifier: "com.humansongs.clicky"))
        #expect(AudioVolumeTarget.visualStudioCode.matches(bundleIdentifier: "com.microsoft.VSCode.helper"))
        #expect(!AudioVolumeTarget.heyClicky.matches(bundleIdentifier: "com.brave.Browser"))
        #expect(!AudioVolumeTarget.visualStudioCode.matches(bundleIdentifier: "org.videolan.vlc"))
    }
}
