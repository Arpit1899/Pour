import SwiftUI

/// How much you dictate, how fast, where, and how often. Counts only; the
/// words themselves live in Recent on Home.
struct InsightsPage: View {
    @Environment(PourSessionModel.self) private var session

    var body: some View {
        let stats = session.stats
        PageScaffold(title: "Insights",
                     subtitle: stats.totalWords == 0
                         ? "Dictate something and your numbers start here. They stay on this Mac."
                         : nil) {
            HStack(alignment: .top, spacing: 12) {
                SpeedCard(wordsPerMinute: stats.wordsPerMinute)
                StatCard(value: stats.totalTidied + stats.totalDictionaryWords,
                         label: "Fixes made") {
                    detail("\(stats.totalTidied.formatted()) words tidied")
                    detail("\(stats.totalDictionaryWords.formatted()) dictionary words")
                }
                StatCard(value: stats.totalWords, label: "Total words") {
                    detail(Self.saved(stats.minutesSaved))
                }
            }
            HStack(alignment: .top, spacing: 12) {
                PlacesCard(places: stats.places)
                StreakCard(stats: stats)
            }
        }
    }

    private func detail(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
    }

    /// Typing time saved, against typing the same words at an easy pace.
    static func saved(_ minutes: Int) -> String {
        if minutes < 1 { return "Typing time saved shows up here" }
        if minutes < 60 { return "About \(minutes) min of typing saved" }
        let hours = Double(minutes) / 60
        return "About \(hours < 10 ? hours.formatted(.number.precision(.fractionLength(1))) : "\(Int(hours))") hours of typing saved"
    }
}

/// The three numbers on Home, a glance at Insights.
struct StatsGlance: View {
    var stats: DictationStats

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            row(stats.totalWords.formatted(), "words")
            row(stats.wordsPerMinute.map(String.init) ?? "–", "wpm")
            row("\(stats.currentStreak)", "day streak")
        }
        .padding(.horizontal, 18)
        .frame(maxHeight: .infinity, alignment: .center)
        .frame(width: 170, alignment: .leading)
        .background(PourTheme.card, in: .rect(cornerRadius: 12, style: .continuous))
    }

    private func row(_ value: String, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(value)
                .font(.system(size: 24, design: .serif))
                .monospacedDigit()
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Cards

private struct StatCard<Detail: View>: View {
    var value: Int
    var label: String
    @ViewBuilder var detail: Detail

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value.formatted())
                .font(.system(size: 26, weight: .medium))
                .monospacedDigit()
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Rectangle().fill(PourTheme.hairline).frame(height: 0.5).padding(.vertical, 8)
            VStack(alignment: .leading, spacing: 5) { detail }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(PourTheme.card, in: .rect(cornerRadius: 12, style: .continuous))
    }
}

/// Speaking speed on a dial, measured against typing.
private struct SpeedCard: View {
    var wordsPerMinute: Int?

    /// Where the dial tops out.
    private static let fullScale = 180.0

    var body: some View {
        let wpm = Double(wordsPerMinute ?? 0)
        VStack(alignment: .leading, spacing: 4) {
            Text(wordsPerMinute.map(String.init) ?? "–")
                .font(.system(size: 26, weight: .medium))
                .monospacedDigit()
            Text("Words per minute")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            ZStack(alignment: .bottom) {
                Dial(fraction: 1).stroke(Color.primary.opacity(0.08),
                                         style: StrokeStyle(lineWidth: 10, lineCap: .round))
                Dial(fraction: min(1, wpm / Self.fullScale))
                    .stroke(PourTheme.accent, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                Text(comparison(wpm))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 2)
            }
            .frame(height: 62)
            .padding(.top, 10)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(PourTheme.card, in: .rect(cornerRadius: 12, style: .continuous))
    }

    private func comparison(_ wpm: Double) -> String {
        guard wpm > 0 else { return "vs typing" }
        let times = wpm / DictationStats.typingWordsPerMinute
        return "\(times.formatted(.number.precision(.fractionLength(1))))× typing"
    }
}

/// A half circle from the left, filled `fraction` of the way round.
private struct Dial: Shape {
    var fraction: Double

