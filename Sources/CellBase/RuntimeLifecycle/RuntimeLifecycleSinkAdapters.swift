// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public actor RuntimeLifecycleFanoutEffectSink: RuntimeLifecycleEffectSink {
    private let sinks: [RuntimeLifecycleEffectSink]

    public init(sinks: [RuntimeLifecycleEffectSink]) {
        self.sinks = sinks
    }

    public func handle(effect: RuntimeLifecycleEffect) async {
        for sink in sinks {
            await sink.handle(effect: effect)
        }
    }
}

public actor RuntimeLifecycleFlowMetricsSink: RuntimeLifecycleMetricsSink {
    private let emitter: FlowElementPusherCell

    public init(emitter: FlowElementPusherCell) {
        self.emitter = emitter
    }

    public func increment(
        _ metric: RuntimeLifecycleMetric,
        by value: Int64 = 1,
        dimensions: [String : String] = [:]
    ) async {
        emit(metric: metric, aggregation: "counter", value: Double(value), dimensions: dimensions)
    }

    public func gauge(
        _ metric: RuntimeLifecycleMetric,
        value: Int64,
        dimensions: [String : String] = [:]
    ) async {
        emit(metric: metric, aggregation: "gauge", value: Double(value), dimensions: dimensions)
    }

    public func histogram(
        _ metric: RuntimeLifecycleMetric,
        value: Double,
        dimensions: [String : String] = [:]
    ) async {
        emit(metric: metric, aggregation: "histogram", value: value, dimensions: dimensions)
    }

    private func emit(
        metric: RuntimeLifecycleMetric,
        aggregation: String,
        value: Double,
        dimensions: [String: String]
    ) {
        var dimensionsObject = Object()
        for (key, currentValue) in dimensions {
            dimensionsObject[key] = .string(currentValue)
        }

        var payload: Object = [
            "metric": .string(metric.rawValue),
            "aggregation": .string(aggregation),
            "value": .float(value)
        ]
        payload["dimensions"] = .object(dimensionsObject)

        var flowElement = FlowElement(
            title: "Runtime lifecycle metric",
            content: .object(payload),
            properties: FlowElement.Properties(type: .event, contentType: .object)
        )
        flowElement.topic = "runtime.lifecycle.metrics"
        emitter.pushFlowElement(flowElement, requester: emitter.owner)
    }
}
