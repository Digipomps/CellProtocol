// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

// skeleton-check: sjekker CellConfiguration-filer før de lastes opp.
//
//   swift run skeleton-check minflate.json
//   swift run skeleton-check --require todo.toggleTodo minflate.json
//   swift run skeleton-check --json minflate.json
//
// Avslutter med 0 når alle filer består, 1 når en fil har funn, 2 ved feil bruk.

import Foundation
import CellBase

let usage = """
Bruk: skeleton-check [--require <keypath>]... [--json] <fil.json>...

Sjekker at hver fil er en CellConfiguration som kan vises: gyldig JSON, kjente
elementer, radmaler som er VStack, og at ingen del av flaten er skjult for godt.
--require <keypath>  En handling flaten må kunne nå (kan gjentas).
--json               Skriv rapporten som JSON.
"""

var files: [String] = []
var required: Set<String> = []
var asJSON = false
var arguments = CommandLine.arguments.dropFirst().makeIterator()
while let argument = arguments.next() {
    switch argument {
    case "--require":
        guard let keypath = arguments.next() else {
            FileHandle.standardError.write(Data("--require trenger en keypath.\n\(usage)\n".utf8)); exit(2)
        }
        required.insert(keypath)
    case "--json":
        asJSON = true
    case "-h", "--help":
        print(usage); exit(0)
    default:
        files.append(argument)
    }
}
guard !files.isEmpty else {
    FileHandle.standardError.write(Data("\(usage)\n".utf8)); exit(2)
}

var anyFindings = false
var reports: [String: SkeletonConfigurationCheckReport] = [:]
for file in files {
    let report: SkeletonConfigurationCheckReport
    if let data = FileManager.default.contents(atPath: file) {
        report = SkeletonConfigurationCheck.check(json: data, requiredActionKeypaths: required)
    } else {
        report = SkeletonConfigurationCheckReport(configurationName: nil, findings: [
            SkeletonConfigurationCheckFinding(kind: .undecodable, path: "", message: "Fant ikke filen.")
        ], reachableActionKeypaths: [])
    }
    anyFindings = anyFindings || !report.passed
    reports[file] = report
    guard !asJSON else { continue }
    print("\(file)\(report.configurationName.map { " («\($0)»)" } ?? "")")
    if report.passed {
        print("  OK: alt kan vises.")
    } else {
        print("  \(report.findings.count) funn:")
        for finding in report.findings {
            print("  - [\(finding.kind.rawValue)] \(finding.path.isEmpty ? "" : "\(finding.path): ")\(finding.message)")
            if !finding.lostActionKeypaths.isEmpty {
                print("    Tapte handlinger: \(finding.lostActionKeypaths.joined(separator: ", "))")
            }
        }
    }
    print("  Handlinger som kan nås: \(report.reachableActionKeypaths.isEmpty ? "ingen" : report.reachableActionKeypaths.joined(separator: ", "))")
}
if asJSON {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    if let data = try? encoder.encode(reports), let text = String(data: data, encoding: .utf8) { print(text) }
}
exit(anyFindings ? 1 : 0)
