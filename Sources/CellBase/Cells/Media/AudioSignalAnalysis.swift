// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

/// Deterministic layer-one audio measurements plus the flags needed to avoid
/// presenting ambiguous measurements as settled facts.
public struct AudioSignalAnalysis: Codable, Equatable, Sendable {
    public let durationSeconds: Double
    public let codec: String
    public let sampleRate: Int
    public let channels: Int
    public let bitRate: Int
    public let tempoBPM: Double
    public let tempoOctaveAmbiguous: Bool
    public let keyEstimate: String
    public let keyCorrelation: Double
    public let keySettled: Bool
    public let rmsMeanDBFS: Double
    public let peakDBFS: Double
    public let limitedAtCeiling: Bool
    public let dynamicsStdDB: Double
    public let spectralCentroidHz: Double
    public let onsetDensityPerSecond: Double
    public let segmentBoundariesSeconds: [Double]
    public let metadataProducer: AudioAnalysisProducer
    public let signalProducer: AudioAnalysisProducer

    public func makeRecord(contentHash: String, computedAt: String) throws -> AudioAnalysisRecord {
        func computed(
            _ value: AudioAnalysisValue,
            producer: AudioAnalysisProducer
        ) -> AudioAnalysisFieldInput {
            AudioAnalysisFieldInput(
                value: value,
                tier: .computed,
                producer: producer,
                computedAt: computedAt
            )
        }

        return try AudioAnalysisRecord(
            contentHash: contentHash,
            fields: [
                "durationSeconds": computed(.double(durationSeconds), producer: metadataProducer),
                "codec": computed(.string(codec), producer: metadataProducer),
                "sampleRate": computed(.integer(sampleRate), producer: metadataProducer),
                "channels": computed(.integer(channels), producer: metadataProducer),
                "bitRate": computed(.integer(bitRate), producer: metadataProducer),
                "tempoBPM": computed(.double(tempoBPM), producer: signalProducer),
                "tempoOctaveAmbiguous": computed(.boolean(tempoOctaveAmbiguous), producer: signalProducer),
                "keyEstimate": computed(.string(keyEstimate), producer: signalProducer),
                "keyCorrelation": computed(.double(keyCorrelation), producer: signalProducer),
                "keySettled": computed(.boolean(keySettled), producer: signalProducer),
                "rmsMeanDBFS": computed(.double(rmsMeanDBFS), producer: signalProducer),
                "peakDBFS": computed(.double(peakDBFS), producer: signalProducer),
                "limitedAtCeiling": computed(.boolean(limitedAtCeiling), producer: signalProducer),
                "dynamicsStdDB": computed(.double(dynamicsStdDB), producer: signalProducer),
                "spectralCentroidHz": computed(.double(spectralCentroidHz), producer: signalProducer),
                "onsetDensityPerSecond": computed(.double(onsetDensityPerSecond), producer: signalProducer),
                "segmentBoundariesSeconds": computed(
                    .array(segmentBoundariesSeconds.map(AudioAnalysisValue.double)),
                    producer: signalProducer
                )
            ]
        )
    }
}

public enum AudioSignalAnalyzerError: Error, Equatable, Sendable {
    case nonFileURL(String)
    case fileNotFound(String)
    case unsupportedPlatform
    case commandLaunchFailed(tool: String, message: String)
    case commandFailed(tool: String, status: Int32, message: String)
    case malformedOutput(tool: String, message: String)
}

/// Offline v0 signal analyzer. It invokes only local executables and refuses
/// non-file URLs, so this layer cannot send audio to a provider.
public struct AudioSignalAnalyzer: Sendable {
    public let ffprobeExecutable: String
    public let ffmpegExecutable: String
    public let pythonExecutable: String

    public init(
        ffprobeExecutable: String = "ffprobe",
        ffmpegExecutable: String = "ffmpeg",
        pythonExecutable: String = "python3"
    ) {
        self.ffprobeExecutable = ffprobeExecutable
        self.ffmpegExecutable = ffmpegExecutable
        self.pythonExecutable = pythonExecutable
    }

