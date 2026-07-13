// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
@_spi(HAVENRuntime) import CellBase

#if canImport(EventKit)
import EventKit
#endif

public final class NativeCalendarBridgeCell: GeneralCell {
#if canImport(EventKit)
    private let eventStore = EKEventStore()
#endif

    public required init(owner: Identity) async {
        await super.init(owner: owner)
        self.identityDomain = "Calendar"
        try? await ensureRuntimeReady()
    }

    public required init(from decoder: Decoder) throws {
        try super.init(from: decoder)
    }

    public override func installCellRuntimeBindingsForAccess() async throws {
        await setup(owner: storedOwnerIdentity)
    }

    private func setup(owner: Identity) async {
        agreementTemplate.ensureGrant("r---", for: CalendarContract.Keys.permissionStatus)
        agreementTemplate.ensureGrant("rw--", for: CalendarContract.Keys.requestAccess)
        agreementTemplate.ensureGrant("rw--", for: CalendarContract.Keys.createItem)

        await registerGet(
            key: CalendarContract.Keys.permissionStatus,
            owner: owner,
            returns: Self.permissionStatusSchema(),
            permissions: ["r---"],
            required: true,
            description: .string("Returns host-native calendar permission status without prompting.")
        ) { requester in
            guard await self.validateAccess("r---", at: CalendarContract.Keys.permissionStatus, for: requester) else { return .string("denied") }
            return .object(Self.permissionStatus())
        }

        await registerSet(
            key: CalendarContract.Keys.requestAccess,
            owner: owner,
            input: ExploreContract.objectSchema(
                properties: [
                    "calendar": ExploreContract.schema(type: "string"),
                    "reminders": ExploreContract.schema(type: "bool")
                ],
                description: "Explicit native access request. calendar may be writeOnly or fullAccess."
            ),
            returns: Self.permissionStatusSchema(),
            permissions: ["-w--"],
            required: true,
            description: .string("Requests native EventKit permissions after explicit user action.")
        ) { requester, payload in
            guard await self.validateAccess("rw--", at: CalendarContract.Keys.requestAccess, for: requester) else { return .string("denied") }
            return await self.requestAccess(payload: payload)
        }

        await registerSet(
            key: CalendarContract.Keys.createItem,
            owner: owner,
            input: CalendarContract.itemSchemaDescriptor(),
            returns: CalendarContract.mutationResultSchemaDescriptor(),
            permissions: ["-w--"],
            required: true,
            flowEffects: [ExploreContract.flowEffect(trigger: .set, topic: CalendarContract.flowTopic, contentType: "object")],
            description: .string("Writes a canonical CalendarItem into the host-native calendar when permission allows it.")
        ) { requester, payload in
            guard await self.validateAccess("rw--", at: CalendarContract.Keys.createItem, for: requester) else { return .string("denied") }
            return await self.createNativeCalendarItem(payload: payload, requester: requester)
        }
    }

    private func requestAccess(payload: ValueType) async -> ValueType {
#if canImport(EventKit)
        let object = CalendarValueCodec.object(payload) ?? [:]
        let requestedCalendarAccess = CalendarValueCodec.string(object["calendar"]) ?? "writeOnly"
        var result = Object()

        if requestedCalendarAccess.lowercased() == "fullaccess" {
            result["calendarGranted"] = .bool(await requestFullCalendarAccess())
        } else {
            result["calendarGranted"] = .bool(await requestWriteCalendarAccess())
        }

        if CalendarValueCodec.bool(object["reminders"]) == true {
            result["remindersGranted"] = .bool(await requestReminderAccess())
        }

        result["permissionStatus"] = .object(Self.permissionStatus())
        result["sideEffect"] = .bool(true)
        return .object(result)
#else
        return .object(Self.permissionStatus())
#endif
    }

