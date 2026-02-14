import 'package:flutter/material.dart';
import '../models/board_models.dart';
import '../models/board_controller.dart';

class PropertiesPanel extends StatelessWidget {
  final BoardController controller;
  final bool isInBottomSheet;

  const PropertiesPanel({
    super.key,
    required this.controller,
    this.isInBottomSheet = false,
  });

  static const List<Color> colors = [
    Color(0xFF000000),
    Color(0xFF374151),
    Color(0xFF6b7280),
    Color(0xFF9ca3af),
    Color(0xFFd1d5db),
    Color(0xFFffffff),
    Color(0xFFef4444),
    Color(0xFFf97316),
    Color(0xFFf59e0b),
    Color(0xFFeab308),
    Color(0xFF84cc16),
    Color(0xFF22c55e),
    Color(0xFF14b8a6),
    Color(0xFF06b6d4),
    Color(0xFF3b82f6),
    Color(0xFF4361ee),
    Color(0xFF8b5cf6),
    Color(0xFFa855f7),
    Color(0xFFec4899),
    Color(0xFFf43f5e),
    Color(0xFF1a1a2e),
    Color(0xFFfecaca),
    Color(0xFFbfdbfe),
    Color(0xFFd9f99d),
  ];

  static const List<double> strokeWidths = [1, 2, 3, 5, 8, 12];
  static const List<double> fontSizes = [14, 18, 24, 32, 48, 64];

