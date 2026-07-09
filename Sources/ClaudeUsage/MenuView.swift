import SwiftUI
import AppKit

struct MenuView: View {
    @EnvironmentObject var model: UsageModel

    var body: some View {
        VStack(spacing: 0) {
            if model.needsLogin {
                loginNeededView
            } else if model.needsOrgId {
                orgIdEntryView
            } else if model.isLoading && model.fiveHourPct == 0 && model.error == nil {
                loadingView
            } else if let err = model.error {
                errorView(err)
            } else {
                usageView
            }
        }
        .frame(width: 280)
        .padding(.vertical, 8)
    }

    // MARK: - Login prompt

    private var loginNeededView: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)

            Text("Sign in to Claude.ai")
                .font(.headline)

            Text("Log in once — your session is\nstored in the macOS Keychain.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Log in…") {
                LoginWindowController.present(model: model)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Divider()

            quitButton
                .foregroundStyle(.secondary)
                .font(.caption)
        }
        .padding()
    }

    // MARK: - Org ID entry

    @State private var orgIdInput = ""

    private var orgIdEntryView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Organisation ID needed", systemImage: "building.2")
                .font(.headline)

            Text("We couldn't auto-detect your org ID. Find it in your browser's Network tab (any request to /api/organizations/{id}/…) or ask your admin.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx", text: $orgIdInput)
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))

            HStack {
                Button("Save") {
                    let id = orgIdInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !id.isEmpty else { return }
                    model.storeOrgId(id)
                    model.needsOrgId = false
                    Task { await model.refresh() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(orgIdInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Spacer()
                quitButton.foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    // MARK: - Loading

    private var loadingView: some View {
        HStack(spacing: 8) {
            ProgressView()
            Text("Fetching usage…")
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    // MARK: - Error

    private func errorView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Could not fetch usage", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.red)

            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            HStack {
                Button("Open Claude.ai") {
                    NSWorkspace.shared.open(URL(string: "https://claude.ai")!)
                }
                Spacer()
                quitButton
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
    }

    // MARK: - Usage

    private var usageView: some View {
        VStack(spacing: 0) {
            WindowRow(label: "5-hour window", pct: model.fiveHourPct, resetsAt: model.fiveHourResetsAt)

            Divider().padding(.horizontal)

            WindowRow(label: "7-day window", pct: model.sevenDayPct, resetsAt: model.sevenDayResetsAt)

            ForEach(model.extraWindows, id: \.label) { w in
                Divider().padding(.horizontal)
                WindowRow(label: w.label, pct: w.pct, resetsAt: w.resetsAt)
            }

            Divider()

            HStack(spacing: 6) {
                Image(systemName: "key")
                    .imageScale(.small)
                Text(model.cookieSource)
                    .font(.caption2)

                Spacer()

                // Refresh
                Button {
                    Task { await model.refresh() }
                } label: {
                    Image(systemName: model.isLoading ? "arrow.clockwise.circle" : "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Refresh")
                .disabled(model.isLoading)

                // Log out (clears Keychain; only relevant when source is Keychain)
                if model.cookieSource == "Keychain" {
                    Button {
                        model.logout()
                    } label: {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                    }
                    .buttonStyle(.plain)
                    .help("Log out")
                }

                quitButton
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal)
            .padding(.top, 6)
        }
    }

    // MARK: - Shared

    private var quitButton: some View {
        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
        .buttonStyle(.plain)
        .font(.caption)
    }
}

// MARK: - Window row

struct WindowRow: View {
    let label: String
    let pct: Double
    let resetsAt: Date?

    private var tint: Color {
        pct >= 90 ? .red : pct >= 75 ? .orange : .accentColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.0f%%", pct))
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(tint)
            }

            ProgressView(value: pct, total: 100)
                .tint(tint)

            if let date = resetsAt {
                // Update the countdown every minute without re-fetching from the API.
                TimelineView(.periodic(from: .now, by: 60)) { _ in
                    Text(resetLabel(for: date))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    /// "resets at 14:23 (1h 7m)"
    private func resetLabel(for date: Date) -> String {
        let timeStr = date.formatted(.dateTime.hour().minute())
        let secs    = max(0, Int(date.timeIntervalSinceNow))
        let h = secs / 3600
        let m = (secs % 3600) / 60
        let rel = h > 0 ? "\(h)h \(m)m" : "\(m)m"
        return "resets at \(timeStr) (\(rel))"
    }
}
