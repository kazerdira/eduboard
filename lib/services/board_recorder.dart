import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/board_controller.dart';
import '../models/recording_models.dart';
import '../painters/board_painter.dart';

/// Captures canvas frames from [BoardPainter] and pipes them to a
/// platform-side encoder (MediaCodec + MediaMuxer on Android).
///
/// ## Recording strategy: Viewport capture (screen-recorder style)
///
/// The recorder captures **exactly what the user sees** on screen:
/// - Zoom in/out movements are recorded in real-time
/// - Pan movements are recorded in real-time
/// - Renders at high resolution (1280×720 or higher) regardless of screen size
/// - 30 FPS for smooth motion capture
class BoardRecorder extends ChangeNotifier {
  static const _channel = MethodChannel('com.eduboard.app/recorder');

  final BoardController controller;
  RecordingConfig _config;
  RecordingState _state = RecordingState.idle;
  Duration _elapsed = Duration.zero;

  Timer? _clockTimer;
  DateTime? _recordingStart;
  DateTime? _pauseStart;
  Duration _pausedAccum = Duration.zero;
  int _droppedFrames = 0;
  int _capturedFrames = 0;

  /// Viewport dimensions (set by widget before starting)
  double viewportWidth = 0;
  double viewportHeight = 0;

  RecordingState get state => _state;
  Duration get elapsed => _elapsed;
  RecordingConfig get config => _config;
  int get droppedFrames => _droppedFrames;
  int get capturedFrames => _capturedFrames;

  BoardRecorder({
    required this.controller,
    RecordingConfig config = const RecordingConfig(),
  }) : _config = config;

  /// Start recording the board canvas + optional microphone.
  Future<bool> start([RecordingConfig? config]) async {
    if (_state == RecordingState.recording) return false;

    if (config != null) _config = config;

    debugPrint('[BoardRecorder] Starting with config: '
        '${_config.width}x${_config.height} @${_config.fps}fps, '
        'viewport: ${viewportWidth}x$viewportHeight, '
        'bitrate: ${_config.videoBitrate}, audio: ${_config.recordAudio}');

    try {
      // Handle microphone permission if audio is requested
      if (_config.recordAudio) {
        final hasPermission = await _requestMicPermission();
        if (!hasPermission) {
          debugPrint('[BoardRecorder] Mic denied — falling back to video-only');
          _config = _config.copyWith(recordAudio: false);
        }
      }

      final ok = await _channel.invokeMethod<bool>(
            'startRecording',
            _config.toMap(),
          ) ??
          false;
      if (!ok) return false;

      _state = RecordingState.recording;
      _recordingStart = DateTime.now();
      _pausedAccum = Duration.zero;
      _elapsed = Duration.zero;
      _droppedFrames = 0;
      _capturedFrames = 0;

      _startFrameCaptureLoop();
      _startClock();

      debugPrint('[BoardRecorder] Recording started successfully');
      notifyListeners();
      return true;
    } catch (e, stack) {
      debugPrint('[BoardRecorder] start failed: $e\n$stack');
      return false;
    }
  }

  /// Pause recording (stops frame capture + audio, keeps file open).
  Future<void> pause() async {
    if (_state != RecordingState.recording) return;

    _pauseStart = DateTime.now();
    _state = RecordingState.paused;

    try {
      await _channel.invokeMethod('pauseRecording');
    } catch (e) {
      debugPrint('[BoardRecorder] pause failed: $e');
    }
    notifyListeners();
  }

  /// Resume a paused recording.
  Future<void> resume() async {
    if (_state != RecordingState.paused) return;

    if (_pauseStart != null) {
      _pausedAccum += DateTime.now().difference(_pauseStart!);
      _pauseStart = null;
    }

    try {
      await _channel.invokeMethod('resumeRecording');
    } catch (e) {
      debugPrint('[BoardRecorder] resume failed: $e');
    }

    _state = RecordingState.recording;
    _startFrameCaptureLoop();
    notifyListeners();
  }

