import SwiftUI

struct ScanDetailView: View {
    /// Stable placeholder selection for the (unreachable) case of a document with no pages.
    private static let noPageTag = UUID()

    let documentID: UUID

    @Environment(ScanStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var selectedPageID: UUID?
    @State private var rendered: [String: UIImage] = [:]
    @State private var isRendering = false
    @State private var sharePayload: SharePayload?
    @State private var showingText = false
    @State private var isRenaming = false
    @State private var draftTitle = ""

    private var document: ScanDocument? { store.document(withID: documentID) }

    var body: some View {
        Group {
            if let document {
                content(for: document)
            } else {
                ContentUnavailableView("Scan deleted", systemImage: "trash")
            }
        }
        .navigationTitle(document?.title ?? "Scan")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .sheet(item: $sharePayload) { payload in
            ShareSheet(items: [payload.url])
        }
        .sheet(isPresented: $showingText) {
            TextSheet(text: document?.fullText ?? "")
        }
        .alert("Rename scan", isPresented: $isRenaming) {
            TextField("Title", text: $draftTitle)
            Button("Cancel", role: .cancel) {}
            Button("Save") { store.rename(documentID, to: draftTitle) }
        }
        .task { await renderVisiblePage() }
        .onChange(of: selectedPageID) { _, _ in
            Task { await renderVisiblePage() }
        }
    }

    // MARK: - Content

    private func content(for document: ScanDocument) -> some View {
        VStack(spacing: 0) {
            TabView(selection: Binding(
                get: { selectedPageID ?? document.pages.first?.id ?? Self.noPageTag },
                set: { selectedPageID = $0 }
            )) {
                ForEach(document.pages) { page in
                    pageView(page)
                        .tag(page.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: document.pages.count > 1 ? .automatic : .never))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            Divider()
            modeBar(for: document)
        }
        .background(Color(.systemGroupedBackground))
    }

    private func pageView(_ page: ScanPage) -> some View {
        ZStack {
            if let image = rendered[key(for: page)] ?? store.loadImage(for: page, in: documentID) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(12)
            } else {
                ContentUnavailableView("Page missing", systemImage: "exclamationmark.triangle")
            }

            if isRendering && page.id == currentPage?.id {
                ProgressView()
                    .padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func modeBar(for document: ScanDocument) -> some View {
        VStack(spacing: 8) {
            Picker("Enhancement", selection: Binding(
                get: { currentPage?.mode ?? .document },
                set: { newMode in
                    guard let page = currentPage else { return }
                    store.setMode(newMode, forPage: page.id, in: documentID)
                    Task { await renderVisiblePage() }
                }
            )) {
                ForEach(EnhancementMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if document.pages.count > 1, let page = currentPage {
                Button("Apply \(page.mode.label) to all pages") {
                    store.setMode(page.mode, forAllPagesIn: documentID)
                    rendered.removeAll()
                    Task { await renderVisiblePage() }
                }
                .font(.footnote)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button {
                    Task { await exportPDF() }
                } label: {
                    Label("Share PDF", systemImage: "square.and.arrow.up")
                }

                Button {
                    showingText = true
                } label: {
                    Label("View text", systemImage: "text.alignleft")
                }
                .disabled(document?.fullText.isEmpty ?? true)

                Button {
                    Task { await exportText() }
                } label: {
                    Label("Share text file", systemImage: "doc.plaintext")
                }
                .disabled(document?.fullText.isEmpty ?? true)

                Divider()

                Button {
                    draftTitle = document?.title ?? ""
                    isRenaming = true
                } label: {
                    Label("Rename", systemImage: "pencil")
                }

                if let page = currentPage, (document?.pages.count ?? 0) > 1 {
                    Button(role: .destructive) {
                        store.deletePage(page.id, in: documentID)
                        selectedPageID = store.document(withID: documentID)?.pages.first?.id
                    } label: {
                        Label("Delete this page", systemImage: "trash")
                    }
                }

                Button(role: .destructive) {
                    store.delete(documentID)
                    dismiss()
                } label: {
                    Label("Delete scan", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    // MARK: - Rendering

    private var currentPage: ScanPage? {
        guard let document else { return nil }
        if let selectedPageID, let match = document.pages.first(where: { $0.id == selectedPageID }) {
            return match
        }
        return document.pages.first
    }

    private func key(for page: ScanPage) -> String {
        "\(page.id.uuidString)-\(page.mode.rawValue)"
    }

    private func renderVisiblePage() async {
        guard let page = currentPage else { return }
        let cacheKey = key(for: page)
        if rendered[cacheKey] != nil { return }

        guard let original = store.loadImage(for: page, in: documentID) else { return }
        guard page.mode != .original else {
            rendered[cacheKey] = original
            return
        }

        isRendering = true
        let mode = page.mode
        let pageID = page.id.uuidString
        let image = await Task.detached(priority: .userInitiated) { () -> UIImage in
            ImageEnhancer.shared.enhance(original, mode: mode, cacheKey: pageID)
        }.value
        rendered[cacheKey] = image
        isRendering = false
    }

    /// Renders every page at its chosen mode, then builds the searchable PDF.
    private func exportPDF() async {
        guard let document else { return }
        isRendering = true
        defer { isRendering = false }

        var pages: [PDFExporter.Page] = []
        for page in document.pages {
            guard let original = store.loadImage(for: page, in: documentID) else { continue }
            let mode = page.mode
            let pageID = page.id.uuidString
            let image = await Task.detached(priority: .userInitiated) { () -> UIImage in
                ImageEnhancer.shared.enhance(original, mode: mode, cacheKey: pageID)
            }.value
            pages.append(PDFExporter.Page(image: image, blocks: page.textBlocks))
        }

        do {
            let url = try PDFExporter.makePDF(pages: pages, title: document.title)
            sharePayload = SharePayload(url: url)
        } catch {
            NSLog("PDF export failed: \(error.localizedDescription)")
        }
    }

    private func exportText() async {
        guard let document else { return }
        do {
            let url = try PDFExporter.makeTextFile(text: document.fullText, title: document.title)
            sharePayload = SharePayload(url: url)
        } catch {
            NSLog("Text export failed: \(error.localizedDescription)")
        }
    }
}

private struct TextSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle("Recognized text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        UIPasteboard.general.string = text
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                }
            }
        }
    }
}
