import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject private var model: KeywardModel

    @State private var showingSnapshots = false
    @State private var showingOpenStore = false
    @State private var newEntryName = ""
    @State private var newEntryValue = ""
    @State private var showingNewEntry = false
    @State private var importTarget: EntryRow?
    @State private var showingImporter = false
    @State private var confirmingKeyGen = false
    @State private var deleteTarget: EntryRow?

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .navigationTitle("Keyward")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    model.checkAll()
                } label: {
                    Label("Deep Check", systemImage: "checkmark.seal")
                }
                .disabled(!model.ready)

                Button {
                    model.loadSnapshots()
                    showingSnapshots = true
                } label: {
                    Label("Snapshots", systemImage: "clock.arrow.circlepath")
                }
                .disabled(!model.ready)

                Button {
                    showingOpenStore = true
                } label: {
                    Label("Open Store…", systemImage: "folder")
                }
                .disabled(!model.ready)
            }
        }
        .alert("Backend message", isPresented: Binding(
            get: { model.message != nil },
            set: { if !$0 { model.message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.message ?? "")
        }
        .sheet(isPresented: $showingSnapshots) { snapshotsSheet }
        .fileImporter(isPresented: $showingOpenStore,
                      allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                model.openStore(at: url)
            }
        }
        .fileImporter(isPresented: $showingImporter,
                      allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first,
               let target = importTarget {
                model.importKey(name: target.name, at: url)
            }
        }
        .alert("New entry in \(model.selected?.name ?? "")", isPresented: $showingNewEntry) {
            TextField("NAME", text: $newEntryName)
            TextField("value (single line)", text: $newEntryValue)
            Button("Set") {
                model.setEntry(name: newEntryName.uppercased(), value: newEntryValue)
                newEntryName = ""
                newEntryValue = ""
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Generate a new Ed25519 update key for \(model.selected?.name ?? "")?\n"
                + "The new pair is collected into the store directly. Rotating the "
                + "signing key is a release-level change — ship a build trusting the "
                + "new public key first.",
            isPresented: $confirmingKeyGen,
            titleVisibility: .visible) {
            Button("Generate", role: .destructive) { model.generateUpdateKey() }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Delete \(deleteTarget?.name ?? "")? A snapshot is taken first and the old "
                + "value stays recoverable from it.",
            isPresented: Binding(get: { deleteTarget != nil },
                                 set: { if !$0 { deleteTarget = nil } }),
            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let t = deleteTarget { model.deleteEntry(t) }
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        }
    }

    // ---- sidebar ------------------------------------------------------------

    private var selectionBinding: Binding<String?> {
        Binding(
            get: { model.selected?.name },
            set: { newName in
                if let newName,
                   let product = model.products.first(where: { $0.name == newName }) {
                    model.select(product)
                }
            })
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(model.products, selection: selectionBinding) { product in
                productRow(product)
                    .tag(product.name)
            }
            .listStyle(.sidebar)

            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text(model.storePath)
                    .font(.caption2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                Text(model.status)
                    .font(.caption2)
                    .foregroundStyle(model.ready ? Color.secondary : Color.orange)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func productRow(_ product: ProductInfo) -> some View {
        HStack {
            Image(systemName: statusIcon(product.status))
                .foregroundStyle(statusColor(product.status))
            VStack(alignment: .leading) {
                Text(product.name)
                Text(product.status == "ok"
                     ? product.fingerprint
                     : product.status)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func statusIcon(_ status: String) -> String {
        status == "ok" ? "key.fill"
            : status.hasPrefix("empty") ? "key.slash"
            : "exclamationmark.triangle.fill"
    }

    private func statusColor(_ status: String) -> Color {
        status == "ok" ? Color.green
            : status.hasPrefix("empty") || status == "no-key" ? Color.secondary
            : Color.orange
    }

    // ---- detail ---------------------------------------------------------------

    @ViewBuilder
    private var detail: some View {
        if let product = model.selected {
            List {
                Section(product.name) {
                    labeled("Entries", product.entries)
                    labeled("Key id", product.keyID)
                    labeled("Fingerprint", product.fingerprint)
                    labeled("Status", product.status)
                }

                Section {
                    ForEach(model.entries) { entry in
                        entryRow(entry)
                    }
                } header: {
                    HStack {
                        Text("Entries")
                        Spacer()
                        Menu {
                            Button("New entry…") { showingNewEntry = true }
                            Button("Import PEM file…") {
                                importTarget = EntryRow(name: "UPDATE_ED25519_PRIVATE_KEY_B64", state: "empty")
                                showingImporter = true
                            }
                            Button("Generate update key…", role: .destructive) {
                                confirmingKeyGen = true
                            }
                        } label: {
                            Image(systemName: "plus")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }
            }
        } else {
            ContentUnavailableView(
                "Keyward",
                systemImage: "key.radiowaves.forward",
                description: Text(
                    "A local vault for the release-signing keys of your\n"
                        + "self-updating apps. Pick a product on the left;\n"
                        + "values are never displayed — copy-only."))
        }
    }

    private func labeled(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            Text(value.isEmpty ? "—" : value)
                .font(value.contains("-") && value.count == 16
                      ? .system(.body, design: .monospaced)
                      : .body)
                .textSelection(.enabled)
        }
    }

    private func entryRow(_ entry: EntryRow) -> some View {
        HStack {
            Image(systemName: entry.state == "set" ? "lock.fill" : "lock.open")
                .foregroundStyle(entry.state == "set" ? Color.secondary : Color.orange)
                .font(.caption)
            Text(entry.name)
                .font(.system(.body, design: .monospaced))
            Spacer()
            Menu {
                Button("Copy value to clipboard") { model.copyEntry(entry) }
                Button("Import PEM file…") {
                    importTarget = entry
                    showingImporter = true
                }
                Button("Delete…", role: .destructive) { deleteTarget = entry }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    // ---- sheets ---------------------------------------------------------------

    private var snapshotsSheet: some View {
        VStack(spacing: 0) {
            Text("Store snapshots — every write lands here first")
                .font(.headline)
                .padding(12)
            Divider()
            if model.snapshots.isEmpty {
                Text("No snapshots yet")
                    .foregroundStyle(.secondary)
                    .padding(30)
            } else {
                List(model.snapshots) { snap in
                    HStack {
                        Text(snap.stamp)
                            .font(.system(.caption, design: .monospaced))
                        Spacer()
                        Text("\(snap.size) B")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Restore") { model.restoreSnapshot(snap) }
                            .controlSize(.small)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Close") { showingSnapshots = false }
                Spacer()
            }
            .padding(10)
        }
        .frame(width: 520, height: 420)
        .task { model.loadSnapshots() }
    }
}
