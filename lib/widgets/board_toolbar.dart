import 'package:flutter/material.dart';
import '../models/board_models.dart';
import '../models/board_controller.dart';

class BoardToolbar extends StatelessWidget {
  final BoardController controller;
  final VoidCallback onUndo;
  final VoidCallback onRedo;
  final VoidCallback onClear;
  final VoidCallback onExport;
  final VoidCallback onInsertImage;
  final VoidCallback? onMathSymbols;
  final VoidCallback? onRecord;
  final bool isRecording;

  const BoardToolbar({
    super.key,
    required this.controller,
    required this.onUndo,
    required this.onRedo,
    required this.onClear,
    required this.onExport,
    required this.onInsertImage,
    this.onMathSymbols,
    this.onRecord,
    this.isRecording = false,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        return Container(
          height: 52,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: const Color(0xFF0f1729),
            border: Border(
              bottom: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
            ),
          ),
          // Always scrollable to handle any screen size
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _buildLogo(),
                const SizedBox(width: 12),
                _buildToolGroup(),
                const SizedBox(width: 12),
                _buildActionButtons(),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildLogo() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: const Color(0xFF4361ee),
            borderRadius: BorderRadius.circular(7),
          ),
          child: const Center(
            child: Text('✏️', style: TextStyle(fontSize: 14)),
          ),
        ),
        const SizedBox(width: 8),
        const Text(
          'EduBoard',
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w700,
            fontSize: 16,
            letterSpacing: -0.3,
          ),
        ),
      ],
    );
  }

  Widget _buildPageNav() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _miniButton('◂', controller.prevPage),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              '${controller.currentPageIndex + 1} / ${controller.pageCount}',
              style: TextStyle(
                fontSize: 13,
                fontFamily: 'monospace',
                color: Colors.white.withValues(alpha: 0.6),
              ),
            ),
          ),
          _miniButton('▸', controller.nextPage),
          const SizedBox(width: 4),
          _miniButton('+', controller.addPage),
        ],
      ),
    );
  }

  Widget _buildToolGroup() {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: const Color(0xFF1a1f3a),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _toolBtn(BoardToolType.pen, '✒️', 'Pen'),
          _toolBtn(BoardToolType.highlighter, '🖍️', 'Highlighter'),
          _toolBtn(BoardToolType.eraser, '🧽', 'Eraser'),
          _separator(),
          _toolBtn(BoardToolType.line, '╱', 'Line'),
          _toolBtn(BoardToolType.arrow, '➜', 'Arrow'),
          _toolBtn(BoardToolType.shape, '▢', 'Shape'),
          _separator(),
          _toolBtn(BoardToolType.text, 'T', 'Text'),
          _separator(),
          _toolBtn(BoardToolType.select, '◇', 'Select'),
          _separator(),
          _toolBtnCustom('🖼️', 'Image', onInsertImage),
          _toolBtn(BoardToolType.laser, '🔴', 'Laser'),
        ],
      ),
    );
  }

  Widget _toolBtn(BoardToolType tool, String icon, String tooltip) {
    final isActive = controller.activeTool == tool;
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: () => controller.setTool(tool),
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: isActive ? const Color(0xFF4361ee) : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            boxShadow: isActive
                ? [
                    BoxShadow(
                        color: const Color(0xFF4361ee).withValues(alpha: 0.3),
                        blurRadius: 12)
                  ]
                : null,
          ),
          child: Center(
            child: Text(
              icon,
              style: TextStyle(
                fontSize: icon.length <= 2 ? 16 : 14,
                color: isActive
                    ? Colors.white
                    : Colors.white.withValues(alpha: 0.5),
                fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _toolBtnCustom(String icon, String tooltip, VoidCallback onTap) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
          ),
          child: Center(
            child: Text(
              icon,
              style: TextStyle(
                fontSize: 16,
                color: Colors.white.withValues(alpha: 0.5),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _separator() {
    return Container(
      width: 1,
      height: 24,
      margin: const EdgeInsets.symmetric(horizontal: 4),
      color: Colors.white.withValues(alpha: 0.08),
    );
  }

  Widget _buildActionButtons() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _actionBtn('↩', onUndo, isSecondary: true),
        const SizedBox(width: 4),
        _actionBtn('↪', onRedo, isSecondary: true),
        const SizedBox(width: 8),
        _buildPageNav(),
        const SizedBox(width: 8),
        _actionBtn('🗑️', onClear, isDanger: true),
        const SizedBox(width: 4),
        if (onRecord != null)
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: _actionBtn(
              isRecording ? '⏹ Stop' : '⏺ Rec',
              onRecord!,
              isDanger: isRecording,
              isPrimary: !isRecording,
            ),
          ),
        _actionBtn('💾 Save', onExport, isPrimary: true),
      ],
    );
  }

  Widget _miniButton(String text, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(4)),
        child: Center(
          child: Text(
            text,
            style: TextStyle(
                fontSize: 14, color: Colors.white.withValues(alpha: 0.5)),
          ),
        ),
      ),
    );
  }

  Widget _actionBtn(String label, VoidCallback onTap,
      {bool isPrimary = false,
      bool isSecondary = false,
      bool isDanger = false}) {
    Color bg;
    if (isPrimary) {
      bg = const Color(0xFF4361ee);
    } else if (isDanger) {
      bg = const Color(0xFFef4444);
    } else {
      bg = Colors.white.withValues(alpha: 0.08);
    }

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
