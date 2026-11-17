import SwiftUI

/// Right-hand `.inspector` (`⌘I`) displaying SRS scheduling metrics and review history
/// for the currently selected flashcard.
public struct CardStatsInspector: View {
    public let card: Flashcard?
    public var fontFamily: String
    public var fontSize: String
    public var isEditDisabled: Bool = false
    public let onEdit: (Flashcard) -> Void
    @Environment(\.colorScheme) private var colorScheme

    public init(
        card: Flashcard?,
        fontFamily: String = "serif",
        fontSize: String = "base",
        isEditDisabled: Bool = false,
        onEdit: @escaping (Flashcard) -> Void
    ) {
        self.card = card
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.isEditDisabled = isEditDisabled
        self.onEdit = onEdit
    }

    public var body: some View {
        Group {
            if let card {
                ScrollView {
                    VStack(alignment: .leading, spacing: LunarTokens.space5) {
                        header(for: card)
                        Divider()
                        schedulingSection(for: card)
                        Divider()
                        historySection(for: card)
                    }
                    .padding(LunarTokens.space4)
                }
            } else {
                ContentUnavailableView(
                    "No Card Selected",
                    systemImage: "sidebar.right",
                    description: Text("Select a card to inspect scheduling state and review history.")
                )
            }
        }
        .frame(minWidth: 260, idealWidth: 290)
        .background {
            ZStack {
                Rectangle().fill(.regularMaterial)
                Rectangle().fill(Color(nsColor: .windowBackgroundColor).opacity(0.55))
            }
        }
    }

    private func header(for card: Flashcard) -> some View {
        VStack(alignment: .leading, spacing: LunarTokens.space2) {
            HStack(spacing: LunarTokens.space2) {
                CardTypeDot(card.cardType)
                Text(card.cardType?.displayName ?? "Card")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Edit") {
                    onEdit(card)
                }
                .buttonStyle(.borderless)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isEditDisabled ? Color.secondary.opacity(0.45) : LunarTokens.neutralHighlight)
                .disabled(isEditDisabled)
            }

            MathView(
                content: card.front.trimmingCharacters(in: .whitespacesAndNewlines),
                fontFamily: fontFamily,
                fontSize: fontSize,
                compact: true,
                minHeight: 24,
                maxHeight: 110
            )

            if !card.topic.isEmpty {
                Text(card.topic)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func schedulingSection(for card: Flashcard) -> some View {
        VStack(alignment: .leading, spacing: LunarTokens.space3) {
            Text("Scheduling")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: LunarTokens.space3),
                    GridItem(.flexible(), spacing: LunarTokens.space3)
                ],
                spacing: LunarTokens.space3
            ) {
                InspectorStatTile(
                    label: "Stage",
                    value: card.masteryStage.label,
                    dotColor: LunarTokens.masteryDotColor(card.masteryStage, scheme: colorScheme)
                )
                InspectorStatTile(label: "Interval", value: card.formattedInterval)
                InspectorStatTile(label: "Repetitions", value: "\(card.repetition)")
                InspectorStatTile(label: "Ease Factor", value: String(format: "%.2f", card.easeFactor))
                InspectorStatTile(label: "Total Reviews", value: "\(card.totalReviews)")
                InspectorStatTile(
                    label: "Accuracy",
                    value: card.accuracyPercent.map { "\($0)%" } ?? "—"
                )
            }

            VStack(alignment: .leading, spacing: LunarTokens.space2) {
                InspectorKeyValueRow(
                    key: "Next review",
                    value: card.isDue()
                        ? "Due now"
                        : ISO8601DateFormatter.lunarShortDate(card.nextReviewDate),
                    accentValue: card.isDue()
                )
                InspectorKeyValueRow(
                    key: "Last reviewed",
                    value: card.lastReviewed.isEmpty
                        ? "Never"
                        : ISO8601DateFormatter.lunarShortDate(card.lastReviewed),
                    accentValue: false
                )
                InspectorKeyValueRow(
                    key: "Correct / Missed",
                    value: "\(card.correctCount) / \(card.incorrectCount)",
                    accentValue: false
                )
            }
            .padding(.top, LunarTokens.space1)
        }
    }

    private func historySection(for card: Flashcard) -> some View {
        VStack(alignment: .leading, spacing: LunarTokens.space3) {
            HStack {
                Text("Review History")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Text("\(card.history.count)")
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            if card.history.isEmpty {
                Text("No reviews recorded yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: LunarTokens.space2) {
                    ForEach(Array(card.history.reversed().prefix(12))) { log in
                        HStack(spacing: LunarTokens.space2) {
                            Text(ratingLabel(log.rating))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(log.rating == 1 ? .secondary : .primary)
                                .frame(width: 44, alignment: .leading)

                            Text(Flashcard.formatIntervalDays(log.intervalDays))
                                .font(.system(size: 12))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)

                            Spacer()

                            Text(ISO8601DateFormatter.lunarShortDate(log.timestamp))
                                .font(.system(size: 11))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .padding(.vertical, LunarTokens.space1)
                    }
                }
            }
        }
    }

    private func ratingLabel(_ rating: Int) -> String {
        switch rating {
        case 1: "Again"
        case 2: "Hard"
        case 3: "Good"
        case 4: "Easy"
        default: "Rate \(rating)"
        }
    }
}

private struct InspectorStatTile: View {
    let label: String
    let value: String
    var dotColor: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                if let dotColor {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 6, height: 6)
                }
                Text(value)
                    .font(.system(size: 14, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(LunarTokens.space2)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: LunarTokens.controlRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: LunarTokens.controlRadius, style: .continuous)
                .strokeBorder(LunarTokens.hairlineBorder(), lineWidth: 1)
        }
    }
}

private struct InspectorKeyValueRow: View {
    let key: String
    let value: String
    let accentValue: Bool

    var body: some View {
        HStack {
            Text(key)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(accentValue ? LunarTokens.neutralHighlight : .primary)
        }
    }
}
