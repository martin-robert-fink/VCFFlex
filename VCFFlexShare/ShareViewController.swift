//
//  ShareViewController.swift
//  VCFFlexShare
//
//  Chat 4: Toggle picker UI — grouped fields, select all, share button.
//

import Cocoa
import SwiftUI
import UniformTypeIdentifiers
import Combine

// MARK: - View Controller

class ShareViewController: NSViewController {

    private let shareData = ShareData()

    override func loadView() {
        let hostingView = NSHostingView(
            rootView: ShareExtensionView(
                shareData: shareData,
                onCancel: { [weak self] in self?.cancel() },
                onShare:  { [weak self] in self?.share()  }
            )
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 420, height: 560)
        self.view = hostingView
        self.preferredContentSize = NSSize(width: 420, height: 560)
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
                            if let d = data as? Data, let s = String(data: d, encoding: .utf8) {
                                vcfString = s
                            } else if let url = data as? URL, let s = try? String(contentsOf: url, encoding: .utf8) {
                                vcfString = s
                            } else if let s = data as? String {
                                vcfString = s
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

    private func share() {
        // Chat 5: rebuild filtered VCF and present NSSharingServicePicker
    }
}

// MARK: - ShareData

class ShareData: ObservableObject {
    @Published var vcfText: String?
    @Published var fields: [VCFField] = [] {
        didSet {
            // Auto-select every toggleable field when the contact loads
            selectedIDs = Set(toggleableFields.map { $0.id })
        }
    }
    @Published var selectedIDs: Set<UUID> = []
    @Published var errorMessage: String?

    /// Non-structural fields — the ones the user can toggle on/off
    var toggleableFields: [VCFField] {
        fields.filter { !$0.isStructural }
    }

    /// Best available display name for the contact header
    var contactName: String {
        if let fn = fields.first(where: { $0.property == "FN" }), !fn.displayValue.isEmpty {
            return fn.displayValue
        }
        if let n = fields.first(where: { $0.property == "N" }), !n.displayValue.isEmpty {
            return n.displayValue
        }
        return "Contact"
    }

    var allSelected: Bool {
        !toggleableFields.isEmpty && toggleableFields.allSatisfy { selectedIDs.contains($0.id) }
    }

    func selectAll()   { selectedIDs = Set(toggleableFields.map { $0.id }) }
    func deselectAll() { selectedIDs = [] }

    func toggle(_ field: VCFField) {
        if selectedIDs.contains(field.id) {
            selectedIDs.remove(field.id)
        } else {
            selectedIDs.insert(field.id)
        }
    }
}

// MARK: - Field Grouping

/// Categories shown in the picker, in display order.
private enum FieldGroup: String, CaseIterable {
    case name     = "Name"
    case phone    = "Phone"
    case email    = "Email"
    case address  = "Address"
    case work     = "Work"
    case web      = "Web & Social"
    case personal = "Personal"
    case note     = "Notes"
    case other    = "Other"

    static func group(for property: String) -> FieldGroup {
        switch property {
        case "FN", "N", "NICKNAME", "PHOTO", "LOGO":   return .name
        case "TEL":                                      return .phone
        case "EMAIL":                                    return .email
        case "ADR":                                      return .address
        case "ORG", "TITLE", "ROLE":                    return .work
        case "URL", "X-SOCIALPROFILE", "IMPP":          return .web
        case "BDAY", "ANNIVERSARY",
             "X-ABRELATEDNAMES", "X-ABSHOWAS":          return .personal
        case "NOTE":                                     return .note
        default:                                         return .other
        }
    }
}

// MARK: - Root View

struct ShareExtensionView: View {
    @ObservedObject var shareData: ShareData
    var onCancel: () -> Void
    var onShare:  () -> Void

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            contentArea
            Divider()
            footerBar
        }
        .frame(width: 420, height: 560)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: Header

    private var headerBar: some View {
        // ZStack lets the title stay centred while Cancel sits left-aligned
        ZStack {
            HStack {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                Spacer()
            }
            VStack(spacing: 2) {
                Text("VCFFlex")
                    .font(.headline)
                if !shareData.fields.isEmpty {
                    Text(shareData.contactName)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: Content area (switches on state)

    @ViewBuilder
    private var contentArea: some View {
        if let error = shareData.errorMessage, shareData.vcfText == nil {
            // Error
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundColor(.secondary)
                Text(error)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        } else if !shareData.fields.isEmpty {
            // Happy path — the picker
            pickerContent

        } else if shareData.vcfText != nil {
            // Parsed but empty
            Text("No fields found")
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        } else {
            // Still loading
            ProgressView("Loading contact…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Picker

    private var pickerContent: some View {
        VStack(spacing: 0) {
            selectAllBar
            Divider()
            List {
                ForEach(FieldGroup.allCases, id: \.self) { group in
                    let groupFields = shareData.toggleableFields.filter {
                        FieldGroup.group(for: $0.property) == group
                    }
                    if !groupFields.isEmpty {
                        Section(header:
                            Text(group.rawValue)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        ) {
                            ForEach(groupFields) { field in
                                FieldToggleRow(
                                    field: field,
                                    isSelected: shareData.selectedIDs.contains(field.id)
                                ) {
                                    shareData.toggle(field)
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    // MARK: Select All bar

    private var selectAllBar: some View {
        HStack {
            Button(shareData.allSelected ? "Deselect All" : "Select All") {
                shareData.allSelected ? shareData.deselectAll() : shareData.selectAll()
            }
            .buttonStyle(.plain)
            .foregroundColor(.accentColor)
            .font(.subheadline)

            Spacer()

            Text("\(shareData.selectedIDs.count) of \(shareData.toggleableFields.count) selected")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor))
    }

    // MARK: Footer / Share button

    private var footerBar: some View {
        HStack {
            Spacer()
            Button(action: onShare) {
                Label("Share", systemImage: "square.and.arrow.up")
                    .padding(.horizontal, 20)
                    .padding(.vertical, 7)
            }
            .buttonStyle(.borderedProminent)
            .disabled(shareData.selectedIDs.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - Field Toggle Row

struct FieldToggleRow: View {
    let field: VCFField
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        // Wrapping in a Button gives us keyboard/click handling for free
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 12) {

                // Checkbox icon
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? .accentColor : Color(NSColor.tertiaryLabelColor))
                    .font(.system(size: 18))
                    .frame(width: 22, height: 22)
                    .padding(.top, 1)

                // Label + value
                VStack(alignment: .leading, spacing: 2) {
                    Text(field.label)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(field.displayValue)
                        .font(.body)
                        .foregroundColor(.primary)
                        // PHOTO shows a long base64 blob — clamp it to one line
                        .lineLimit(field.property == "PHOTO" ? 1 : 5)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()
            }
            // Make the entire row (including empty space) tappable
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 3)
    }
}