  static const List<MapEntry<ShapeType, String>> shapes = [
    MapEntry(ShapeType.rectangle, '▭'),
    MapEntry(ShapeType.circle, '○'),
    MapEntry(ShapeType.triangle, '△'),
    MapEntry(ShapeType.diamond, '◇'),
    MapEntry(ShapeType.ellipse, '⬮'),
    MapEntry(ShapeType.star, '☆'),
    MapEntry(ShapeType.hexagon, '⬡'),
    MapEntry(ShapeType.rightTriangle, '◿'),
  ];

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final content = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSection('COLOR', _buildColorGrid()),
            _buildSection('STROKE WIDTH', _buildStrokeOptions()),
            _buildSection('OPACITY', _buildOpacitySlider()),
            if (controller.activeTool == BoardToolType.shape) ...[
              _buildSection('SHAPE', _buildShapeGrid()),
              _buildFillToggle(),
            ],
            if (controller.activeTool == BoardToolType.text) ...[
              _buildSection('FONT FAMILY', _buildFontSelector()),
              _buildSection('FONT SIZE', _buildFontSizes()),
            ],
            const SizedBox(height: 8),
            _buildSection('CANVAS', _buildCanvasType()),
            const SizedBox(height: 8),
            _buildDarkToggle(),
          ],
        );

        if (isInBottomSheet) {
          return content;
        }

        return Container(
          width: 220,
          decoration: BoxDecoration(
            color: const Color(0xFF0f1729),
            border: Border(
              left: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
            ),
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: content,
          ),
        );
      },
    );
  }

  Widget _buildSection(String label, Widget child) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.8,
              color: Colors.white.withValues(alpha: 0.3),
            ),
          ),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }

  Widget _buildColorGrid() {
    return Column(
      children: [
        Row(
          children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: controller.activeColor,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Colors.white24, width: 2),
                boxShadow: [
                  BoxShadow(
                    color: controller.activeColor.withValues(alpha: 0.4),
                    blurRadius: 6,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                children: [
                  _buildColorRow(colors.sublist(0, 6)),
                  const SizedBox(height: 3),
                  _buildColorRow(colors.sublist(6, 12)),
                  const SizedBox(height: 3),
                  _buildColorRow(colors.sublist(12, 18)),
                  const SizedBox(height: 3),
                  _buildColorRow(colors.sublist(18, 24)),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildColorRow(List<Color> rowColors) {
    return Row(
      children: rowColors.map((color) {
        final isActive = controller.activeColor.value == color.value;
        return Expanded(
          child: GestureDetector(
            onTap: () => controller.setColor(color),
            child: Container(
              height: 18,
              margin: const EdgeInsets.symmetric(horizontal: 1),
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(3),
                border:
                    isActive ? Border.all(color: Colors.white, width: 2) : null,
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildStrokeOptions() {
    return Wrap(
      spacing: 4,
      children: strokeWidths.map((w) {
        final isActive = controller.strokeWidth == w;
        return GestureDetector(
          onTap: () => controller.setStrokeWidth(w),
          child: Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              border: Border.all(
                color: isActive
                    ? const Color(0xFF4361ee)
                    : Colors.white.withValues(alpha: 0.08),
              ),
              borderRadius: BorderRadius.circular(6),
              color: isActive
                  ? const Color(0xFF4361ee).withValues(alpha: 0.15)
                  : Colors.transparent,
            ),
            child: Center(
              child: Container(
                width: (w * 1.5).clamp(3, 14),
                height: (w * 1.5).clamp(3, 14),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.9),
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildOpacitySlider() {
    // Show the selected object's opacity when one is selected
    final sel = controller.selectedObject;
    final displayOpacity = sel != null ? sel.opacity : controller.opacity;
    return Row(
      children: [
        Expanded(
          child: SliderTheme(
            data: SliderThemeData(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              activeTrackColor: const Color(0xFF4361ee),
              inactiveTrackColor: Colors.white.withValues(alpha: 0.15),
              thumbColor: const Color(0xFF4361ee),
              overlayColor: const Color(0xFF4361ee).withValues(alpha: 0.2),
            ),
            child: Slider(
              value: displayOpacity,
              min: 0.1,
              max: 1.0,
              onChanged: (v) => controller.setOpacity(v),
            ),
          ),
        ),
        SizedBox(
          width: 32,
          child: Text(
            '${(displayOpacity * 100).round()}%',
            textAlign: TextAlign.right,
            style: TextStyle(
              fontSize: 10,
              fontFamily: 'monospace',
              color: Colors.white.withValues(alpha: 0.5),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildShapeGrid() {
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: shapes.map((entry) {
        final isActive = controller.shapeType == entry.key;
        return GestureDetector(
          onTap: () => controller.setShapeType(entry.key),
          child: Container(
            width: 44,
            height: 36,
            decoration: BoxDecoration(
              border: Border.all(
                color: isActive
                    ? const Color(0xFF4361ee)
                    : Colors.white.withValues(alpha: 0.08),
              ),
              borderRadius: BorderRadius.circular(6),
              color: isActive
                  ? const Color(0xFF4361ee).withValues(alpha: 0.15)
                  : Colors.transparent,
            ),
            child: Center(
              child: Text(
                entry.value,
                style: TextStyle(
                  fontSize: 16,
                  color: isActive
                      ? const Color(0xFF4361ee)
                      : Colors.white.withValues(alpha: 0.5),
                ),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildFillToggle() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text('Filled',
              style: TextStyle(
                  fontSize: 13, color: Colors.white.withValues(alpha: 0.5))),
          GestureDetector(
            onTap: controller.toggleShapeFilled,
            child: Container(
              width: 36,
              height: 20,
              decoration: BoxDecoration(
                color: controller.shapeFilled
                    ? const Color(0xFF4361ee)
                    : Colors.white.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: AnimatedAlign(
                alignment: controller.shapeFilled
                    ? Alignment.centerRight
                    : Alignment.centerLeft,
                duration: const Duration(milliseconds: 200),
                child: Container(
                  width: 16,
                  height: 16,
                  margin: const EdgeInsets.all(2),
                  decoration: const BoxDecoration(
                      color: Colors.white, shape: BoxShape.circle),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFontSelector() {
    const fonts = ['Roboto', 'Courier', 'Georgia', 'serif', 'cursive'];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: controller.fontFamily,
          dropdownColor: const Color(0xFF1a1f3a),
          style: TextStyle(
              color: Colors.white.withValues(alpha: 0.9), fontSize: 13),
          isExpanded: true,
          items: fonts
              .map((f) => DropdownMenuItem(value: f, child: Text(f)))
              .toList(),
          onChanged: (v) {
            if (v != null) controller.setFontFamily(v);
          },
        ),
      ),
    );
  }

  Widget _buildFontSizes() {
    return Wrap(
      spacing: 4,
      children: fontSizes.map((s) {
        final isActive = controller.fontSize == s;
        return GestureDetector(
          onTap: () => controller.setFontSize(s),
          child: Container(
            width: 34,
            height: 30,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.06),
              border: Border.all(
                color: isActive
                    ? const Color(0xFF4361ee)
                    : Colors.white.withValues(alpha: 0.08),
              ),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Center(
              child: Text(
                '${s.toInt()}',
                style: TextStyle(
                  fontSize: 12,
                  color: isActive
                      ? const Color(0xFF4361ee)
                      : Colors.white.withValues(alpha: 0.5),
                ),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildCanvasType() {
    final types = CanvasBackground.values;
    final labels = ['Blank', 'Grid', 'Ruled', 'Dot', 'X/Y'];
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: List.generate(types.length, (i) {
        final isActive = controller.canvasBackground == types[i];
        return GestureDetector(
          onTap: () => controller.setCanvasBackground(types[i]),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: isActive
                  ? Colors.white.withValues(alpha: 0.1)
                  : Colors.white.withValues(alpha: 0.03),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                  color:
                      isActive ? const Color(0xFF4361ee) : Colors.transparent),
            ),
            child: Text(
              labels[i],
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: isActive
                    ? Colors.white
                    : Colors.white.withValues(alpha: 0.3),
              ),
            ),
          ),
        );
      }),
    );
  }

  Widget _buildDarkToggle() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text('Dark Canvas',
            style: TextStyle(
                fontSize: 13, color: Colors.white.withValues(alpha: 0.5))),
        GestureDetector(
          onTap: controller.toggleDarkMode,
          child: Container(
            width: 36,
            height: 20,
            decoration: BoxDecoration(
              color: controller.darkMode
                  ? const Color(0xFF4361ee)
                  : Colors.white.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: AnimatedAlign(
              alignment: controller.darkMode
                  ? Alignment.centerRight
                  : Alignment.centerLeft,
              duration: const Duration(milliseconds: 200),
              child: Container(
                width: 16,
                height: 16,
                margin: const EdgeInsets.all(2),
                decoration: const BoxDecoration(
                    color: Colors.white, shape: BoxShape.circle),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
