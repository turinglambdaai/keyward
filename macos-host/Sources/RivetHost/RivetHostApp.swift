import AppKit
import SwiftUI
import RivetEmbedding
import RivetRuntime
import RivetSystem

@main
struct RivetHostApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self)
    private var applicationDelegate
    @StateObject private var model = KeywardModel()

    var body: some Scene {
        WindowGroup("Keyward") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 860, minHeight: 560)
                .task { model.start() }
                .sheet(isPresented: $model.aboutVisible) {
                    AboutSheet().environmentObject(model)
                }
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            KeywardCommands(model: model)
            CommandGroup(replacing: .toolbar) {}
            CommandGroup(replacing: .sidebar) {}
            CommandGroup(replacing: .help) {
                Button("About Keyward") { model.aboutVisible = true }
                Button("User Guide — 使用手册") {
                    if let url = URL(string:
                        "https://github.com/turinglambdaai/keyward/blob/main/docs/GUIDE.zh-CN.md") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }
}

struct KeywardCommands: Commands {
    @ObservedObject var model: KeywardModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Choose Vault…") { model.requestOpenStore() }
                .keyboardShortcut("o", modifiers: [.command])
        }
        CommandMenu("Vault") {
            Button("Deep Check") { model.checkAll() }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(!model.ready || model.storePath.isEmpty)
            Button("Snapshots") {
                model.loadSnapshots()
                model.snapshotsVisible = true
            }
            .keyboardShortcut("l", modifiers: [.command])
            .disabled(!model.ready || model.storePath.isEmpty)
        }
    }
}

/// Every termination path — Cmd-Q, window close, logout, and OS shutdown —
/// passes through applicationShouldTerminate before the process exits, so
/// the embedded backend gets one orderly stop hook. The model registers its
/// backend shutdown once startup succeeds.
@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    static var orderlyShutdown: (() -> Void)?

    nonisolated func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        true
    }

    nonisolated func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // AppKit delivers this callback on the main thread, where the
        // registered shutdown closure lives.
        MainActor.assumeIsolated { Self.orderlyShutdown?() }
        return .terminateNow
    }
}

struct ProductInfo: Identifiable, Equatable {
    let name: String
    let entries: String
    let keyID: String
    let fingerprint: String
    let status: String
    var id: String { name }
}

struct EntryRow: Identifiable, Equatable {
    let name: String
    let state: String
    var id: String { name }
}

struct CheckRow: Identifiable, Equatable {
    let name: String
    let kind: String
    let fingerprint: String
    let paired: String
    let status: String
    var id: String { name }
}

struct SnapshotRow: Identifiable, Equatable {
    let stamp: String
    let size: String
    var id: String { stamp }
}

@MainActor
final class KeywardModel: ObservableObject {
    @Published var status = "Starting embedded Racket CS…"
    @Published var ready = false
    @Published var storePath = ""
    @Published var products: [ProductInfo] = []
    @Published var entries: [EntryRow] = []
    @Published var checks: [CheckRow] = []
    @Published var snapshots: [SnapshotRow] = []
    @Published var selected: ProductInfo?
    @Published var statusMessage: String?
    @Published var errorMessage: String?
    @Published var snapshotsVisible = false
    @Published var aboutVisible = false
    @Published var openStoreRequested = false
    @Published var isDark = false

    var theme: ThemeState { ThemeState(isDark: isDark) }

    var productCount: Int { products.count }
    var okCount: Int { products.filter { $0.status == "ok" }.count }
    var attentionCount: Int {
        products.filter { $0.status != "ok" && $0.status != "no-key" && $0.status != "empty-section" }.count
    }

    /// Bumped on every selection change. Async entry/copy completions carry
    /// the generation they were issued under and are dropped when it no
    /// longer matches — rows and copy targets always bind to the product on
    /// screen, never to a stale selection (issue #3).
    private var selectionGeneration = 0
    /// changeCount captured right after our copy; the expiry timer clears
    /// the pasteboard only while this is still the current count, so a
    /// later unrelated copy by the user is never erased.
    private var clipboardCopyChangeCount = 0
    private var clipboardExpiryWork: DispatchWorkItem?

    private var backend: EmbeddedRacketBackend?

