// SPDX-License-Identifier: Apache-2.0
// swift probe-icu.swift <compiled-probe-icu> <messages.json>
import Foundation

let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))) as! [String: Any]
let configuration = fixture["configuration"] as! [String: Any]
let catalog = (configuration["resources"] as! [[String: Any]])[0]
let messages = catalog["messages"] as! [String: [String: Any]]
let cases = fixture["cases"] as! [[String: Any]]
var results: [[String: Any]] = []
for sample in cases where sample["fallbackReason"] is NSNull {
    let message = messages[sample["key"] as! String]!
    let locale = sample["locale"] as! String
    let translations = message["translations"] as! [String: [String: Any]]
    let pattern = translations[locale]!["value"] as! String
    var actual = pattern
    if message["format"] as! String != "literal" {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[1])
        var arguments = [pattern, locale, "UTC"]
        let types = message["arguments"] as! [String: String]
        for (key, value) in (sample["arguments"] as! [String: Any]).sorted(by: { $0.key < $1.key }) {
            arguments += [key, types[key]!, String(describing: value)]
        }
        process.arguments = arguments
        let output = Pipe(); process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { fatalError("ICU probe failed: \(sample["id"]!)") }
        actual = String(data: data, encoding: .utf8)!
    }
    results.append(["id": sample["id"]!, "expected": sample["expected"]!, "actual": actual,
                    "exact": actual == sample["expected"] as! String])
}
let output = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
print(String(data: output, encoding: .utf8)!)
// Any difference is deliberately reported. ICU/CLDR differences are evaluated
// explicitly instead of normalized away to manufacture a parity pass.
exit(results.allSatisfy { $0["exact"] as? Bool == true } ? 0 : 1)
