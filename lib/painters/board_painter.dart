import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../models/board_models.dart';
import '../models/board_controller.dart';

/// Cache for decoded images (keyed by object id).
final Map<String, ui.Image> _imageCache = {};
final Set<String> _imageDecoding = {}; // ids currently being decoded

/// Cached background pattern tiles (keyed by "type_darkMode").
/// Rendered once, then tiled via ImageShader — avoids 250k+ draw calls.
ui.Image? _dotTileLight;
ui.Image? _dotTileDark;
ui.Image? _gridTileLight;
ui.Image? _gridTileDark;

class BoardPainter extends CustomPainter {
  final BoardController controller;

  BoardPainter(this.controller) : super(repaint: controller);

  @override
  void paint(Canvas canvas, Size size) {
    _drawBackground(canvas, size);

    // Clip to canvas bounds
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, size.width, size.height));

    for (int i = 0; i < controller.currentObjects.length; i++) {
      // Skip the text object being edited inline (prevents ghost doubling)
      if (i == controller.editingTextIndex) continue;
      final obj = controller.currentObjects[i];
      final isSelected = controller.selectedObjectIndex == i;
      final isMultiSelected = controller.multiSelectedIndices.contains(i);
      _renderObject(canvas, obj, isSelected || isMultiSelected,
          isMultiSelected: isMultiSelected);
    }

    // Current stroke preview
    if (controller.currentStrokePoints != null &&
        controller.currentStrokePoints!.length >= 2) {
      _drawFreehandStroke(
        canvas,
        controller.currentStrokePoints!,
        controller.activeTool == BoardToolType.highlighter
            ? controller.activeColor.withValues(alpha: 0.35)
            : controller.activeTool == BoardToolType.eraser
                ? Colors.white
                : controller.activeColor.withValues(alpha: controller.opacity),
        controller.activeTool == BoardToolType.eraser
            ? controller.strokeWidth * 4
            : controller.strokeWidth,
        isHighlighter: controller.activeTool == BoardToolType.highlighter,
        isEraser: controller.activeTool == BoardToolType.eraser,
      );
    }

    // Shape preview
    if (controller.shapeStartPoint != null &&
        controller.shapeCurrentPoint != null) {
      _drawShapePreview(canvas);
    }

    // Laser
    if (controller.laserPoints.isNotEmpty) {
      _drawLaser(canvas);
    }

    // Marquee selection rectangle (dashed)
    if (controller.marqueeStart != null && controller.marqueeEnd != null) {
      _drawMarqueeRect(
          canvas, controller.marqueeStart!, controller.marqueeEnd!);
    }

    // Multi-selection bounding box
    if (controller.hasMultiSelection) {
      _drawMultiSelectionBounds(canvas);
    }

    canvas.restore();
  }

  // ============================================================
  // BACKGROUND
  // ============================================================

  void _drawBackground(Canvas canvas, Size size) {
    final bgColor =
        controller.darkMode ? const Color(0xFF1e1e2e) : Colors.white;
    canvas.drawRect(
        Rect.fromLTWH(0, 0, size.width, size.height), Paint()..color = bgColor);

    final isDark = controller.darkMode;

    switch (controller.canvasBackground) {
      case CanvasBackground.grid:
        _drawTiledGrid(canvas, size, isDark);
        break;

      case CanvasBackground.ruled:
        final lineColor = isDark
            ? Colors.white.withValues(alpha: 0.06)
            : Colors.black.withValues(alpha: 0.06);
        final paint = Paint()
          ..color = lineColor
          ..strokeWidth = 0.5;
        for (double y = 32; y < size.height; y += 28)
          canvas.drawLine(Offset(60, y), Offset(size.width - 20, y), paint);
        canvas.drawLine(
            Offset(60, 0),
            Offset(60, size.height),
            Paint()
              ..color = Colors.red.withValues(alpha: 0.2)
              ..strokeWidth = 1);
        break;

      case CanvasBackground.dot:
        _drawTiledDots(canvas, size, isDark);
        break;

      case CanvasBackground.cartesian:
        _drawTiledGrid(canvas, size, isDark);

        // Axes through center
        final axisColor = isDark
            ? Colors.white.withValues(alpha: 0.25)
            : Colors.black.withValues(alpha: 0.2);
        final axisPaint = Paint()
          ..color = axisColor
          ..strokeWidth = 1.5;
        final cx = size.width / 2;
        final cy = size.height / 2;
        canvas.drawLine(Offset(0, cy), Offset(size.width, cy), axisPaint);
        canvas.drawLine(Offset(cx, 0), Offset(cx, size.height), axisPaint);

        // Tick marks
        final tickPaint = Paint()
          ..color = axisColor
          ..strokeWidth = 1;
        const s = 24.0;
        for (double x = cx % s; x < size.width; x += s)
          canvas.drawLine(Offset(x, cy - 4), Offset(x, cy + 4), tickPaint);
        for (double y = cy % s; y < size.height; y += s)
          canvas.drawLine(Offset(cx - 4, y), Offset(cx + 4, y), tickPaint);
        break;

      case CanvasBackground.blank:
        break;
    }
  }

  /// Draw dot background using a cached tile + ImageShader.
  /// Renders a single 20×20 tile once, then fills the entire canvas
  /// with one drawRect call — ~1 GPU op instead of 250,000.
  void _drawTiledDots(Canvas canvas, Size size, bool isDark) {
    final tile = isDark ? _dotTileDark : _dotTileLight;
    if (tile != null) {
      final shader = ImageShader(
        tile,
        TileMode.repeated,
        TileMode.repeated,
        // Offset the tile by 12px to match original dot positioning
        (Matrix4.identity()..translate(12.0, 12.0)).storage,
      );
      canvas.drawRect(
        Rect.fromLTWH(0, 0, size.width, size.height),
        Paint()..shader = shader,
      );
      return;
    }

    // Generate tile asynchronously if not cached yet.
    _generateDotTile(isDark).then((_) => controller.refresh());
  }

  /// Draw grid background using a cached tile + ImageShader.
  void _drawTiledGrid(Canvas canvas, Size size, bool isDark) {
    final tile = isDark ? _gridTileDark : _gridTileLight;
    if (tile != null) {
      final shader = ImageShader(
        tile,
        TileMode.repeated,
        TileMode.repeated,
        Matrix4.identity().storage,
      );
      canvas.drawRect(
        Rect.fromLTWH(0, 0, size.width, size.height),
        Paint()..shader = shader,
      );
      return;
    }

    _generateGridTile(isDark).then((_) => controller.refresh());
  }

  /// Create a 20×20 tile with a single dot at center (matches spacing=20, radius=1.2).
  static Future<void> _generateDotTile(bool isDark) async {
    // Guard against duplicate generation
    final key = isDark ? '_dotDark' : '_dotLight';
    if (_imageDecoding.contains(key)) return;
    _imageDecoding.add(key);

    const tileSize = 20.0;
    final dotColor = isDark
        ? Colors.white.withValues(alpha: 0.06)
        : Colors.black.withValues(alpha: 0.06);

    final recorder = ui.PictureRecorder();
    final c = Canvas(recorder);
    // Transparent background — the bg color is already drawn by _drawBackground
    c.drawCircle(const Offset(tileSize / 2, tileSize / 2), 1.2,
        Paint()..color = dotColor);

    final picture = recorder.endRecording();
    final image = await picture.toImage(tileSize.toInt(), tileSize.toInt());
    picture.dispose();

    if (isDark) {
      _dotTileDark = image;
    } else {
      _dotTileLight = image;
    }
    _imageDecoding.remove(key);
  }

  /// Create a 24×24 tile with grid lines along edges.
  static Future<void> _generateGridTile(bool isDark) async {
    final key = isDark ? '_gridDark' : '_gridLight';
    if (_imageDecoding.contains(key)) return;
    _imageDecoding.add(key);

    const tileSize = 24.0;
    final lineColor = isDark
        ? Colors.white.withValues(alpha: 0.06)
        : Colors.black.withValues(alpha: 0.06);
    final paint = Paint()
      ..color = lineColor
      ..strokeWidth = 0.5;

    final recorder = ui.PictureRecorder();
    final c = Canvas(recorder);
    // Draw left edge and top edge — tiling repeats these into a full grid
    c.drawLine(const Offset(0, 0), const Offset(0, tileSize), paint);
    c.drawLine(const Offset(0, 0), const Offset(tileSize, 0), paint);

    final picture = recorder.endRecording();
    final image = await picture.toImage(tileSize.toInt(), tileSize.toInt());
    picture.dispose();

    if (isDark) {
      _gridTileDark = image;
    } else {
      _gridTileLight = image;
    }
    _imageDecoding.remove(key);
  }

  // ============================================================
  // RENDER OBJECTS
  // ============================================================

  void _renderObject(Canvas canvas, BoardObject obj, bool isSelected,
      {bool isMultiSelected = false}) {
    canvas.save();

    // Apply rotation around the object's center if any
    if (obj.rotation != 0.0) {
      final c = obj.center;
      canvas.translate(c.dx, c.dy);
      canvas.rotate(obj.rotation);
      canvas.translate(-c.dx, -c.dy);
    }

    if (obj is StrokeObject) {
      _drawFreehandStroke(
          canvas,
          obj.points,
          obj.isHighlighter
              ? obj.color.withValues(alpha: 0.35)
              : obj.color.withValues(alpha: obj.opacity),
          obj.strokeWidth,
          isHighlighter: obj.isHighlighter);
    } else if (obj is EraserObject) {
      _drawFreehandStroke(canvas, obj.points, Colors.white, obj.strokeWidth,
          isEraser: true);
    } else if (obj is LineObject) {
      _drawLine(canvas, obj);
    } else if (obj is ArrowObject) {
      _drawArrow(canvas, obj);
    } else if (obj is ShapeObject) {
      _drawShape(canvas, obj);
    } else if (obj is TextObject) {
      _drawText(canvas, obj);
    } else if (obj is ImageObject) {
      _drawImagePlaceholder(canvas, obj);
    } else if (obj is RulerObject) {
      _drawRuler(canvas, obj);
    }

    if (isSelected && isMultiSelected) {
      // Simplified highlight for multi-selected objects (no resize/rotate handles)
      _drawMultiSelectHighlight(canvas, obj);
    } else if (isSelected) {
      _drawSelection(canvas, obj);
    }

    canvas.restore();
  }

  // ============================================================
  // FREEHAND STROKE (perfect_freehand style)
  // ============================================================

  void _drawFreehandStroke(
      Canvas canvas, List<PointData> points, Color color, double size,
      {bool isHighlighter = false, bool isEraser = false}) {
    if (points.length < 2) return;

    final paint = Paint()
      ..color = color
      ..strokeWidth = size
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke
      ..isAntiAlias = true;

    if (isHighlighter) {
      paint.blendMode = BlendMode.multiply;
      paint.strokeWidth = size * 3;
    }

    if (isEraser) {
      paint.blendMode = BlendMode.srcOver;
      paint.color = Colors.white;
    }

    // Build smooth path with quadratic bezier
    final path = Path();
    path.moveTo(points[0].x, points[0].y);

    for (int i = 1; i < points.length - 1; i++) {
      final midX = (points[i].x + points[i + 1].x) / 2;
      final midY = (points[i].y + points[i + 1].y) / 2;
      path.quadraticBezierTo(points[i].x, points[i].y, midX, midY);
    }
    path.lineTo(points.last.x, points.last.y);

    // Variable width based on pressure — draw as filled outline
    if (!isHighlighter && !isEraser && size > 1) {
      final outlinePoints = _getStrokeOutline(points, size);
      if (outlinePoints.length >= 3) {
        final fillPath = Path();
        fillPath.moveTo(outlinePoints[0].dx, outlinePoints[0].dy);
        for (int i = 1; i < outlinePoints.length; i++) {
          fillPath.lineTo(outlinePoints[i].dx, outlinePoints[i].dy);
        }
        fillPath.close();
        canvas.drawPath(
            fillPath,
            Paint()
              ..color = color
              ..style = PaintingStyle.fill
              ..isAntiAlias = true);
        return;
      }
    }

    canvas.drawPath(path, paint);
  }

  List<Offset> _getStrokeOutline(List<PointData> points, double baseSize) {
    if (points.length < 2) return [];

    final left = <Offset>[];
    final right = <Offset>[];

    for (int i = 0; i < points.length; i++) {
      final p = points[i];
      final pressure = p.pressure.clamp(0.2, 1.0);
      final radius = baseSize * (0.5 + 0.5 * pressure) / 2;

      double perpX, perpY;
      if (i == 0) {
        final n = points[i + 1];
        final dx = n.x - p.x, dy = n.y - p.y;
        final len = sqrt(dx * dx + dy * dy);
        if (len == 0) continue;
        perpX = -dy / len;
        perpY = dx / len;
      } else if (i == points.length - 1) {
        final prev = points[i - 1];
        final dx = p.x - prev.x, dy = p.y - prev.y;
        final len = sqrt(dx * dx + dy * dy);
        if (len == 0) continue;
        perpX = -dy / len;
        perpY = dx / len;
      } else {
        final prev = points[i - 1], n = points[i + 1];
        final dx = n.x - prev.x, dy = n.y - prev.y;
        final len = sqrt(dx * dx + dy * dy);
        if (len == 0) continue;
        perpX = -dy / len;
        perpY = dx / len;
      }

      left.add(Offset(p.x + perpX * radius, p.y + perpY * radius));
      right.add(Offset(p.x - perpX * radius, p.y - perpY * radius));
    }

    return [...left, ...right.reversed];
  }

  // ============================================================
  // LINE / ARROW / RULER
  // ============================================================

  void _drawLine(Canvas canvas, LineObject obj) {
    canvas.drawLine(
        obj.start,
        obj.end,
        Paint()
          ..color = obj.color.withValues(alpha: obj.opacity)
          ..strokeWidth = obj.strokeWidth
          ..strokeCap = StrokeCap.round);
  }

  void _drawArrow(Canvas canvas, ArrowObject obj) {
    final paint = Paint()
      ..color = obj.color.withValues(alpha: obj.opacity)
      ..strokeWidth = obj.strokeWidth
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(obj.start, obj.end, paint);

    final angle = atan2(obj.end.dy - obj.start.dy, obj.end.dx - obj.start.dx);
    final headLen = 14.0 + obj.strokeWidth;
    final p1 = Offset(obj.end.dx - headLen * cos(angle - pi / 6),
        obj.end.dy - headLen * sin(angle - pi / 6));
    final p2 = Offset(obj.end.dx - headLen * cos(angle + pi / 6),
        obj.end.dy - headLen * sin(angle + pi / 6));
    canvas.drawPath(
      Path()
        ..moveTo(obj.end.dx, obj.end.dy)
        ..lineTo(p1.dx, p1.dy)
        ..lineTo(p2.dx, p2.dy)
        ..close(),
      Paint()
        ..color = obj.color.withValues(alpha: obj.opacity)
        ..style = PaintingStyle.fill,
    );
  }

  void _drawRuler(Canvas canvas, RulerObject obj) {
    final paint = Paint()
      ..color = obj.color.withValues(alpha: obj.opacity)
      ..strokeWidth = obj.strokeWidth
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(obj.start, obj.end, paint);

    // End caps (perpendicular ticks)
    final angle = atan2(obj.end.dy - obj.start.dy, obj.end.dx - obj.start.dx);
    final perpAngle = angle + pi / 2;
    const tickLen = 8.0;

    for (final pt in [obj.start, obj.end]) {
      canvas.drawLine(
        Offset(
            pt.dx + tickLen * cos(perpAngle), pt.dy + tickLen * sin(perpAngle)),
        Offset(
            pt.dx - tickLen * cos(perpAngle), pt.dy - tickLen * sin(perpAngle)),
        paint,
      );
    }

    // Distance label
    final dist = obj.length;
    final label = '${dist.toStringAsFixed(0)} px';
    final mid = Offset(
        (obj.start.dx + obj.end.dx) / 2, (obj.start.dy + obj.end.dy) / 2);

    final textPainter = TextPainter(
      text: TextSpan(
          text: label,
          style: TextStyle(
            color: obj.color.withValues(alpha: obj.opacity),
            fontSize: 12,
            fontWeight: FontWeight.w600,
            backgroundColor: controller.darkMode
                ? const Color(0xAA1e1e2e)
                : const Color(0xAAFFFFFF),
          )),
      textDirection: TextDirection.ltr,
    )..layout();

    textPainter.paint(
        canvas,
        Offset(
            mid.dx - textPainter.width / 2, mid.dy - textPainter.height - 6));
  }

  // ============================================================
  // SHAPES — including new geometry shapes
  // ============================================================

  void _drawShape(Canvas canvas, ShapeObject obj) {
    final paint = Paint()
      ..color = obj.color.withValues(alpha: obj.opacity)
      ..strokeWidth = obj.strokeWidth
      ..style = obj.filled ? PaintingStyle.fill : PaintingStyle.stroke;

    final r = obj.rect;

    switch (obj.shapeType) {
      case ShapeType.rectangle:
        canvas.drawRRect(
            RRect.fromRectAndRadius(r, const Radius.circular(2)), paint);
        break;
      case ShapeType.circle:
        final radius = min(r.width.abs(), r.height.abs()) / 2;
        canvas.drawCircle(r.center, radius, paint);
        break;
      case ShapeType.ellipse:
        canvas.drawOval(r, paint);
        break;
      case ShapeType.triangle:
        canvas.drawPath(
            Path()
              ..moveTo(r.center.dx, r.top)
              ..lineTo(r.right, r.bottom)
              ..lineTo(r.left, r.bottom)
              ..close(),
            paint);
        break;
      case ShapeType.rightTriangle:
        canvas.drawPath(
            Path()
              ..moveTo(r.left, r.top)
              ..lineTo(r.left, r.bottom)
              ..lineTo(r.right, r.bottom)
              ..close(),
            paint);
        // Right angle marker
        const m = 12.0;
        canvas.drawPath(
          Path()
            ..moveTo(r.left + m, r.bottom)
            ..lineTo(r.left + m, r.bottom - m)
            ..lineTo(r.left, r.bottom - m),
          Paint()
            ..color = obj.color.withValues(alpha: obj.opacity * 0.6)
            ..strokeWidth = 1
            ..style = PaintingStyle.stroke,
        );
        break;
      case ShapeType.diamond:
        canvas.drawPath(
            Path()
              ..moveTo(r.center.dx, r.top)
              ..lineTo(r.right, r.center.dy)
              ..lineTo(r.center.dx, r.bottom)
              ..lineTo(r.left, r.center.dy)
              ..close(),
            paint);
        break;
      case ShapeType.star:
        _drawStarPath(
            canvas, r.center, min(r.width.abs(), r.height.abs()) / 2, 5, paint);
        break;
      case ShapeType.hexagon:
        _drawRegularPolygon(
            canvas, r.center, min(r.width.abs(), r.height.abs()) / 2, 6, paint);
        break;
      case ShapeType.parallelogram:
        final skew = r.width * 0.2;
        canvas.drawPath(
            Path()
              ..moveTo(r.left + skew, r.top)
              ..lineTo(r.right, r.top)
              ..lineTo(r.right - skew, r.bottom)
              ..lineTo(r.left, r.bottom)
              ..close(),
            paint);
        break;
      case ShapeType.trapezoid:
        final inset = r.width * 0.15;
        canvas.drawPath(
            Path()
              ..moveTo(r.left + inset, r.top)
              ..lineTo(r.right - inset, r.top)
              ..lineTo(r.right, r.bottom)
              ..lineTo(r.left, r.bottom)
              ..close(),
            paint);
        break;
    }
  }

  void _drawStarPath(
      Canvas canvas, Offset center, double outerR, int points, Paint paint) {
    final innerR = outerR * 0.4;
    final path = Path();
    var angle = -pi / 2;
    final step = pi / points;
    path.moveTo(
        center.dx + outerR * cos(angle), center.dy + outerR * sin(angle));
    for (int i = 0; i < points; i++) {
      angle += step;
      path.lineTo(
          center.dx + innerR * cos(angle), center.dy + innerR * sin(angle));
      angle += step;
      path.lineTo(
          center.dx + outerR * cos(angle), center.dy + outerR * sin(angle));
    }
    path.close();
    canvas.drawPath(path, paint);
  }

  void _drawRegularPolygon(
      Canvas canvas, Offset center, double radius, int sides, Paint paint) {
    final path = Path();
    var angle = -pi / 2;
    final step = 2 * pi / sides;
    path.moveTo(
        center.dx + radius * cos(angle), center.dy + radius * sin(angle));
    for (int i = 1; i < sides; i++) {
      angle += step;
      path.lineTo(
          center.dx + radius * cos(angle), center.dy + radius * sin(angle));
    }
    path.close();
    canvas.drawPath(path, paint);
  }

  // ============================================================
  // TEXT / IMAGE
  // ============================================================

  /// Detects if text starts with RTL characters (Arabic, Hebrew, etc.)
  static TextDirection _detectDir(String text) {
    if (text.isEmpty) return TextDirection.ltr;
    final trimmed = text.trimLeft();
    if (trimmed.isEmpty) return TextDirection.ltr;
    final c = trimmed.codeUnitAt(0);
    if ((c >= 0x0590 && c <= 0x05FF) ||
        (c >= 0x0600 && c <= 0x06FF) ||
        (c >= 0x0750 && c <= 0x077F) ||
        (c >= 0xFB50 && c <= 0xFDFF) ||
        (c >= 0xFE70 && c <= 0xFEFF)) {
      return TextDirection.rtl;
    }
    return TextDirection.ltr;
  }

  void _drawText(Canvas canvas, TextObject obj) {
    final dir = _detectDir(obj.text);
    final lines = obj.text.split('\n');
    for (int i = 0; i < lines.length; i++) {
      final tp = TextPainter(
        text: TextSpan(
            text: lines[i],
            style: TextStyle(
              color: obj.color.withValues(alpha: obj.opacity),
              fontSize: obj.fontSize,
              fontFamily: obj.fontFamily,
            )),
        textDirection: dir,
        textAlign: dir == TextDirection.rtl ? TextAlign.right : TextAlign.left,
      )..layout();
      tp.paint(canvas,
          Offset(obj.position.dx, obj.position.dy + i * obj.fontSize * 1.3));
    }
  }

  void _drawImagePlaceholder(Canvas canvas, ImageObject obj) {
    final rect = Rect.fromLTWH(
        obj.position.dx, obj.position.dy, obj.size.width, obj.size.height);

    // If we have a cached decoded image, draw it
    final cached = _imageCache[obj.id];
    if (cached != null) {
      // If this is the first paint, correct the size to match aspect ratio
      final srcRect = Rect.fromLTWH(
          0, 0, cached.width.toDouble(), cached.height.toDouble());
      final paint = Paint()
        ..filterQuality = FilterQuality.medium
        ..color = Color.fromRGBO(255, 255, 255, obj.opacity);
      canvas.drawImageRect(cached, srcRect, rect, paint);
      return;
    }

    // If we have bytes but haven't decoded yet, start decoding
    if (obj.imageBytes != null && !_imageDecoding.contains(obj.id)) {
      _imageDecoding.add(obj.id);
      ui.decodeImageFromList(obj.imageBytes!, (ui.Image decoded) {
        _imageCache[obj.id] = decoded;
        _imageDecoding.remove(obj.id);

        // Fix the size to match aspect ratio on first decode
        final aspect = decoded.width / decoded.height;
        final maxSide = max(obj.size.width, obj.size.height);
        if (aspect >= 1) {
          obj.size = Size(maxSide, maxSide / aspect);
        } else {
          obj.size = Size(maxSide * aspect, maxSide);
        }

        // Trigger repaint
        controller.refresh();
      });
    }

    // While decoding (or no bytes), draw a placeholder
    canvas.drawRect(
        rect,
        Paint()
          ..color = Colors.grey.withValues(alpha: 0.15)
          ..style = PaintingStyle.fill);
    canvas.drawRect(
        rect,
        Paint()
          ..color = Colors.grey.withValues(alpha: 0.4)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1);

    // Loading indicator or placeholder icon
    final iconText = obj.imageBytes != null ? '⏳' : '🖼️';
    final tp = TextPainter(
      text: TextSpan(text: iconText, style: const TextStyle(fontSize: 32)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas,
        Offset(rect.center.dx - tp.width / 2, rect.center.dy - tp.height / 2));
  }

  // ============================================================
  // SHAPE PREVIEW
  // ============================================================

  void _drawShapePreview(Canvas canvas) {
    final s = controller.shapeStartPoint!;
    final c = controller.shapeCurrentPoint!;
    final previewPaint = Paint()
      ..color = controller.activeColor.withValues(alpha: 0.5)
      ..strokeWidth = controller.strokeWidth
      ..style = PaintingStyle.stroke;

    if (controller.activeTool == BoardToolType.line ||
        controller.activeTool == BoardToolType.ruler) {
      canvas.drawLine(s, c, previewPaint);
      if (controller.activeTool == BoardToolType.ruler) {
        final dist = (c - s).distance;
        final mid = Offset((s.dx + c.dx) / 2, (s.dy + c.dy) / 2);
        final tp = TextPainter(
          text: TextSpan(
              text: '${dist.toStringAsFixed(0)} px',
              style: TextStyle(
                  color: controller.activeColor.withValues(alpha: 0.7),
                  fontSize: 11)),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(mid.dx - tp.width / 2, mid.dy - tp.height - 8));
      }
    } else if (controller.activeTool == BoardToolType.arrow) {
      canvas.drawLine(s, c, previewPaint);
    } else if (controller.activeTool == BoardToolType.shape) {
      final rect = Rect.fromPoints(s, c);
      final preview = ShapeObject(
          id: 'preview',
          rect: rect,
          shapeType: controller.shapeType,
          color: controller.activeColor,
          strokeWidth: controller.strokeWidth,
          filled: controller.shapeFilled,
          opacity: 0.5);
      _drawShape(canvas, preview);
    }
  }

  // ============================================================
  // LASER
  // ============================================================

  void _drawLaser(Canvas canvas) {
    final points = controller.laserPoints;
    if (points.length < 2) return;
    for (int i = 1; i < points.length; i++) {
      final alpha = i / points.length;
      canvas.drawLine(
          points[i - 1],
          points[i],
          Paint()
            ..color = Colors.red.withValues(alpha: alpha * 0.8)
            ..strokeWidth = 3
            ..strokeCap = StrokeCap.round
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6));
    }
    final last = points.last;
    canvas.drawCircle(
        last,
        6,
        Paint()
          ..color = Colors.red
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12));
    canvas.drawCircle(last, 4, Paint()..color = Colors.red);
  }

  // ============================================================
  // SELECTION HANDLES
  // ============================================================

  void _drawSelection(Canvas canvas, BoardObject obj) {
    final bounds = obj.getBounds();
    final b = bounds.inflate(4);
    final selPaint = Paint()
      ..color = const Color(0xFF4361ee)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    // Dashed-look border
    canvas.drawRect(b, selPaint);

    // Corner handles
    final handleFill = Paint()
      ..color = const Color(0xFF4361ee)
      ..style = PaintingStyle.fill;
    final handleBorder = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    const r = 6.0;

    for (final corner in [
      b.topLeft,
      b.topRight,
      b.bottomLeft,
      b.bottomRight,
    ]) {
      canvas.drawCircle(corner, r, handleFill);
      canvas.drawCircle(corner, r, handleBorder);
    }

    // ---- Rotation handle ----
    // Stem line from top-center upward
    final topCenter = Offset(b.center.dx, b.top);
    const rotOffset = 28.0;
    final rotPos = Offset(b.center.dx, b.top - rotOffset);
    final stemPaint = Paint()
      ..color = const Color(0xFF4361ee).withValues(alpha: 0.5)
      ..strokeWidth = 1.5;
    canvas.drawLine(topCenter, rotPos, stemPaint);

    // Rotation circle with icon
    canvas.drawCircle(rotPos, 10, Paint()..color = const Color(0xFF4361ee));
    canvas.drawCircle(
        rotPos,
        10,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5);
    // Small rotation arrow icon
    final iconPaint = Paint()
      ..color = Colors.white
      ..strokeWidth = 1.8
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final arc = Rect.fromCircle(center: rotPos, radius: 5);
    canvas.drawArc(arc, -pi * 0.8, pi * 1.3, false, iconPaint);
    // arrowhead
    final arrowTip = Offset(rotPos.dx + 3, rotPos.dy - 5);
    canvas.drawLine(
        arrowTip, Offset(arrowTip.dx + 3, arrowTip.dy + 2), iconPaint);
    canvas.drawLine(
        arrowTip, Offset(arrowTip.dx - 1, arrowTip.dy + 3), iconPaint);
  }

  // ============================================================
  // MARQUEE & MULTI-SELECTION
  // ============================================================

  /// Draw a dashed rectangle while the user drags for marquee selection.
  void _drawMarqueeRect(Canvas canvas, Offset start, Offset end) {
    final rect = Rect.fromPoints(start, end);

    // Semi-transparent blue fill
    canvas.drawRect(
      rect,
      Paint()
        ..color = const Color(0xFF4361ee).withValues(alpha: 0.08)
        ..style = PaintingStyle.fill,
    );

    // Dashed border
    final dashPaint = Paint()
      ..color = const Color(0xFF4361ee).withValues(alpha: 0.7)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    _drawDashedRect(canvas, rect, dashPaint, dashLength: 8, gapLength: 5);
  }

  /// Simplified blue highlight for objects that are part of a multi-selection.
  void _drawMultiSelectHighlight(Canvas canvas, BoardObject obj) {
    final b = obj.getBounds();

    // Blue tinted fill
    canvas.drawRect(
      b.inflate(3),
      Paint()
        ..color = const Color(0xFF4361ee).withValues(alpha: 0.08)
        ..style = PaintingStyle.fill,
    );

    // Blue border (no handles, no rotation knob)
    canvas.drawRect(
      b.inflate(3),
      Paint()
        ..color = const Color(0xFF4361ee).withValues(alpha: 0.5)
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke,
    );
  }

  /// Draw a bounding box around all multi-selected objects with dashed border.
  void _drawMultiSelectionBounds(Canvas canvas) {
    final bounds = controller.multiSelectionBounds;
    if (bounds == null) return;

    final inflated = bounds.inflate(8);

    // Very subtle fill
    canvas.drawRect(
      inflated,
      Paint()
        ..color = const Color(0xFF4361ee).withValues(alpha: 0.04)
        ..style = PaintingStyle.fill,
    );

    // Dashed border
    final dashPaint = Paint()
      ..color = const Color(0xFF4361ee).withValues(alpha: 0.4)
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;

    _drawDashedRect(canvas, inflated, dashPaint, dashLength: 6, gapLength: 4);
  }

  /// Helper: draw a dashed rectangle.
  void _drawDashedRect(Canvas canvas, Rect rect, Paint paint,
      {double dashLength = 8, double gapLength = 5}) {
    final edges = [
      [rect.topLeft, rect.topRight],
      [rect.topRight, rect.bottomRight],
      [rect.bottomRight, rect.bottomLeft],
      [rect.bottomLeft, rect.topLeft],
    ];

    for (final edge in edges) {
      final start = edge[0];
      final end = edge[1];
      final dx = end.dx - start.dx;
      final dy = end.dy - start.dy;
      final length = sqrt(dx * dx + dy * dy);
      final unitX = dx / length;
      final unitY = dy / length;

      double drawn = 0;
      bool drawing = true;
      while (drawn < length) {
        final segLen = drawing ? dashLength : gapLength;
        final remaining = length - drawn;
        final seg = segLen < remaining ? segLen : remaining;
        if (drawing) {
          canvas.drawLine(
            Offset(start.dx + unitX * drawn, start.dy + unitY * drawn),
            Offset(start.dx + unitX * (drawn + seg),
                start.dy + unitY * (drawn + seg)),
            paint,
          );
        }
        drawn += seg;
        drawing = !drawing;
      }
    }
  }

  // ============================================================
  // EXPORT TO IMAGE
  // ============================================================

  /// Renders the board contents to a PNG image.
  /// Returns the raw PNG bytes, or null if the board is empty.
  ///
  /// [padding] – extra space around the content (in canvas units).
  /// [maxSide] – the longest dimension of the output image in pixels.
  /// [backgroundColor] – override; defaults to the controller's dark/light bg.
  static Future<Uint8List?> exportToImage(
    BoardController controller, {
    double padding = 40,
    double maxSide = 1920,
    Color? backgroundColor,
  }) async {
    final objects = controller.currentObjects;
    if (objects.isEmpty) return null;

    // 1. Compute the bounding rect of all objects.
    Rect bounds = objects.first.getBounds();
    for (final obj in objects) {
      bounds = bounds.expandToInclude(obj.getBounds());
    }
    bounds = bounds.inflate(padding);

    // 2. Determine output size (scale to fit maxSide).
    final scale = maxSide / max(bounds.width, bounds.height);
    final w = (bounds.width * scale).ceil();
    final h = (bounds.height * scale).ceil();

    // 3. Record drawing commands.
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    // Background
    final bgColor = backgroundColor ??
        (controller.darkMode ? const Color(0xFF1e1e2e) : Colors.white);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      Paint()..color = bgColor,
    );

    // Translate & scale so objects land correctly.
    canvas.scale(scale);
    canvas.translate(-bounds.left, -bounds.top);

    // 4. Paint every object (no selection highlights).
    final painter = BoardPainter(controller);
    for (final obj in objects) {
      painter._renderObject(canvas, obj, false);
    }

    // 5. Convert to PNG bytes.
    final picture = recorder.endRecording();
    final image = await picture.toImage(w, h);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return byteData?.buffer.asUint8List();
  }

  /// Renders the board to raw RGBA pixel data at a specific resolution.
  ///
  /// Used by [BoardRecorder] for video encoding — raw pixels are much
  /// cheaper than PNG and the native encoder needs them anyway.
  static Future<Uint8List?> exportToRawRgba(
    BoardController controller, {
    required int width,
    required int height,
  }) async {
    final objects = controller.currentObjects;

    // Record drawing commands.
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    final w = width.toDouble();
    final h = height.toDouble();

    // Background
    final bgColor =
        controller.darkMode ? const Color(0xFF1e1e2e) : Colors.white;
    canvas.drawRect(Rect.fromLTWH(0, 0, w, h), Paint()..color = bgColor);

    // Draw background pattern
    final painter = BoardPainter(controller);
    painter._drawBackground(canvas, Size(w, h));

    if (objects.isNotEmpty) {
      // Compute bounding rect of all objects to center content.
      Rect bounds = objects.first.getBounds();
      for (final obj in objects) {
        bounds = bounds.expandToInclude(obj.getBounds());
      }
      bounds = bounds.inflate(40);

      // Scale to fit the target resolution.
      final scaleX = w / bounds.width;
      final scaleY = h / bounds.height;
      final scale = scaleX < scaleY ? scaleX : scaleY;

      // Center the content.
      final offsetX = (w - bounds.width * scale) / 2;
      final offsetY = (h - bounds.height * scale) / 2;

      canvas.save();
      canvas.translate(offsetX, offsetY);
      canvas.scale(scale);
      canvas.translate(-bounds.left, -bounds.top);

      for (final obj in objects) {
        painter._renderObject(canvas, obj, false);
      }
      canvas.restore();
    }

    // Convert to raw RGBA pixels.
    final picture = recorder.endRecording();
    final image = await picture.toImage(width, height);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    image.dispose();
    return byteData?.buffer.asUint8List();
  }

  /// Renders the board viewport (what the user actually sees) to raw RGBA.
  /// Simple direct capture — exactly like phone screen recorders.
  ///
  /// [viewportWidth] / [viewportHeight] — logical pixel dimensions of the
  /// visible canvas area on screen.
  /// [outputWidth] / [outputHeight] — recording resolution in pixels.
  static Future<Uint8List?> exportViewportToRawRgba(
    BoardController controller, {
    required double viewportWidth,
    required double viewportHeight,
    required int outputWidth,
    required int outputHeight,
  }) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    final ow = outputWidth.toDouble();
    final oh = outputHeight.toDouble();

    // Scale from viewport to output resolution
    final scaleX = ow / viewportWidth;
    final scaleY = oh / viewportHeight;
    final scale = scaleX < scaleY ? scaleX : scaleY;
    final offsetX = (ow - viewportWidth * scale) / 2;
    final offsetY = (oh - viewportHeight * scale) / 2;

    // Background
    final bgColor =
        controller.darkMode ? const Color(0xFF1e1e2e) : Colors.white;
    canvas.drawRect(Rect.fromLTWH(0, 0, ow, oh), Paint()..color = bgColor);

    canvas.save();
    canvas.translate(offsetX, offsetY);
    canvas.scale(scale);

    // Apply same transform as live widget
    const canvasSize = 10000.0;
    final z = controller.zoom;
    final px = controller.panOffset.dx;
    final py = controller.panOffset.dy;

    canvas.translate(px + viewportWidth / 2, py + viewportHeight / 2);
    canvas.scale(z);
    canvas.translate(-canvasSize / 2, -canvasSize / 2);
    canvas.clipRect(Rect.fromLTWH(0, 0, canvasSize, canvasSize));

    // Draw content
    final painter = BoardPainter(controller);
    painter._drawBackground(canvas, const Size(canvasSize, canvasSize));

    for (final obj in controller.currentObjects) {
      painter._renderObject(canvas, obj, false);
    }

    // Current stroke being drawn
    if (controller.currentStrokePoints != null &&
        controller.currentStrokePoints!.length >= 2) {
      painter._drawFreehandStroke(
        canvas,
        controller.currentStrokePoints!,
        controller.activeTool == BoardToolType.highlighter
            ? controller.activeColor.withValues(alpha: 0.35)
            : controller.activeTool == BoardToolType.eraser
                ? Colors.white
                : controller.activeColor.withValues(alpha: controller.opacity),
        controller.activeTool == BoardToolType.eraser
            ? controller.strokeWidth * 4
            : controller.strokeWidth,
        isHighlighter: controller.activeTool == BoardToolType.highlighter,
        isEraser: controller.activeTool == BoardToolType.eraser,
      );
    }

    // Shape preview
    if (controller.shapeStartPoint != null &&
        controller.shapeCurrentPoint != null) {
      painter._drawShapePreview(canvas);
    }

    // Laser pointer
    if (controller.laserPoints.isNotEmpty) {
      painter._drawLaser(canvas);
    }

    canvas.restore();

    // Render directly at output resolution
    final picture = recorder.endRecording();
    final image = await picture.toImage(outputWidth, outputHeight);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    image.dispose();
    return byteData?.buffer.asUint8List();
  }

  /// Renders a specific rectangular region of the canvas (the "recording
  /// frame") to raw RGBA at the given output resolution.
  ///
  /// Used by [BoardRecorder] for content-tracking video capture.
  /// The [frame] rect is in canvas coordinates (0..10000) and defines
  /// exactly which portion of the board appears in the video. The content
  /// within [frame] is scaled to fill [outputWidth]×[outputHeight] at
  /// maximum quality — completely independent of user zoom/pan.
  static Future<Uint8List?> exportFrameToRawRgba(
    BoardController controller, {
    required Rect frame,
    required int outputWidth,
    required int outputHeight,
  }) async {
    final ow = outputWidth.toDouble();
    final oh = outputHeight.toDouble();

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    // Background fill
    final bgColor =
        controller.darkMode ? const Color(0xFF1e1e2e) : Colors.white;
    canvas.drawRect(Rect.fromLTWH(0, 0, ow, oh), Paint()..color = bgColor);

    // Map the recording frame → output pixels
    final scaleX = ow / frame.width;
    final scaleY = oh / frame.height;
    final scale = scaleX < scaleY ? scaleX : scaleY;
    final offsetX = (ow - frame.width * scale) / 2;
    final offsetY = (oh - frame.height * scale) / 2;

    canvas.save();
    canvas.translate(offsetX, offsetY);
    canvas.scale(scale);
    canvas.translate(-frame.left, -frame.top);

    // Clip to the frame region so we don't render the entire 10k canvas bg
    canvas.clipRect(frame.inflate(50));

    // Background pattern
    final painter = BoardPainter(controller);
    painter._drawBackground(canvas, const Size(10000, 10000));

    // All objects on the current page
    for (final obj in controller.currentObjects) {
      painter._renderObject(canvas, obj, false);
    }

    canvas.restore();

    // Convert to raw RGBA
    final picture = recorder.endRecording();
    final image = await picture.toImage(outputWidth, outputHeight);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    image.dispose();
    return byteData?.buffer.asUint8List();
  }

  @override
  bool shouldRepaint(covariant BoardPainter oldDelegate) => true;
}