    public func analyze(fileURL: URL) throws -> AudioSignalAnalysis {
        guard fileURL.isFileURL else {
            throw AudioSignalAnalyzerError.nonFileURL(fileURL.absoluteString)
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw AudioSignalAnalyzerError.fileNotFound(fileURL.path)
        }

        #if os(macOS) || os(Linux)
        let metadataData = try run(
            tool: ffprobeExecutable,
            arguments: [
                "-v", "error",
                "-select_streams", "a:0",
                "-show_entries", "format=duration,bit_rate:stream=codec_name,sample_rate,channels,bit_rate",
                "-of", "json",
                fileURL.path
            ]
        )

        let metadata: FFProbeOutput
        do {
            metadata = try JSONDecoder().decode(FFProbeOutput.self, from: metadataData)
        } catch {
            throw AudioSignalAnalyzerError.malformedOutput(
                tool: ffprobeExecutable,
                message: error.localizedDescription
            )
        }

        guard let stream = metadata.streams.first,
              let duration = Double(metadata.format.duration),
              let sampleRate = Int(stream.sampleRate),
              let bitRate = Int(stream.bitRate ?? metadata.format.bitRate ?? "") else {
            throw AudioSignalAnalyzerError.malformedOutput(
                tool: ffprobeExecutable,
                message: "Missing or invalid audio stream metadata"
            )
        }

        let dspData = try run(
            tool: pythonExecutable,
            arguments: [
                "-c", Self.pythonHelper,
                fileURL.path,
                ffmpegExecutable,
                String(stream.channels)
            ]
        )

        let dsp: PythonDSPOutput
        do {
            dsp = try JSONDecoder().decode(PythonDSPOutput.self, from: dspData)
        } catch {
            throw AudioSignalAnalyzerError.malformedOutput(
                tool: pythonExecutable,
                message: error.localizedDescription
            )
        }

        let ffprobeVersion = try firstLine(
            of: run(tool: ffprobeExecutable, arguments: ["-version"]),
            tool: ffprobeExecutable
        )
        let ffmpegVersion = try firstLine(
            of: run(tool: ffmpegExecutable, arguments: ["-version"]),
            tool: ffmpegExecutable
        )

        let metadataProducer = AudioAnalysisProducer(
            toolOrModel: "ffprobe",
            version: ffprobeVersion,
            paramsOrPrompt: .object([
                "audioStream": .integer(0),
                "entries": .string("duration,bit_rate,codec_name,sample_rate,channels")
            ])
        )
        let signalProducer = AudioAnalysisProducer(
            toolOrModel: "ffmpeg + Python/NumPy audio-signal-v0",
            version: "\(ffmpegVersion); Python \(dsp.pythonVersion); NumPy \(dsp.numpyVersion)",
            paramsOrPrompt: .object([
                "analysisSampleRate": .integer(22_050),
                "frameLength": .integer(2_048),
                "hopLength": .integer(512),
                "keyFFTLength": .integer(8_192),
                "keyFrequencyCeilingHz": .integer(1_500),
                "keySettledThreshold": .double(0.8),
                "limitedAtCeilingThresholdDBFS": .double(-0.1),
                "tempoAmbiguityRatio": .double(0.85),
                "tempoPriorCenterBPM": .double(120.0),
                "tempoPriorOctavesStdDev": .double(0.5),
                "requestedSegmentCount": .integer(6)
            ])
        )

        return AudioSignalAnalysis(
            durationSeconds: Self.rounded(duration),
            codec: stream.codecName,
            sampleRate: sampleRate,
            channels: stream.channels,
            bitRate: bitRate,
            tempoBPM: dsp.tempoBPM,
            tempoOctaveAmbiguous: dsp.tempoOctaveAmbiguous,
            keyEstimate: dsp.keyEstimate,
            keyCorrelation: dsp.keyCorrelation,
            keySettled: dsp.keyCorrelation >= 0.8,
            rmsMeanDBFS: dsp.rmsMeanDBFS,
            peakDBFS: dsp.peakDBFS,
            limitedAtCeiling: dsp.peakDBFS >= -0.1,
            dynamicsStdDB: dsp.dynamicsStdDB,
            spectralCentroidHz: dsp.spectralCentroidHz,
            onsetDensityPerSecond: dsp.onsetDensityPerSecond,
            segmentBoundariesSeconds: dsp.segmentBoundariesSeconds,
            metadataProducer: metadataProducer,
            signalProducer: signalProducer
        )
        #else
        throw AudioSignalAnalyzerError.unsupportedPlatform
        #endif
    }

    private static func rounded(_ value: Double) -> Double {
        (value * 1_000_000).rounded() / 1_000_000
    }

