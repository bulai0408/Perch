import Foundation
import Testing
@testable import Perch

/// magpie is plain http on any address the computer has: the home network's,
/// Tailscale's (100.64.0.0/10, `*.ts.net`), a VPN's, a public one. With
/// NSAllowsLocalNetworking in Info.plist iOS ignores NSAllowsArbitraryLoads,
/// and ATS then let 192.168.x through but refused http://100.x and
/// http://…ts.net with -1022 (a Tailscale address that Safari opened failed
/// in Perch). These run in the Perch host app, under its Info.plist.
struct ATSTests {
    @Test func infoPlistAllowsEveryHTTPAddress() throws {
        let ats = try #require(Bundle.main.infoDictionary?["NSAppTransportSecurity"] as? [String: Any])
        #expect(ats["NSAllowsArbitraryLoads"] as? Bool == true)
        // Any of these makes iOS ignore NSAllowsArbitraryLoads.
        for key in ["NSAllowsLocalNetworking", "NSAllowsArbitraryLoadsInWebContent", "NSAllowsArbitraryLoadsForMedia"] {
            #expect(ats[key] == nil, "\(key) turns NSAllowsArbitraryLoads off")
        }
    }

    /// ATS refuses before connecting, so -1022 comes back at once whatever
    /// the network; any other outcome (a timeout, no such host) means ATS let
    /// the call go.
    @Test(arguments: [
        "http://100.100.100.100:3425/v1/magpie/quotas/cards",
        "http://100.101.102.103:3425/v1/magpie/quotas/cards",
        "http://office-mac.tail1234.ts.net:3425/v1/magpie/quotas/cards",
        "http://192.168.1.20:3425/v1/magpie/quotas/cards",
        "http://office-mac.local:3425/v1/magpie/quotas/cards",
        "http://office-mac:3425/v1/magpie/quotas/cards",
    ])
    func atsLetsPlainHTTPThrough(url: String) async throws {
        let request = URLRequest(url: try #require(URL(string: url)), timeoutInterval: 2)
        do {
            _ = try await QuotaClient.session.data(for: request)
        } catch {
            #expect((error as? URLError)?.code != .appTransportSecurityRequiresSecureConnection, "\(url): \(error)")
        }
    }
}
