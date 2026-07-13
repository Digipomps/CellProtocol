// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

/// Runtime adapter for evaluating explicit GoalDefinitions against supplied observations.
public final class GoalEvaluationCell: GeneralCell {
    private var definition: GoalDefinition?
    private var observations: [GoalObservation]
    private var lastEvaluation: GoalEvaluation?

    private enum CodingKeys: String, CodingKey {
        case definition
        case observations
        case lastEvaluation
        case generalCell
    }

    public required init(owner: Identity) async {
        self.definition = nil
        self.observations = []
        self.lastEvaluation = nil
        await super.init(owner: owner)
        try? await ensureRuntimeReady()
    }

    public required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.definition = try container.decodeIfPresent(GoalDefinition.self, forKey: .definition)
        self.observations = try container.decodeIfPresent([GoalObservation].self, forKey: .observations) ?? []
        self.lastEvaluation = try container.decodeIfPresent(GoalEvaluation.self, forKey: .lastEvaluation)
        try super.init(from: decoder)

    }

    public override func installCellRuntimeBindingsForAccess() async throws {
        await setupPermissions(owner: owner)
        await setupKeys(owner: owner)
    }

    public override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(definition, forKey: .definition)
        try container.encode(observations, forKey: .observations)
        try container.encodeIfPresent(lastEvaluation, forKey: .lastEvaluation)
    }

    private func setupPermissions(owner: Identity) async {
        agreementTemplate.ensureGrant("rw--", for: "goal")
    }

    private func setupKeys(owner: Identity) async {
        await registerGet(
            key: "goal.state",
            owner: owner,
            returns: Self.stateSchema(),
            permissions: ["r---"],
            description: .string("Returns configured definition state, observation count, and latest evaluation status.")
        ) { [weak self] requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("r---", at: "goal", for: requester) else { return .string("denied") }
            return self.statePayload()
        }

        await registerGet(
            key: "goal.definition.current",
            owner: owner,
            returns: ExploreContract.oneOfSchema(
                options: [.null, Self.goalDefinitionSchema()],
                description: "Returns null until a GoalDefinition is configured."
            ),
            permissions: ["r---"],
            description: .string("Returns the currently configured GoalDefinition.")
        ) { [weak self] requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("r---", at: "goal", for: requester) else { return .string("denied") }
            return self.definitionPayload()
        }

        await registerGet(
            key: "goal.observations.current",
            owner: owner,
            returns: Self.observationListSchema(),
            permissions: ["r---"],
            description: .string("Returns the observations currently staged for evaluation.")
        ) { [weak self] requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("r---", at: "goal", for: requester) else { return .string("denied") }
            return self.observationsPayload()
        }

        await registerGet(
            key: "goal.lastEvaluation",
            owner: owner,
            returns: ExploreContract.oneOfSchema(
                options: [.null, Self.goalEvaluationSchema()],
                description: "Returns null until the first evaluation."
            ),
            permissions: ["r---"],
            description: .string("Returns the latest GoalEvaluation produced by this cell.")
        ) { [weak self] requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("r---", at: "goal", for: requester) else { return .string("denied") }
            return self.lastEvaluationPayload()
        }

        await registerSet(
            key: "goal.definition",
            owner: owner,
            input: Self.goalDefinitionSchema(),
            returns: ExploreContract.oneOfSchema(
                options: [Self.goalDefinitionSchema(), Self.errorSchema(operation: "goal.definition")],
                description: "Returns the accepted GoalDefinition or a structured error."
            ),
            permissions: ["-w--"],
            required: true,
            description: .string("Configures the GoalDefinition used for subsequent evaluations.")
        ) { [weak self] requester, payload in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "goal", for: requester) else { return .string("denied") }
            return self.configureDefinition(payload)
        }

        await registerSet(
            key: "goal.observations",
            owner: owner,
            input: ExploreContract.oneOfSchema(
                options: [
                    Self.observationListSchema(),
                    ExploreContract.objectSchema(
                        properties: ["observations": Self.observationListSchema()],
                        requiredKeys: ["observations"]
                    )
                ],
                description: "Accepts an observation list or an object containing observations."
            ),
            returns: Self.observationListSchema(),
            permissions: ["-w--"],
            description: .string("Replaces the current observations staged for evaluation.")
        ) { [weak self] requester, payload in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "goal", for: requester) else { return .string("denied") }
            return self.replaceObservations(payload)
        }

        await registerSet(
            key: "goal.evaluate",
            owner: owner,
            input: Self.evaluateInputSchema(),
            returns: ExploreContract.oneOfSchema(
                options: [Self.goalEvaluationSchema(), Self.errorSchema(operation: "goal.evaluate")],
                description: "Returns a GoalEvaluation or a structured error."
            ),
            permissions: ["-w--"],
            flowEffects: [
                ExploreContract.flowEffect(trigger: .set, topic: "goal.evaluation.updated", contentType: "object", minimumCount: 1)
            ],
            description: .string("Evaluates the configured goal against explicit observations and stores the latest result.")
        ) { [weak self] requester, payload in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "goal", for: requester) else { return .string("denied") }
            return self.evaluate(payload, requester: requester)
        }

        await registerSet(
            key: "goal.reset",
            owner: owner,
            input: .null,
            returns: Self.stateSchema(),
            permissions: ["-w--"],
            description: .string("Clears the configured definition, staged observations, and latest evaluation.")
        ) { [weak self] requester, _ in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "goal", for: requester) else { return .string("denied") }
            self.definition = nil
            self.observations = []
            self.lastEvaluation = nil
            return self.statePayload()
        }
    }

    private func configureDefinition(_ payload: ValueType) -> ValueType {
        do {
            let definition = try GoalEvaluationCellCodec.decode(payload, as: GoalDefinition.self)
            self.definition = definition
            self.lastEvaluation = nil
            return (try? GoalEvaluationCellCodec.encode(definition)) ?? Self.errorValue(
                operation: "goal.definition",
                code: "encoding_failed",
                message: "Configured GoalDefinition could not be encoded."
            )
        } catch {
            return Self.errorValue(
                operation: "goal.definition",
                code: "invalid_goal_definition",
                message: "\(error)"
            )
        }
    }

    private func replaceObservations(_ payload: ValueType) -> ValueType {
        do {
            let observations = try decodeObservations(payload)
            self.observations = observations
            return observationsPayload()
        } catch {
            return Self.errorValue(
                operation: "goal.observations",
                code: "invalid_observations",
                message: "\(error)"
            )
        }
    }

    private func evaluate(_ payload: ValueType, requester: Identity) -> ValueType {
        guard let definition else {
            return Self.errorValue(
                operation: "goal.evaluate",
                code: "missing_goal_definition",
                message: "Configure goal.definition before evaluating."
            )
        }

        let input = ExploreContract.object(from: payload) ?? [:]
        let evaluatedAt = Self.stringValue(input["evaluatedAt"]) ?? Self.iso8601(Date())
        let nextCheckAt = Self.stringValue(input["nextCheckAt"])

        if let observationValue = input["observations"] {
            do {
                observations = try decodeObservations(observationValue)
            } catch {
                return Self.errorValue(
                    operation: "goal.evaluate",
                    code: "invalid_observations",
                    message: "\(error)"
                )
            }
        }

        let evaluation = GoalEvaluationEngine.evaluate(
            definition: definition,
            observations: observations,
            evaluatedAt: evaluatedAt,
            nextCheckAt: nextCheckAt
        )
        lastEvaluation = evaluation
        emit(evaluation: evaluation, requester: requester)

        return (try? GoalEvaluationCellCodec.encode(evaluation)) ?? Self.errorValue(
            operation: "goal.evaluate",
            code: "encoding_failed",
            message: "GoalEvaluation could not be encoded."
        )
    }

    private func emit(evaluation: GoalEvaluation, requester: Identity) {
        guard case let .object(payload)? = try? GoalEvaluationCellCodec.encode(evaluation) else {
            return
        }

        for topic in evaluation.emittedEvents {
            var flowElement = FlowElement(
                title: "Goal \(evaluation.status.rawValue)",
                content: .object(payload),
                properties: FlowElement.Properties(type: .event, contentType: .object)
            )
            flowElement.topic = topic
            flowElement.origin = uuid
            pushFlowElement(flowElement, requester: requester)
        }
    }

    private func decodeObservations(_ payload: ValueType) throws -> [GoalObservation] {
        if case .object(let object) = payload, let nested = object["observations"] {
            return try decodeObservations(nested)
        }
        return try GoalEvaluationCellCodec.decode(payload, as: [GoalObservation].self)
    }

    private func statePayload() -> ValueType {
        var object: Object = [
            "status": .string("ok"),
            "definitionConfigured": .bool(definition != nil),
            "observationCount": .integer(observations.count)
        ]
        if let definition {
            object["goalID"] = .string(definition.goalID)
            object["purposeRef"] = .string(definition.purposeRef)
            object["evaluatorKind"] = .string(definition.evaluatorKind.rawValue)
        }
        if let lastEvaluation {
            object["lastStatus"] = .string(lastEvaluation.status.rawValue)
            object["lastEvaluationAt"] = .string(lastEvaluation.evaluatedAt)
        }
        return .object(object)
    }

    private func definitionPayload() -> ValueType {
        guard let definition else { return .null }
        return (try? GoalEvaluationCellCodec.encode(definition)) ?? .null
    }

    private func observationsPayload() -> ValueType {
        (try? GoalEvaluationCellCodec.encode(observations)) ?? .list([])
    }

    private func lastEvaluationPayload() -> ValueType {
        guard let lastEvaluation else { return .null }
        return (try? GoalEvaluationCellCodec.encode(lastEvaluation)) ?? .null
    }

    private static func goalDefinitionSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "schema": ExploreContract.schema(type: "string"),
                "goalID": ExploreContract.schema(type: "string"),
                "purposeRef": ExploreContract.schema(type: "string"),
                "title": ExploreContract.schema(type: "string"),
                "description": ExploreContract.schema(type: "string"),
                "lifecycle": ExploreContract.schema(type: "string"),
                "evaluatorKind": ExploreContract.schema(type: "string"),
                "evidenceSources": ExploreContract.listSchema(item: ExploreContract.schema(type: "object")),
                "predicate": ExploreContract.schema(type: "object"),
                "statusPolicy": ExploreContract.schema(type: "object"),
                "privacy": ExploreContract.schema(type: "object")
            ],
            requiredKeys: ["goalID", "purposeRef", "title", "description", "lifecycle", "evaluatorKind"],
            description: GoalDefinition.schemaID
        )
    }

    private static func observationSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "sourceID": ExploreContract.schema(type: "string"),
                "status": ExploreContract.schema(type: "string"),
                "observedAt": ExploreContract.schema(type: "string"),
                "value": ExploreContract.schema(type: "string"),
                "labels": ExploreContract.listSchema(item: ExploreContract.schema(type: "string")),
                "eventTypes": ExploreContract.listSchema(item: ExploreContract.schema(type: "string")),
                "consecutiveFailures": ExploreContract.schema(type: "integer"),
                "confidence": ExploreContract.schema(type: "float"),
                "summary": ExploreContract.schema(type: "string")
            ],
            requiredKeys: ["sourceID"],
            description: "GoalObservation"
        )
    }

    private static func observationListSchema() -> ValueType {
        ExploreContract.listSchema(item: observationSchema(), description: "GoalObservation list")
    }

    private static func goalEvaluationSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "schema": ExploreContract.schema(type: "string"),
                "goalID": ExploreContract.schema(type: "string"),
                "purposeRef": ExploreContract.schema(type: "string"),
                "status": ExploreContract.schema(type: "string"),
                "progress": ExploreContract.schema(type: "float"),
                "confidence": ExploreContract.schema(type: "float"),
                "evaluatedAt": ExploreContract.schema(type: "string"),
                "evidence": ExploreContract.listSchema(item: ExploreContract.schema(type: "object")),
                "missing": ExploreContract.listSchema(item: ExploreContract.schema(type: "string")),
                "blockers": ExploreContract.listSchema(item: ExploreContract.schema(type: "string")),
                "nextCheckAt": ExploreContract.schema(type: "string"),
                "emittedEvents": ExploreContract.listSchema(item: ExploreContract.schema(type: "string"))
            ],
            requiredKeys: ["goalID", "purposeRef", "status", "progress", "confidence", "evaluatedAt"],
            description: GoalEvaluation.schemaID
        )
    }

    private static func evaluateInputSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "evaluatedAt": ExploreContract.schema(type: "string"),
                "nextCheckAt": ExploreContract.schema(type: "string"),
                "observations": observationListSchema()
            ],
            description: "Optional evaluation timestamp, next check timestamp, and replacement observations."
        )
    }

    private static func stateSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "status": ExploreContract.schema(type: "string"),
                "definitionConfigured": ExploreContract.schema(type: "boolean"),
                "observationCount": ExploreContract.schema(type: "integer"),
                "goalID": ExploreContract.schema(type: "string"),
                "purposeRef": ExploreContract.schema(type: "string"),
                "evaluatorKind": ExploreContract.schema(type: "string"),
                "lastStatus": ExploreContract.schema(type: "string"),
                "lastEvaluationAt": ExploreContract.schema(type: "string")
            ],
            requiredKeys: ["status", "definitionConfigured", "observationCount"]
        )
    }

    private static func errorSchema(operation: String) -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "status": ExploreContract.schema(type: "string"),
                "operation": ExploreContract.schema(type: "string", description: operation),
                "code": ExploreContract.schema(type: "string"),
                "message": ExploreContract.schema(type: "string")
            ],
            requiredKeys: ["status", "operation", "code", "message"]
        )
    }

    private static func errorValue(operation: String, code: String, message: String) -> ValueType {
        .object([
            "status": .string("error"),
            "operation": .string(operation),
            "code": .string(code),
            "message": .string(message)
        ])
    }

    private static func stringValue(_ value: ValueType?) -> String? {
        guard case let .string(string)? = value else { return nil }
        return string
    }

    private static func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

private enum GoalEvaluationCellCodec {
    static func encode<T: Encodable>(_ value: T) throws -> ValueType {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(ValueType.self, from: data)
    }

    static func decode<T: Decodable>(_ value: ValueType, as type: T.Type) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(type, from: data)
    }
}