    #if os(macOS) || os(Linux)
    private func run(tool: String, arguments: [String]) throws -> Data {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [tool] + arguments
        process.standardOutput = standardOutput
        process.standardError = standardError

        do {
            try process.run()
        } catch {
            throw AudioSignalAnalyzerError.commandLaunchFailed(
                tool: tool,
                message: error.localizedDescription
            )
        }

        let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8) ?? "No error output"
            throw AudioSignalAnalyzerError.commandFailed(
                tool: tool,
                status: process.terminationStatus,
                message: message.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return output
    }

    private func firstLine(of data: Data, tool: String) throws -> String {
        guard let output = String(data: data, encoding: .utf8),
              let line = output.split(whereSeparator: \.isNewline).first else {
            throw AudioSignalAnalyzerError.malformedOutput(
                tool: tool,
                message: "Version command returned no UTF-8 output"
            )
        }
        return String(line)
    }
    #endif

    private struct FFProbeOutput: Decodable {
        let streams: [Stream]
        let format: Format

        struct Stream: Decodable {
            let codecName: String
            let sampleRate: String
            let channels: Int
            let bitRate: String?

            enum CodingKeys: String, CodingKey {
                case codecName = "codec_name"
                case sampleRate = "sample_rate"
                case channels
                case bitRate = "bit_rate"
            }
        }

        struct Format: Decodable {
            let duration: String
            let bitRate: String?

            enum CodingKeys: String, CodingKey {
                case duration
                case bitRate = "bit_rate"
            }
        }
    }

    private struct PythonDSPOutput: Decodable {
        let tempoBPM: Double
        let tempoOctaveAmbiguous: Bool
        let keyEstimate: String
        let keyCorrelation: Double
        let rmsMeanDBFS: Double
        let peakDBFS: Double
        let dynamicsStdDB: Double
        let spectralCentroidHz: Double
        let onsetDensityPerSecond: Double
        let segmentBoundariesSeconds: [Double]
        let pythonVersion: String
        let numpyVersion: String

        enum CodingKeys: String, CodingKey {
            case tempoBPM = "tempo_bpm"
            case tempoOctaveAmbiguous = "tempo_octave_ambiguous"
            case keyEstimate = "key_estimate"
            case keyCorrelation = "key_correlation"
            case rmsMeanDBFS = "rms_mean_dbfs"
            case peakDBFS = "peak_dbfs"
            case dynamicsStdDB = "dynamics_std_db"
            case spectralCentroidHz = "spectral_centroid_hz"
            case onsetDensityPerSecond = "onset_density_per_second"
            case segmentBoundariesSeconds = "segment_boundaries_seconds"
            case pythonVersion = "python_version"
            case numpyVersion = "numpy_version"
        }
    }

