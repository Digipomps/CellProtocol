// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import HavenCoreSchemas
import KeyPathResolver
import PurposeInterestBenchmarkSupport
import TaxonomyResolver

enum CLIError: Error, CustomStringConvertible {
    case usage(String)
    case missingArgument(String)
    case invalidArgument(String)
    case notFound(String)
    case lintFailed([String])
    case validationFailed(String)

    var description: String {
        switch self {
        case .usage(let message):
            return message
        case .missingArgument(let argument):
            return "Missing required argument: \(argument)"
        case .invalidArgument(let argument):
            return "Invalid argument: \(argument)"
        case .notFound(let message):
            return message
        case .lintFailed(let issues):
            return issues.joined(separator: "\n")
        case .validationFailed(let message):
            return message
        }
    }
}

struct HavenCommonsCLI {
    let arguments: [String]
    let service: CommonsLocalService
    let commonsRoot: URL

    init(arguments: [String]) throws {
        self.arguments = arguments
        self.commonsRoot = Self.resolveCommonsRoot()
        self.service = try CommonsLocalService(commonsRoot: commonsRoot)
    }

    func run() async throws {
        guard let command = arguments.first else {
            throw CLIError.usage(Self.usage)
        }

        switch command {
        case "lint":
            try runLint(Array(arguments.dropFirst()))
        case "validate":
            try runValidate(Array(arguments.dropFirst()))
        case "resolve":
            try runResolve(Array(arguments.dropFirst()))
        case "benchmark":
            try await runBenchmark(Array(arguments.dropFirst()))
        case "help", "--help", "-h":
            print(Self.usage)
        default:
            throw CLIError.usage(Self.usage)
        }
    }

    private func runLint(_ args: [String]) throws {
        guard args.first == "keypaths" else {
            throw CLIError.usage("Usage: haven-commons lint keypaths")
        }

        let issues = service.keyPathResolver.registry.lintIssues()
        if issues.isEmpty {
            print("keypaths lint: ok")
            return
        }

        throw CLIError.lintFailed(issues)
    }

    private func runValidate(_ args: [String]) throws {
        guard let domain = args.first else {
            throw CLIError.usage("Usage: haven-commons validate <schema|purposes> ...")
        }

        switch domain {
        case "schema":
            try runValidateSchema()
        case "purposes":
            try runValidatePurposes(Array(args.dropFirst()))
        default:
            throw CLIError.usage("Usage: haven-commons validate <schema|purposes> ...")
        }
    }

    private func runValidateSchema() throws {
        let fileManager = FileManager.default
        let schemaRoot = CommonsPaths.schemasURL(root: commonsRoot)
        guard let enumerator = fileManager.enumerator(at: schemaRoot, includingPropertiesForKeys: nil) else {
            throw CLIError.invalidArgument("Could not enumerate schema directory at \(schemaRoot.path)")
        }

        var validatedFiles: [String] = []

        for case let fileURL as URL in enumerator where fileURL.pathExtension == "json" {
            let data = try Data(contentsOf: fileURL)
            _ = try JSONSerialization.jsonObject(with: data)
            validatedFiles.append(fileURL.path)
        }

        _ = try TaxonomyRegistry.load(from: CommonsPaths.taxonomiesURL(root: commonsRoot))
        _ = try KeyPathRegistry.load(from: CommonsPaths.keypathsURL(root: commonsRoot))

        print("schema validation: ok (\(validatedFiles.count) schema files)")
    }

    private func runValidatePurposes(_ args: [String]) throws {
        let namespace = try requiredOptionValue("--namespace", in: args)
        let result = try service.getTaxonomyPurposeTreeValidation(namespace: namespace)
        print(try encodeJSON(result))

        if !result.isValid {
            throw CLIError.validationFailed(
                "purpose tree validation failed for '\(namespace)' with \(result.errorCount) errors"
            )
        }
    }

    private func runResolve(_ args: [String]) throws {
        guard let domain = args.first else {
            throw CLIError.usage("Usage: haven-commons resolve <keypath|term|guidance> ...")
        }

        switch domain {
        case "keypath":
            try runResolveKeypath(Array(args.dropFirst()))
        case "term":
            try runResolveTerm(Array(args.dropFirst()))
        case "guidance":
            try runResolveGuidance(Array(args.dropFirst()))
        default:
            throw CLIError.usage("Usage: haven-commons resolve <keypath|term|guidance> ...")
        }
    }

    private func runBenchmark(_ args: [String]) async throws {
        guard let domain = args.first else {
            throw CLIError.usage("Usage: haven-commons benchmark purpose-interest [--format <markdown|json>] [--tuning <path>] [--output <path>]")
        }

        switch domain {
        case "purpose-interest":
            try await runPurposeInterestBenchmark(Array(args.dropFirst()))
        default:
            throw CLIError.usage("Usage: haven-commons benchmark purpose-interest [--format <markdown|json>] [--tuning <path>] [--output <path>]")
        }
    }

