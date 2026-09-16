// SPDX-License-Identifier: Apache-2.0
// Run: swift -module-cache-path /tmp/haven-localization-cache probe-apple.swift <bundle> <fixture>
import Foundation
import JavaScriptCore

let context = JSContext()!
let source = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))) as! [String: Any]
context.evaluateScript(source)
if let error = context.exception { fatalError(error.toString()) }
context.setObject(fixture, forKeyedSubscript: "fixture" as NSString)
let report = context.evaluateScript("""
JSON.stringify(fixture.cases.map(sample => {
  const runtime = HavenLocalization.createRuntime({ configuration: fixture.configuration, context: {ui_locale: sample.locale} });
  const result = runtime.resolve({namespace:'demo', key:sample.key,
    arguments:Object.fromEntries(Object.entries(sample.arguments).map(([k,v]) => [k,{value:v}]))}, 'Legacy');
  return {id:sample.id, passed:result.text === sample.expected && result.fallback_reason === sample.fallbackReason,
    expected:sample.expected, actual:result.text, reason:result.fallback_reason};
}))
""")!.toString()!
if let error = context.exception { fatalError(error.toString()) }
let results = try JSONSerialization.jsonObject(with: Data(report.utf8)) as! [[String: Any]]
let failures = results.filter { $0["passed"] as? Bool != true }
print("JavaScriptCore: \(results.count - failures.count)/\(results.count) shared cases passed")
for failure in failures { print(failure) }
exit(failures.isEmpty ? 0 : 1)
