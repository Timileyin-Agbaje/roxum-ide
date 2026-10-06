// Stand-in for package:llama_flutter_android, which this fork removes along with
// local GGUF models. It mirrors the parts of the API the app references so the
// (now hidden) local model code keeps compiling; every call fails.

class GpuInfo {
  GpuInfo({
    required this.vulkanSupported,
    required this.gpuName,
    required this.vulkanApiVersion,
    required this.deviceLocalMemoryBytes,
    required this.freeRamBytes,
    required this.recommendedGpuLayers,
  });

  bool vulkanSupported;
  String gpuName;
  int vulkanApiVersion;
  int deviceLocalMemoryBytes;
  int freeRamBytes;
  int recommendedGpuLayers;
}

class ChatMessage {
  ChatMessage({
    required this.role,
    required this.content,
  });

  String role;
  String content;
}

class LlamaController {
  static UnsupportedError get _unsupported =>
      UnsupportedError('Local models are not available in this build.');

  Future<void> loadModel({
    required String modelPath,
    int threads = 4,
    int contextSize = 2048,
    int? gpuLayers,
  }) async => throw _unsupported;

  Stream<String> generate({
    required String prompt,
    int maxTokens = 512,
    double temperature = 0.7,
    double topP = 0.9,
    int topK = 40,
    double minP = 0.05,
    double typicalP = 1.0,
    double repeatPenalty = 1.1,
    double frequencyPenalty = 0.0,
    double presencePenalty = 0.0,
    int repeatLastN = 64,
    int mirostat = 0,
    double mirostatTau = 5.0,
    double mirostatEta = 0.1,
    int? seed,
    bool penalizeNewline = true,
  }) => Stream.error(_unsupported);

  Stream<String> generateChat({
    required List<ChatMessage> messages,
    String? template,
    int maxTokens = 512,
    double temperature = 0.7,
    double topP = 0.9,
    int topK = 40,
    double minP = 0.05,
    double typicalP = 1.0,
    double repeatPenalty = 1.1,
    double frequencyPenalty = 0.0,
    double presencePenalty = 0.0,
    int repeatLastN = 64,
    int mirostat = 0,
    double mirostatTau = 5.0,
    double mirostatEta = 0.1,
    int? seed,
    bool penalizeNewline = true,
  }) => Stream.error(_unsupported);

  Future<GpuInfo> detectGpu() async => throw _unsupported;

  Future<void> stop() async {}

  Future<void> dispose() async {}
}
