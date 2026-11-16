import Foundation
import Testing
@testable import Perch

/// UTF-8 bytes of a JSON literal.
private func json(_ text: String) -> Data { Data(text.utf8) }

/// `GET /v1/magpie/quotas/history` as the latest magpie (0.1.43xx,
/// internal/provider/quota_history.go) answers it: one item per account,
/// `user` lowercased, a `lines` entry per card window, points of `at` /
/// `left` (% left) / `start` / `resetsAt`, Go RFC 3339 times with nanos.
struct QuotaHistoryLatestTests {
    static let history = json("""
    {"data":[
      {"provider":"claude","user":"work@example.com","lines":[
        {"name":"5 hours","points":[
          {"at":"2026-11-16T09:00:03.120934Z","left":100,"start":"2026-11-16T09:00:00Z","resetsAt":"2026-11-16T14:00:00Z"},
          {"at":"2026-11-16T10:05:41.88Z","left":81,"start":"2026-11-16T09:00:00Z","resetsAt":"2026-11-16T14:00:00Z"},
          {"at":"2026-11-16T11:10:00+08:00","left":64}]},
        {"name":"7 days","points":[
          {"at":"2026-11-14T08:00:00Z","left":90,"resetsAt":"2026-11-20T08:00:00Z"},
          {"at":"2026-11-16T10:00:00.5Z","left":59,"resetsAt":"2026-11-20T08:00:00Z"}]},
        {"name":"7 days · Fable","points":[
          {"at":"2026-11-15T08:00:00Z","left":100},
          {"at":"2026-11-16T10:00:00Z","left":100}]},
        {"name":"Usage credits","points":[]}
      ]},
      {"provider":"codex","user":"me@example.com","lines":[
        {"name":"5 hours","points":[{"at":"2026-11-16T09:30:00Z","left":70}]},
        {"name":"weekly","points":[{"at":"2026-11-16T09:30:00Z","left":40,"start":null,"resetsAt":null}]}
      ]},
      {"provider":"claude","user":"","lines":[{"name":"7 days","points":[{"at":"2026-11-16T09:00:00Z","left":12}]}]},
      {"provider":"office/claude","user":"remote@example.com","lines":[{"name":"5 hours","points":[{"at":"2026-11-16T09:00:00Z","left":50}]}]}
    ],"object":"list"}
    """)

    /// `/v1/magpie/quotas/cards` for the same accounts (the user kept as
    /// typed, window names the same as the history's lines).
    static let cards = json("""
    {"data":[
      {"provider":"claude","name":"Claude","kind":"subscription","plan":"Max","user":"Work@Example.com",
       "windows":[{"name":"5 hours","used":36,"resetsAt":"2026-11-16T14:00:00Z"},
                  {"name":"7 days","used":41,"resetsAt":"2026-11-20T08:00:00Z"},
                  {"name":"7 days · Fable","used":0,"resetsAt":"2026-11-20T08:00:00Z"}]},
      {"provider":"codex","name":"Codex","kind":"subscription","user":"me@example.com",
       "windows":[{"name":"5 hours","used":30},{"name":"weekly","used":60}]},
      {"provider":"claude","name":"Claude","kind":"subscription","user":"other@example.com","windows":[{"name":"5 hours","used":3}]}
    ],"object":"list"}
    """)

    @Test func readsLatestShape() throws {
        guard case .series(let all) = QuotaHistoryDecoding.history(from: Self.history) else {
            Issue.record("latest magpie history not read"); return
        }
        // The empty "Usage credits" line is skipped, not fatal.
        #expect(all.map(\.window) == ["5 hours", "7 days", "7 days · Fable", "5 hours", "weekly", "7 days", "5 hours"])
        let five = all[0]
        #expect(five.provider == "claude")
        #expect(five.user == "work@example.com")
        #expect(five.kind == .fiveHour)
        // 11:10+08:00 is 03:10Z, so it sorts first.
        #expect(five.points.map(\.used) == [36, 0, 19])
        #expect(five.points.first?.time == RFC3339.parse("2026-11-16T03:10:00Z"))
        #expect(all[1].kind == .weekly)
        #expect(all[1].points.map(\.used) == [10, 41])
        #expect(all[2].kind == .modelWeekly("Fable"))
        #expect(all[2].points.map(\.used) == [0, 0])
        #expect(all[4].kind == .weekly)
        // An account with no user is told as "".
        #expect(all[5].user == nil)
    }

