// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

/// Emits runtime lifecycle events on a FlowElement feed.
/// This gives listeners a command route for fenced/CAS lifecycle actions.
public actor RuntimeLifecycleFlowEventSink: RuntimeLifecycleEffectSink {
    private let emitter: FlowElementPusherCell

    public init(emitter: FlowElementPusherCell) {
        self.emitter = emitter
    }

    public func handle(effect: RuntimeLifecycleEffect) async {
        guard case .emit(let event) = effect else {
            return
        }
        var payload: Object = [
            "type": .string(event.type.rawValue),
            "cellID": .string(event.cellID.rawValue),
            "version": .string(String(event.version)),
            "tick": .string(String(event.tick)),
            "fencingToken": .string(String(event.fencingToken))
        ]

        if event.type == .memoryTTLWarning {
            payload["warningCommandRoute"] = .string("RuntimeLifecycleManager.applyWarningCommand")
            payload["warningCommands"] = .list([
                .string("extendMemoryTTL"),
                .string("extendPersistedTTL"),
                .string("persistAndUnload"),
                .string("delete"),
                .string("ignore")
            ])
        }

        var flowElement = FlowElement(
            title: "Runtime lifecycle event",
            content: .object(payload),
            properties: FlowElement.Properties(type: .event, contentType: .object)
        )
        flowElement.topic = "runtime.lifecycle"
        emitter.pushFlowElement(flowElement, requester: emitter.owner)
    }
}
