import Foundation

/// One portable Skeleton for both web and Binding. User overrides derive from
/// this configuration; the host must never replace it with a platform-only UI.
public enum MeetingSurfaceConfiguration {
    public static let skeletonJSON = #"""
    {
      "VStack": {
        "elements": [
          {
            "Text": {
              "modifiers": {
                "fontSize": 12,
                "fontWeight": "semibold",
                "foregroundColor": "#626B60",
                "lineHeightMultiple": 1.25
              },
              "text": "PRIVAT MØTE"
            }
          },
          {
            "Text": {
              "keypath": "meeting.state.title",
              "modifiers": {
                "fontSize": 28,
                "fontWeight": "bold",
                "foregroundColor": "#292D29",
                "lineHeightMultiple": 1.25
              }
            }
          },
          {
            "Text": {
              "keypath": "meeting.state.notice",
              "modifiers": {
                "fontSize": 16,
                "fontWeight": "semibold",
                "foregroundColor": "#98382F",
                "lineHeightMultiple": 1.25
              }
            }
          },
          {
            "List": {
              "elements": [],
              "flowElementSkeleton": {
                "VStack": {
                  "elements": [
                    {
                      "Button": {
                        "icon": "xmark.circle",
                        "keypath": "",
                        "keypathKeypath": "keypath",
                        "label": "",
                        "labelKeypath": "label",
                        "modifiers": {
                          "background": "#98382F",
                          "cornerRadius": 10,
                          "fontSize": 18,
                          "fontWeight": "semibold",
                          "foregroundColor": "#FFFFFF",
                          "hAlignment": "leading",
                          "maxWidthInfinity": false,
                          "minHeight": 44,
                          "multilineTextAlignment": "leading",
                          "padding": 12,
                          "width": 300
                        },
                        "payloadKeypath": "payload"
                      }
                    }
                  ],
                  "modifiers": {
                    "hAlignment": "leading",
                    "maxWidthInfinity": true
                  },
                  "spacing": 0
                }
              },
              "keypath": "meeting.state.stopOnlyActions",
              "modifiers": {
                "maxWidthInfinity": true,
                "rowDecoration": "none"
              }
            }
          },
          {
            "List": {
              "elements": [],
              "flowElementSkeleton": {
                "VStack": {
                  "elements": [
                    {
                      "Button": {
                        "icon": "plus",
                        "keypath": "",
                        "keypathKeypath": "keypath",
                        "label": "",
                        "labelKeypath": "label",
                        "modifiers": {
                          "background": "#E5EBDD",
                          "cornerRadius": 10,
                          "fontSize": 18,
                          "fontWeight": "semibold",
                          "foregroundColor": "#384938",
                          "hAlignment": "leading",
                          "maxWidthInfinity": false,
                          "minHeight": 44,
                          "multilineTextAlignment": "leading",
                          "padding": 12,
                          "width": 300
                        },
                        "payloadKeypath": "payload"
                      }
                    }
                  ],
                  "modifiers": {
                    "hAlignment": "leading",
                    "maxWidthInfinity": true
                  },
                  "spacing": 0
                }
              },
              "keypath": "meeting.state.newParticipantActions",
              "modifiers": {
                "maxWidthInfinity": true,
                "rowDecoration": "none"
              }
            }
          },
          {
            "HStack": {
              "elements": [
                {
                  "VStack": {
                    "elements": [
                      {
                        "Text": {
                          "modifiers": {
                            "fontSize": 18,
                            "fontWeight": "semibold",
                            "foregroundColor": "#292D29",
                            "lineHeightMultiple": 1.25
                          },
                          "text": "Møteplan"
                        }
                      },
                      {
                        "Text": {
                          "keypath": "meeting.state.purpose",
                          "modifiers": {
                            "fontSize": 20,
                            "fontWeight": "semibold",
                            "foregroundColor": "#292D29",
                            "lineHeightMultiple": 1.25
                          }
                        }
                      },
                      {
                        "Text": {
                          "keypath": "meeting.state.captureTerms",
                          "modifiers": {
                            "fontSize": 15,
                            "fontWeight": "regular",
                            "foregroundColor": "#292D29",
                            "lineHeightMultiple": 1.25
                          }
                        }
                      },
                      {
                        "Text": {
                          "keypath": "meeting.state.deliveryTerms",
                          "modifiers": {
                            "fontSize": 15,
                            "fontWeight": "regular",
                            "foregroundColor": "#292D29",
                            "lineHeightMultiple": 1.25
                          }
                        }
                      },
                      {
                        "Text": {
                          "keypath": "meeting.state.retentionTerms",
                          "modifiers": {
                            "fontSize": 14,
                            "fontWeight": "regular",
                            "foregroundColor": "#626B60",
                            "lineHeightMultiple": 1.25
                          }
                        }
                      }
                    ],
                    "modifiers": {
                      "background": "#FFFFFF",
                      "cornerRadius": 12,
                      "hAlignment": "leading",
                      "maxWidthInfinity": true,
                      "padding": 18,
                      "flexGrow": 1
                    },
                    "spacing": 12
                  }
                },
                {
                  "VStack": {
                    "elements": [
                      {
                        "Text": {
                          "modifiers": {
                            "fontSize": 18,
                            "fontWeight": "semibold",
                            "foregroundColor": "#292D29",
                            "lineHeightMultiple": 1.25
                          },
                          "text": "Deltakere"
                        }
                      },
                      {
                        "List": {
                          "keypath": "meeting.state.participants",
                          "flowElementSkeleton": {
                            "VStack": {
                              "spacing": 2,
                              "elements": [
                                {
                                  "Text": {
                                    "keypath": "name",
                                    "modifiers": {
                                      "fontSize": 16,
                                      "fontWeight": "semibold",
                                      "foregroundColor": "#292D29",
                                      "lineHeightMultiple": 1.25
                                    }
                                  }
                                },
                                {
                                  "Text": {
                                    "keypath": "status",
                                    "modifiers": {
                                      "fontSize": 14,
                                      "fontWeight": "regular",
                                      "foregroundColor": "#626B60",
                                      "lineHeightMultiple": 1.25
                                    }
                                  }
                                }
                              ],
                              "modifiers": {
                                "padding": 8,
                                "background": "#F5F2E9",
                                "cornerRadius": 10,
                                "maxWidthInfinity": true,
                                "hAlignment": "leading"
                              }
                            }
                          },
                          "modifiers": {
                            "rowDecoration": "none",
                            "maxWidthInfinity": true
                          }
                        }
                      },
                      {
                        "Text": {
                          "modifiers": {
                            "fontSize": 14,
                            "fontWeight": "regular",
                            "foregroundColor": "#626B60",
                            "lineHeightMultiple": 1.25
                          },
                          "text": "Alle på listen får transkript og tillitspakke."
                        }
                      }
                    ],
                    "modifiers": {
                      "background": "#FFFFFF",
                      "cornerRadius": 12,
                      "hAlignment": "leading",
                      "maxWidthInfinity": true,
                      "padding": 18,
                      "flexGrow": 1
                    },
                    "spacing": 12
                  }
                }
              ],
              "modifiers": {
                "layoutVariants": [
                  {
                    "axis": "vertical",
                    "maxAvailableWidth": 700
                  }
                ],
                "vAlignment": "top",
                "maxWidthInfinity": true
              },
              "spacing": 16
            }
          },
          {
            "Text": {
              "modifiers": {
                "fontSize": 14,
                "fontWeight": "regular",
                "foregroundColor": "#626B60",
                "lineHeightMultiple": 1.25
              },
              "text": "Ny deltaker eller endret plan → alle godkjenner på nytt. Alle kan stoppe."
            }
          },
          {
            "HStack": {
              "elements": [
                {
                  "List": {
                    "elements": [],
                    "flowElementSkeleton": {
                      "VStack": {
                        "elements": [
                          {
                            "Button": {
                              "icon": "checkmark",
                              "keypath": "",
                              "keypathKeypath": "keypath",
                              "label": "",
                              "labelKeypath": "label",
                              "modifiers": {
                                "background": "#384938",
                                "cornerRadius": 10,
                                "fontSize": 18,
                                "fontWeight": "semibold",
                                "foregroundColor": "#FFFFFF",
                                "hAlignment": "leading",
                                "maxWidthInfinity": false,
                                "minHeight": 44,
                                "multilineTextAlignment": "leading",
                                "padding": 12,
                                "width": 300
                              },
                              "payloadKeypath": "payload"
                            }
                          }
                        ],
                        "modifiers": {
                          "hAlignment": "leading",
                          "maxWidthInfinity": true
                        },
                        "spacing": 0
                      }
                    },
                    "keypath": "meeting.state.approveActions",
                    "modifiers": {
                      "maxWidthInfinity": true,
                      "rowDecoration": "none"
                    }
                  }
                },
                {
                  "List": {
                    "elements": [],
                    "flowElementSkeleton": {
                      "VStack": {
                        "elements": [
                          {
                            "Button": {
                              "icon": "xmark",
                              "keypath": "",
                              "keypathKeypath": "keypath",
                              "label": "",
                              "labelKeypath": "label",
                              "modifiers": {
                                "background": "#E5EBDD",
                                "cornerRadius": 10,
                                "fontSize": 18,
                                "fontWeight": "semibold",
                                "foregroundColor": "#384938",
                                "hAlignment": "leading",
                                "maxWidthInfinity": false,
                                "minHeight": 44,
                                "multilineTextAlignment": "leading",
                                "padding": 12,
                                "width": 300
                              },
                              "payloadKeypath": "payload"
                            }
                          }
                        ],
                        "modifiers": {
                          "hAlignment": "leading",
                          "maxWidthInfinity": true
                        },
                        "spacing": 0
                      }
                    },
                    "keypath": "meeting.state.declineActions",
                    "modifiers": {
                      "maxWidthInfinity": true,
                      "rowDecoration": "none"
                    }
                  }
                }
              ],
              "modifiers": {
                "layoutVariants": [
                  {
                    "axis": "vertical",
                    "maxAvailableWidth": 500
                  }
                ]
              },
              "spacing": 12
            }
          },
          {
            "List": {
              "elements": [],
              "flowElementSkeleton": {
                "VStack": {
                  "elements": [
                    {
                      "Button": {
                        "icon": "xmark",
                        "keypath": "",
                        "keypathKeypath": "keypath",
                        "label": "",
                        "labelKeypath": "label",
                        "modifiers": {
                          "background": "#E5EBDD",
                          "cornerRadius": 10,
                          "fontSize": 18,
                          "fontWeight": "semibold",
                          "foregroundColor": "#384938",
                          "hAlignment": "leading",
                          "maxWidthInfinity": false,
                          "minHeight": 44,
                          "multilineTextAlignment": "leading",
                          "padding": 12,
                          "width": 300
                        },
                        "payloadKeypath": "payload"
                      }
                    }
                  ],
                  "modifiers": {
                    "hAlignment": "leading",
                    "maxWidthInfinity": true
                  },
                  "spacing": 0
                }
              },
              "keypath": "meeting.state.revokeActions",
              "modifiers": {
                "maxWidthInfinity": true,
                "rowDecoration": "none"
              }
            }
          },
          {
            "List": {
              "elements": [],
              "flowElementSkeleton": {
                "VStack": {
                  "elements": [
                    {
                      "Button": {
                        "icon": "checkmark.circle",
                        "keypath": "",
                        "keypathKeypath": "keypath",
                        "label": "",
                        "labelKeypath": "label",
                        "modifiers": {
                          "background": "#384938",
                          "cornerRadius": 10,
                          "fontSize": 18,
                          "fontWeight": "semibold",
                          "foregroundColor": "#FFFFFF",
                          "hAlignment": "leading",
                          "maxWidthInfinity": false,
                          "minHeight": 44,
                          "multilineTextAlignment": "leading",
                          "padding": 12,
                          "width": 300
                        },
                        "payloadKeypath": "payload"
                      }
                    }
                  ],
                  "modifiers": {
                    "hAlignment": "leading",
                    "maxWidthInfinity": true
                  },
                  "spacing": 0
                }
              },
              "keypath": "meeting.state.startActions",
              "modifiers": {
                "maxWidthInfinity": true,
                "rowDecoration": "none"
              }
            }
          },
          {
            "Button": {
              "icon": "bubble.left",
              "keypath": "addConfiguration",
              "label": "Hjelp i chat",
              "modifiers": {
                "background": "#E5EBDD",
                "cornerRadius": 10,
                "fontSize": 16,
                "foregroundColor": "#384938",
                "hAlignment": "leading",
                "maxWidthInfinity": false,
                "minHeight": 44,
                "multilineTextAlignment": "leading",
                "padding": 10,
                "width": 300
              },
              "payload": {
                "configurationLookup": {
                  "name": "Co-Pilot Chat",
                  "sourceCellEndpoint": "cell:///PersonalChatHub"
                }
              }
            }
          }
        ],
        "modifiers": {
          "background": "#F5F2E9",
          "hAlignment": "leading",
          "maxWidthInfinity": true,
          "padding": 24
        },
        "spacing": 14
      }
    }
    """#
    public static func make(endpoint: String) throws -> CellConfiguration {
        var configuration = CellConfiguration(name: "Privat møte", cellReferences: [CellReference(endpoint: endpoint, subscribeFeed: true, label: "meeting")])
        configuration.skeleton = try JSONDecoder().decode(SkeletonElement.self, from: Data(skeletonJSON.utf8))
        return configuration
    }
    public static func state(_ snapshot: MeetingConsentSnapshot, viewer: MeetingPrincipal, mediaAvailable: Bool) -> ValueType {
        let approved = Set(snapshot.approvals.filter { $0.plan == snapshot.reference }.map(\.participant))
        let count = approved.count; let total = snapshot.plan.participants.count
        let hasDecline = !snapshot.declined.isEmpty
        let active = snapshot.recording != nil
        func action(_ key: String, _ label: String) -> ValueType {
            .object(["keypath": .string("meeting." + key), "label": .string(label), "payload": encode(MeetingActionInput(expected: snapshot.reference))])
        }
        var actions: [ValueType] = []
        if !active && !hasDecline {
            if !approved.contains(viewer) {
                actions.append(action("consent.approve", "Godkjenn opptak"))
                actions.append(action("consent.decline", "Nei til opptak"))
            } else {
                actions.append(action("consent.revoke", "Trekk tilbake mitt ja"))
            }
            if count == total && viewer == snapshot.plan.recorder && mediaAvailable {
                actions.insert(action("recording.start", "Start opptak"), at: 0)
            }
        }
        func group(_ key: String) -> ValueType {
            .list(actions.filter {
                guard case let .object(row) = $0 else { return false }
                return row["keypath"] == .string("meeting." + key)
            })
        }
        let notice = active ? "Tar opp lyd · alle \(total) har godkjent plan \(snapshot.reference.revision)." :
            hasDecline ? "En deltaker har sagt nei. Mikrofonen er av." :
            "Mikrofonen er av · \(count) av \(total) har godkjent plan \(snapshot.reference.revision)." + (count == total && !mediaAvailable ? " Opptaksadapter er ikke tilgjengelig." : "")
        return .object([
            "title": .string(active ? "Opptak pågår" : hasDecline ? "Møte uten opptak" : snapshot.reference.revision > 1 ? "Ny godkjenning" : "Godkjenn opptak"),
            "notice": .string(notice),
            "purpose": .string(snapshot.plan.purpose),
            "captureTerms": .string("Opptaker: \(snapshot.plan.recorder.id) · Apple Speech på enheten · \(snapshot.plan.locale)"),
            "deliveryTerms": .string("Rålyd deles ikke. Slettes etter transkript, senest \(Int(snapshot.plan.rawAudioLifetime / 3600)) timer."),
            "retentionTerms": .string("Leveringskø: \(Int(snapshot.plan.deliveryLifetime / 86400)) dager · Mottakerkopi: \(Int(snapshot.plan.recipientLifetime / 86400)) dager"),
            "participants": .list(snapshot.plan.participants.map { p in .object([
                "name": .string(p.id + (p == viewer ? " · deg" : "")),
                "status": .string(snapshot.declined.contains(p) ? "Avslått" : approved.contains(p) ? "Godkjent" : "Venter")
            ]) }),
            "approveActions": group("consent.approve"),
            "declineActions": group("consent.decline"),
            "revokeActions": group("consent.revoke"),
            "startActions": group("recording.start"),
            "stopOnlyActions": .list(active ? [action("recording.stop", "Stopp opptak")] : []),
            "newParticipantActions": .list(active ? [action("recording.stop", "Ny deltaker · stopp")] : []),
            "actions": .list(actions),
            "stopActions": .list(active ? [action("recording.stop", "Stopp opptak"), action("recording.stop", "Ny deltaker – stopp først")] : [])
        ])
    }
    static func encode<T: Encodable>(_ input: T) -> ValueType {
        guard let bytes = try? JSONEncoder().encode(input), let value = try? JSONDecoder().decode(ValueType.self, from: bytes) else { return .null }
        return value
    }
}
