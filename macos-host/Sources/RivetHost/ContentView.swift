import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject private var model: KeywardModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                SidebarView()
                    .frame(width: Palette.sidebarWidth)
                Divider()
                    .overlay(model.theme.divider)
                ProductPaneView()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider().overlay(model.theme.divider)
            StatusBar()
        }
        .background(model.theme.background)
        .sheet(isPresented: $model.snapshotsVisible) {
            SnapshotsSheet()
        }
        .fileImporter(isPresented: $model.openStoreRequested,
                      allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                model.openStore(at: url)
            }
        }
        .alert("Engine message", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

// ---- sidebar ------------------------------------------------------------------

private struct SidebarView: View {
    @EnvironmentObject private var model: KeywardModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                brand
                tiles
                productSection
            }
            .padding(12)
        }
        .background(model.theme.sidebar)
    }

    private var brand: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Keyward")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(model.theme.onSurface)
            Text("release-signing key vault")
                .font(.system(size: 11))
                .foregroundStyle(model.theme.tertiaryText)
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
    }

    private var tiles: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible())],
                  spacing: 8) {
            SummaryTile(icon: "tray.full", title: "Products", count: model.productCount,
                        color: model.theme.accent, theme: model.theme)
            SummaryTile(icon: "checkmark.seal.fill", title: "Paired", count: model.okCount,
                        color: model.theme.ok, theme: model.theme)
            SummaryTile(icon: "exclamationmark.triangle.fill", title: "Attention",
                        count: model.attentionCount, color: model.theme.warn, theme: model.theme)
            SummaryTile(icon: "clock.arrow.circlepath", title: "Snapshots",
                        count: nil, color: model.theme.neutral, theme: model.theme)
        }
    }

    private var productSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Products")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(model.theme.secondaryText)
                Spacer()
                Button {
                    model.checkAll()
                } label: {
                    Image(systemName: "checkmark.seal")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(model.theme.accent)
                }
                .buttonStyle(.plain)
                .disabled(!model.ready)
                .help("Deep Check (⌘R)")
            }
            .padding(.horizontal, 4)

            ForEach(model.products) { product in
                ProductRowView(product: product)
            }
        }
    }
}

/// Summary tile (taskly SmartChip pattern): colored 14px glyph, 13px label,
/// quiet count; selection/hover are quiet fills, the color never fills.
private struct SummaryTile: View {
    @EnvironmentObject private var model: KeywardModel
    let icon: String
    let title: String
    let count: Int?
    let color: Color
    let theme: ThemeState

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(color)
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(theme.onSurface)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 4)
            if let count {
                Text("\(count)")
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(theme.secondaryText)
                    // the count must never wrap or compress: "15" folding into
                    // a vertical "1/5" reads as two mystery numbers
                    .lineLimit(1)
                    .fixedSize()
                    .layoutPriority(2)
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .frame(height: 34)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: Palette.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Palette.cardRadius)
                .strokeBorder(theme.divider, lineWidth: 1))
    }
}

private struct ProductRowView: View {
    @EnvironmentObject private var model: KeywardModel
    let product: ProductInfo

    @State private var isHovering = false

    private var isSelected: Bool { model.selected?.name == product.name }

    private var dotColor: Color {
        let theme = model.theme
        if product.status == "ok" { return theme.ok }
        if product.status == "no-key" || product.status == "empty-section"
            || product.status.hasPrefix("empty") { return theme.neutral }
        return theme.warn
    }

    private var caption: String {
        product.status == "ok" ? product.fingerprint : product.status
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(product.name)
                    .font(.system(size: 13))
                    .foregroundStyle(model.theme.onSurface)
                    .lineLimit(1)
                Text(caption)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(model.theme.tertiaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(product.entries)
                .font(.system(size: 11))
                .foregroundStyle(model.theme.secondaryText)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Palette.cardRadius)
                .fill(isSelected ? model.theme.selection : (isHovering ? model.theme.hover : .clear)))
        .contentShape(RoundedRectangle(cornerRadius: Palette.cardRadius))
        .onTapGesture { model.select(product) }
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isSelected)
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

