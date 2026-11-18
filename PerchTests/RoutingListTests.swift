import Foundation
import Testing
@testable import Perch

/// 路由组 as magpie marks them: `disabled` (switched off, provider.Group
/// .Disabled) and `hidden` (a found group the user deleted, which magpie
/// keeps in its list so it can come back).
struct RoutingListTests {
    /// The shape `GET /v1/magpie/admin/routing-groups` answers with a group
    /// switched off (`switch {on:false}`) and a found group deleted.
    static let sample = """
    {"groups":[
      {"id":"retired","name":"Retired","members":["alpha/m-alpha"],"routing":"order","disabled":true,"ref":"group/retired"},
      {"id":"coder","name":"Coder","members":["alpha/m-alpha","beta/m-beta"],"routing":"order","ref":"group/coder"},
      {"id":"m-alpha","name":"m-alpha","members":["alpha/m-alpha","alpha2/m-alpha"],"auto":true,"hidden":true,"ref":"auto/m-alpha"},
      {"id":"pinned","name":"Pinned","members":["alpha/m-alpha","beta/m-beta"],"routing":"manual","pick":"beta/m-beta"},
      {"id":"old","name":"Old","members":["beta/m-beta"],"disabled":true}
    ]}
    """

    @Test func decodesHiddenAndDisabled() throws {
        let groups = try RoutingDecoding.groups(from: Data(Self.sample.utf8))
        #expect(groups.count == 5)
        #expect(groups.first { $0.id == "m-alpha" }?.hidden == true)
        #expect(groups.first { $0.id == "coder" }?.hidden == false)
        #expect(groups.filter(\.disabled).map(\.id) == ["retired", "old"])
    }

    @Test func deletedGroupsAreDroppedAndStoppedOnesGoLast() throws {
        let listed = RoutingGroup.listed(try RoutingDecoding.groups(from: Data(Self.sample.utf8)))
        #expect(listed.map(\.id) == ["coder", "pinned", "retired", "old"])
        #expect(!listed.contains { $0.hidden })
    }

    @Test func aDeletedFlagAlsoHides() throws {
        let data = Data(#"{"groups":[{"id":"a","members":["x/y"],"deleted":true},{"id":"b","members":["x/y"]}]}"#.utf8)
        #expect(RoutingGroup.listed(try RoutingDecoding.groups(from: data)).map(\.id) == ["b"])
    }

    @Test func nothingStoppedKeepsMagpiesOrder() throws {
        let data = Data(#"{"groups":[{"id":"b","members":[]},{"id":"a","members":[]},{"id":"c","members":[],"disabled":false,"hidden":false}]}"#.utf8)
        #expect(RoutingGroup.listed(try RoutingDecoding.groups(from: data)).map(\.id) == ["b", "a", "c"])
    }

    @MainActor
    @Test func storeSplitsInUseAndStopped() async throws {
        #if DEBUG
        // Demo data carries one stopped group and one deleted found group.
        let groups = RoutingGroup.listed(DemoData.routingGroups())
        #expect(!groups.contains { $0.id == "auto-m-alpha" })
        #expect(groups.last?.id == "night")
        #expect(groups.last?.disabled == true)
        #endif
    }

    /// 「kimi-k3 · 另有 2 个」: the count is words (body font), not a model.
    @Test func manualChainKeepsTheCountApart() {
        let members = ["a/x", "b/y", "c/z"].map { RoutingMember(id: $0, title: $0, providerName: nil, ready: true) }
        let group = RoutingGroup(id: "g", name: "G", members: members, routing: "manual", pick: "c/z",
                                 disabled: false, auto: false, ref: "group/g")
        let chain = RoutingChain(group)
        #expect(chain.lead == "z")
        #expect(chain.rest == "")
        #expect(chain.note == " · 另有 2 个")
        #expect(chain.text == "z · 另有 2 个")
        var order = group
        order.routing = "order"
        #expect(RoutingChain(order).note == "")
        #expect(RoutingChain(order).rest == " → y → z")
    }

    @Test func addressShownWithoutScheme() throws {
        #expect(MagpieAddress.shown(URL(string: "http://office-mac.local:3425")!) == "office-mac.local:3425")
        #expect(MagpieAddress.shown(URL(string: "https://box.example.com/magpie")!) == "box.example.com/magpie")
        #expect(MagpieAddress.shown(URL(string: "HTTP://10.0.0.2:3425")!) == "10.0.0.2:3425")
        let normalized = try #require(MagpieAddress.normalize("office-mac.local"))
        #expect(MagpieAddress.shown(normalized) == "office-mac.local:3425")
    }

    @Test func addressWrapsOnlyBeforePort() {
        let zw = "\u{200B}", nbh = "\u{2011}"
        #expect(MagpieAddress.wrappable(URL(string: "http://office-mac.local:3425")!)
                == "office\(nbh)mac.local\(zw):3425")
        #expect(MagpieAddress.wrappable(URL(string: "http://192.168.1.30:3425")!)
                == "192.\(zw)168.\(zw)1.\(zw)30\(zw):3425")
        #expect(MagpieAddress.wrappable(URL(string: "https://my-box.example.com/ma-gpie")!)
                == "my\(nbh)box.example.com/ma-gpie")
        #expect(MagpieAddress.wrappable(URL(string: "http://[::1]:3425")!) == "[::1]\(zw):3425")
        #expect(MagpieAddress.wrappingText(URL(string: "http://a:1")!).languageIdentifier == "en")
    }
}
