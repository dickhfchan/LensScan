import SwiftUI

struct LibraryView: View {
    @Environment(ScanStore.self) private var store

    @State private var isScanning = false
    @State private var isProcessing = false
    @State private var scannerUnavailable = false

    var body: some View {
        NavigationStack {
            Group {
                if store.documents.isEmpty {
                    emptyState
                } else {
                    documentList
                }
            }
            .navigationTitle("Scans")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        startScan()
                    } label: {
                        Label("New Scan", systemImage: "doc.viewfinder")
                    }
                }
            }
            .overlay {
                if isProcessing {
                    processingOverlay
                }
            }
        }
        .fullScreenCover(isPresented: $isScanning) {
            DocumentScannerView(
                onFinish: { images in
                    isScanning = false
                    handleCapture(images)
                },
                onCancel: { isScanning = false }
            )
            .ignoresSafeArea()
        }
        .alert("Camera not available", isPresented: $scannerUnavailable) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Document scanning needs a device camera. The Simulator can't run it.")
        }
    }

    // MARK: - Pieces

    private var documentList: some View {
        List {
            ForEach(store.documents) { document in
                NavigationLink(value: document.id) {
                    row(for: document)
                }
            }
            .onDelete { offsets in
                // Resolve IDs before deleting; indices shift as the array mutates.
                let ids = offsets.map { store.documents[$0].id }
                for id in ids {
                    store.delete(id)
                }
            }
        }
        .listStyle(.plain)
        .navigationDestination(for: UUID.self) { id in
            ScanDetailView(documentID: id)
        }
    }

    private func row(for document: ScanDocument) -> some View {
        HStack(spacing: 12) {
            thumbnail(for: document)
            VStack(alignment: .leading, spacing: 4) {
                Text(document.title)
                    .font(.headline)
                    .lineLimit(1)
                Text("\(document.pageCountLabel) · \(document.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func thumbnail(for document: ScanDocument) -> some View {
        if let page = document.pages.first,
           let image = store.loadThumbnail(for: page, in: document.id) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 48, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary)
                .frame(width: 48, height: 64)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No scans yet", systemImage: "doc.viewfinder")
        } description: {
            Text("Point the camera at a document, whiteboard or receipt. Edges are found and straightened automatically.")
        } actions: {
            Button("Start scanning") { startScan() }
                .buttonStyle(.borderedProminent)
        }
    }

    private var processingOverlay: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                Text("Reading text…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    // MARK: - Actions

    private func startScan() {
        guard DocumentScannerView.isSupported else {
            scannerUnavailable = true
            return
        }
        isScanning = true
    }

    private func handleCapture(_ images: [UIImage]) {
        guard !images.isEmpty else { return }
        isProcessing = true
        Task {
            await store.addDocument(images: images)
            isProcessing = false
        }
    }
}
