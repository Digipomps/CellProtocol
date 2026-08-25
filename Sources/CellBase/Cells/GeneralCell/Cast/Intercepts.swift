// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  File.swift
//  
//
//  Created by Kjetil Hustveit on 26/11/2022.
//

import Foundation

public typealias FlowElementIntercept = ((FlowElement, Identity) async -> FlowElement?)

/// Som FlowElementIntercept, men far ogsaa labelen elementet ankom paa.
/// Labelen er allerede i skop paa dispatch-stedet; for denne endringen ble den
/// kastet. Uten den kan en handtering ikke vite hvilken referanse som fyrte, og
/// da kan den heller ikke velge riktig malelement.
///
/// Kontrakt: en handtering som fanger [weak self] MAA returnere elementet
/// uendret naar self er borte - aldri nil. nil betyr svelg, og et dodt handtak
/// ville da spist flyten permanent og stille.
public typealias LabelledFlowElementIntercept = ((FlowElement, String, Identity) async -> FlowElement?)
public typealias SetValueForKeyIntercept = ((ValueType, Identity) async -> Void)
public typealias ValueForKeyIntercept = ((Identity) async -> (ValueType))

public typealias SetValueIntercept = ((String, ValueType, Identity) async throws -> ValueType?)
public typealias GetValueIntercept = (( String, Identity) async throws -> (ValueType))

actor Intercepts {
    var feedIntercept: FlowElementIntercept?
    /// Topic-register. Keypaths har hatt ordbok hele tiden; flow hadde bare en
    /// enkelt closure, som tvang hver mottaker til aa skrive sin egen
    /// `if topic ==`-kjede. Se ScaffoldOrchestratorCell og dens TODO.
    var feedInterceptsByTopic: [String : LabelledFlowElementIntercept] = [:]
    var interceptSetValueForKeys: [String : SetValueForKeyIntercept] = [:]
    var interceptValueForKeys: [String : ValueForKeyIntercept] = [:]
    
    var interceptSetValueForKeypaths: [String : SetValueIntercept] = [:]
    var interceptValueForKeypaths: [String : GetValueIntercept] = [:]
    
    func storeFeedIntercept(_ intercept: @escaping FlowElementIntercept) {
        feedIntercept = intercept
    }

    /// Nekter aa overskrive. To subsystemer som begge tar "consent" skal
    /// oppdage det ved registrering, ikke ved at det ene slutter aa virke.
    func storeFeedIntercept(topic: String, _ intercept: @escaping LabelledFlowElementIntercept) -> Bool {
        guard feedInterceptsByTopic[topic] == nil else {
            CellBase.diagnosticLog(
                "topic_intercept_collision topic=\(topic) - registrering avvist, eksisterende beholdt",
                domain: .flow)
            return false
        }
        feedInterceptsByTopic[topic] = intercept
        return true
    }

    /// Eksakt treff, sa lengste "prefix.*", sa "*". Produsentene bruker
    /// allerede punktnavnerom: agreement.engagement, connect.challenge.
    func resolveFeedIntercept(topic: String) -> LabelledFlowElementIntercept? {
        if let exact = feedInterceptsByTopic[topic] { return exact }
        var best: (key: String, handler: LabelledFlowElementIntercept)?
        for (key, handler) in feedInterceptsByTopic where key.hasSuffix(".*") {
            let prefix = String(key.dropLast(1))
            guard topic.hasPrefix(prefix) else { continue }
            if best == nil || key.count > best!.key.count {
                best = (key, handler)
            }
        }
        if let best { return best.handler }
        return feedInterceptsByTopic["*"]
    }

    func hasTopicIntercepts() -> Bool {
        feedInterceptsByTopic.isEmpty == false
    }
    func loadFeedIntercept() -> FlowElementIntercept? {
        return feedIntercept
    }

    func storeInterceptValueForKey(key: String, intercept: @escaping ValueForKeyIntercept) {
        interceptValueForKeys[key] = intercept
    }
    func loadInterceptValueForKey(key: String) -> ValueForKeyIntercept? {
        return interceptValueForKeys[key]
    }
    func storeInterceptSetValueForKey(key: String, intercept: @escaping SetValueForKeyIntercept) {
        interceptSetValueForKeys[key] = intercept
    }
    func loadInterceptSetValueForKey(key: String) -> SetValueForKeyIntercept? {
        return interceptSetValueForKeys[key]
    }
    
    // Keypath lookup
    func storeInterceptGet(keypath: String, intercept: @escaping GetValueIntercept) {
        interceptValueForKeypaths[keypath] = intercept
    }
    func loadInterceptGet(keypath: String) -> GetValueIntercept? {
        return interceptValueForKeypaths[keypath]
    }
    func storeInterceptSet(keypath: String, intercept: @escaping SetValueIntercept) {
        interceptSetValueForKeypaths[keypath] = intercept
    }
    func loadInterceptSet(keypath: String) -> SetValueIntercept? {
        return interceptSetValueForKeypaths[keypath]
    }
}
