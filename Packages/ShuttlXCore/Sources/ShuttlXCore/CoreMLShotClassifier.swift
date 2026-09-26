#if canImport(CoreML)
import CoreML
import Foundation

/// The injected model must have numeric scalar inputs and a string-keyed class-probability output.
/// Training and independent wrist/hand/device validation are caller responsibilities.
public struct CoreMLFeatureSchema: Sendable {
    public enum Feature: String, Sendable, CaseIterable {
        case duration, peakAcceleration, peakRotation, accelerationImpulse, rotationImpulse
        case rotationX, rotationY, rotationZ, sampleCount
        func value(from features: SwingFeatures) -> Double {
            switch self {
            case .duration: features.duration
            case .peakAcceleration: features.peakAcceleration
            case .peakRotation: features.peakRotation
            case .accelerationImpulse: features.accelerationImpulse
            case .rotationImpulse: features.rotationImpulse
            case .rotationX: features.dominantAxis.x
            case .rotationY: features.dominantAxis.y
            case .rotationZ: features.dominantAxis.z
            case .sampleCount: Double(features.sampleCount)
            }
        }
    }
    public var inputs: [String: Feature]
    public var probabilitiesOutput: String
    public var labels: [String: ShotType]
    public init(inputs: [String: Feature], probabilitiesOutput: String, labels: [String: ShotType]) {
        self.inputs = inputs; self.probabilitiesOutput = probabilitiesOutput; self.labels = labels
    }
}
public enum CoreMLClassifierError: Error { case invalidSchema(String) }

/// MLModel is guarded by a private lock: synchronous prediction can be used on the motion executor,
/// never on the main UI actor. Do heavier model work after the session if latency exceeds the window budget.
public final class CoreMLShotClassifier: ShotClassifier, @unchecked Sendable {
    private let model: MLModel
    private let schema: CoreMLFeatureSchema
    private let lock = NSLock()
    public let modelVersion: String
    public init(model: MLModel, schema: CoreMLFeatureSchema, modelVersion: String) throws {
        guard !schema.inputs.isEmpty, !schema.labels.isEmpty, !modelVersion.isEmpty else {
            throw CoreMLClassifierError.invalidSchema("Inputs, labels and model version are required.")
        }
        for (name, description) in model.modelDescription.inputDescriptionsByName {
            guard schema.inputs[name] != nil,
                  description.type == .double || description.type == .int64 else {
                throw CoreMLClassifierError.invalidSchema("Missing or non-scalar model input: \(name)")
            }
        }
        guard Set(schema.inputs.keys) == Set(model.modelDescription.inputDescriptionsByName.keys),
              model.modelDescription.outputDescriptionsByName[schema.probabilitiesOutput]?.type == .dictionary else {
            throw CoreMLClassifierError.invalidSchema("Inputs or probability output do not match the model.")
        }
        self.model = model; self.schema = schema; self.modelVersion = modelVersion
    }
    public func classify(features: SwingFeatures, settings: TrackingSettings) -> ShotClassification {
        lock.lock(); defer { lock.unlock() }
        do {
            var values: [String: Any] = [:]
            for (name, feature) in schema.inputs {
                let value = feature.value(from: features)
                guard value.isFinite else { return .init() }
                if model.modelDescription.inputDescriptionsByName[name]?.type == .int64 {
                    guard value >= Double(Int64.min), value < Double(Int64.max) else { return .init() }
                    values[name] = NSNumber(value: Int64(value))
                } else { values[name] = NSNumber(value: value) }
            }
            let input = try MLDictionaryFeatureProvider(dictionary: values)
            let output = try model.prediction(from: input)
            guard let distribution = output.featureValue(for: schema.probabilitiesOutput)?.dictionaryValue else { return .init() }
            var winner: (ShotType, Double)?
            for (key, number) in distribution {
                guard let label = key.base as? String, let type = schema.labels[label] else { continue }
                let probability = number.doubleValue
                guard probability.isFinite, (0...1).contains(probability) else { return .init() }
                if winner == nil || probability > winner!.1 { winner = (type, probability) }
            }
            guard let winner else { return .init() }
            // A shot classifier does not infer hand, body position, tactical intent or speed.
            return ShotClassification(type: winner.0, confidence: winner.1).thresholded(at: settings.validated().confidenceThreshold)
        } catch { return .init() }
    }
}
#endif
