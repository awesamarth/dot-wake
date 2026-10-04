// Keyword-only subset of sherpa-onnx 1.13.8 Swift API.
// Copyright (c) 2023 Xiaomi Corporation; Apache-2.0.
import Foundation
import SherpaOnnxC

public func toCPointer(_ s: String) -> UnsafePointer<Int8>! {
  let cs = (s as NSString).utf8String
  return UnsafePointer<Int8>(cs)
}

public func sherpaOnnxOnlineTransducerModelConfig(
  encoder: String = "",
  decoder: String = "",
  joiner: String = ""
) -> SherpaOnnxOnlineTransducerModelConfig {
  return SherpaOnnxOnlineTransducerModelConfig(
    encoder: toCPointer(encoder),
    decoder: toCPointer(decoder),
    joiner: toCPointer(joiner)
  )
}

public func sherpaOnnxOnlineParaformerModelConfig(
  encoder: String = "",
  decoder: String = ""
) -> SherpaOnnxOnlineParaformerModelConfig {
  return SherpaOnnxOnlineParaformerModelConfig(
    encoder: toCPointer(encoder),
    decoder: toCPointer(decoder)
  )
}

public func sherpaOnnxOnlineZipformer2CtcModelConfig(
  model: String = ""
) -> SherpaOnnxOnlineZipformer2CtcModelConfig {
  return SherpaOnnxOnlineZipformer2CtcModelConfig(
    model: toCPointer(model)
  )
}

public func sherpaOnnxOnlineNemoCtcModelConfig(
  model: String = ""
) -> SherpaOnnxOnlineNemoCtcModelConfig {
  return SherpaOnnxOnlineNemoCtcModelConfig(
    model: toCPointer(model)
  )
}

public func sherpaOnnxOnlineToneCtcModelConfig(
  model: String = ""
) -> SherpaOnnxOnlineToneCtcModelConfig {
  return SherpaOnnxOnlineToneCtcModelConfig(
    model: toCPointer(model)
  )
}

public func sherpaOnnxOnlineModelConfig(
  tokens: String,
  transducer: SherpaOnnxOnlineTransducerModelConfig = sherpaOnnxOnlineTransducerModelConfig(),
  paraformer: SherpaOnnxOnlineParaformerModelConfig = sherpaOnnxOnlineParaformerModelConfig(),
  zipformer2Ctc: SherpaOnnxOnlineZipformer2CtcModelConfig =
    sherpaOnnxOnlineZipformer2CtcModelConfig(),
  numThreads: Int = 1,
  provider: String = "cpu",
  debug: Int = 0,
  modelType: String = "",
  modelingUnit: String = "cjkchar",
  bpeVocab: String = "",
  tokensBuf: String = "",
  tokensBufSize: Int = 0,
  nemoCtc: SherpaOnnxOnlineNemoCtcModelConfig = sherpaOnnxOnlineNemoCtcModelConfig(),
  toneCtc: SherpaOnnxOnlineToneCtcModelConfig = sherpaOnnxOnlineToneCtcModelConfig()
) -> SherpaOnnxOnlineModelConfig {
  return SherpaOnnxOnlineModelConfig(
    transducer: transducer,
    paraformer: paraformer,
    zipformer2_ctc: zipformer2Ctc,
    tokens: toCPointer(tokens),
    num_threads: Int32(numThreads),
    provider: toCPointer(provider),
    debug: Int32(debug),
    model_type: toCPointer(modelType),
    modeling_unit: toCPointer(modelingUnit),
    bpe_vocab: toCPointer(bpeVocab),
    tokens_buf: toCPointer(tokensBuf),
    tokens_buf_size: Int32(tokensBufSize),
    nemo_ctc: nemoCtc,
    t_one_ctc: toneCtc
  )
}

public func sherpaOnnxFeatureConfig(
  sampleRate: Int = 16000,
  featureDim: Int = 80
) -> SherpaOnnxFeatureConfig {
  return SherpaOnnxFeatureConfig(
    sample_rate: Int32(sampleRate),
    feature_dim: Int32(featureDim))
}

public class SherpaOnnxKeywordResultWrapper {
  /// A pointer to the underlying counterpart in C
  public let result: UnsafePointer<SherpaOnnxKeywordResult>!

  public var keyword: String {
    return String(cString: result.pointee.keyword)
  }

  public var count: Int32 {
    return result.pointee.count
  }

  public var tokens: [String] {
    if let tokensPointer = result.pointee.tokens_arr {
      var tokens: [String] = []
      for index in 0..<count {
        if let tokenPointer = tokensPointer[Int(index)] {
          let token = String(cString: tokenPointer)
          tokens.append(token)
        }
      }
      return tokens
    } else {
      let tokens: [String] = []
      return tokens
    }
  }

  public init(result: UnsafePointer<SherpaOnnxKeywordResult>!) {
    self.result = result
  }

  deinit {
    if let result {
      SherpaOnnxDestroyKeywordResult(result)
    }
  }
}

public func sherpaOnnxKeywordSpotterConfig(
  featConfig: SherpaOnnxFeatureConfig,
  modelConfig: SherpaOnnxOnlineModelConfig,
  keywordsFile: String,
  maxActivePaths: Int = 4,
  numTrailingBlanks: Int = 1,
  keywordsScore: Float = 1.0,
  keywordsThreshold: Float = 0.25,
  keywordsBuf: String = "",
  keywordsBufSize: Int = 0
) -> SherpaOnnxKeywordSpotterConfig {
  return SherpaOnnxKeywordSpotterConfig(
    feat_config: featConfig,
    model_config: modelConfig,
    max_active_paths: Int32(maxActivePaths),
    num_trailing_blanks: Int32(numTrailingBlanks),
    keywords_score: keywordsScore,
    keywords_threshold: keywordsThreshold,
    keywords_file: toCPointer(keywordsFile),
    keywords_buf: toCPointer(keywordsBuf),
    keywords_buf_size: Int32(keywordsBufSize)
  )
}

public class SherpaOnnxKeywordSpotterWrapper {
  /// A pointer to the underlying counterpart in C
  public let spotter: OpaquePointer!
  public var stream: OpaquePointer!

  public init(
    config: UnsafePointer<SherpaOnnxKeywordSpotterConfig>!
  ) {
    spotter = SherpaOnnxCreateKeywordSpotter(config)
    stream = SherpaOnnxCreateKeywordStream(spotter)
  }

  deinit {
    if let stream {
      SherpaOnnxDestroyOnlineStream(stream)
    }

    if let spotter {
      SherpaOnnxDestroyKeywordSpotter(spotter)
    }
  }

  public func acceptWaveform(samples: [Float], sampleRate: Int = 16000) {
    SherpaOnnxOnlineStreamAcceptWaveform(stream, Int32(sampleRate), samples, Int32(samples.count))
  }

  public func isReady() -> Bool {
    return SherpaOnnxIsKeywordStreamReady(spotter, stream) == 1 ? true : false
  }

  public func decode() {
    SherpaOnnxDecodeKeywordStream(spotter, stream)
  }

  public func reset() {
    SherpaOnnxResetKeywordStream(spotter, stream)
  }

  public func getResult() -> SherpaOnnxKeywordResultWrapper {
    let result: UnsafePointer<SherpaOnnxKeywordResult>? = SherpaOnnxGetKeywordResult(
      spotter, stream)
    return SherpaOnnxKeywordResultWrapper(result: result)
  }

  /// Signal that no more audio samples would be available.
  /// After this call, you cannot call acceptWaveform() any more.
  public func inputFinished() {
    SherpaOnnxOnlineStreamInputFinished(stream)
  }
}
