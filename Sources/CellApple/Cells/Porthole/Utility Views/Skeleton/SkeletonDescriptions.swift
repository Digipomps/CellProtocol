// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  SkeletonDescriptions.swift
//  HAVEN_MVP
//
//  Created by Kjetil Hustveit on 24/10/2024.
//
import Foundation
import CellBase


public struct SkeletonDescriptions {
    static func simpleSkeletonDescription() -> CellConfiguration {
        var configuration = CellConfiguration(name: "Preview config", cellReferences: [CellReference(endpoint: "cell:///EventEmitter", label: "eventTest")])
        let cellText = SkeletonText(text: "String")
        let element = SkeletonElement.Text(cellText)
        
        configuration.skeleton = element
        
        return configuration
    }
    
    static func simpleSkeletonDescription2() -> CellConfiguration {
        var configuration = CellConfiguration(name: "Preview config", cellReferences: [CellReference(endpoint: "cell:///EventEmitter", label: "eventTest")])
        var skelImage = SkeletonImage(name: "Haven_logo_cropped")
        skelImage.resizable = true
//        skelImage.scaledToFit = true
        let skelText = SkeletonText(text: "String")
        let skelText2 = SkeletonText(text: "String2")
        
        let skelVStack = SkeletonVStack(elements: [.Image(skelImage), .Text(skelText), .Text(skelText2)])
        
        configuration.skeleton = .VStack(skelVStack)
                
        do {
            let jsonData = try JSONEncoder().encode(configuration)
            print(String(data: jsonData, encoding: .utf8) ?? "failed...")
            
        } catch {
            print("json dump failed with error: \(error)")
        }
        return configuration
    }
    
    static func jsonData1() -> Data {
        let jsonString = """
{
  "cellReferences": [
    {
      "setKeysAndValues": [
        {
          "key": "start"
        }
      ],
      "endpoint": "cell:///EventEmitter",
      "label": "eventTest",
      "subscribeFeed": true,
      "subscriptions": []
    }
  ],
  "name": "Preview config",
  "uuid": "1E33CF55-D756-47A8-877B-4BCC2AB9A56D",
  "skeleton": {
    "Text": {
      "text": "Should vi try with List?"
    }
  }
}
"""
        
        
        let jsonString2 = """
{
  "cellReferences": [
    {
      "setKeysAndValues": [
        {
          "key": "start"
        }
      ],
      "endpoint": "cell:///EventEmitter",
      "label": "eventTest",
      "subscribeFeed": true,
      "subscriptions": []
    }
  ],
  "name": "Preview config",
  "uuid": "1E33CF55-D756-47A8-877B-4BCC2AB9A56D",
  "skeleton": {
    "VStack": [
      {
        "Image": {
          "name": "Haven_logo_cropped",
          "resizable": true,
          "scaledToFit": true
        }
      },
      {
        "Text": {
          "text": "Should vi try with List?"
        }
      },
      {
        "Text": {
          "text": "Well - it must be done..."
        }
      },
      {
        "Text": {
          "url": "cell:///Porthole/eventTest.text"
        }
      },
        {
            "Reference" : {
                "topic" : "test",
                "keypath" : "testEvent"
            }
        }
    ]
  }
}
"""
        
        if let jsonData = jsonString2.data(using: .utf8) {
            return jsonData
        }
        print("Conveting json string to data failed")
        return Data()
        
    }
    
    static func jsonPerspectivePurpose() -> Data {
        let jsonString = """
{
  "name": "Radar",
  "uuid": "7D934E46-9AD8-47C5-8ACB-F364452E2521",
  "cellReferences": [
    {
      "subscriptions": [
        {
          "subscriptions": [],
          "label": "radar",
          "endpoint": "cell:///EventGoal",
          "subscribeFeed": true,
          "setKeysAndValues": [
            {
              "key": "addMatchers",
              "value": [
                {
                  "key": "count",
                  "op": "=",
                  "match": 1
                }
              ]
            }
          ]
        }
      ],
      "label": "radar",
      "endpoint": "cell:///Perspective",
      "subscribeFeed": true,
      "setKeysAndValues": [
        {
          "key": "start"
        }
      ]
    }
  ]
}
"""
        

        
        if let jsonData = jsonString.data(using: .utf8) {
            return jsonData
        }
        print("Conveting json string to data failed")
        return Data()
        
    }
    
 
    
    static func skeletonDescriptionForPurposes() -> CellConfiguration {
        let jsonString = """
{
  "cellReferences": [
    {
      "setKeysAndValues": [
        {
          "key": "start"
        }
      ],
      "endpoint": "cell:///Purposes",
      "label": "purposes",
      "subscribeFeed": true,
      "subscriptions": []
    }
  ],
  "name": "Preview config",
  "uuid": "1E33CF55-D756-47A8-877B-4BCC2AB9A56D",
  "skeleton": {
    "VStack": [
      {
        "Image": {
          "name": "Haven_logo_cropped",
          "resizable": true,
          "scaledToFit": true
        }
      },
      {
        "Text": {
          "text": "Should vi try with List?"
        }
      },
      {
        "Text": {
          "text": "Well - it must be done..."
        }
      },
      {
        "Text": {
          "url": "cell:///Porthole/eventTest.text"
        }
      },
        {
            "Reference" : {
                "topic" : "purposes",
                "keypath" : "testEvent"
            }
        }
    ]
  }
}
"""
        let jsonData = jsonString.data(using: .utf8)! // Just for testing
        do {
            let configuration = try JSONDecoder().decode(CellConfiguration.self, from: jsonData)
            // Debug
            do {
                let jsonData = try JSONEncoder().encode(configuration)
                print(String(data: jsonData, encoding: .utf8) ?? "failed...")
                
            } catch {
                print("json dump failed with error: \(error)")
            }
            return configuration
        } catch {
            print("json decoding failed with error: \(error)")
        }
    return SkeletonDescriptions.simpleSkeletonDescription()
    }
    
