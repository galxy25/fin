import SwiftUI
import SwiftData
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct ClipboardManagerView: View {
    let session: TerminalSession

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Clipping.createdAt, order: .reverse) private var allClippings: [Clipping]

    @State private var selectedDirection: ClippingDirection = .to
    @State private var isAddingClipping = false

    private var clippings: [Clipping] {
        allClippings.filter { $0.direction == selectedDirection }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Direction", selection: $selectedDirection) {
                    Text("To").tag(ClippingDirection.to)
                    Text("From").tag(ClippingDirection.from)
                }
                .pickerStyle(.segmented)
                .padding()

                List {
                    ForEach(clippings) { clipping in
                        Button {
                            paste(clipping)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(clipping.name)
                                    .font(.subheadline.weight(.semibold))
                                Text(clipping.text)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .swipeActions {
                            Button("Delete", role: .destructive) {
                                modelContext.delete(clipping)
                            }
                        }
                        // Tap pastes into the terminal; this is the other direction —
                        // out of Fin's clipboard onto the system one, so a captured
                        // terminal snippet can land anywhere else (the agent composer,
                        // another app) instead of only back into the shell.
                        .swipeActions(edge: .leading) {
                            Button {
                                copyToSystemClipboard(clipping)
                            } label: {
                                Label("Copy", systemImage: "doc.on.doc")
                            }
                            .tint(.blue)
                        }
                        .contextMenu {
                            Button {
                                copyToSystemClipboard(clipping)
                            } label: {
                                Label("Copy to Clipboard", systemImage: "doc.on.doc")
                            }
                            Button {
                                paste(clipping)
                            } label: {
                                Label("Paste into Terminal", systemImage: "arrow.right.square")
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .overlay {
                    if clippings.isEmpty {
                        ContentUnavailableView(
                            selectedDirection == .to ? "No Saved Clippings" : "Nothing Copied Yet",
                            systemImage: "doc.on.clipboard"
                        )
                    }
                }
            }
            .navigationTitle("Clipboard")
            .toolbar {
                if selectedDirection == .to {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            isAddingClipping = true
                        } label: {
                            Image(systemName: "plus")
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $isAddingClipping) {
            AddClippingView()
        }
    }

    private func paste(_ clipping: Clipping) {
        session.send(text: clipping.text)
        dismiss()
    }

    private func copyToSystemClipboard(_ clipping: Clipping) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(clipping.text, forType: .string)
        #else
        UIPasteboard.general.string = clipping.text
        #endif
    }
}

private struct AddClippingView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var name = String(Int(Date().timeIntervalSince1970))
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                TextEditor(text: $text)
                    .frame(minHeight: 120)
                    .font(.system(.body, design: .monospaced))
            }
            .navigationTitle("New Clipping")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        modelContext.insert(Clipping(name: name, text: text, direction: .to))
                        dismiss()
                    }
                    .disabled(text.isEmpty)
                }
            }
        }
    }
}