    func path(in rect: CGRect) -> Path {
        let radius = min(rect.width / 2, rect.height) - 5
        let center = CGPoint(x: rect.midX, y: rect.maxY - 5)
        var path = Path()
        path.addArc(center: center, radius: radius,
                    startAngle: .degrees(180), endAngle: .degrees(180 + 180 * fraction),
                    clockwise: false)
        return path
    }
}

private struct PlacesCard: View {
    var places: [(place: DictationPlace, count: Int)]

    var body: some View {
        let used = places.filter { $0.count > 0 }
        let total = max(1, used.reduce(0) { $0 + $1.count })
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Where you dictate")
                    .font(.system(size: 15, weight: .medium))
                Spacer()
                Text("\(used.count) kinds of app")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if used.isEmpty {
                Text("Nothing yet")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(used.enumerated()), id: \.element.place) { index, item in
                let share = Double(item.count) / Double(total)
                HStack(spacing: 10) {
                    Image(systemName: item.place.symbol)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    GeometryReader { proxy in
                        Capsule()
                            .fill(PourTheme.accent.opacity(1 - Double(index) * 0.14))
                            .frame(width: max(6, proxy.size.width * share))
                    }
                    .frame(width: 90, height: 8)
                    Text("\(Int((share * 100).rounded()))%")
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .frame(width: 32, alignment: .trailing)
                    Text("\(item.count) \(item.place == .aiPrompts ? item.place.label : item.place.label.lowercased())")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(PourTheme.card, in: .rect(cornerRadius: 12, style: .continuous))
    }
}

/// One square a day for the last twenty weeks, deeper amber the more you said.
private struct StreakCard: View {
    var stats: DictationStats

    private static let weeks = 20
    private static let cell: CGFloat = 10
    private static let gap: CGFloat = 3

    var body: some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let weekday = calendar.component(.weekday, from: today) - 1
        let start = calendar.date(byAdding: .day, value: -(Self.weeks - 1) * 7 - weekday, to: today)!
        let busiest = max(1, (0..<Self.weeks * 7).map {
            stats.words(on: calendar.date(byAdding: .day, value: $0, to: start)!)
        }.max() ?? 1)

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(stats.currentStreak) day streak")
                    .font(.system(size: 15, weight: .medium))
                Spacer()
                Text("Longest \(stats.longestStreak)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: Self.gap) {
                ForEach(0..<Self.weeks, id: \.self) { week in
                    VStack(spacing: Self.gap) {
                        ForEach(0..<7, id: \.self) { day in
                            let date = calendar.date(byAdding: .day, value: week * 7 + day, to: start)!
                            square(words: stats.words(on: date), busiest: busiest,
                                   isToday: date == today, isFuture: date > today)
                        }
                    }
                }
            }
            HStack(spacing: 4) {
                Text("Less").font(.system(size: 10)).foregroundStyle(.secondary)
                ForEach([0.0, 0.35, 0.6, 1], id: \.self) { level in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(level == 0 ? Color.primary.opacity(0.07) : PourTheme.accent.opacity(level))
                        .frame(width: Self.cell, height: Self.cell)
                }
                Text("More").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(PourTheme.card, in: .rect(cornerRadius: 12, style: .continuous))
    }

    private func square(words: Int, busiest: Int, isToday: Bool, isFuture: Bool) -> some View {
        let level = words == 0 ? 0 : 0.35 + 0.65 * Double(words) / Double(busiest)
        return RoundedRectangle(cornerRadius: 2)
            .fill(level == 0 ? Color.primary.opacity(isFuture ? 0 : 0.07) : PourTheme.accent.opacity(level))
            .overlay {
                if isToday {
                    RoundedRectangle(cornerRadius: 2).strokeBorder(Color.primary.opacity(0.5), lineWidth: 1)
                }
            }
            .frame(width: Self.cell, height: Self.cell)
    }
}