    init() {
        // The model lives for the whole app session, so the observer needs
        // no explicit teardown (Swift 6 forbids touching it from deinit).
        DistributedNotificationCenter.default.addObserver(
            forName: .init("AppleInterfaceThemeChanged"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.syncAppearance() }
        }
    }

    func syncAppearance() {
        isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    func start() {
        guard backend == nil else { return }
        syncAppearance()

        do {
            let config = try EmbeddedRacketConfiguration.resolvedDefault(
                moduleName: RivetGeneratedConfig.moduleName,
                entryName: RivetGeneratedConfig.entryName
            )
            let backend = EmbeddedRacketBackend(configuration: config)
            self.backend = backend
            ApplicationDelegate.orderlyShutdown = { [weak backend] in
                backend?.stop()
            }

            Task.detached { [backend, weak self] in
                do {
                    try backend.start()
                    let api = RivetAPI(client: backend.client)
                    let path = try await api.store_path()
                    let infos = try await api.store_info()
                    let parsed = infos.map {
                        ProductInfo(name: $0[0], entries: $0[1],
                                    keyID: $0.count > 2 ? $0[2] : "",
                                    fingerprint: $0.count > 3 ? $0[3] : "",
                                    status: $0.count > 4 ? $0[4] : "")
                    }
                    // Unwrap off the main actor, then await a MainActor
                    // method: sending a @MainActor-isolated instance to its
                    // own actor never needs Sendable — the MainActor.run
                    // closure form trips older toolchains (Xcode 16.4).
                    guard let self else { return }
                    await self.bootstrapSucceeded(path: path, products: parsed)
                } catch {
                    guard let self else { return }
                    await self.bootstrapFailed(error)
                }
            }
        } catch {
            status = "Configuration error: \(error)"
        }
    }

    // T: Sendable — the result crosses an isolation boundary; older
    // toolchains (e.g. Xcode 16.4) reject the unconstrained form.
    func bootstrapSucceeded(path: String, products: [ProductInfo]) {
        storePath = path
        self.products = products
        ready = true
        status = "Connected — \(products.count) products"
        loadSnapshots()
    }

    func bootstrapFailed(_ error: Error) {
        ready = false
        status = "Backend error: \(error)"
    }

    private func call<T: Sendable>(_ what: String, _ body: @escaping (RivetAPI) async throws -> T,
                         then post: @escaping (T) -> Void) {
        guard let backend, ready else { return }
        Task {
            do {
                let api = RivetAPI(client: backend.client)
                let result = try await body(api)
                await MainActor.run {
                    post(result)
                    self.errorMessage = nil
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "\(what): \(error)"
                }
            }
        }
    }

    func refreshProducts() {
        call("store-info") { try await $0.store_info() } then: { infos in
            self.products = infos.map {
                ProductInfo(name: $0[0], entries: $0[1],
                            keyID: $0.count > 2 ? $0[2] : "",
                            fingerprint: $0.count > 3 ? $0[3] : "",
                            status: $0.count > 4 ? $0[4] : "")
            }
            if let sel = self.selected {
                self.selected = self.products.first { $0.name == sel.name }
            }
            // The sidebar Snapshots tile tracks every store mutation, the
            // same way the Windows and Linux hosts refresh theirs.
            self.loadSnapshots()
        }
    }

    func checkAll() {
        call("check-store") { try await $0.check_store() } then: { rows in
            self.checks = rows.compactMap { r in
                guard r[0] != "(file)" else { return nil }
                return CheckRow(name: r[0], kind: r.count > 4 ? r[4] : "",
                                fingerprint: r.count > 5 ? r[5] : "",
                                paired: r.count > 6 ? r[6] : "",
                                status: r.count > 7 ? r[7] : "")
            }
            self.refreshProducts()
            // Count product sections only — the "(file)" row is the
            // whole-file report, not a section (Windows/Linux parity).
            self.statusMessage = "Deep check finished — \(self.checks.count) sections"
        }
    }

    func select(_ product: ProductInfo) {
        selected = product
        selectionGeneration += 1
        let generation = selectionGeneration
        call("entry-list") { try await $0.entry_list(product: product.name) } then: { rows in
            guard generation == self.selectionGeneration else { return }
            self.entries = rows.map { EntryRow(name: $0[0], state: $0[1]) }
        }
    }

    /// Copy is bound to the product whose rows are on screen. If the user
    /// has since selected another product, the result is dropped instead of
    /// landing a secret on the clipboard against a different header.
    func copyEntry(_ entry: EntryRow, in product: ProductInfo) {
        let generation = selectionGeneration
        call("entry-get") { try await $0.entry_get(product: product.name, name: entry.name) } then: { value in
            guard product.name == self.selected?.name,
                  generation == self.selectionGeneration else {
                self.statusMessage = "Copy skipped — selection changed"
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            self.scheduleClipboardExpiry()
            self.statusMessage = "Copied \(entry.name) — raw value on the clipboard, "
                + "other apps can read it; auto-clears in 30 s unless something else copies first"
        }
    }

    /// Optional expiry: erase the copied value 30 s later, but only while
    /// the pasteboard still holds exactly what this action put there. A
    /// user copy in between bumps changeCount and survives untouched. The
    /// OS pasteboard history/sync is out of our control and never claimed
    /// otherwise.
    private func scheduleClipboardExpiry() {
        clipboardExpiryWork?.cancel()
        clipboardCopyChangeCount = NSPasteboard.general.changeCount
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  NSPasteboard.general.changeCount == self.clipboardCopyChangeCount else { return }
            NSPasteboard.general.clearContents()
            self.statusMessage = "Auto-cleared the copied key from the clipboard"
        }
        clipboardExpiryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
    }

    func setEntry(name: String, value: String) {
        guard let product = selected else { return }
        call("entry-set") { try await $0.entry_set(product: product.name, name: name, value: value) } then: { result in
            self.statusMessage = "Set \(name) — \(result)"
            // Counts and chips live in store-info: refresh products, then
            // re-fetch the selection's rows, so the sidebar never shows
            // stale numbers (Linux/Windows parity). refreshProducts also
            // refreshes the Snapshots tile.
            self.refreshProducts()
            self.select(product)
        }
    }

    func deleteEntry(_ entry: EntryRow) {
        guard let product = selected else { return }
        call("entry-delete") { try await $0.entry_delete(product: product.name, name: entry.name) } then: { _ in
            self.statusMessage = "Deleted \(entry.name) (snapshot taken)"
            self.refreshProducts()
            self.select(product)
        }
    }

    func importKey(name: String, at url: URL) {
        guard let product = selected else { return }
        let path = url.path
        call("entry-import-file") {
            try await $0.entry_import_file(product: product.name, name: name, file_path: path)
        } then: { result in
            self.statusMessage = "Imported \(name) — \(result)"
            self.refreshProducts()
            self.select(product)
        }
    }

    func generateUpdateKey() {
        guard let product = selected else { return }
        call("keypair-generate") { try await $0.keypair_generate(product: product.name) } then: { row in
            self.statusMessage = "Generated \(row[0]) — fingerprint \(row[1]) (collected into the vault)"
            self.refreshProducts()
            self.select(product)
        }
    }

    func loadSnapshots() {
        call("snapshot-list") { try await $0.snapshot_list() } then: { rows in
            self.snapshots = rows.map { SnapshotRow(stamp: $0[0], size: $0[1]) }
        }
    }

    func restoreSnapshot(_ snap: SnapshotRow) {
        call("snapshot-restore") { try await $0.snapshot_restore(stamp: snap.stamp) } then: { _ in
            self.statusMessage = "Restored \(snap.stamp) (pre-restore snapshot taken)"
            // refreshProducts also refreshes the Snapshots tile count.
            self.refreshProducts()
            // The restored file may hold different entries for the product
            // still on screen — re-fetch them instead of trusting the
            // pre-restore list.
            if let product = self.selected { self.select(product) }
        }
    }

    func openStore(at url: URL) {
        call("store-open") { try await $0.store_open(path: url.path) } then: { path in
            self.storePath = path
            self.products = []
            self.selected = nil
            // Invalidate entry/copy completions still in flight for the
            // previous store's selection.
            self.selectionGeneration += 1
            self.checks = []
            self.entries = []
            self.refreshProducts()
            self.statusMessage = "Store switched: \(path)"
        }
    }

    /// The host raises this flag; the view presents the file importer.
    func requestOpenStore() {
        openStoreRequested = true
    }
}
