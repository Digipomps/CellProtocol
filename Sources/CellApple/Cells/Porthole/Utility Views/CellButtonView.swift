// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  CellButtonView.swift
//  HAVEN_MVP
//
//  Created by Kjetil Hustveit on 20/11/2024.
//

import SwiftUI
import CellBase

struct CellButtonView: View {
    let skeletonButton: SkeletonButton
    let userInfoValue: ValueType?
    @Binding var responseValue: ValueType?
    @EnvironmentObject var viewModel: PortholeViewModel

    var body: some View {
        Button(buttonLabel) {
            executeSkeletonButton(skeletonButton)
        }
        .disabled(feedbackState == .working)
        .opacity(feedbackState == .working ? 0.86 : 1.0)
        .accessibilityValue(accessibilityValue)
    }

    private var actionID: String {
        skeletonButton.id.uuidString
    }

    private var feedbackState: PortholeViewModel.ActionFeedbackState {
        viewModel.actionFeedbackState(for: actionID)
    }

    private var buttonLabel: String {
        switch feedbackState {
        case .working:
            return "\(skeletonButton.label) …"
        case .succeeded:
            return "✓ \(skeletonButton.label)"
        case .failed:
            return "⚠︎ \(skeletonButton.label)"
        case .idle:
            return skeletonButton.label
        }
    }

    private var accessibilityValue: String {
        switch feedbackState {
        case .idle:
            return "Idle"
        case .working:
            return "Working"
        case .succeeded:
            return "Completed"
        case .failed:
            return "Failed"
        }
    }

    func executeSkeletonButton(_ skeletonButton: SkeletonButton) {
        Task {
            await MainActor.run {
                viewModel.setActionFeedbackState(.working, for: actionID)
            }
            let requester = await viewModel.executionRequesterIdentity()
            responseValue = await extractPropertiesFromUserInfo(skeletonButton: skeletonButton).execute(requester: requester)
            await MainActor.run {
                viewModel.markLocalMutation()
                viewModel.setActionFeedbackState(responseValue == nil ? .failed : .succeeded, for: actionID)
            }
            if responseValue != nil {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                await MainActor.run {
                    if viewModel.actionFeedbackState(for: actionID) == .succeeded {
                        viewModel.clearActionFeedbackState(for: actionID)
                    }
                }
            }
        }
    }

    func extractPropertiesFromUserInfo(skeletonButton: SkeletonButton) -> SkeletonButton {
        var localSkeletonButton = skeletonButton
        guard case let .object(object)? = userInfoValue else {
            return localSkeletonButton
        }

        let sources = [object, objectValue(from: object["content"])]
            .compactMap { $0 }

        let candidateKeys = [skeletonButton.keypath, skeletonButton.label]

        for source in sources {
            if let actions = objectValue(from: source["actions"]) {
                for candidate in candidateKeys where candidate.isEmpty == false {
                    if let actionObject = objectValue(from: actions[candidate]) {
                        applyProperties(from: actionObject, to: &localSkeletonButton)
                        return localSkeletonButton
                    }
                }
            }
        }

        for source in sources {
            applyProperties(from: source, to: &localSkeletonButton)
        }
        return localSkeletonButton
    }

    private func applyProperties(from object: Object, to skeletonButton: inout SkeletonButton) {
        if let urlValue = object["url"],
           case let .string(urlString) = urlValue {
            skeletonButton.url = urlString
        }
        if let keypathValue = object["keypath"],
           case let .string(keypathString) = keypathValue {
            skeletonButton.keypath = keypathString
        }
        if let payloadValue = object["payload"] {
            skeletonButton.payload = payloadValue
        }
        if let labelValue = object["label"],
           case let .string(labelString) = labelValue {
            skeletonButton.label = labelString
        }
    }

    private func objectValue(from value: ValueType?) -> Object? {
        guard let value, case let .object(object) = value else {
            return nil
        }
        return object
    }
}
