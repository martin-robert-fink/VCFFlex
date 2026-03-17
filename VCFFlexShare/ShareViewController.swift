//
//  ShareViewController.swift
//  VCFFlexShare
//
//  Created by Martin Fink on 3/16/26.
//

import Cocoa
import SwiftUI
import UniformTypeIdentifiers
import Combine

class ShareViewController: NSViewController {

    private let shareData = ShareData()

    override func loadView() {
        let hostingView = NSHostingView(
            rootView: ShareExtensionView(shareData: shareData, onCancel: { [weak self] in
                self?.cancel()
            })
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 400, height: 500)
        self.view = hostingView
        self.preferredContentSize = NSSize(width: 400, height: 500)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        extractVCF()
    }

    private func extractVCF() {
        guard let extensionItems = extensionContext?.inputItems as? [NSExtensionItem] else {
            shareData.errorMessage = "No items received"
            return
        }

        for item in extensionItems {
            guard let attachments = item.attachments else { continue }

            for provider in attachments {
                if provider.hasItemConformingToTypeIdentifier(UTType.vCard.identifier) {
                    provider.loadItem(forTypeIdentifier: UTType.vCard.identifier, options: nil) { [weak self] data, error in
                        DispatchQueue.main.async {
                            if let error = error {
                                self?.shareData.errorMessage = "Failed to load: \(error.localizedDescription)"
                                return
                            }

                            var vcfString: String?

                            if let vcfData = data as? Data, let str = String(data: vcfData, encoding: .utf8) {
                                vcfString = str
                            } else if let url = data as? URL, let str = try? String(contentsOf: url, encoding: .utf8) {
                                vcfString = str
                            } else if let str = data as? String {
                                vcfString = str
                            }

                            if let vcfString = vcfString {
                                self?.shareData.vcfText = vcfString
                                self?.shareData.fields = VCFParser.parse(vcfString)
                            } else {
                                self?.shareData.errorMessage = "Unrecognized data format"
                            }
                        }
                    }
                    return
                }
            }
        }

        shareData.errorMessage = "No vCard data found"
    }

    private func cancel() {
        extensionContext?.cancelRequest(withError: NSError(
            domain: NSCocoaErrorDomain,
            code: NSUserCancelledError
        ))
    }
}

class ShareData: ObservableObject {
    @Published var vcfText: String?
    @Published var fields: [VCFField] = []
    @Published var errorMessage: String?
}

struct ShareExtensionView: View {
    @ObservedObject var shareData: ShareData
    var onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button("Cancel") {
                    onCancel()
                }
                Spacer()
                Text("VCFFlex")
                    .font(.headline)
                Spacer()
                // Invisible button for balanced layout
                Button("Cancel") {}
                    .hidden()
            }
            .padding()

            Divider()

            // Content
            if let errorMessage = shareData.errorMessage, shareData.vcfText == nil {
                Spacer()
                Text(errorMessage)
                    .foregroundColor(.red)
                Spacer()
            } else if !shareData.fields.isEmpty {
                List {
                    ForEach(shareData.fields.filter { !$0.isStructural }) { field in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(field.label)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(field.displayValue)
                                .font(.body)
                                .lineLimit(field.property == "PHOTO" ? 1 : 4)
                        }
                        .padding(.vertical, 4)
                    }
                }
            } else if shareData.vcfText != nil {
                Spacer()
                Text("No parseable fields found")
                    .foregroundColor(.secondary)
                Spacer()
            } else {
                Spacer()
                ProgressView("Loading contact…")
                Spacer()
            }
        }
        .frame(width: 400, height: 500)
        .background(Color(NSColor.windowBackgroundColor))
    }
}
