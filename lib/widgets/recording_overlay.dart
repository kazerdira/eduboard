import 'package:flutter/material.dart';
import '../models/recording_models.dart';
import '../services/board_recorder.dart';

/// Floating recording control overlay.
///
/// Shows a red recording pill with elapsed time, pause/resume, and stop.
/// Must be placed inside a Stack (the parent widget handles Positioned).
class RecordingOverlay extends StatelessWidget {
  final BoardRecorder recorder;
  final void Function(RecordingResult? result)? onStop;

  const RecordingOverlay({
    super.key,
    required this.recorder,
    this.onStop,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: recorder,
      builder: (context, _) {
        if (recorder.state == RecordingState.idle) {
          return const SizedBox.shrink();
        }
        return _buildPill(context);
      },
    );
  }

  Widget _buildPill(BuildContext context) {
    final isRecording = recorder.state == RecordingState.recording;
    final isPaused = recorder.state == RecordingState.paused;
    final isStopping = recorder.state == RecordingState.stopping;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xDD1a1a2e),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: isRecording
              ? const Color(0xFFef4444)
              : isPaused
                  ? const Color(0xFFf59e0b)
                  : Colors.white24,
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.4),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Status indicator
          if (isStopping)
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white54,
              ),
            )
          else if (isPaused)
            const Icon(Icons.pause, color: Color(0xFFf59e0b), size: 16)
          else
            const _BlinkingDot(),

          const SizedBox(width: 8),

          // Timer
          Text(
            _formatDuration(recorder.elapsed),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w600,
              fontFamily: 'monospace',
              letterSpacing: 1,
            ),
          ),

          if (!isStopping) ...[
            const SizedBox(width: 10),

            // Pause / Resume
            _ControlButton(
              icon:
                  isRecording ? Icons.pause_rounded : Icons.play_arrow_rounded,
              color: isRecording
                  ? const Color(0xFFf59e0b)
                  : const Color(0xFF22c55e),
              onTap: () {
                if (isRecording) {
                  recorder.pause();
                } else if (isPaused) {
                  recorder.resume();
                }
              },
            ),
            const SizedBox(width: 4),

            // Stop
            _ControlButton(
              icon: Icons.stop_rounded,
              color: const Color(0xFFef4444),
              onTap: () async {
                final result = await recorder.stop();
                onStop?.call(result);
              },
            ),
          ],
        ],
      ),
    );
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (d.inHours > 0) {
      final h = d.inHours.toString().padLeft(2, '0');
      return '$h:$m:$s';
    }
    return '$m:$s';
  }
}

class _ControlButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _ControlButton({
    required this.icon,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          color: color.withOpacity(0.15),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: color, size: 18),
      ),
    );
  }
}

/// A tiny red dot that blinks while recording.
class _BlinkingDot extends StatefulWidget {
  const _BlinkingDot();

  @override
  State<_BlinkingDot> createState() => _BlinkingDotState();
}

class _BlinkingDotState extends State<_BlinkingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _anim,
      child: Container(
        width: 10,
        height: 10,
        decoration: const BoxDecoration(
          color: Color(0xFFef4444),
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}
