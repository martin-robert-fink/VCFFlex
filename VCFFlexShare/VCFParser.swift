//
//  VCFParser.swift
//  VCFFlexShare
//
//  Chat 3: Parses raw VCF text into structured fields for the picker UI.
//  Handles Apple Contacts' grouped properties (item1.EMAIL + item1.X-ABLabel).
//

import Foundation

/// A single parsed field from a vCard.
struct VCFField: Identifiable {
    let id = UUID()
    let label: String         // Human-readable, e.g. "Email — Other"
    let displayValue: String  // What to show the user, e.g. "mfink@yahoo.com"
    let rawLines: String      // Original VCF line(s) — preserved exactly for rebuilding
    let property: String      // VCF property name, e.g. "EMAIL", "TEL", "PHOTO"
    let isStructural: Bool    // true for BEGIN, END, VERSION — always included, never toggled
}

enum VCFParser {

    // MARK: - Public API

    /// Parse a raw VCF string into an array of VCFField.
    /// Groups Apple's itemN.PROPERTY + itemN.X-ABLabel pairs into single fields.
    /// Structural fields (BEGIN, END, VERSION) are included but marked as non-toggleable.
    static func parse(_ rawVCF: String) -> [VCFField] {
        let unfoldedLines = unfold(rawVCF)
        let parsed = unfoldedLines.compactMap { parseLine($0) }
        return resolveGroups(parsed)
    }

    // MARK: - Internal types

    /// Intermediate representation before group resolution
    private struct ParsedLine {
        let group: String?       // e.g. "item1", "item2" — nil if ungrouped
        let property: String     // e.g. "EMAIL", "X-ABLABEL", "TEL"
        let params: [String]     // e.g. ["type=CELL", "type=VOICE"]
        let value: String        // Raw value after the colon
        let rawBlock: String     // Original text for VCF reconstruction
    }

    // MARK: - Step 1: Unfold continuation lines

    /// vCard 3.0 "folds" long lines by inserting a CRLF followed by a space or tab.
    /// This joins those continuation lines back into single logical lines,
    /// while preserving the *original* raw text (with folds) for each logical line.
    private static func unfold(_ raw: String) -> [(unfolded: String, rawBlock: String)] {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
                            .replacingOccurrences(of: "\r", with: "\n")

        let physicalLines = normalized.components(separatedBy: "\n")
        var results: [(unfolded: String, rawBlock: String)] = []

        var currentUnfolded = ""
        var currentRawLines: [String] = []

        for line in physicalLines {
            if line.isEmpty { continue }

            let isContinuation = line.hasPrefix(" ") || line.hasPrefix("\t")

            if isContinuation && !currentUnfolded.isEmpty {
                let continuation = String(line.dropFirst())
                currentUnfolded += continuation
                currentRawLines.append(line)
            } else {
                if !currentUnfolded.isEmpty {
                    results.append((
                        unfolded: currentUnfolded,
                        rawBlock: currentRawLines.joined(separator: "\r\n")
                    ))
                }
                currentUnfolded = line
                currentRawLines = [line]
            }
        }

        if !currentUnfolded.isEmpty {
            results.append((
                unfolded: currentUnfolded,
                rawBlock: currentRawLines.joined(separator: "\r\n")
            ))
        }

        return results
    }

    // MARK: - Step 2: Parse each unfolded line

    private static func parseLine(_ entry: (unfolded: String, rawBlock: String)) -> ParsedLine? {
        let line = entry.unfolded

        guard let colonIndex = findPropertyDelimiter(in: line) else { return nil }

        let nameAndParams = String(line[line.startIndex..<colonIndex])
        let value = String(line[line.index(after: colonIndex)...])

        let parts = nameAndParams.components(separatedBy: ";")
        var propertyWithGroup = parts[0]
        let params = Array(parts.dropFirst())

        // Extract group prefix: "item1.EMAIL" → group="item1", property="EMAIL"
        var group: String? = nil
        if let dotIndex = propertyWithGroup.firstIndex(of: ".") {
            group = String(propertyWithGroup[propertyWithGroup.startIndex..<dotIndex]).lowercased()
            propertyWithGroup = String(propertyWithGroup[propertyWithGroup.index(after: dotIndex)...])
        }

        let property = propertyWithGroup.uppercased()

        return ParsedLine(
            group: group,
            property: property,
            params: params,
            value: value,
            rawBlock: entry.rawBlock
        )
    }

