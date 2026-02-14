/// Recording state & configuration models for EduBoard screen recording.
///
/// Designed to be package-independent so the same models can be reused
/// when streaming via LiveKit or another transport later.

enum RecordingState {
  idle,
  recording,
  paused,
  stopping,
}

class RecordingConfig {
  /// Frames per second for the canvas capture.
  final int fps;

  /// Video width in pixels (must be even for H.264).
  final int width;

  /// Video height in pixels (must be even for H.264).
  final int height;

  /// Video bitrate (bits/s). 2 Mbps is plenty for whiteboard content.
  final int videoBitrate;

  /// Audio sample rate in Hz.
  final int audioSampleRate;

  /// Audio bitrate (bits/s).
  final int audioBitrate;

  /// Audio channel count (1 = mono, 2 = stereo).
  final int audioChannels;

  /// Whether to record microphone audio.
  final bool recordAudio;

  /// Output file path. If null, a default timestamped path is generated
  /// on the platform side.
  final String? outputPath;

  const RecordingConfig({
    this.fps = 30,
    this.width = 1080,
    this.height = 1920,
    this.videoBitrate = 8000000,
    this.audioSampleRate = 48000,
    this.audioBitrate = 128000,
    this.audioChannels = 1,
    this.recordAudio = true,
    this.outputPath,
  });

  /// Creates a config matching the screen aspect ratio at 720p.
  /// A 360×716 phone viewport → records at 1280×720, not 360×716.
  /// Creates a config using native viewport resolution (like phone screen recorders).
  /// This captures at the exact screen pixel density for maximum sharpness.
  factory RecordingConfig.fromViewport({
    required double viewportWidth,
    required double viewportHeight,
    double devicePixelRatio = 1.0,
    bool recordAudio = true,
  }) {
    // Use native screen resolution scaled by device pixel ratio
    // This matches what phone screen recorders do
    int w = (viewportWidth * devicePixelRatio).round();
    int h = (viewportHeight * devicePixelRatio).round();

    // Cap at reasonable max to avoid memory issues
    if (w > 2160 || h > 2160) {
      final scale = 2160 / (w > h ? w : h);
      w = (w * scale).round();
      h = (h * scale).round();
    }

    // H.264 requires even dimensions
    w = _ensureEven(w);
    h = _ensureEven(h);

    // Bitrate: ~8 Mbps per megapixel for high quality
    // Phone screen recorder: ~5 Mbps for 0.73 MP = 6.8 Mbps/MP
    final megapixels = (w * h) / 1000000.0;
    final bitrate = (megapixels * 8000000).round().clamp(4000000, 40000000);

    return RecordingConfig(
      fps: 30,
      width: w,
      height: h,
      videoBitrate: bitrate,
      recordAudio: recordAudio,
    );
  }

  /// Copy with overrides — useful for fallback (e.g. audio denied).
  RecordingConfig copyWith({
    int? fps,
    int? width,
    int? height,
    int? videoBitrate,
    int? audioSampleRate,
    int? audioBitrate,
    int? audioChannels,
    bool? recordAudio,
    String? outputPath,
  }) {
    return RecordingConfig(
      fps: fps ?? this.fps,
      width: width ?? this.width,
      height: height ?? this.height,
      videoBitrate: videoBitrate ?? this.videoBitrate,
      audioSampleRate: audioSampleRate ?? this.audioSampleRate,
      audioBitrate: audioBitrate ?? this.audioBitrate,
      audioChannels: audioChannels ?? this.audioChannels,
      recordAudio: recordAudio ?? this.recordAudio,
      outputPath: outputPath ?? this.outputPath,
    );
  }

  Map<String, dynamic> toMap() => {
        'fps': fps,
        'width': _ensureEven(width),
        'height': _ensureEven(height),
        'videoBitrate': videoBitrate,
        'audioSampleRate': audioSampleRate,
        'audioBitrate': audioBitrate,
        'audioChannels': audioChannels,
        'recordAudio': recordAudio,
        'outputPath': outputPath,
      };

  /// H.264 requires even dimensions.
  static int _ensureEven(int v) => v.isOdd ? v + 1 : v;
}

/// Holds information about a completed recording.
class RecordingResult {
  final String filePath;
  final Duration duration;
  final int fileSizeBytes;

  const RecordingResult({
    required this.filePath,
    required this.duration,
    required this.fileSizeBytes,
  });

  factory RecordingResult.fromMap(Map<String, dynamic> map) => RecordingResult(
        filePath: map['filePath'] as String,
        duration: Duration(milliseconds: map['durationMs'] as int),
        fileSizeBytes: map['fileSizeBytes'] as int? ?? 0,
      );

  /// Human-readable file size.
  String get formattedSize {
    if (fileSizeBytes < 1024) return '$fileSizeBytes B';
    if (fileSizeBytes < 1024 * 1024) {
      return '${(fileSizeBytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(fileSizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