    static public func skeletonDescriptionFromJson() -> CellConfiguration {
        let jsonData = jsonData1()
        
            do {
                let configuration = try JSONDecoder().decode(CellConfiguration.self, from: jsonData)
                // Debug
                do {
                    let jsonData = try JSONEncoder().encode(configuration)
                    print(String(data: jsonData, encoding: .utf8) ?? "failed...")
                    
                } catch {
                    print("json dump failed with error: \(error)")
                }
                return configuration
            } catch {
                print("json decoding failed with error: \(error)")
            }
        return SkeletonDescriptions.simpleSkeletonDescription()
    }
    
    static func setupPerspectiveGoalFromJson() -> CellConfiguration {
        let jsonData = jsonPerspectivePurpose()
        
            do {
                let configuration = try JSONDecoder().decode(CellConfiguration.self, from: jsonData)
                // Debug
                do {
                    let jsonData = try JSONEncoder().encode(configuration)
                    print(String(data: jsonData, encoding: .utf8) ?? "failed...")
                    
                } catch {
                    print("json dump failed with error: \(error)")
                }
                return configuration
            } catch {
                print("json decoding failed with error: \(error)")
            }
        return SkeletonDescriptions.simpleSkeletonDescription()
    }
    
    static func menuConfigurations() async throws -> [CellConfiguration] {
        var configurations = [CellConfiguration]()
        
        var configuration1 = CellConfiguration(name: "Chat")
        var chatReference = CellReference(endpoint: "cell:///Chat", label: "chat")
        chatReference.addKeyAndValue(KeyValue(key: "start"))
        configuration1.addReference(chatReference)
        configurations.append(configuration1)
        
        var configuration2 = CellConfiguration(name: "Radar")
        var entityScannerReference = CellReference(endpoint: "cell:///EntityScanner", label: "scanner")
        entityScannerReference.addKeyAndValue( KeyValue(key: "start") )
        configuration2.addReference(entityScannerReference)
        
        
        var elementList = SkeletonElementList()
        elementList.append(.Spacer(SkeletonSpacer()))
        
        let skeletonText = SkeletonText(text: "Radar")
        elementList.append(.Text(skeletonText))
        
        
        let skeletonButtonStart = SkeletonButton(keypath: "scanner.start", label: "start")
        elementList.append(.Button(skeletonButtonStart))
        let skeletonButtonStop = SkeletonButton(keypath: "scanner.stop", label: "stop")
        elementList.append(.Button(skeletonButtonStop))
        
        
        var skeletonReference = SkeletonCellReference(keypath: "scanner", topic: "scanner")
        
        var flowElements = SkeletonElementList()
        flowElements.append(.Text(SkeletonText(text: "Flow Element")))
        flowElements.append(.Text(SkeletonText(keypath: ".")))
        let  vstack = SkeletonVStack(elements: flowElements)
        skeletonReference.flowElementSkeleton = vstack
        elementList.append(.Reference(skeletonReference))
        
        
        elementList.append(.Spacer(SkeletonSpacer()))
        
        
        
        var skeletonReference2 = SkeletonCellReference(keypath: "scanner", topic: "scanner.found")
        var flowElements2 = SkeletonElementList()
        flowElements2.append(.Text(SkeletonText(text: "Device Found")))
        flowElements2.append(.Text(SkeletonText(keypath: "displayname")))
        
        let inviteButton = SkeletonButton(keypath: "invite", label: "invite")
        flowElements2.append(.Button(inviteButton))
        
        let  vstack2 = SkeletonVStack(elements: flowElements2)
        skeletonReference2.flowElementSkeleton = vstack2
        elementList.append(.Reference(skeletonReference2))
        

        configuration2.skeleton = .VStack(SkeletonVStack(elements: elementList))
        configurations.append(configuration2)

        var configuration2Step2 = CellConfiguration(name: "Radar Step 2")
        var entityScannerReferenceStep2 = CellReference(endpoint: "cell:///EntityScanner", label: "scanner")
        entityScannerReferenceStep2.addKeyAndValue(KeyValue(key: "start"))
        configuration2Step2.addReference(entityScannerReferenceStep2)

        var step2Elements = SkeletonElementList()
        step2Elements.append(.Spacer(SkeletonSpacer()))
        step2Elements.append(.Text(SkeletonText(text: "Radar Step 2")))
        step2Elements.append(.Text(SkeletonText(text: "Event-driven nearby entities")))

        let step2StartButton = SkeletonButton(keypath: "scanner.start", label: "start")
        step2Elements.append(.Button(step2StartButton))
        let step2StopButton = SkeletonButton(keypath: "scanner.stop", label: "stop")
        step2Elements.append(.Button(step2StopButton))

        var statusReference = SkeletonCellReference(keypath: "scanner", topic: "scanner.status")
        var statusElements = SkeletonElementList()
        statusElements.append(.Text(SkeletonText(text: "Scanner status")))
        statusElements.append(.Text(SkeletonText(keypath: "status")))
        statusElements.append(.Text(SkeletonText(keypath: "remoteUUID")))
        statusElements.append(.Text(SkeletonText(keypath: "timestamp")))
        statusReference.flowElementSkeleton = SkeletonVStack(elements: statusElements)
        step2Elements.append(.Reference(statusReference))

        var foundReference = SkeletonCellReference(keypath: "scanner", topic: "scanner.found")
        var foundElements = SkeletonElementList()
        foundElements.append(.Text(SkeletonText(text: "Entity found")))
        foundElements.append(.Text(SkeletonText(keypath: "displayName")))
        foundElements.append(.Text(SkeletonText(keypath: "remoteUUID")))
        foundElements.append(.Button(SkeletonButton(keypath: "invite", label: "invite")))
        foundReference.flowElementSkeleton = SkeletonVStack(elements: foundElements)
        step2Elements.append(.Reference(foundReference))

        var connectedReference = SkeletonCellReference(keypath: "scanner", topic: "scanner.connected")
        var connectedElements = SkeletonElementList()
        connectedElements.append(.Text(SkeletonText(text: "Connected devices")))
        connectedElements.append(.Text(SkeletonText(keypath: "connectedCount")))
        connectedElements.append(.Text(SkeletonText(keypath: "connectedDevices")))
        connectedReference.flowElementSkeleton = SkeletonVStack(elements: connectedElements)
        step2Elements.append(.Reference(connectedReference))

        var proximityReference = SkeletonCellReference(keypath: "scanner", topic: "scanner.proximity")
        var proximityElements = SkeletonElementList()
        proximityElements.append(.Text(SkeletonText(text: "Proximity update")))
        proximityElements.append(.Text(SkeletonText(keypath: "remoteUUID")))
        proximityElements.append(.Text(SkeletonText(keypath: "distanceMeters")))
        proximityElements.append(.Text(SkeletonText(keypath: "direction.x")))
        proximityElements.append(.Text(SkeletonText(keypath: "direction.y")))
        proximityElements.append(.Text(SkeletonText(keypath: "direction.z")))
        proximityReference.flowElementSkeleton = SkeletonVStack(elements: proximityElements)
        step2Elements.append(.Reference(proximityReference))

        var lostReference = SkeletonCellReference(keypath: "scanner", topic: "scanner.lost")
        var lostElements = SkeletonElementList()
        lostElements.append(.Text(SkeletonText(text: "Entity lost")))
        lostElements.append(.Text(SkeletonText(keypath: "displayName")))
        lostElements.append(.Text(SkeletonText(keypath: "remoteUUID")))
        lostReference.flowElementSkeleton = SkeletonVStack(elements: lostElements)
        step2Elements.append(.Reference(lostReference))

        configuration2Step2.skeleton = .VStack(SkeletonVStack(elements: step2Elements))
        configurations.append(configuration2Step2)

        var configurationEntityScanner = CellConfiguration(name: "Entity Scanner")
        var entityScannerToolReference = CellReference(endpoint: "cell:///EntityScanner", label: "scanner")
        entityScannerToolReference.addKeyAndValue(KeyValue(key: "start"))
        configurationEntityScanner.addReference(entityScannerToolReference)

        var entityScannerElements = SkeletonElementList()
        entityScannerElements.append(.Spacer(SkeletonSpacer()))
        entityScannerElements.append(.Text(SkeletonText(text: "Entity Scanner")))
        entityScannerElements.append(.Text(SkeletonText(text: "Discover peers, invite them, exchange signed contact proofs and inspect saved encounters")))
        entityScannerElements.append(.Button(SkeletonButton(keypath: "scanner.start", label: "start")))
        entityScannerElements.append(.Button(SkeletonButton(keypath: "scanner.stop", label: "stop")))

        var capabilityReference = SkeletonCellReference(keypath: "scanner", topic: "scanner.capabilities")
        var capabilityElements = SkeletonElementList()
        capabilityElements.append(.Text(SkeletonText(text: "Capabilities")))
        capabilityElements.append(.Text(SkeletonText(keypath: "transportMode")))
        capabilityElements.append(.Text(SkeletonText(keypath: "precisionMode")))
        capabilityElements.append(.Text(SkeletonText(keypath: "description")))
        capabilityReference.flowElementSkeleton = SkeletonVStack(elements: capabilityElements)
        entityScannerElements.append(.Reference(capabilityReference))

        var scannerStatusReference = SkeletonCellReference(keypath: "scanner", topic: "scanner.status")
        var scannerStatusElements = SkeletonElementList()
        scannerStatusElements.append(.Text(SkeletonText(text: "Scanner status")))
        scannerStatusElements.append(.Text(SkeletonText(keypath: "status")))
        scannerStatusElements.append(.Text(SkeletonText(keypath: "remoteUUID")))
        scannerStatusElements.append(.Text(SkeletonText(keypath: "timestamp")))
        scannerStatusReference.flowElementSkeleton = SkeletonVStack(elements: scannerStatusElements)
        entityScannerElements.append(.Reference(scannerStatusReference))

        var toolFoundReference = SkeletonCellReference(keypath: "scanner", topic: "scanner.found")
        var toolFoundElements = SkeletonElementList()
        toolFoundElements.append(.Text(SkeletonText(text: "Peer found")))
        toolFoundElements.append(.Text(SkeletonText(keypath: "displayName")))
        toolFoundElements.append(.Text(SkeletonText(keypath: "remoteUUID")))
        toolFoundElements.append(.Text(SkeletonText(keypath: "precisionMode")))
        toolFoundElements.append(.Button(SkeletonButton(keypath: "invite", label: "invite")))
        toolFoundElements.append(.Button(SkeletonButton(keypath: "requestContact", label: "request contact")))
        toolFoundReference.flowElementSkeleton = SkeletonVStack(elements: toolFoundElements)
        entityScannerElements.append(.Reference(toolFoundReference))

        var incomingContactReference = SkeletonCellReference(keypath: "scanner", topic: "scanner.contact.received")
        var incomingContactElements = SkeletonElementList()
        incomingContactElements.append(.Text(SkeletonText(text: "Incoming contact request")))
        incomingContactElements.append(.Text(SkeletonText(keypath: "requesterDisplayName")))
        incomingContactElements.append(.Text(SkeletonText(keypath: "requestId")))
        incomingContactElements.append(.Text(SkeletonText(keypath: "verification.status")))
        incomingContactElements.append(.Text(SkeletonText(keypath: "requesterPerspective.activePurposeCount")))
        incomingContactElements.append(.Button(SkeletonButton(keypath: "acceptContact", label: "accept")))
        incomingContactReference.flowElementSkeleton = SkeletonVStack(elements: incomingContactElements)
        entityScannerElements.append(.Reference(incomingContactReference))

        var outgoingContactReference = SkeletonCellReference(keypath: "scanner", topic: "scanner.contact.outgoing")
        var outgoingContactElements = SkeletonElementList()
        outgoingContactElements.append(.Text(SkeletonText(text: "Outgoing contact request")))
        outgoingContactElements.append(.Text(SkeletonText(keypath: "displayName")))
        outgoingContactElements.append(.Text(SkeletonText(keypath: "requestId")))
        outgoingContactElements.append(.Text(SkeletonText(keypath: "status")))
        outgoingContactReference.flowElementSkeleton = SkeletonVStack(elements: outgoingContactElements)
        entityScannerElements.append(.Reference(outgoingContactReference))

        var connectedToolReference = SkeletonCellReference(keypath: "scanner", topic: "scanner.connected")
        var connectedToolElements = SkeletonElementList()
        connectedToolElements.append(.Text(SkeletonText(text: "Connected peers")))
        connectedToolElements.append(.Text(SkeletonText(keypath: "connectedCount")))
        connectedToolElements.append(.Text(SkeletonText(keypath: "connectedDevices")))
        connectedToolReference.flowElementSkeleton = SkeletonVStack(elements: connectedToolElements)
        entityScannerElements.append(.Reference(connectedToolReference))

        var savedEncounterReference = SkeletonCellReference(keypath: "scanner", topic: "scanner.encounter.saved")
        var savedEncounterElements = SkeletonElementList()
        savedEncounterElements.append(.Text(SkeletonText(text: "Encounter saved")))
        savedEncounterElements.append(.Text(SkeletonText(keypath: "remoteDisplayName")))
        savedEncounterElements.append(.Text(SkeletonText(keypath: "matchCount")))
        savedEncounterElements.append(.Text(SkeletonText(keypath: "acceptedAt")))
        savedEncounterReference.flowElementSkeleton = SkeletonVStack(elements: savedEncounterElements)
        entityScannerElements.append(.Reference(savedEncounterReference))

        var encounterList = SkeletonList(keypath: "scanner.encounters")
        var encounterListElements = SkeletonElementList()
        encounterListElements.append(.Text(SkeletonText(text: "Saved encounter")))
        encounterListElements.append(.Text(SkeletonText(keypath: "remoteDisplayName")))
        encounterListElements.append(.Text(SkeletonText(keypath: "matchCount")))
        encounterListElements.append(.Text(SkeletonText(keypath: "acceptedAt")))
        encounterListElements.append(.Text(SkeletonText(keypath: "precisionMode")))
        encounterList.flowElementSkeleton = SkeletonVStack(elements: encounterListElements)
        entityScannerElements.append(.List(encounterList))

        configurationEntityScanner.skeleton = .VStack(SkeletonVStack(elements: entityScannerElements))
        configurations.append(configurationEntityScanner)

        var configurationEntityScannerHelper = CellConfiguration(name: "Entity Scanner Test Helper")
        var entityScannerHelperReference = CellReference(endpoint: "cell:///EntityScanner", label: "scanner")
        entityScannerHelperReference.addKeyAndValue(KeyValue(key: "start"))
        configurationEntityScannerHelper.addReference(entityScannerHelperReference)
        configurationEntityScannerHelper.addReference(CellReference(endpoint: "cell:///Perspective", label: "perspective"))
        configurationEntityScannerHelper.addReference(CellReference(endpoint: "cell:///EntityAnchor", label: "entity"))

        var helperElements = SkeletonElementList()
        helperElements.append(.Spacer(SkeletonSpacer()))
        helperElements.append(.Text(SkeletonText(text: "Entity Scanner Test Helper")))
        helperElements.append(.Text(SkeletonText(text: "Manual verification of nearby discovery, signed contact exchange, local perspective snapshot and saved encounter proofs")))
        helperElements.append(.Button(SkeletonButton(keypath: "scanner.start", label: "start")))
        helperElements.append(.Button(SkeletonButton(keypath: "scanner.stop", label: "stop")))
        helperElements.append(.Divider(SkeletonDivider()))

        var localPerspectiveSectionContent = SkeletonElementList()
        localPerspectiveSectionContent.append(.Text(SkeletonText(text: "Local perspective snapshot")))
        localPerspectiveSectionContent.append(.List({
            var activePurposeList = SkeletonList(keypath: "perspective.perspective.state.activePurposes")
            var activePurposeRow = SkeletonElementList()
            activePurposeRow.append(.Text(SkeletonText(text: "Purpose")))
            activePurposeRow.append(.Text(SkeletonText(keypath: "name")))
            activePurposeRow.append(.Text(SkeletonText(keypath: "weight")))
            activePurposeRow.append(.Text(SkeletonText(keypath: "interests")))
            activePurposeList.flowElementSkeleton = SkeletonVStack(elements: activePurposeRow)
            return activePurposeList
        }()))
        helperElements.append(.Section(SkeletonSection(
            header: .Text(SkeletonText(text: "Perspective")),
            content: localPerspectiveSectionContent
        )))

        var helperCapabilitiesReference = SkeletonCellReference(keypath: "scanner", topic: "scanner.capabilities")
        var helperCapabilitiesElements = SkeletonElementList()
        helperCapabilitiesElements.append(.Text(SkeletonText(text: "Capabilities event")))
        helperCapabilitiesElements.append(.Text(SkeletonText(keypath: "transportMode")))
        helperCapabilitiesElements.append(.Text(SkeletonText(keypath: "precisionMode")))
        helperCapabilitiesElements.append(.Text(SkeletonText(keypath: "description")))
        helperCapabilitiesReference.flowElementSkeleton = SkeletonVStack(elements: helperCapabilitiesElements)

        var helperFoundReference = SkeletonCellReference(keypath: "scanner", topic: "scanner.found")
        var helperFoundElements = SkeletonElementList()
        helperFoundElements.append(.Text(SkeletonText(text: "Found peer")))
        helperFoundElements.append(.Text(SkeletonText(keypath: "displayName")))
        helperFoundElements.append(.Text(SkeletonText(keypath: "remoteUUID")))
        helperFoundElements.append(.Button(SkeletonButton(keypath: "invite", label: "invite")))
        helperFoundElements.append(.Button(SkeletonButton(keypath: "requestContact", label: "request contact")))
        helperFoundReference.flowElementSkeleton = SkeletonVStack(elements: helperFoundElements)

        var helperOutgoingReference = SkeletonCellReference(keypath: "scanner", topic: "scanner.contact.outgoing")
        var helperOutgoingElements = SkeletonElementList()
        helperOutgoingElements.append(.Text(SkeletonText(text: "Outgoing request")))
        helperOutgoingElements.append(.Text(SkeletonText(keypath: "requesterDisplayName")))
        helperOutgoingElements.append(.Text(SkeletonText(keypath: "requestId")))
        helperOutgoingElements.append(.Text(SkeletonText(keypath: "status")))
        helperOutgoingReference.flowElementSkeleton = SkeletonVStack(elements: helperOutgoingElements)

        var helperIncomingReference = SkeletonCellReference(keypath: "scanner", topic: "scanner.contact.received")
        var helperIncomingElements = SkeletonElementList()
        helperIncomingElements.append(.Text(SkeletonText(text: "Incoming request")))
        helperIncomingElements.append(.Text(SkeletonText(keypath: "requesterDisplayName")))
        helperIncomingElements.append(.Text(SkeletonText(keypath: "requestId")))
        helperIncomingElements.append(.Text(SkeletonText(keypath: "verification.status")))
        helperIncomingElements.append(.Button(SkeletonButton(keypath: "acceptContact", label: "accept")))
        helperIncomingReference.flowElementSkeleton = SkeletonVStack(elements: helperIncomingElements)

        var helperSavedEncounterReference = SkeletonCellReference(keypath: "scanner", topic: "scanner.encounter.saved")
        var helperSavedEncounterElements = SkeletonElementList()
        helperSavedEncounterElements.append(.Text(SkeletonText(text: "Saved encounter event")))
        helperSavedEncounterElements.append(.Text(SkeletonText(keypath: "remoteDisplayName")))
        helperSavedEncounterElements.append(.Text(SkeletonText(keypath: "matchCount")))
        helperSavedEncounterElements.append(.Text(SkeletonText(keypath: "requestVerification.status")))
        helperSavedEncounterElements.append(.Text(SkeletonText(keypath: "acceptanceVerification.status")))
        helperSavedEncounterReference.flowElementSkeleton = SkeletonVStack(elements: helperSavedEncounterElements)

        var helperExportedEncounterReference = SkeletonCellReference(keypath: "scanner", topic: "scanner.encounter.exported")
        var helperExportedEncounterElements = SkeletonElementList()
        helperExportedEncounterElements.append(.Text(SkeletonText(text: "Exported encounter proof")))
        helperExportedEncounterElements.append(.Text(SkeletonText(keypath: "remoteDisplayName")))
        helperExportedEncounterElements.append(.Text(SkeletonText(keypath: "encounterId")))
        helperExportedEncounterElements.append(.Text(SkeletonText(keypath: "requestVerification.status")))
        helperExportedEncounterElements.append(.Text(SkeletonText(keypath: "acceptanceVerification.status")))
        helperExportedEncounterElements.append(.Text(SkeletonText(keypath: "requestProof")))
        helperExportedEncounterElements.append(.Text(SkeletonText(keypath: "acceptanceProof")))
        helperExportedEncounterReference.flowElementSkeleton = SkeletonVStack(elements: helperExportedEncounterElements)

        var helperExportedEncounterJSONReference = SkeletonCellReference(keypath: "scanner", topic: "scanner.encounter.jsonExported")
        var helperExportedEncounterJSONElements = SkeletonElementList()
        helperExportedEncounterJSONElements.append(.Text(SkeletonText(text: "Copy/export JSON")))
        helperExportedEncounterJSONElements.append(.Text(SkeletonText(keypath: "remoteDisplayName")))
        helperExportedEncounterJSONElements.append(.Text(SkeletonText(keypath: "fileName")))
        helperExportedEncounterJSONElements.append(.Text(SkeletonText(keypath: "copiedToClipboard")))
        helperExportedEncounterJSONElements.append(.Text(SkeletonText(keypath: "characterCount")))
        helperExportedEncounterJSONElements.append(.Text(SkeletonText(keypath: "json")))
        helperExportedEncounterJSONReference.flowElementSkeleton = SkeletonVStack(elements: helperExportedEncounterJSONElements)

        var liveEventSectionContent = SkeletonElementList()
        liveEventSectionContent.append(.Reference(helperCapabilitiesReference))
        liveEventSectionContent.append(.Reference(helperFoundReference))
        liveEventSectionContent.append(.Reference(helperOutgoingReference))
        liveEventSectionContent.append(.Reference(helperIncomingReference))
        liveEventSectionContent.append(.Reference(helperSavedEncounterReference))
        liveEventSectionContent.append(.Reference(helperExportedEncounterReference))
        liveEventSectionContent.append(.Reference(helperExportedEncounterJSONReference))
        helperElements.append(.Section(SkeletonSection(
            header: .Text(SkeletonText(text: "Live scanner flow")),
            content: liveEventSectionContent
        )))

        var helperEncounterList = SkeletonList(keypath: "scanner.encounters")
        var helperEncounterRow = SkeletonElementList()
        helperEncounterRow.append(.Text(SkeletonText(text: "Encounter proof")))
        helperEncounterRow.append(.Text(SkeletonText(keypath: "remoteDisplayName")))
        helperEncounterRow.append(.Text(SkeletonText(keypath: "matchCount")))
        helperEncounterRow.append(.Text(SkeletonText(keypath: "requestVerification.status")))
        helperEncounterRow.append(.Text(SkeletonText(keypath: "acceptanceVerification.status")))
        helperEncounterRow.append(.Text(SkeletonText(keypath: "precisionMode")))
        helperEncounterRow.append(.Text(SkeletonText(keypath: "acceptedAt")))
        helperEncounterRow.append(.Button(SkeletonButton(keypath: "exportEncounter", label: "export")))
        helperEncounterRow.append(.Button(SkeletonButton(keypath: "exportEncounterJSON", label: "copy json")))
        helperEncounterList.flowElementSkeleton = SkeletonVStack(elements: helperEncounterRow)

        var helperStorageSectionContent = SkeletonElementList()
        helperStorageSectionContent.append(.Text(SkeletonText(text: "Saved encounter summaries from EntityScanner/EntityAnchor")))
        helperStorageSectionContent.append(.Button(SkeletonButton(
            keypath: "proofs.encounters",
            label: "clear encounter proofs",
            url: "cell:///EntityAnchor",
            payload: .object(Object())
        )))
        helperStorageSectionContent.append(.Text(SkeletonText(text: "This clears encounter proofs only. Stored identities remain untouched.")))
        helperStorageSectionContent.append(.List(helperEncounterList))
        helperElements.append(.Section(SkeletonSection(
            header: .Text(SkeletonText(text: "Stored encounters")),
            content: helperStorageSectionContent
        )))

        configurationEntityScannerHelper.skeleton = .VStack(SkeletonVStack(elements: helperElements))
        configurations.append(configurationEntityScannerHelper)

        var configurationEntityScannerChecklist = CellConfiguration(name: "Entity Scanner Pairing Checklist")
        var checklistScannerReference = CellReference(endpoint: "cell:///EntityScanner", label: "scanner")
        checklistScannerReference.addKeyAndValue(KeyValue(key: "start"))
        configurationEntityScannerChecklist.addReference(checklistScannerReference)
        configurationEntityScannerChecklist.addReference(CellReference(endpoint: "cell:///Perspective", label: "perspective"))

        var checklistElements = SkeletonElementList()
        checklistElements.append(.Spacer(SkeletonSpacer()))
        checklistElements.append(.Text(SkeletonText(text: "Entity Scanner Pairing Checklist")))
        checklistElements.append(.Button(SkeletonButton(keypath: "scanner.start", label: "start scanner")))
        checklistElements.append(.Button(SkeletonButton(keypath: "scanner.stop", label: "stop scanner")))

        var checklistIntro = SkeletonElementList()
        checklistIntro.append(.Text(SkeletonText(text: "1. Start scanner on both devices")))
        checklistIntro.append(.Text(SkeletonText(text: "2. Check capabilities: precision should be uwb on supported iPhone pairs, otherwise multipeer-only")))
        checklistIntro.append(.Text(SkeletonText(text: "3. Wait for scanner.found and invite the peer")))
        checklistIntro.append(.Text(SkeletonText(text: "4. Send request contact from one side, accept on the other")))
        checklistIntro.append(.Text(SkeletonText(text: "5. Confirm scanner.encounter.saved and a stored encounter row with verified signatures")))
        checklistElements.append(.Section(SkeletonSection(
            header: .Text(SkeletonText(text: "Steps")),
            content: checklistIntro
        )))

        var checklistCapabilitiesReference = SkeletonCellReference(keypath: "scanner", topic: "scanner.capabilities")
        var checklistCapabilitiesElements = SkeletonElementList()
        checklistCapabilitiesElements.append(.Text(SkeletonText(text: "Capabilities")))
        checklistCapabilitiesElements.append(.Text(SkeletonText(keypath: "transportMode")))
        checklistCapabilitiesElements.append(.Text(SkeletonText(keypath: "precisionMode")))
        checklistCapabilitiesElements.append(.Text(SkeletonText(keypath: "description")))
        checklistCapabilitiesReference.flowElementSkeleton = SkeletonVStack(elements: checklistCapabilitiesElements)

        var checklistFoundReference = SkeletonCellReference(keypath: "scanner", topic: "scanner.found")
        var checklistFoundElements = SkeletonElementList()
        checklistFoundElements.append(.Text(SkeletonText(text: "Found peer")))
        checklistFoundElements.append(.Text(SkeletonText(keypath: "displayName")))
        checklistFoundElements.append(.Text(SkeletonText(keypath: "remoteUUID")))
        checklistFoundElements.append(.Button(SkeletonButton(keypath: "invite", label: "invite")))
        checklistFoundElements.append(.Button(SkeletonButton(keypath: "requestContact", label: "request contact")))
        checklistFoundReference.flowElementSkeleton = SkeletonVStack(elements: checklistFoundElements)

        var checklistIncomingReference = SkeletonCellReference(keypath: "scanner", topic: "scanner.contact.received")
        var checklistIncomingElements = SkeletonElementList()
        checklistIncomingElements.append(.Text(SkeletonText(text: "Incoming contact")))
        checklistIncomingElements.append(.Text(SkeletonText(keypath: "requesterDisplayName")))
        checklistIncomingElements.append(.Text(SkeletonText(keypath: "verification.status")))
        checklistIncomingElements.append(.Button(SkeletonButton(keypath: "acceptContact", label: "accept")))
        checklistIncomingReference.flowElementSkeleton = SkeletonVStack(elements: checklistIncomingElements)

        var checklistSavedReference = SkeletonCellReference(keypath: "scanner", topic: "scanner.encounter.saved")
        var checklistSavedElements = SkeletonElementList()
        checklistSavedElements.append(.Text(SkeletonText(text: "Saved encounter")))
        checklistSavedElements.append(.Text(SkeletonText(keypath: "remoteDisplayName")))
        checklistSavedElements.append(.Text(SkeletonText(keypath: "requestVerification.status")))
        checklistSavedElements.append(.Text(SkeletonText(keypath: "acceptanceVerification.status")))
        checklistSavedElements.append(.Text(SkeletonText(keypath: "precisionMode")))
        checklistSavedReference.flowElementSkeleton = SkeletonVStack(elements: checklistSavedElements)

        var checklistExportedReference = SkeletonCellReference(keypath: "scanner", topic: "scanner.encounter.exported")
        var checklistExportedElements = SkeletonElementList()
        checklistExportedElements.append(.Text(SkeletonText(text: "Exported encounter")))
        checklistExportedElements.append(.Text(SkeletonText(keypath: "remoteDisplayName")))
        checklistExportedElements.append(.Text(SkeletonText(keypath: "encounterId")))
        checklistExportedElements.append(.Text(SkeletonText(keypath: "requestProof")))
        checklistExportedReference.flowElementSkeleton = SkeletonVStack(elements: checklistExportedElements)

        var checklistExportedJSONReference = SkeletonCellReference(keypath: "scanner", topic: "scanner.encounter.jsonExported")
        var checklistExportedJSONElements = SkeletonElementList()
        checklistExportedJSONElements.append(.Text(SkeletonText(text: "Encounter JSON")))
        checklistExportedJSONElements.append(.Text(SkeletonText(keypath: "fileName")))
        checklistExportedJSONElements.append(.Text(SkeletonText(keypath: "copiedToClipboard")))
        checklistExportedJSONElements.append(.Text(SkeletonText(keypath: "json")))
        checklistExportedJSONReference.flowElementSkeleton = SkeletonVStack(elements: checklistExportedJSONElements)

        var checklistLiveSection = SkeletonElementList()
        checklistLiveSection.append(.Reference(checklistCapabilitiesReference))
        checklistLiveSection.append(.Reference(checklistFoundReference))
        checklistLiveSection.append(.Reference(checklistIncomingReference))
        checklistLiveSection.append(.Reference(checklistSavedReference))
        checklistLiveSection.append(.Reference(checklistExportedReference))
        checklistLiveSection.append(.Reference(checklistExportedJSONReference))
        checklistElements.append(.Section(SkeletonSection(
            header: .Text(SkeletonText(text: "Live checkpoints")),
            content: checklistLiveSection
        )))

        var checklistEncounterList = SkeletonList(keypath: "scanner.encounters")
        var checklistEncounterRow = SkeletonElementList()
        checklistEncounterRow.append(.Text(SkeletonText(text: "Encounter row")))
        checklistEncounterRow.append(.Text(SkeletonText(keypath: "remoteDisplayName")))
        checklistEncounterRow.append(.Text(SkeletonText(keypath: "matchCount")))
        checklistEncounterRow.append(.Text(SkeletonText(keypath: "requestVerification.status")))
        checklistEncounterRow.append(.Text(SkeletonText(keypath: "acceptanceVerification.status")))
        checklistEncounterRow.append(.Button(SkeletonButton(keypath: "exportEncounter", label: "export")))
        checklistEncounterRow.append(.Button(SkeletonButton(keypath: "exportEncounterJSON", label: "copy json")))
        checklistEncounterList.flowElementSkeleton = SkeletonVStack(elements: checklistEncounterRow)

        var checklistStoredSection = SkeletonElementList()
        checklistStoredSection.append(.Button(SkeletonButton(
            keypath: "proofs.encounters",
            label: "clear encounter proofs",
            url: "cell:///EntityAnchor",
            payload: .object(Object())
        )))
        checklistStoredSection.append(.List(checklistEncounterList))
        checklistElements.append(.Section(SkeletonSection(
            header: .Text(SkeletonText(text: "Stored verification")),
            content: checklistStoredSection
        )))

        configurationEntityScannerChecklist.skeleton = .VStack(SkeletonVStack(elements: checklistElements))
        configurations.append(configurationEntityScannerChecklist)
        
        // Test Purposes Cell (is going to be loaded based on current Purpose - which is starting with filling perspective withh purposes)
        
        var configuration3 = CellConfiguration(name: "Purposes")
        var connectPurposesReference = CellReference(endpoint: "cell:///Purposes", label: "purposes")
        
//        connectPurposesReference.addKeyAndValue( KeyValue(key: "state", target: "") )
        configuration3.addReference(connectPurposesReference)
        
        var elementListPurposes = SkeletonElementList()
        
        let skeletonPurposeTitleText = SkeletonText(text: "Purposes")
        elementListPurposes.append(.Text(skeletonPurposeTitleText))
        
        var purposesList = SkeletonList(topic: "purpose", keypath: "purposes.state") // Keypath is relative to porthole
        
        // Insert flow element skeleton here
        var flowElementsPurposes = SkeletonElementList()
        flowElementsPurposes.append(.Text(SkeletonText(keypath: "payload.name")))
        flowElementsPurposes.append(.Text(SkeletonText(keypath: "payload.description")))
        
        let addButton = SkeletonButton(keypath: "purposes.addPurpose", label: "Add") // First test with add pointing to local cell - PurposesCell - Test another pointing to PerspectiveCell
        flowElementsPurposes.append(.Button(addButton))
        
        let addButton2 = SkeletonButton(keypath: "cell://Perspective/addPurpose", label: "Add2")
        flowElementsPurposes.append(.Button(addButton2))
        
        let  vstackPurposes = SkeletonVStack(elements: flowElementsPurposes)
        purposesList.flowElementSkeleton = vstackPurposes
        
        //...
        
        
        elementListPurposes.append(.List(purposesList))
        
        configuration3.skeleton = .VStack(SkeletonVStack(elements: elementListPurposes))
        configurations.append(configuration3)
        
        do {
            let jsonData = try JSONEncoder().encode(configuration2)
            print(String(data: jsonData, encoding: .utf8) ?? "failed...")
            
        } catch {
            print("json dump failed with error: \(error)")
        }
        
        return configurations
    }
}