// ---- product pane ---------------------------------------------------------------

private struct ProductPaneView: View {
    @EnvironmentObject private var model: KeywardModel

    var body: some View {
        if let product = model.selected {
            ProductDetail(product: product)
        } else if model.storePath.isEmpty {
            noVault
        } else {
            KeywardIntroPane()
        }
    }

    private var noVault: some View {
        VStack(spacing: 14) {
            Image(systemName: "key.radiowaves.forward")
                .font(.system(size: 44))
                .foregroundStyle(model.theme.accent)
            Text("No vault selected")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(model.theme.onSurface)
            Text("Point Keyward at your secrets.ini — any vault in the same\nINI format works. The choice is remembered across launches.")
                .font(.system(size: 13))
                .foregroundStyle(model.theme.secondaryText)
                .multilineTextAlignment(.center)
            Button("Choose Vault…") { model.requestOpenStore() }
                .buttonStyle(.borderedProminent)
                .tint(model.theme.accent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct KeywardIntroPane: View {
    @EnvironmentObject private var model: KeywardModel

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "key.fill")
                .font(.system(size: 40))
                .foregroundStyle(model.theme.accent)
            Text("A local vault for release-signing keys")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(model.theme.onSurface)
            Text("Pick a product on the left. Values are never displayed —\nthey only ever leave through copy-to-clipboard.")
                .font(.system(size: 13))
                .foregroundStyle(model.theme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ProductDetail: View {
    @EnvironmentObject private var model: KeywardModel
    let product: ProductInfo

    @State private var showingNewEntry = false
    @State private var newEntryName = ""
    @State private var newEntryValue = ""
    @State private var importTarget: EntryRow?
    @State private var showingImporter = false
    @State private var confirmingKeyGen = false
    @State private var deleteTarget: EntryRow?

    private var check: CheckRow? {
        model.checks.first { $0.name == product.name }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                entriesSection
            }
            .padding(20)
        }
        .background(model.theme.background)
        .fileImporter(isPresented: $showingImporter,
                      allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first, let target = importTarget {
                model.importKey(name: target.name, at: url)
            }
        }
        .alert("New entry in \(product.name)", isPresented: $showingNewEntry) {
            TextField("NAME", text: $newEntryName)
            TextField("value (single line)", text: $newEntryValue)
            Button("Set") {
                model.setEntry(name: newEntryName.uppercased(), value: newEntryValue)
                newEntryName = ""
                newEntryValue = ""
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(keyGenTitle, isPresented: $confirmingKeyGen,
                            titleVisibility: .visible) {
            Button("Generate", role: .destructive) { model.generateUpdateKey() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(keyGenMessage)
        }
        .confirmationDialog(deleteTitle, isPresented: deleteBinding,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let t = deleteTarget { model.deleteEntry(t) }
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            Text(deleteMessage)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(product.name)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(model.theme.onSurface)
                Spacer()
                Button {
                    model.checkAll()
                } label: {
                    Label("Deep Check", systemImage: "checkmark.seal")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(model.theme.accent)
                .disabled(!model.ready)
                .help("Deep Check (⌘R)")

                Button {
                    model.loadSnapshots()
                    model.snapshotsVisible = true
                } label: {
                    Label("Snapshots", systemImage: "clock.arrow.circlepath")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(model.theme.secondaryText)
                .disabled(!model.ready)
                .help("Snapshots (⌘L)")
            }

            HStack(spacing: 8) {
                KVChip(label: "entries", value: product.entries, theme: model.theme)
                if !product.keyID.isEmpty {
                    KVChip(label: "key id", value: product.keyID, theme: model.theme)
                }
                if !product.fingerprint.isEmpty && product.fingerprint != "-" {
                    KVChip(label: "fingerprint", value: product.fingerprint,
                           mono: true, theme: model.theme)
                }
                StatusChip(status: product.status, theme: model.theme)
                Spacer()
            }

            if let check {
                HStack(spacing: 8) {
                    KVChip(label: "kind", value: check.kind, theme: model.theme)
                    KVChip(label: "paired", value: check.paired,
                           tone: check.paired == "yes" ? .ok : .warn, theme: model.theme)
                    KVChip(label: "check", value: check.status,
                           tone: check.status == "ok" ? .ok : .warn, theme: model.theme)
                    Spacer()
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(model.theme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(model.theme.divider, lineWidth: 1))
    }

    private var entriesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Entries")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(model.theme.secondaryText)
                Spacer()
                addMenu
            }
            if model.entries.isEmpty {
                Text("No entries in this section.")
                    .font(.system(size: 13))
                    .foregroundStyle(model.theme.tertiaryText)
                    .padding(.vertical, 10)
            }
            ForEach(model.entries) { entry in
                EntryCard(entry: entry,
                          onCopy: { model.copyEntry(entry) },
                          onImport: {
                              importTarget = entry
                              showingImporter = true
                          },
                          onDelete: { deleteTarget = entry })
            }
        }
    }

    private var addMenu: some View {
        Menu {
            Button("New entry…") { showingNewEntry = true }
            Button("Import PEM file…") {
                importTarget = EntryRow(name: "UPDATE_ED25519_PRIVATE_KEY_B64", state: "empty")
                showingImporter = true
            }
            Button("Generate update key…") { confirmingKeyGen = true }
        } label: {
            Label("Add", systemImage: "plus")
                .font(.system(size: 12, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .tint(model.theme.accent)
    }

    private var keyGenTitle: String { "Generate a new Ed25519 update key for \(product.name)?" }
    private var keyGenMessage: String {
        "The new pair is collected into the vault directly. Rotating the signing key "
            + "is a release-level change — ship a build trusting the new public key first."
    }
    private var deleteTitle: String { "Delete \(deleteTarget?.name ?? "")?" }
    private var deleteMessage: String {
        "A snapshot is taken first and the old value stays recoverable from it."
    }
    private var deleteBinding: Binding<Bool> {
        Binding(get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } })
    }
}

private struct KVChip: View {
    let label: String
    let value: String
    var mono: Bool = false
    var tone: Tone = .neutral
    let theme: ThemeState

    enum Tone { case neutral, ok, warn }

    var body: some View {
        HStack(spacing: 5) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme.tertiaryText)
            Text(value.isEmpty ? "—" : value)
                .font(.system(size: 12, design: mono ? .monospaced : .default))
                .foregroundStyle(textColor)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(theme.badgeBackground, in: RoundedRectangle(cornerRadius: 6))
    }

    private var textColor: Color {
        switch tone {
        case .neutral: return theme.onSurface
        case .ok: return theme.ok
        case .warn: return theme.warn
        }
    }
}

private struct StatusChip: View {
    let status: String
    let theme: ThemeState

    private var color: Color {
        status == "ok" ? theme.ok
            : status == "no-key" || status == "empty-section" ? theme.neutral
            : theme.warn
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(status)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(theme.badgeBackground, in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct EntryCard: View {
    @EnvironmentObject private var model: KeywardModel
    let entry: EntryRow
    let onCopy: () -> Void
    let onImport: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: entry.state == "set" ? "lock.fill" : "lock.open.fill")
                .font(.system(size: 12))
                .foregroundStyle(entry.state == "set"
                                 ? model.theme.accent
                                 : model.theme.tertiaryText)
            Text(entry.name)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(model.theme.onSurface)
                .lineLimit(1)
            if entry.state == "empty" {
                Text("empty")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(model.theme.warn)
            }
            Spacer(minLength: 8)
            if isHovering {
                Button {
                    onCopy()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(model.theme.accent)
                .transition(.opacity)
            }
            Menu {
                Button("Copy value to clipboard") { onCopy() }
                Button("Import PEM file…") { onImport() }
                Button("Delete…", role: .destructive) { onDelete() }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(model.theme.secondaryText)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(model.theme.surface, in: RoundedRectangle(cornerRadius: Palette.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Palette.cardRadius)
                .strokeBorder(isHovering ? model.theme.accent.opacity(0.45)
                                          : model.theme.divider, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: Palette.cardRadius))
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
        }
    }
}

// ---- status bar -----------------------------------------------------------------

private struct StatusBar: View {
    @EnvironmentObject private var model: KeywardModel

    var body: some View {
        HStack(spacing: 12) {
            Text(model.statusMessage ?? model.status)
                .font(.system(size: 12))
                .foregroundStyle(model.statusMessage != nil
                                 ? model.theme.onSurface
                                 : model.theme.secondaryText)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            Text(model.storePath)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(model.theme.tertiaryText)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .padding(.horizontal, 12)
        .frame(height: Palette.statusHeight)
        .background(model.theme.sidebar)
    }
}

// ---- snapshots sheet --------------------------------------------------------------

private struct SnapshotsSheet: View {
    @EnvironmentObject private var model: KeywardModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Store snapshots")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(model.theme.onSurface)
                    Text("Every write lands here first — restoring takes one click.")
                        .font(.system(size: 12))
                        .foregroundStyle(model.theme.secondaryText)
                }
                Spacer()
                Button("Done") { model.snapshotsVisible = false }
            }
            .padding(16)
            Divider().overlay(model.theme.divider)
            if model.snapshots.isEmpty {
                Text("No snapshots yet")
                    .font(.system(size: 13))
                    .foregroundStyle(model.theme.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(model.snapshots) { snap in
                            SnapshotRowView(snap: snap)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .frame(width: 540, height: 440)
        .background(model.theme.background)
        .task { model.loadSnapshots() }
    }
}

// ---- about sheet --------------------------------------------------------------

/// About (Help ▸ About): version, product line, license, site and the
/// issue tracker — a bug report starts one click from the failure it
/// describes. Keyward is AGPL-3.0, so the license line names it plainly.
struct AboutSheet: View {
    @EnvironmentObject private var model: KeywardModel
    @Environment(\.dismiss) private var dismiss

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? RivetGeneratedConfig.version
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "key")
                .font(.system(size: 44))
                .foregroundStyle(model.theme.accent)
            Text("Keyward v\(version)")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(model.theme.onSurface)
            Text("A signing-key vault over your synced INI file — local by design.")
                .font(.system(size: 12))
                .foregroundStyle(model.theme.secondaryText)
                .multilineTextAlignment(.center)
            Text("Released under the GNU AGPL-3.0")
                .font(.system(size: 11))
                .foregroundStyle(model.theme.secondaryText)
            HStack(spacing: 20) {
                Link("keyward.jrtx.site",
                     destination: URL(string: "https://keyward.jrtx.site")!)
                Link("Report an Issue",
                     destination: URL(string:
                        "https://github.com/turinglambdaai/keyward/issues")!)
            }
            .font(.system(size: 12))
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(28)
        .frame(width: 360)
        .background(model.theme.background)
    }
}

private struct SnapshotRowView: View {
    @EnvironmentObject private var model: KeywardModel
    let snap: SnapshotRow

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "camera.on.rectangle")
                .font(.system(size: 12))
                .foregroundStyle(model.theme.accent)
            Text(snap.stamp)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(model.theme.onSurface)
            Spacer()
            Text("\(snap.size) B")
                .font(.system(size: 11))
                .foregroundStyle(model.theme.secondaryText)
            Button("Restore") { model.restoreSnapshot(snap) }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(model.theme.accent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(model.theme.surface, in: RoundedRectangle(cornerRadius: Palette.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Palette.cardRadius)
                .strokeBorder(model.theme.divider, lineWidth: 1))
    }
}