    private static let pythonHelper = #"""
import json
import math
import platform
import subprocess
import sys

import numpy as np

audio_path = sys.argv[1]
ffmpeg = sys.argv[2]
channels = int(sys.argv[3])
sample_rate = 22050
frame_length = 2048
hop_length = 512

decoded = subprocess.run(
    [ffmpeg, "-v", "error", "-i", audio_path, "-f", "f32le",
     "-acodec", "pcm_f32le", "-ac", str(channels), "-ar", str(sample_rate), "pipe:1"],
    check=True,
    stdout=subprocess.PIPE,
).stdout
samples = np.frombuffer(decoded, dtype="<f4").astype(np.float64)
if samples.size == 0 or samples.size % channels != 0:
    raise ValueError("ffmpeg returned an invalid sample buffer")
samples = samples.reshape((-1, channels))
peak = min(float(np.max(np.abs(samples))), 1.0)
y = np.mean(samples, axis=1)
duration = len(y) / sample_rate

if len(y) < frame_length:
    y = np.pad(y, (0, frame_length - len(y)))
frame_count = 1 + (len(y) - frame_length) // hop_length
frames = np.lib.stride_tricks.as_strided(
    y,
    shape=(frame_count, frame_length),
    strides=(y.strides[0] * hop_length, y.strides[0]),
)
windowed = frames * np.hanning(frame_length)
magnitude = np.abs(np.fft.rfft(windowed, axis=1))
power = magnitude * magnitude
frequencies = np.fft.rfftfreq(frame_length, d=1.0 / sample_rate)

rms = np.sqrt(np.mean(frames * frames, axis=1))
rms_db = 20.0 * np.log10(np.maximum(rms, 1e-10))
spectral_centroid = np.sum(magnitude * frequencies, axis=1) / np.maximum(
    np.sum(magnitude, axis=1), 1e-12
)

log_magnitude = np.log1p(10.0 * magnitude)
onset_envelope = np.maximum(0.0, np.diff(log_magnitude, axis=0)).sum(axis=1)
onset_envelope = np.concatenate(([0.0], onset_envelope))
onset_envelope = np.maximum(0.0, onset_envelope - np.median(onset_envelope))
onset_envelope /= max(float(np.max(onset_envelope)), 1e-12)

centered_onsets = onset_envelope - np.mean(onset_envelope)
autocorrelation = np.correlate(centered_onsets, centered_onsets, mode="full")
autocorrelation = autocorrelation[len(centered_onsets) - 1:]
autocorrelation /= np.maximum(np.arange(len(centered_onsets), 0, -1), 1)
minimum_lag = max(1, int(round(60.0 * sample_rate / (200.0 * hop_length))))
maximum_lag = int(round(60.0 * sample_rate / (60.0 * hop_length)))
tempo_region = autocorrelation[minimum_lag:maximum_lag + 1]
tempo_lags = np.arange(minimum_lag, maximum_lag + 1)
tempo_candidates_bpm = 60.0 * sample_rate / (hop_length * tempo_lags)
tempo_prior = np.exp(-0.5 * (np.log2(tempo_candidates_bpm / 120.0) / 0.5) ** 2)
best_lag = int(tempo_lags[np.argmax(tempo_region * tempo_prior)])
tempo_bpm = 60.0 * sample_rate / (hop_length * best_lag)
primary_tempo_score = float(autocorrelation[best_lag])
octave_scores = []
for octave_lag in (best_lag // 2, best_lag * 2):
    if 1 <= octave_lag < len(autocorrelation):
        lower = max(1, octave_lag - 1)
        upper = min(len(autocorrelation), octave_lag + 2)
        octave_scores.append(float(np.max(autocorrelation[lower:upper])))
tempo_octave_ambiguous = (
    primary_tempo_score > 0.0
    and bool(octave_scores)
    and max(octave_scores) >= 0.85 * primary_tempo_score
)

onset_candidates = np.where(
    (onset_envelope[1:-1] > onset_envelope[:-2])
    & (onset_envelope[1:-1] >= onset_envelope[2:])
    & (onset_envelope[1:-1] >= 0.08)
)[0] + 1
minimum_onset_distance = max(1, int(0.08 * sample_rate / hop_length))
selected_onsets = []
for index in sorted(onset_candidates.tolist(), key=lambda item: (-onset_envelope[item], item)):
    if all(abs(index - selected) >= minimum_onset_distance for selected in selected_onsets):
        selected_onsets.append(index)

notes = ["C", "D-flat", "D", "E-flat", "E", "F",
         "G-flat", "G", "A-flat", "A", "B-flat", "B"]
major_profile = np.array([6.35, 2.23, 3.48, 2.33, 4.38, 4.09,
                          2.52, 5.19, 2.39, 3.66, 2.29, 2.88])
minor_profile = np.array([6.33, 2.68, 3.52, 5.38, 2.60, 3.53,
                          2.54, 4.75, 3.98, 2.69, 3.34, 3.17])
key_fft_length = 8192
key_hop_length = 1024
if len(y) < key_fft_length:
    y = np.pad(y, (0, key_fft_length - len(y)))
key_frame_count = 1 + max(0, (len(y) - key_fft_length) // key_hop_length)
aggregate_key_power = np.zeros(key_fft_length // 2 + 1)
key_window = np.hanning(key_fft_length)
for first_frame in range(0, key_frame_count, 128):
    chunk_count = min(128, key_frame_count - first_frame)
    offsets = (
        np.arange(chunk_count)[:, None] * key_hop_length
        + first_frame * key_hop_length
        + np.arange(key_fft_length)[None, :]
    )
    chunk = y[offsets] * key_window
    spectrum = np.abs(np.fft.rfft(chunk, axis=1))
    aggregate_key_power += np.sum(spectrum * spectrum, axis=0)
key_frequencies = np.fft.rfftfreq(key_fft_length, d=1.0 / sample_rate)
key_mask = (key_frequencies >= 50.0) & (key_frequencies <= 1500.0)
key_midi = np.rint(
    69.0 + 12.0 * np.log2(key_frequencies[key_mask] / 440.0)
).astype(int)
key_pitch_classes = np.mod(key_midi, 12)
key_chroma = np.array([
    aggregate_key_power[key_mask][key_pitch_classes == pitch_class].sum()
    for pitch_class in range(12)
])
key_scores = []
for tonic in range(12):
    key_scores.append((
        float(np.corrcoef(key_chroma, np.roll(major_profile, tonic))[0, 1]),
        notes[tonic] + " major",
    ))
    key_scores.append((
        float(np.corrcoef(key_chroma, np.roll(minor_profile, tonic))[0, 1]),
        notes[tonic] + " minor",
    ))
key_correlation, key_estimate = max(key_scores, key=lambda item: item[0])

valid_chroma_bins = (frequencies >= 65.0) & (frequencies <= 5000.0)
chroma_midi = np.rint(
    69.0 + 12.0 * np.log2(frequencies[valid_chroma_bins] / 440.0)
).astype(int)
chroma_pitch_classes = np.mod(chroma_midi, 12)
frame_chroma = np.zeros((power.shape[0], 12))
valid_power = power[:, valid_chroma_bins]
for pitch_class in range(12):
    frame_chroma[:, pitch_class] = valid_power[:, chroma_pitch_classes == pitch_class].sum(axis=1)
frame_chroma /= np.maximum(frame_chroma.sum(axis=1, keepdims=True), 1e-12)
frame_features = np.column_stack((frame_chroma, rms_db, spectral_centroid))
frame_times = np.arange(frame_features.shape[0]) * hop_length / sample_rate
block_ids = np.floor(frame_times).astype(int)
block_count = int(block_ids[-1]) + 1
blocks = np.vstack([
    frame_features[block_ids == block].mean(axis=0)
    for block in range(block_count)
])
blocks -= blocks.mean(axis=0, keepdims=True)
blocks /= np.maximum(blocks.std(axis=0, keepdims=True), 1e-9)
prefix = np.vstack((np.zeros((1, blocks.shape[1])), np.cumsum(blocks, axis=0)))
prefix_squared = np.vstack((
    np.zeros((1, blocks.shape[1])),
    np.cumsum(blocks * blocks, axis=0),
))
minimum_segment_blocks = 5
segment_count = min(6, max(1, block_count // minimum_segment_blocks))
minimum_segment_blocks = min(minimum_segment_blocks, max(1, block_count // segment_count))
costs = np.full((segment_count + 1, block_count + 1), np.inf)
previous = np.full((segment_count + 1, block_count + 1), -1, dtype=int)
costs[0, 0] = 0.0

def segment_cost(start, end):
    length = end - start
    total = prefix[end] - prefix[start]
    total_squared = prefix_squared[end] - prefix_squared[start]
    return float(np.sum(total_squared - total * total / length))

for count in range(1, segment_count + 1):
    for end in range(count * minimum_segment_blocks, block_count + 1):
        earliest = (count - 1) * minimum_segment_blocks
        latest = end - minimum_segment_blocks
        for start in range(earliest, latest + 1):
            candidate = costs[count - 1, start] + segment_cost(start, end)
            if candidate < costs[count, end]:
                costs[count, end] = candidate
                previous[count, end] = start
segment_starts = []
segment_end = block_count
for count in range(segment_count, 0, -1):
    segment_start = int(previous[count, segment_end])
    segment_starts.append(segment_start)
    segment_end = segment_start
segment_starts.reverse()

def rounded(value):
    return round(float(value), 6)

result = {
    "tempo_bpm": rounded(tempo_bpm),
    "tempo_octave_ambiguous": bool(tempo_octave_ambiguous),
    "key_estimate": key_estimate,
    "key_correlation": rounded(key_correlation),
    "rms_mean_dbfs": rounded(np.mean(rms_db)),
    "peak_dbfs": rounded(20.0 * math.log10(max(peak, 1e-12))),
    "dynamics_std_db": rounded(np.std(rms_db)),
    "spectral_centroid_hz": rounded(np.mean(spectral_centroid)),
    "onset_density_per_second": rounded(len(selected_onsets) / max(duration, 1e-12)),
    "segment_boundaries_seconds": [rounded(start) for start in segment_starts],
    "python_version": platform.python_version(),
    "numpy_version": np.__version__,
}
print(json.dumps(result, sort_keys=True, allow_nan=False))
"""#
}