    /// Find the colon that separates property name+params from the value.
    /// Skips colons inside double quotes.
    private static func findPropertyDelimiter(in line: String) -> String.Index? {
        var inQuotes = false
        for i in line.indices {
            let ch = line[i]
            if ch == "\"" {
                inQuotes.toggle()
            } else if ch == ":" && !inQuotes {
                return i
            }
        }
        return nil
    }

    // MARK: - Step 3: Resolve grouped properties

    /// Apple Contacts uses groups like:
    ///   item1.EMAIL;type=INTERNET:mfink@yahoo.com
    ///   item1.X-ABLabel:_$!<Other>!$_
    ///
    /// The X-ABLabel provides the custom label for the property in the same group.
    /// We merge them: the main property gets the label, X-ABLabel is consumed/hidden,
    /// and the raw lines of both are combined so we can reconstruct them in Chat 5.
    private static func resolveGroups(_ lines: [ParsedLine]) -> [VCFField] {

        // Index X-ABLabel and other group-metadata lines by their group
        var labelsByGroup: [String: ParsedLine] = [:]
        var metadataByGroup: [String: [ParsedLine]] = [:]

        for line in lines {
            guard let group = line.group else { continue }
            if line.property == "X-ABLABEL" {
                labelsByGroup[group] = line
            } else if hiddenGroupedProperties.contains(line.property) {
                metadataByGroup[group, default: []].append(line)
            }
        }

        var results: [VCFField] = []

        for line in lines {
            // Skip lines that were consumed as group metadata
            if line.property == "X-ABLABEL" { continue }
            if hiddenGroupedProperties.contains(line.property) && line.group != nil { continue }

            // Structural lines — always included, never shown in picker
            if structuralProperties.contains(line.property) {
                results.append(VCFField(
                    label: line.property,
                    displayValue: line.value,
                    rawLines: line.rawBlock,
                    property: line.property,
                    isStructural: true
                ))
                continue
            }

            // Hidden metadata — preserved in VCF but not shown to user
            if hiddenProperties.contains(line.property) {
                results.append(VCFField(
                    label: line.property,
                    displayValue: line.value,
                    rawLines: line.rawBlock,
                    property: line.property,
                    isStructural: true
                ))
                continue
            }

            // Resolve the label from the group's X-ABLabel if present
            let groupLabel: String? = {
                guard let group = line.group, let labelLine = labelsByGroup[group] else { return nil }
                return decodeABLabel(labelLine.value)
            }()

            // Combine raw lines: main property + its X-ABLabel + any X-ABADR etc.
            var combinedRaw = line.rawBlock
            if let group = line.group {
                if let labelLine = labelsByGroup[group] {
                    combinedRaw += "\r\n" + labelLine.rawBlock
                }
                for metaLine in metadataByGroup[group] ?? [] {
                    combinedRaw += "\r\n" + metaLine.rawBlock
                }
            }

            let label = buildLabel(property: line.property, params: line.params, groupLabel: groupLabel)
            let displayValue = buildDisplayValue(property: line.property, value: line.value, params: line.params)

            results.append(VCFField(
                label: label,
                displayValue: displayValue,
                rawLines: combinedRaw,
                property: line.property,
                isStructural: false
            ))
        }

        return results
    }

    /// Decode Apple's X-ABLabel format: "_$!<Other>!$_" → "Other", or plain text → as-is
    private static func decodeABLabel(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("_$!<") && trimmed.hasSuffix(">!$_") {
            let start = trimmed.index(trimmed.startIndex, offsetBy: 4)
            let end = trimmed.index(trimmed.endIndex, offsetBy: -4)
            if start < end {
                let label = String(trimmed[start..<end])
                return expandCamelCase(label)
            }
        }
        // Plain text custom label (e.g. "Daughter-in-law")
        return trimmed
    }

