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

                            if let vcfData = data as? Data, let vcfString = String(data: vcfData, encoding: .utf8) {
                                self?.shareData.vcfText = vcfString
                            } else if let url = data as? URL, let vcfString = try? String(contentsOf: url, encoding: .utf8) {
                                self?.shareData.vcfText = vcfString
                            } else if let vcfString = data as? String {
                                self?.shareData.vcfText = vcfString
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
            } else if let vcfText = shareData.vcfText {
                ScrollView {
                    Text(vcfText)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
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
