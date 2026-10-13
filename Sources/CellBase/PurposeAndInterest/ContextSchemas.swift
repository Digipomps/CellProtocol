// SPDX-License-Identifier: Apache-2.0
import Foundation

public enum ContextSchemas {
    static let string = ExploreContract.schema(type: "string")
    static let integer = ExploreContract.schema(type: "integer")
    static let strings = ExploreContract.listSchema(item: string)
    static let numberMap = ExploreContract.schema(type: "object", description: "Map from purpose reference to finite nonnegative weight; zero deactivates.")
    public static func decision() -> ValueType {
        ExploreContract.objectSchema(properties: ["revision": integer, "validUntil": ExploreContract.oneOfSchema(options: [string, .null]), "labels": strings,
            "activeRules": strings, "purposeWeights": numberMap,
            "purposeRules": ExploreContract.schema(type: "object", description: "Map from purpose reference to winning rule ID."),
            "sourceRevisions": ExploreContract.schema(type: "object", description: "Map from source ID to last accepted revision."), "unknownSources": strings],
            requiredKeys: ["revision", "labels", "activeRules", "purposeWeights", "purposeRules", "sourceRevisions", "unknownSources"])
    }
    public static func configuration() -> ValueType {
        let source = ExploreContract.objectSchema(properties: ["sourceID": string, "endpoint": string, "snapshotKey": string, "enabled": ExploreContract.schema(type: "bool")], requiredKeys: ["sourceID", "endpoint", "snapshotKey", "enabled"])
        let predicateNode = ExploreContract.objectSchema(properties: [
            "kind": string, "sourceID": string, "keypath": string, "operation": string,
            "expected": string, "metric": string,
            "all": ExploreContract.listSchema(item: ExploreContract.schema(type: "object", description: "Recursive GoalPredicate; each child requires kind, all and any.")),
            "any": ExploreContract.listSchema(item: ExploreContract.schema(type: "object", description: "Recursive GoalPredicate; each child requires kind, all and any."))
        ], requiredKeys: ["kind", "all", "any"], description: "Recursive GoalPredicate; include empty all/any arrays on leaves. Runtime decodes each child with the same shape.")
        let privacy = ExploreContract.objectSchema(properties: [
            "rawEvidenceVisibility": string, "publishableStatuses": strings,
            "doNotExportRawLocation": ExploreContract.schema(type: "bool"), "retentionSeconds": integer
        ], requiredKeys: ["rawEvidenceVisibility", "publishableStatuses", "doNotExportRawLocation"])
        let evidence = ExploreContract.objectSchema(properties: [
            "sourceID": string, "visibility": string, "endpoint": string, "keypath": string,
            "topic": string, "eventType": string, "requiredGrant": string,
            "freshnessSeconds": integer, "summary": string
        ], requiredKeys: ["sourceID", "visibility"])
        let helper = ExploreContract.objectSchema(properties: ["endpoint": string, "purposeRef": string, "actionKeypath": string, "title": string], requiredKeys: ["endpoint"])
        let definition = ExploreContract.objectSchema(properties: [
            "schema": string, "goalID": string, "purposeRef": string, "title": string,
            "description": string, "lifecycle": string, "evaluatorKind": string,
            "metric": string, "baseline": string, "target": string, "timeframe": string,
            "evidenceSources": ExploreContract.listSchema(item: evidence),
            "predicate": ExploreContract.oneOfSchema(options: [predicateNode, .null]),
            "tolerance": ExploreContract.schema(type: "object", description: "Optional GoalTolerance; all fields optional."),
            "statusPolicy": ExploreContract.schema(type: "object", description: "Optional GoalStatusPolicy; all fields optional."),
            "helperCells": ExploreContract.listSchema(item: helper), "privacy": privacy, "tags": strings
        ], requiredKeys: ["schema", "goalID", "purposeRef", "title", "description", "lifecycle", "evaluatorKind", "evidenceSources", "helperCells", "privacy", "tags"])
        let rule = ExploreContract.objectSchema(properties: ["id": string, "priority": integer, "definition": definition, "label": string, "purposeWeights": numberMap], requiredKeys: ["id", "priority", "definition", "label", "purposeWeights"])
        return ExploreContract.objectSchema(properties: ["sources": ExploreContract.listSchema(item: source), "rules": ExploreContract.listSchema(item: rule)], requiredKeys: ["sources", "rules"])
    }
    public static func perspective() -> ValueType { ExploreContract.objectSchema(properties: ["state": decision(), "configuration": configuration()], requiredKeys: ["state", "configuration"]) }
    public static func acknowledgement() -> ValueType {
        ExploreContract.objectSchema(properties: ["status": string, "message": string], requiredKeys: ["status"], description: "ok after storage and connection succeed; error otherwise.")
    }
    public static func filterConfiguration() -> ValueType {
        ExploreContract.objectSchema(properties: ["perspectiveEndpoint": string, "contentEndpoints": strings, "baseTopics": strings,
            "topicsByLabel": ExploreContract.schema(type: "object", description: "Map from semantic label to array of allowed topics/patterns; active entries intersect.")], requiredKeys: ["perspectiveEndpoint", "contentEndpoints", "baseTopics", "topicsByLabel"])
    }
    public static func filterState() -> ValueType { ExploreContract.objectSchema(properties: ["configuration": ExploreContract.oneOfSchema(options: [filterConfiguration(), .null]), "state": ExploreContract.oneOfSchema(options: [decision(), .null])], requiredKeys: ["configuration", "state"]) }
}