  /// Stop recording and finalize the MP4 file.
  Future<RecordingResult?> stop() async {
    if (_state == RecordingState.idle) return null;

    _state = RecordingState.stopping;
    notifyListeners();

    _clockTimer?.cancel();
    _clockTimer = null;

    try {
      final result = await _channel.invokeMethod<Map>('stopRecording');
      _state = RecordingState.idle;
      _elapsed = Duration.zero;
      notifyListeners();

      if (result != null) {
        final r = RecordingResult.fromMap(Map<String, dynamic>.from(result));
        debugPrint('[BoardRecorder] Saved: ${r.filePath} '
            '(${r.formattedSize}, dropped=$_droppedFrames)');
        return r;
      }
    } catch (e) {
      debugPrint('[BoardRecorder] stop failed: $e');
      _state = RecordingState.idle;
      notifyListeners();
    }
    return null;
  }

  // ---------------------------------------------------------------
  // Internal
  // ---------------------------------------------------------------

  Future<bool> _requestMicPermission() async {
    try {
      final granted =
          await _channel.invokeMethod<bool>('checkPermission') ?? false;
      if (granted) return true;

      // Permission dialog shown by the system — re-check after a delay
      await Future.delayed(const Duration(seconds: 2));
      return await _channel.invokeMethod<bool>('checkPermission') ?? false;
    } catch (e) {
      debugPrint('[BoardRecorder] permission check error: $e');
      return false;
    }
  }

  /// Frame pacing loop: captures frames sequentially, waiting for each to
  /// complete before starting the next. This prevents queue buildup and
  /// cascade failures that happen with Timer.periodic.
  ///
  /// Target framerate is maintained by calculating sleep time based on
  /// how long the capture actually took.
  void _startFrameCaptureLoop() {
    final targetFrameTimeMs = 1000 ~/ _config.fps;

    Future<void> captureLoop() async {
      while (_state == RecordingState.recording) {
        final frameStart = DateTime.now();

        await _captureAndSendFrame();

        // Calculate how long this frame took
        final elapsed = DateTime.now().difference(frameStart).inMilliseconds;

        // Sleep for remaining time to hit target framerate
        // If frame took longer than target, don't sleep (we're behind)
        final sleepMs = targetFrameTimeMs - elapsed;
        if (sleepMs > 0) {
          await Future.delayed(Duration(milliseconds: sleepMs));
        } else {
          // Frame took too long, skip sleep but yield to event loop
          await Future.delayed(Duration.zero);
        }
      }
    }

    // Start the loop (runs in background)
    captureLoop();
  }

  void _startClock() {
    _clockTimer?.cancel();
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_state == RecordingState.recording && _recordingStart != null) {
        _elapsed = DateTime.now().difference(_recordingStart!) - _pausedAccum;
        notifyListeners();
      }
    });
  }

  /// Capture one frame and send to encoder. Returns quickly even if
  /// capture is slow - the frame pacing loop handles timing.
  Future<void> _captureAndSendFrame() async {
    if (_state != RecordingState.recording) return;

    try {
      final bytes = await BoardPainter.exportViewportToRawRgba(
        controller,
        viewportWidth:
            viewportWidth > 0 ? viewportWidth : _config.width.toDouble(),
        viewportHeight:
            viewportHeight > 0 ? viewportHeight : _config.height.toDouble(),
        outputWidth: _config.width,
        outputHeight: _config.height,
      );

      if (bytes != null && _state == RecordingState.recording) {
        final expectedSize = _config.width * _config.height * 4;
        if (bytes.length != expectedSize) {
          debugPrint(
              '[BoardRecorder] Frame size mismatch: ${bytes.length} vs $expectedSize');
          _droppedFrames++;
          return;
        }

        await _channel.invokeMethod('addFrame', bytes);
        _capturedFrames++;

        // Log progress every 30 frames
        if (_capturedFrames % 30 == 0) {
          debugPrint('[BoardRecorder] Captured $_capturedFrames frames');
        }
      } else {
        _droppedFrames++;
      }
    } catch (e) {
      debugPrint('[BoardRecorder] Frame capture error: $e');
      _droppedFrames++;
    }
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    if (_state != RecordingState.idle) {
      _state = RecordingState.idle; // Stop the capture loop
      _channel.invokeMethod('stopRecording').catchError((_) {});
    }
    super.dispose();
  }
}