    private func runPurposeInterestBenchmark(_ args: [String]) async throws {
        let rawFormat = (try optionalOptionValue("--format", in: args) ?? ScenarioBenchmarkReportFormat.markdown.rawValue)
            .lowercased()
        guard let format = ScenarioBenchmarkReportFormat(rawValue: rawFormat) else {
            throw CLIError.invalidArgument("--format \(rawFormat)")
        }

        let tuning = try optionalOptionValue("--tuning", in: args).map(loadTuningConfig(from:))
        let repositoryRoot = commonsRoot.deletingLastPathComponent()
        let report = try await PerspectiveMatchingScenarioSupport.buildBenchmarkReport(
            format: format,
            repositoryRoot: repositoryRoot,
            tuning: tuning
        )

        if let outputPath = try optionalOptionValue("--output", in: args) {
            try write(report: report, to: outputPath)
            print("benchmark report written to \(resolvedOutputURL(for: outputPath).path)")
        } else {
            print(report)
        }
    }

    private func runResolveKeypath(_ args: [String]) throws {
        let entityID = try requiredOptionValue("--entity", in: args)
        let inputPath = try requiredOptionValue("--path", in: args)
        let role = try parseRole(try optionalOptionValue("--role", in: args) ?? "member")
        let consent = try optionalOptionValue("--consent", in: args)
            .map { $0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) } }
            ?? []

        let resolvedPath: String
        let resolvedEntityID: String
        if let parsedURI = PathURI.parse(inputPath) {
            resolvedPath = parsedURI.path
            resolvedEntityID = parsedURI.entityId == "self" ? entityID : parsedURI.entityId
        } else {
            resolvedPath = inputPath
            resolvedEntityID = entityID
        }

        let request = ResolveKeyPathRequest(
            entityId: resolvedEntityID,
            path: resolvedPath,
            context: RequesterContext(role: role, consentTokens: consent)
        )

        let result = try service.postResolveKeyPath(request)
        print(try encodeJSON(result))
    }

    private func runResolveTerm(_ args: [String]) throws {
        let termID = try requiredOptionValue("--id", in: args)
        let lang = try optionalOptionValue("--lang", in: args) ?? "nb-NO"
        let namespace = try optionalOptionValue("--namespace", in: args)

        guard let resolved = try service.getTaxonomyResolve(termId: termID, lang: lang, namespace: namespace) else {
            throw CLIError.notFound("Term not found: \(termID)")
        }

        print(try encodeJSON(resolved))
    }

    private func runResolveGuidance(_ args: [String]) throws {
        let namespace = try requiredOptionValue("--namespace", in: args)

        guard let guidance = try service.getTaxonomyGuidance(namespace: namespace) else {
            throw CLIError.notFound("Guidance not found for namespace: \(namespace)")
        }

        print(try encodeJSON(guidance))
    }

    private func parseRole(_ rawValue: String) throws -> RequesterRole {
        guard let role = RequesterRole(rawValue: rawValue.lowercased()) else {
            throw CLIError.invalidArgument("--role \(rawValue)")
        }
        return role
    }

    private func requiredOptionValue(_ key: String, in args: [String]) throws -> String {
        guard let value = try optionalOptionValue(key, in: args) else {
            throw CLIError.missingArgument(key)
        }
        return value
    }

    private func optionalOptionValue(_ key: String, in args: [String]) throws -> String? {
        guard let index = args.firstIndex(of: key) else {
            return nil
        }

        let valueIndex = args.index(after: index)
        guard valueIndex < args.endIndex else {
            throw CLIError.missingArgument("value for \(key)")
        }

        return args[valueIndex]
    }

    private func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    private func write(report: String, to outputPath: String) throws {
        let outputURL = resolvedOutputURL(for: outputPath)
        let directoryURL = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try Data(report.utf8).write(to: outputURL)
    }

    private func loadTuningConfig(from path: String) throws -> ScenarioWeightTuningConfig {
        let url = resolvedOutputURL(for: path)
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(ScenarioWeightTuningConfig.self, from: data)
    }

    private func resolvedOutputURL(for outputPath: String) -> URL {
        let expandedPath = (outputPath as NSString).expandingTildeInPath
        if expandedPath.hasPrefix("/") {
            return URL(fileURLWithPath: expandedPath)
        }

        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(expandedPath)
    }

    static var usage: String {
        """
        haven-commons commands:
          haven-commons lint keypaths
          haven-commons validate schema
          haven-commons validate purposes --namespace <namespace>
          haven-commons resolve keypath --entity <id> --path <path> [--role <owner|member|sponsor|service|unknown>] [--consent <token1,token2>]
          haven-commons resolve term --id <term_id> --lang <locale> [--namespace <namespace>]
          haven-commons resolve guidance --namespace <namespace>
          haven-commons benchmark purpose-interest [--format <markdown|json>] [--tuning <path>] [--output <path>]
        """
    }

    static func resolveCommonsRoot() -> URL {
        if let override = ProcessInfo.processInfo.environment["HAVEN_COMMONS_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }

        return CommonsPaths.defaultRootURL()
    }
}

@main
enum HavenCommonsMain {
    static func main() async {
        do {
            let cli = try HavenCommonsCLI(arguments: Array(CommandLine.arguments.dropFirst()))
            try await cli.run()
        } catch {
            let message: String
            if let error = error as? CLIError {
                message = error.description
            } else {
                message = error.localizedDescription
            }

            fputs("\(message)\n", stderr)
            exit(1)
        }
    }
}
