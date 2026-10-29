/// Online stream wrapper adapted from Xiaomi / sherpa-onnx. See ThirdPartyNotices.
import Foundation
import SherpaOnnx

/// Wrapper for recognition result.
///
/// Usage:
///
///  let result = recognizer.getResult()
///  print("text: \(result.text)")
///
class SherpaOnnxOnlineRecongitionResult {
  /// A pointer to the underlying counterpart in C
  private let result: UnsafePointer<SherpaOnnxOnlineRecognizerResult>

  private lazy var _text: String = {
    guard let cstr = result.pointee.text else { return "" }
    return String(cString: cstr)
  }()

  private lazy var _tokens: [String] = {
    guard let tokensPointer = result.pointee.tokens_arr else { return [] }
    return (0..<count).compactMap { index in
      guard let ptr = tokensPointer[index] else { return nil }
      return String(cString: ptr)
    }
  }()

  private lazy var _timestamps: [Float] = {
    guard let timestampsPointer = result.pointee.timestamps else { return [] }
    return (0..<count).map { index in timestampsPointer[index] }
  }()

  init(result: UnsafePointer<SherpaOnnxOnlineRecognizerResult>) {
    self.result = result
  }

  deinit {
    SherpaOnnxDestroyOnlineRecognizerResult(result)
  }

  /// Return the actual recognition result.
  /// For English models, it contains words separated by spaces.
  /// For Chinese models, it contains Chinese words.
  var text: String { _text }

  var count: Int { Int(result.pointee.count) }

  var tokens: [String] { _tokens }

  var timestamps: [Float] { _timestamps }
}

class SherpaOnnxRecognizer {
  /// A pointer to the underlying counterpart in C
  private let recognizer: OpaquePointer
  private var stream: OpaquePointer

  /// Constructor taking a model config
  init(
    config: UnsafePointer<SherpaOnnxOnlineRecognizerConfig>
  ) throws {
    guard SherpaRuntimeSupportsRequiredAPI() != 0 else {
      throw SherpaRuntimeError.incompatible
    }
    guard let recognizer = SherpaOnnxCreateOnlineRecognizer(config) else { throw TranslatorError.modelUnavailable }
    guard let stream = SherpaOnnxCreateOnlineStream(recognizer) else {
      SherpaOnnxDestroyOnlineRecognizer(recognizer)
      throw TranslatorError.modelUnavailable
    }
    self.recognizer = recognizer
    self.stream = stream
  }

  deinit {
    SherpaOnnxDestroyOnlineStream(stream)
    SherpaOnnxDestroyOnlineRecognizer(recognizer)
  }

  /// Decode wave samples.
  ///
  /// - Parameters:
  ///   - samples: Audio samples normalized to the range [-1, 1]
  ///   - sampleRate: Sample rate of the input audio samples. Must match
  ///                 the one expected by the model.
  func acceptWaveform(samples: [Float], sampleRate: Int = 16_000) {
    SherpaOnnxOnlineStreamAcceptWaveform(stream, Int32(sampleRate), samples, Int32(samples.count))
  }

  func isReady() -> Bool {
    return SherpaOnnxIsOnlineStreamReady(recognizer, stream) != 0
  }

  /// If there are enough number of feature frames, it invokes the neural
  /// network computation and decoding. Otherwise, it is a no-op.
  func decode() {
    SherpaOnnxDecodeOnlineStream(recognizer, stream)
  }

  /// Get the decoding results so far
  func getResult() throws -> SherpaOnnxOnlineRecongitionResult {
    guard let result = SherpaOnnxGetOnlineStreamResult(recognizer, stream) else {
      throw TranslatorError.recordingFailed
    }
    return SherpaOnnxOnlineRecongitionResult(result: result)
  }

  /// Reset the recognizer, which clears the neural network model state
  /// and the state for decoding.
  /// If hotwords is an empty string, it just recreates the decoding stream
  /// If hotwords is not empty, it will create a new decoding stream with
  /// the given hotWords appended to the default hotwords.
  func reset() throws {
    // OnlineStreamReset only advances segment counters. It neither reopens a
    // finished feature extractor nor discards previously supplied audio.
    guard let replacement = SherpaOnnxCreateOnlineStream(recognizer) else {
      throw TranslatorError.modelUnavailable
    }
    SherpaOnnxDestroyOnlineStream(stream)
    stream = replacement
  }

  /// Signal that no more audio samples would be available.
  /// After this call, you cannot call acceptWaveform() any more.
  func inputFinished() {
    SherpaOnnxOnlineStreamInputFinished(stream)
  }

  /// Return true is an endpoint has been detected.
  func isEndpoint() -> Bool {
    return SherpaOnnxOnlineStreamIsEndpoint(recognizer, stream) != 0
  }
}

enum SherpaRuntimeError: LocalizedError {
  case incompatible
  var errorDescription: String? { "语音引擎与运行库版本不兼容，请安装更新后的客户端。已下载的模型可以保留。" }
}
