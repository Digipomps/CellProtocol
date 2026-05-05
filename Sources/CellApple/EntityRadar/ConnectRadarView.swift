// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  ConnectRadarView.swift
//  HAVEN_MVP
//
//  Created by Kjetil Hustveit on 25/09/2024.
//
import Foundation
import SwiftUI

public struct ConnectRadarView: View {
    @StateObject private var viewModel = RadarViewModel()
    @State private var pulseDots = false

    public init() {}

    public var body: some View {
        VStack(spacing: 16) {
            header
            radarCanvas
            controls
            entitiesList
        }
        .padding(20)
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0.94), Color(red: 0.03, green: 0.09, blue: 0.10)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .task {
            await viewModel.connectIfNeeded()
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                pulseDots = true
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Entity Radar")
                    .font(.title2.weight(.bold))
                Text("Status: \(viewModel.scannerStatus)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Text("\(viewModel.entities.count)")
                .font(.title3.monospacedDigit().weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.08), in: Capsule())
        }
        .foregroundColor(.white)
    }

    private var radarCanvas: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let radius = side * 0.46
            let center = CGPoint(x: geometry.size.width / 2.0, y: geometry.size.height / 2.0)

            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color(red: 0.02, green: 0.17, blue: 0.13).opacity(0.85),
                                Color(red: 0.01, green: 0.07, blue: 0.06)
                            ],
                            center: .center,
                            startRadius: 10,
                            endRadius: side * 0.50
                        )
                    )

                RadarGridBackground()

                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
                    let period = 3.8
                    let phase = context.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: period) / period
                    RadarSweepShape(angle: .radians(phase * 2.0 * .pi))
                        .fill(
                            LinearGradient(
                                colors: [Color.green.opacity(0.38), Color.green.opacity(0.0)],
                                startPoint: .center,
                                endPoint: .trailing
                            )
                        )
                        .blur(radius: 1.4)
                        .clipShape(Circle())
                }

                Circle()
                    .stroke(Color.green.opacity(0.35), lineWidth: 1)

                ForEach(viewModel.entities) { entity in
                    entityDot(entity, center: center, radius: radius)
                }

                Circle()
                    .fill(Color.green.opacity(0.92))
                    .frame(width: 9, height: 9)
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.7), lineWidth: 1)
                    )
                    .shadow(color: Color.green.opacity(0.55), radius: 6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minHeight: 250, maxHeight: 340)
    }

    private func entityDot(_ entity: NearbyEntity, center: CGPoint, radius: CGFloat) -> some View {
        let xPosition = center.x + CGFloat(entity.radarXNormalized) * radius
        let yPosition = center.y - CGFloat(entity.radarYNormalized) * radius
        let markerColor = entity.connected ? Color.green : Color.cyan
        let markerSize: CGFloat = entity.connected ? 16 : 12

        return VStack(spacing: 4) {
            Circle()
                .fill(markerColor)
                .frame(width: markerSize, height: markerSize)
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.75), lineWidth: 1)
                )
                .shadow(color: markerColor.opacity(0.55), radius: 6)
                .scaleEffect(pulseDots ? 1.05 : 0.90)

            Text(entity.displayName)
                .font(.caption2)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.black.opacity(0.28), in: Capsule())
                .foregroundColor(.white.opacity(0.95))
        }
        .position(x: xPosition, y: yPosition)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button("Start") {
                Task {
                    await viewModel.startScanning()
                }
            }
            .buttonStyle(.borderedProminent)

            Button("Stop") {
                Task {
                    await viewModel.stopScanning()
                }
            }
            .buttonStyle(.bordered)

            Spacer()

            Text("Connected: \(viewModel.connectedDevices.count)")
                .font(.caption.monospacedDigit())
                .foregroundColor(.white.opacity(0.85))
        }
    }

    private var entitiesList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Nearby Entities")
                .font(.headline)
                .foregroundColor(.white)

            if viewModel.entities.isEmpty {
                Text("No entities discovered yet.")
                    .font(.footnote)
                    .foregroundColor(.white.opacity(0.68))
                    .padding(.vertical, 6)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(viewModel.entities) { entity in
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entity.displayName)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundColor(.white)
                                    Text(entity.status)
                                        .font(.caption)
                                        .foregroundColor(.white.opacity(0.70))
                                }

                                Spacer()

                                Text(distanceText(for: entity.distanceMeters))
                                    .font(.caption.monospacedDigit())
                                    .foregroundColor(.white.opacity(0.85))

                                Button("Invite") {
                                    Task {
                                        await viewModel.invite(remoteUUID: entity.remoteUUID)
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
                .frame(maxHeight: 180)
            }

            if let lastError = viewModel.lastError, !lastError.isEmpty {
                Text(lastError)
                    .font(.caption)
                    .foregroundColor(.orange.opacity(0.95))
            }
        }
    }

    private func distanceText(for distance: Double?) -> String {
        guard let distance else {
            return "-- m"
        }
        return String(format: "%.2f m", distance)
    }
}

private struct RadarGridBackground: View {
    var body: some View {
        ZStack {
            ForEach([0.22, 0.44, 0.66, 0.88], id: \.self) { ring in
                Circle()
                    .stroke(Color.green.opacity(0.24), lineWidth: 1)
                    .padding(CGFloat(30.0 * ring))
            }
            Rectangle()
                .fill(Color.clear)
                .overlay(Rectangle().stroke(Color.green.opacity(0.18), lineWidth: 1))
                .rotationEffect(.degrees(0))
                .padding(8)
            Rectangle()
                .fill(Color.clear)
                .overlay(Rectangle().stroke(Color.green.opacity(0.18), lineWidth: 1))
                .rotationEffect(.degrees(90))
                .padding(8)
        }
    }
}

private struct RadarSweepShape: Shape {
    var angle: Angle
    var width: Angle = .degrees(32)

    var animatableData: Double {
        get { angle.radians }
        set { angle = .radians(newValue) }
    }

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) * 0.5
        let halfWidth = Angle.radians(width.radians / 2.0)
        let start = angle - halfWidth
        let end = angle + halfWidth

        var path = Path()
        path.move(to: center)
        path.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
        path.closeSubpath()
        return path
    }
}

#Preview {
    ConnectRadarView()
}