    /// "SonInLaw" → "Son In Law"
    private static func expandCamelCase(_ input: String) -> String {
        var result = ""
        for (i, char) in input.enumerated() {
            if char.isUppercase && i > 0 {
                result.append(" ")
            }
            result.append(char)
        }
        return result
    }

    // MARK: - Property classifications

    private static let structuralProperties: Set<String> = ["BEGIN", "END", "VERSION"]

    /// Properties preserved in VCF but hidden from the picker
    private static let hiddenProperties: Set<String> = ["PRODID", "X-ABUID", "REV", "UID"]

    /// Grouped properties consumed into their parent and hidden
    private static let hiddenGroupedProperties: Set<String> = ["X-ABADR"]

    // MARK: - Label building

    private static func buildLabel(property: String, params: [String], groupLabel: String?) -> String {
        let friendlyName = friendlyPropertyName(property)

        // Group label takes precedence (it's the user-visible label from Apple Contacts)
        if let groupLabel = groupLabel {
            return "\(friendlyName) — \(groupLabel)"
        }

        let typeLabels = extractTypes(from: params)
        if typeLabels.isEmpty {
            return friendlyName
        } else {
            let typeSuffix = typeLabels.map { capitalizeFirst($0) }.joined(separator: ", ")
            return "\(friendlyName) — \(typeSuffix)"
        }
    }

    private static func friendlyPropertyName(_ property: String) -> String {
        switch property {
        case "FN":              return "Full Name"
        case "N":               return "Name"
        case "NICKNAME":        return "Nickname"
        case "TEL":             return "Phone"
        case "EMAIL":           return "Email"
        case "ADR":             return "Address"
        case "ORG":             return "Organization"
        case "TITLE":           return "Job Title"
        case "ROLE":            return "Role"
        case "URL":             return "URL"
        case "NOTE":            return "Note"
        case "BDAY":            return "Birthday"
        case "ANNIVERSARY":     return "Anniversary"
        case "PHOTO":           return "Photo"
        case "LOGO":            return "Logo"
        case "IMPP":            return "Instant Message"
        case "X-SOCIALPROFILE": return "Social Profile"
        case "X-ABSHOWAS":     return "Show As"
        case "X-ABRELATEDNAMES": return "Related Name"
        default:
            if property.hasPrefix("X-") {
                let stripped = String(property.dropFirst(2))
                return stripped.replacingOccurrences(of: "-", with: " ")
                              .split(separator: " ")
                              .map { capitalizeFirst(String($0)) }
                              .joined(separator: " ")
            }
            return property
        }
    }

    /// Extract TYPE values from parameters like "type=HOME" or "TYPE=CELL"
    private static func extractTypes(from params: [String]) -> [String] {
        var types: [String] = []
        for param in params {
            let lower = param.lowercased()

            if lower.hasPrefix("type=") {
                let raw = String(param.dropFirst(5))
                let values = raw.components(separatedBy: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !isNoiseType($0) }
                types.append(contentsOf: values)
            } else if isBareType(param) {
                types.append(param)
            }
        }
        return types
    }

    private static func isNoiseType(_ type: String) -> Bool {
        let noise: Set<String> = ["voice", "internet", "pref"]
        return noise.contains(type.lowercased())
    }

    private static func isBareType(_ param: String) -> Bool {
        let known: Set<String> = [
            "home", "work", "cell", "fax", "pager", "main",
            "iphone", "other", "mobile"
        ]
        return known.contains(param.lowercased())
    }

    // MARK: - Display value formatting

    private static func buildDisplayValue(property: String, value: String, params: [String]) -> String {
        switch property {
        case "N":
            return formatStructuredName(value)
        case "ADR":
            return formatAddress(value)
        case "ORG":
            return value.components(separatedBy: ";")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                        .joined(separator: ", ")
        case "PHOTO", "LOGO":
            return "(embedded image)"
        case "BDAY", "ANNIVERSARY":
            return formatDate(value)
        case "X-SOCIALPROFILE":
            return formatSocialProfile(value, params: params)
        case "IMPP":
            if let colonIdx = value.firstIndex(of: ":") {
                return String(value[value.index(after: colonIdx)...])
            }
            return value
        default:
            return unescapeVCF(value)
        }
    }

