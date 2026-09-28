import SwiftUI

struct FocusStatsView: View {
    @ObservedObject var pomodoro: PomodoroModel

    private let columns = 53
    private let cell: CGFloat = 8
    private let gap: CGFloat = 3

    private var today: Date { Calendar.current.startOfDay(for: Date()) }

    private var firstWeek: Date {
        let calendar = Calendar.current
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: today)!.start
        return calendar.date(byAdding: .weekOfYear, value: -52, to: thisWeek)!
    }

    private func day(_ week: Int, _ weekday: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: week * 7 + weekday,
                              to: firstWeek)!
    }

    private func monthTitle(_ week: Int) -> String {
        let current = day(week, 0)
        if week > 0 && Calendar.current.component(.month, from: current)
            == Calendar.current.component(.month, from: day(week - 1, 0)) {
            return ""
        }
        return "\(Calendar.current.component(.month, from: current))月"
    }

    private func shade(_ seconds: Int) -> Double {
        switch seconds {
        case 0: return 0.10
        case 1..<(25 * 60): return 0.30
        case (25 * 60)..<(50 * 60): return 0.48
        case (50 * 60)..<(100 * 60): return 0.68
        default: return 0.88
        }
    }

    private func durationText(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) 秒" }
        let minutes = seconds / 60
        let remainder = seconds % 60
        return remainder == 0 ? "\(minutes) 分钟" : "\(minutes) 分 \(remainder) 秒"
    }

    private func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private func weekdayTitle(_ index: Int) -> String {
        let weekday = Calendar.current.component(.weekday, from: day(0, index))
        return ["日", "一", "二", "三", "四", "五", "六"][weekday - 1]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text("专注统计").font(.system(size: 21, weight: .semibold))
                Spacer()
                Text("过去一年").font(.system(size: 12)).foregroundStyle(.secondary)
            }

            HStack(spacing: 36) {
                metric("今日", value: "\(pomodoro.today.sessions) 次",
                       detail: durationText(pomodoro.today.seconds))
                metric("累计", value: "\(pomodoro.totalFocus.sessions) 次",
                       detail: durationText(pomodoro.totalFocus.seconds))
                Spacer()
            }

            VStack(alignment: .leading, spacing: 9) {
                Text("专注热力图").font(.system(size: 13, weight: .medium))
                HStack(alignment: .top, spacing: gap) {
                    VStack(alignment: .trailing, spacing: gap) {
                        Text("").frame(height: 15)
                        ForEach(0..<7, id: \.self) { index in
                            Text(index == 0 || index == 2 || index == 4
                                 ? weekdayTitle(index) : "")
                                .font(.system(size: 8))
                                .foregroundStyle(.secondary)
                                .frame(width: 12, height: cell)
                        }
                    }
                    ForEach(0..<columns, id: \.self) { week in
                        VStack(alignment: .leading, spacing: gap) {
                            Text(monthTitle(week))
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .fixedSize()
                                .frame(width: cell, height: 15, alignment: .leading)
                            ForEach(0..<7, id: \.self) { weekday in
                                let date = day(week, weekday)
                                let record = pomodoro.focusDay(on: date)
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(.primary.opacity(shade(record.seconds)))
                                    .frame(width: cell, height: cell)
                                    .opacity(date > today ? 0 : 1)
                                    .help("\(dateText(date)) · \(record.sessions) 次 · \(durationText(record.seconds))")
                            }
                        }
                    }
                }
                HStack(spacing: 4) {
                    Spacer()
                    Text("少").font(.system(size: 10)).foregroundStyle(.secondary)
                    ForEach([0, 15, 25, 50, 100], id: \.self) { minutes in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(.primary.opacity(shade(minutes)))
                            .frame(width: cell, height: cell)
                    }
                    Text("多").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }

            Divider()
            Text("最近专注").font(.system(size: 13, weight: .medium))
            if pomodoro.sessions.isEmpty && !pomodoro.isSessionActive {
                Text("开始一次命名专注后，进行中的记录会显示在这里。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 7) {
                        if pomodoro.isSessionActive,
                           let name = pomodoro.activeFocusName {
                            HStack {
                                Text(name).lineLimit(1)
                                Spacer()
                                Text("进行中 · 已专注 \(durationText(pomodoro.currentSessionFocusSeconds))")
                                    .foregroundStyle(.secondary)
                            }.font(.system(size: 11))
                        }
                        ForEach(Array(pomodoro.sessions.reversed().prefix(8))) { session in
                            HStack {
                                Text(session.name).lineLimit(1)
                                Spacer()
                                Text("\(durationText(session.seconds)) · \(dateText(session.finishedAt))")
                                    .foregroundStyle(.secondary)
                            }
                            .font(.system(size: 11))
                        }
                    }
                }
                .frame(height: 105)
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(width: 700, height: 390)
        .background(.regularMaterial)
    }

    private func metric(_ title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 19, weight: .semibold, design: .rounded))
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}
