import SwiftUI
import Combine

@MainActor
final class UsageModel: ObservableObject {
    @Published var fiveHourPct: Double = 0
    @Published var sevenDayPct: Double = 0
    @Published var fiveHourResetsAt: Date?
    @Published var sevenDayResetsAt: Date?
    @Published var extraWindows: [(label: String, pct: Double, resetsAt: Date?)] = []
    @Published var error: String?
    @Published var isLoading = false
    @Published var needsLogin = false
    @Published var needsOrgId = false
    @Published var cookieSource = ""

    private var timer: AnyCancellable?
    let client = UsageClient()

    init() {
        Task { await refresh() }
        timer = Timer.publish(every: 60, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                Task { [weak self] in await self?.refresh() }
            }
    }

    var menuBarText: String {
        if needsLogin { return "⬡ ?" }
        if error != nil { return "! Claude" }
        if isLoading && fiveHourPct == 0 { return "⬡ …" }
        return String(format: "⬡ %.0f%% (%.0f%%)", fiveHourPct, sevenDayPct)
    }

    var labelColor: Color {
        if needsLogin || error != nil { return .red }
        if fiveHourPct >= 90 { return .red }
        if fiveHourPct >= 75 { return .orange }
        return .primary
    }

    // MARK: - Actions

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await client.fetchUsage()
            fiveHourPct      = result.fiveHour.utilization
            sevenDayPct      = result.sevenDay.utilization
            fiveHourResetsAt = result.fiveHour.resetsAt
            sevenDayResetsAt = result.sevenDay.resetsAt
            extraWindows     = result.extra.map { (label: $0.label, pct: $0.window.utilization, resetsAt: $0.window.resetsAt) }
            cookieSource     = result.cookieSource
            error          = nil
            needsLogin     = false
        } catch UsageError.noCookiesFound {
            needsLogin = true
            error = nil
        } catch UsageError.noOrgFound {
            needsOrgId = true
            error = nil
        } catch UsageError.httpError(let code) where code == 401 || code == 403 {
            // Stored token expired — clear it and prompt re-login
            await client.clearSessionKey()
            needsLogin = true
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func handleLogin(sessionKey: String, orgId: String? = nil) async {
        await client.storeSessionKey(sessionKey, orgId: orgId)
        needsLogin = false
        await refresh()
    }

    func storeOrgId(_ id: String) {
        Task { await client.storeOrgId(id) }
    }

    func logout() {
        Task {
            await client.clearSessionKey()
            fiveHourPct      = 0
            sevenDayPct      = 0
            fiveHourResetsAt = nil
            sevenDayResetsAt = nil
            cookieSource     = ""
            error            = nil
            needsLogin       = true
        }
    }
}
