import CruiseCore
import SwiftUI

struct AudioVolumeSettingsView: View {
    @ObservedObject var controller: AudioVolumeController

    private var heyClickyVolume: Binding<Double> {
        Binding(
            get: { Double(controller.volume(for: .heyClicky)) },
            set: { controller.setVolume(Float($0), for: .heyClicky) }
        )
    }

    private var vscodeVolume: Binding<Double> {
        Binding(
            get: { Double(controller.volume(for: .visualStudioCode)) },
            set: { controller.setVolume(Float($0), for: .visualStudioCode) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Audio controls")
                    .font(BrandFont.inter(22, .bold))
                    .foregroundStyle(.white)
                Text("Independent app gains · 100% leaves the desktop audio path untouched")
                    .font(BrandFont.inter(12))
                    .foregroundStyle(.white.opacity(0.58))
            }

            HStack(alignment: .top, spacing: 16) {
                AudioVolumeControlCard(target: .heyClicky,
                                       volume: heyClickyVolume,
                                       status: controller.status(for: .heyClicky))
                AudioVolumeControlCard(target: .visualStudioCode,
                                       volume: vscodeVolume,
                                       status: controller.status(for: .visualStudioCode))
            }

            VStack(alignment: .leading, spacing: 9) {
                Label("What this changes", systemImage: "waveform.path")
                    .font(BrandFont.inter(13, .semibold))
                    .foregroundStyle(.white)
                Text("Below 100%, Cruise applies a private Core Audio process tap to the selected app and sends only that app’s stream to the current output at the chosen gain. The system output device and desktop volume are never changed. At 100%, the tap is removed.")
                    .font(BrandFont.inter(11.5))
                    .foregroundStyle(.white.opacity(0.68))
                Text("macOS asks for System Audio Recording Only the first time. Cruise probes without muting and will not attenuate an app until it confirms that samples are arriving. No audio is saved or sent anywhere.")
                    .font(BrandFont.inter(11.5))
                    .foregroundStyle(.white.opacity(0.68))
            }
            .padding(15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Brand.card, in: RoundedRectangle(cornerRadius: 13))

            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .foregroundStyle(Brand.periwinkle)
                Text("VS Code’s knob covers audio from VS Code’s app processes, not only agent sound effects. Shared browser audio is deliberately excluded from HeyClicky’s route so other browser tabs (including video playback) stay unchanged.")
                    .font(BrandFont.inter(11))
                    .foregroundStyle(.white.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Reset both to 100%") { controller.resetToDesktopLevels() }
                    .disabled(!controller.preferences.hasAttenuation)
                Spacer()
                Text("Saved on this Mac")
                    .font(BrandFont.inter(10.5))
                    .foregroundStyle(.white.opacity(0.42))
            }
            Spacer(minLength: 0)
        }
        .padding(22)
        .frame(minWidth: 760, maxWidth: .infinity, minHeight: 520, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black)
        .preferredColorScheme(.dark)
        .tint(Brand.periwinkle)
    }
}

private struct AudioVolumeControlCard: View {
    let target: AudioVolumeTarget
    @Binding var volume: Double
    let status: String

    private var symbol: String {
        switch target {
        case .heyClicky: "waveform"
        case .visualStudioCode: "chevron.left.forwardslash.chevron.right"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Brand.periwinkle)
                    .frame(width: 31, height: 31)
                    .background(Brand.periwinkle.opacity(0.16), in: RoundedRectangle(cornerRadius: 9))
                Text(target.title)
                    .font(BrandFont.inter(14, .semibold))
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
                Text("\(Int((volume * 100).rounded()))%")
                    .font(BrandFont.inter(16, .bold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
            }

            Slider(value: $volume, in: 0...1)
                .accessibilityLabel("\(target.title) volume")
                .accessibilityValue("\(Int((volume * 100).rounded())) percent")

            HStack {
                Label("Mute", systemImage: "speaker.slash.fill")
                Spacer()
                Label("Full", systemImage: "speaker.wave.3.fill")
            }
            .font(BrandFont.inter(9.5, .medium))
            .foregroundStyle(.white.opacity(0.46))

            Text(status)
                .font(BrandFont.inter(10.5))
                .foregroundStyle(status.hasPrefix("Live") ? Brand.accent(for: .cruise) : .white.opacity(0.58))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 31, alignment: .topLeading)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 154, alignment: .topLeading)
        .background(Brand.card, in: RoundedRectangle(cornerRadius: 14))
    }
}
