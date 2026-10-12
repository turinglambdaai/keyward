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
        WindowGroup(RivetGeneratedConfig.displayName) {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 780, minHeight: 480)
                .task { model.start() }
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
    @Published var message: String?

    private var backend: EmbeddedRacketBackend?

    func start() {
        guard backend == nil else { return }

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
                    await MainActor.run {
                        guard let self else { return }
                        self.storePath = path
                        self.products = parsed
                        self.ready = true
                        self.status = "Connected — \(parsed.count) products"
                    }
                } catch {
                    await MainActor.run {
                        self?.ready = false
                        self?.status = "Backend error: \(error)"
                    }
                }
            }
        } catch {
            status = "Configuration error: \(error)"
        }
    }

    private func call<T>(_ what: String, _ body: @escaping (RivetAPI) async throws -> T,
                         then post: @escaping (T) -> Void) {
        guard let backend, ready else { return }
        Task {
            do {
                let api = RivetAPI(client: backend.client)
                let result = try await body(api)
                await MainActor.run {
                    post(result)
                    self.message = nil
                }
            } catch {
                await MainActor.run {
                    self.message = "\(what): \(error)"
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
            self.message = "Deep check finished — \(rows.count) sections"
        }
    }

    func select(_ product: ProductInfo) {
        selected = product
        call("entry-list") { try await $0.entry_list(product: product.name) } then: { rows in
            self.entries = rows.map { EntryRow(name: $0[0], state: $0[1]) }
        }
    }

    func copyEntry(_ entry: EntryRow) {
        guard let product = selected else { return }
        call("entry-get") { try await $0.entry_get(product: product.name, name: entry.name) } then: { value in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            self.message = "Copied \(entry.name) to clipboard (never displayed)"
        }
    }

    func setEntry(name: String, value: String) {
        guard let product = selected else { return }
        call("entry-set") { try await $0.entry_set(product: product.name, name: name, value: value) } then: { result in
            self.message = "Set \(name) — \(result)"
            self.select(product)
        }
    }

    func deleteEntry(_ entry: EntryRow) {
        guard let product = selected else { return }
        call("entry-delete") { try await $0.entry_delete(product: product.name, name: entry.name) } then: { _ in
            self.message = "Deleted \(entry.name) (snapshot taken)"
            self.select(product)
        }
    }

    func importKey(name: String, at url: URL) {
        guard let product = selected else { return }
        let path = url.path
        call("entry-import-file") {
            try await $0.entry_import_file(product: product.name, name: name, file_path: path)
        } then: { result in
            self.message = "Imported \(name) — \(result)"
            self.select(product)
        }
    }

    func generateUpdateKey() {
        guard let product = selected else { return }
        call("keypair-generate") { try await $0.keypair_generate(product: product.name) } then: { row in
            self.message = "Generated \(row[0]) — fingerprint \(row[1]) (collected into store, no stray files)"
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
            self.message = "Restored \(snap.stamp) (pre-restore snapshot taken)"
            self.refreshProducts()
        }
    }

    func openStore(at url: URL) {
        call("store-open") { try await $0.store_open(path: url.path) } then: { path in
            self.storePath = path
            self.products = []
            self.selected = nil
            self.checks = []
            self.entries = []
            self.refreshProducts()
            self.message = "Store switched: \(path)"
        }
    }
}