    private func createNativeCalendarItem(payload: ValueType, requester: Identity) async -> ValueType {
#if canImport(EventKit)
        guard let object = CalendarValueCodec.object(payload),
              let item = CalendarItem.fromObject(CalendarValueCodec.object(object["item"]) ?? object) else {
            return .object(errorObject("invalid_item", "calendar.createItem requires a canonical CalendarItem."))
        }
        guard Self.canWriteEvents() else {
            return .object(errorObject("calendar_permission_required", "Native calendar write access is not granted."))
        }
        guard let startDate = CalendarDateCodec.date(from: item.time.startAt) else {
            return .object(errorObject("invalid_start", "Calendar item has no parseable start time."))
        }

        let event = EKEvent(eventStore: eventStore)
        event.title = item.title
        event.notes = item.description
        event.location = item.location?.name ?? item.location?.address
        event.startDate = startDate
        event.endDate = CalendarDateCodec.date(from: item.time.endAt) ?? startDate.addingTimeInterval(item.time.isAllDay ? 86_400 : 3_600)
        event.isAllDay = item.time.isAllDay
        event.calendar = eventStore.defaultCalendarForNewEvents
        if let url = item.links.compactMap({ $0.url }).first.flatMap(URL.init(string:)) {
            event.url = url
        }

        do {
            try eventStore.save(event, span: .thisEvent, commit: true)
            await emitCalendarEvent(kind: "calendar.native.item.created", item: item, nativeIdentifier: event.eventIdentifier, requester: requester)
            return .object([
                "ok": .bool(true),
                "status": .string("created"),
                "item": .object(item.asObject()),
                "nativeIdentifier": event.eventIdentifier.map(ValueType.string) ?? .null,
                "permissionStatus": .object(Self.permissionStatus())
            ])
        } catch {
            return .object(errorObject("native_write_failed", String(describing: error)))
        }
#else
        return .object(errorObject("eventkit_unavailable", "EventKit is not available in this build."))
#endif
    }

#if canImport(EventKit)
    private func requestWriteCalendarAccess() async -> Bool {
        if #available(macOS 14.0, iOS 17.0, *) {
            return await withCheckedContinuation { continuation in
                eventStore.requestWriteOnlyAccessToEvents { granted, _ in
                    continuation.resume(returning: granted)
                }
            }
        }
        return await withCheckedContinuation { continuation in
            eventStore.requestAccess(to: .event) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    private func requestFullCalendarAccess() async -> Bool {
        if #available(macOS 14.0, iOS 17.0, *) {
            return await withCheckedContinuation { continuation in
                eventStore.requestFullAccessToEvents { granted, _ in
                    continuation.resume(returning: granted)
                }
            }
        }
        return await withCheckedContinuation { continuation in
            eventStore.requestAccess(to: .event) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    private func requestReminderAccess() async -> Bool {
        if #available(macOS 14.0, iOS 17.0, *) {
            return await withCheckedContinuation { continuation in
                eventStore.requestFullAccessToReminders { granted, _ in
                    continuation.resume(returning: granted)
                }
            }
        }
        return await withCheckedContinuation { continuation in
            eventStore.requestAccess(to: .reminder) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    private static func canWriteEvents() -> Bool {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .authorized:
            return true
        case .fullAccess, .writeOnly:
            return true
        default:
            return false
        }
    }
#endif

    private static func permissionStatus() -> Object {
#if canImport(EventKit)
        [
            "nativeBridge": .string("eventkit"),
            "calendar": .string(permissionString(EKEventStore.authorizationStatus(for: .event))),
            "reminders": .string(permissionString(EKEventStore.authorizationStatus(for: .reminder))),
            "requiresExplicitUserAction": .bool(true),
            "remoteConfigurationsReceiveNativePermission": .bool(false),
            "writeOnlySupported": .bool(true),
            "fullAccessRequiredForRead": .bool(true)
        ]
#else
        [
            "nativeBridge": .string("unavailable"),
            "calendar": .string("unavailable"),
            "reminders": .string("unavailable"),
            "requiresExplicitUserAction": .bool(true),
            "remoteConfigurationsReceiveNativePermission": .bool(false),
            "writeOnlySupported": .bool(false),
            "fullAccessRequiredForRead": .bool(true)
        ]
#endif
    }

#if canImport(EventKit)
    private static func permissionString(_ status: EKAuthorizationStatus) -> String {
        switch status {
        case .notDetermined:
            return "notDetermined"
        case .restricted:
            return "restricted"
        case .denied:
            return "denied"
        case .authorized:
            return "authorized"
        case .fullAccess:
            return "fullAccess"
        case .writeOnly:
            return "writeOnly"
        @unknown default:
            return "unknown"
        }
    }
#endif

    private static func permissionStatusSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "nativeBridge": ExploreContract.schema(type: "string"),
                "calendar": ExploreContract.schema(type: "string"),
                "reminders": ExploreContract.schema(type: "string"),
                "requiresExplicitUserAction": ExploreContract.schema(type: "bool"),
                "remoteConfigurationsReceiveNativePermission": ExploreContract.schema(type: "bool"),
                "writeOnlySupported": ExploreContract.schema(type: "bool"),
                "fullAccessRequiredForRead": ExploreContract.schema(type: "bool")
            ],
            requiredKeys: ["nativeBridge", "calendar", "requiresExplicitUserAction", "remoteConfigurationsReceiveNativePermission"],
            description: "Native calendar bridge permission status."
        )
    }

    private func errorObject(_ code: String, _ message: String) -> Object {
        [
            "ok": .bool(false),
            "status": .string("error"),
            "code": .string(code),
            "message": .string(message),
            "permissionStatus": .object(Self.permissionStatus())
        ]
    }

    private func emitCalendarEvent(kind: String, item: CalendarItem, nativeIdentifier: String?, requester: Identity) async {
        var payload: Object = [
            "schema": .string(CalendarContract.itemSchema),
            "itemId": .string(item.id),
            "uid": .string(item.uid),
            "title": .string(item.title)
        ]
        payload["nativeIdentifier"] = nativeIdentifier.map(ValueType.string) ?? .null
        var flowElement = FlowElement(
            title: kind,
            content: .object(payload),
            properties: FlowElement.Properties(type: .event, contentType: .object)
        )
        flowElement.topic = CalendarContract.flowTopic
        flowElement.origin = uuid
        pushFlowElement(flowElement, requester: requester)
    }
}