    @Test func seriesBelongToTheirCards() throws {
        guard case .series(let all) = QuotaHistoryDecoding.history(from: Self.history) else {
            Issue.record("not read"); return
        }
        let cards = try QuotaDecoding.cards(from: Self.cards)
        let work = cards[0], codex = cards[1], other = cards[2]
        // magpie lowercases user; the card keeps the case it was typed in.
        let mine = all.filter { $0.belongs(to: work) }
        #expect(Set(mine.map(\.window)) == ["5 hours", "7 days", "7 days · Fable"])
        #expect(mine.contains { $0.kind == .modelWeekly("Fable") })
        #expect(all.filter { $0.belongs(to: codex) }.map(\.window) == ["5 hours", "weekly"])
        // Another Claude login gets only the user-less series.
        #expect(all.filter { $0.belongs(to: other) }.map(\.user) == [nil])
        // The remote magpie's account is not this one's.
        #expect(!all.contains { $0.provider == "office/claude" && $0.belongs(to: work) })

        // Every window on the card finds its own line (the chart and run-out use this).
        for w in work.windows {
            let samples = RunOutEstimate.samples(.series(all), card: work, window: w)
            #expect(!samples.isEmpty, "no history for \(w.name)")
        }
        let account = try #require(SubscriptionAccounts.accounts(cards: cards).first)
        #expect(account.modelWeekly.first.map { WindowCell.label($0.window) } == "Fable 每周")
    }

    @Test func toleratesOddBits() {
        // Unknown keys, a bad point, a line that isn't an object, a bare list.
        let odd = QuotaHistoryDecoding.history(from: json("""
        [{"provider":"claude","user":"a@example.com","extra":{"x":1},"lines":[
           "nope", {"name":"5 hours","points":[{"at":"not a time","left":3},{"at":1763200000,"left":"80"},{"left":5}]}]},
         {"something":"else"}]
        """))
        guard case .series(let s) = odd else { Issue.record("odd not read"); return }
        #expect(s.count == 1)
        #expect(s[0].points.map(\.used) == [20])

        // An envelope inside `data`, and the history file's own form.
        let inner = QuotaHistoryDecoding.history(from: json("""
        {"data":{"data":[{"provider":"codex","user":"x","lines":[{"name":"weekly","points":[{"at":"2026-11-16T00:00:00Z","left":10}]}]}]}}
        """))
        guard case .series(let i) = inner else { Issue.record("inner not read"); return }
        #expect(i[0].points.map(\.used) == [90])
        let file = QuotaHistoryDecoding.history(from: json("""
        {"codex|me@example.com":{"5 hours":[{"at":"2026-11-16T00:00:00Z","left":90},{"at":"2026-11-16T01:00:00Z","left":70}]}}
        """))
        guard case .series(let f) = file else { Issue.record("file form not read"); return }
        #expect(f[0].provider == "codex")
        #expect(f[0].user == "me@example.com")
        #expect(f[0].points.map(\.used) == [10, 30])

        // Recognised accounts whose lines have no usable point: nothing yet, not 看不懂.
        #expect(QuotaHistoryDecoding.history(from: json(#"{"data":[{"provider":"claude","user":"a","lines":[]}],"object":"list"}"#)) == .empty)
        #expect(QuotaHistoryDecoding.history(from: json(#"{"object":"list"}"#)) == .empty)
        #expect(QuotaHistoryDecoding.history(from: json(#"{"data":null}"#)) == .empty)
        // Truly nothing usable.
        #expect(QuotaHistoryDecoding.history(from: json(#"{"error":{"message":"x"}}"#)) == .unrecognized)
        #expect(QuotaHistoryDecoding.history(from: json(#""text""#)) == .unrecognized)
        #expect(QuotaHistoryDecoding.history(from: json(#"[1,2]"#)) == .unrecognized)
    }
}

#if DEBUG
/// The DEBUG demo history decodes through the real decoder.
struct DemoHistoryTests {
    /// The demo chart is read by the real decoder from the latest shape.
    @Test func demoHistoryDecodes() throws {
        guard case .series(let s) = DemoData.history() else { Issue.record("demo history not read"); return }
        #expect(Set(s.map(\.kind)) == [.fiveHour, .weekly])
        let work = try #require(try QuotaDecoding.cards(from: Data(#"{"data":[{"provider":"claude","name":"Claude","kind":"subscription","user":"work@example.com","windows":[]}]}"#.utf8)).first)
        #expect(s.allSatisfy { $0.belongs(to: work) })
    }
}
#endif