    /// N field: "Last;First;Middle;Prefix;Suffix"
    private static func formatStructuredName(_ value: String) -> String {
        let components = value.components(separatedBy: ";")
        let prefix = components.count > 3 ? components[3] : ""
        let first  = components.count > 1 ? components[1] : ""
        let middle = components.count > 2 ? components[2] : ""
        let last   = components.count > 0 ? components[0] : ""
        let suffix = components.count > 4 ? components[4] : ""

        return [prefix, first, middle, last, suffix]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// ADR field: "PO Box;Extended;Street;City;State;ZIP;Country"
    private static func formatAddress(_ value: String) -> String {
        let components = value.components(separatedBy: ";")

        let po      = components.count > 0 ? components[0].trimmed : ""
        let ext     = components.count > 1 ? components[1].trimmed : ""
        let street  = components.count > 2 ? components[2].trimmed : ""
        let city    = components.count > 3 ? components[3].trimmed : ""
        let state   = components.count > 4 ? components[4].trimmed : ""
        let zip     = components.count > 5 ? components[5].trimmed : ""
        let country = components.count > 6 ? components[6].trimmed : ""

        var lines: [String] = []
        if !po.isEmpty { lines.append(po) }
        if !ext.isEmpty { lines.append(ext) }
        if !street.isEmpty { lines.append(street) }

        var cityLine = ""
        if !city.isEmpty { cityLine += city }
        if !state.isEmpty { cityLine += cityLine.isEmpty ? state : ", \(state)" }
        if !zip.isEmpty { cityLine += cityLine.isEmpty ? zip : " \(zip)" }
        if !cityLine.isEmpty { lines.append(cityLine) }

        if !country.isEmpty { lines.append(country) }

        return lines.isEmpty ? "(empty address)" : lines.joined(separator: "\n")
    }

    private static func formatDate(_ value: String) -> String {
        let isoFormatter = DateFormatter()
        isoFormatter.dateFormat = "yyyy-MM-dd"
        if let date = isoFormatter.date(from: value) {
            let display = DateFormatter()
            display.dateStyle = .long
            return display.string(from: date)
        }

        let compactFormatter = DateFormatter()
        compactFormatter.dateFormat = "yyyyMMdd"
        if let date = compactFormatter.date(from: value) {
            let display = DateFormatter()
            display.dateStyle = .long
            return display.string(from: date)
        }

        if value.hasPrefix("--") {
            let stripped = String(value.dropFirst(2))
            let noYearFormatter = DateFormatter()
            noYearFormatter.dateFormat = "MM-dd"
            if let date = noYearFormatter.date(from: stripped) {
                let display = DateFormatter()
                display.dateFormat = "MMMM d"
                return display.string(from: date)
            }
        }

        return value
    }

    private static func formatSocialProfile(_ value: String, params: [String]) -> String {
        for param in params {
            if param.lowercased().hasPrefix("x-user=") {
                return String(param.dropFirst(7))
            }
        }
        var display = value
        for prefix in ["https://", "http://", "x-apple:"] {
            if display.lowercased().hasPrefix(prefix) {
                display = String(display.dropFirst(prefix.count))
            }
        }
        return display
    }

    // MARK: - Helpers

    private static func unescapeVCF(_ value: String) -> String {
        value.replacingOccurrences(of: "\\n", with: "\n")
             .replacingOccurrences(of: "\\N", with: "\n")
             .replacingOccurrences(of: "\\,", with: ",")
             .replacingOccurrences(of: "\\;", with: ";")
             .replacingOccurrences(of: "\\\\", with: "\\")
    }

    private static func capitalizeFirst(_ string: String) -> String {
        guard let first = string.first else { return string }
        return first.uppercased() + string.dropFirst().lowercased()
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespaces)
    }
}
