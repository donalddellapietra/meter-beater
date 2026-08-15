import AppKit
import SwiftUI
import UsageCore

struct CostSettingsView: View {
    @Bindable var model: WoolModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(copy.costTitle)
                .font(.title2.weight(.semibold))

            Text(copy.costDescription)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            GroupBox(copy.estimatedServingCost) {
                VStack(spacing: 14) {
                    CostRatioRow(
                        title: copy.providerTitle(.codex),
                        value: costBinding(for: .codex)
                    )
                    Divider()
                    CostRatioRow(
                        title: copy.providerTitle(.claude),
                        value: costBinding(for: .claude)
                    )
                }
                .padding(.vertical, 5)
            }

            Text(copy.uncertaintyNote)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Link(copy.viewResearch, destination: methodologyURL)
                Spacer()
                Button(copy.restoreDefaults) { model.resetServingCostRatios() }
            }
        }
        .padding(20)
        .frame(width: 440)
        .tint(WoolPalette.pasture)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func costBinding(for provider: Provider) -> Binding<Double> {
        Binding(
            get: { model.servingCostRatio(for: provider) },
            set: { model.setServingCostRatio($0, for: provider) }
        )
    }

    private var copy: AppCopy { model.copy }

    private var methodologyURL: URL {
        URL(string: ServingCostCatalog.methodologySource)!
    }
}

private struct CostRatioRow: View {
    let title: String
    @Binding var value: Double

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .frame(width: 145, alignment: .leading)
            Slider(value: $value, in: 0...1, step: 0.005)
                .accessibilityLabel(title)
                .accessibilityValue(formattedPercentage)
            Text(formattedPercentage)
                .monospacedDigit()
                .frame(width: 48, alignment: .trailing)
        }
    }

    private var formattedPercentage: String {
        let percent = value * 100
        let digits = percent.rounded() == percent ? 0 : 1
        return value.formatted(.percent.precision(.fractionLength(digits)))
    }
}
