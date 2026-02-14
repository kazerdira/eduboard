import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui';
import 'dart:math' as math;
import 'package:flutter/material.dart';

enum BoardToolType {
  pen,
  highlighter,
  eraser,
  line,
  arrow,
  shape,
  text,
  select,
  pan,
  laser,
  image,
  ruler, // measured line with distance
  protractor, // angle measurement
  coordAxes, // x/y coordinate grid overlay
}

enum ShapeType {
  rectangle,
  circle,
  triangle,
  ellipse,
  diamond,
  star,
  hexagon,
  parallelogram,
  trapezoid,
  rightTriangle,
}

enum CanvasBackground { blank, grid, ruled, dot, cartesian }

class PointData {
  final double x;
  final double y;
  final double pressure;

  const PointData(this.x, this.y, [this.pressure = 0.5]);

  Map<String, dynamic> toJson() => {'x': x, 'y': y, 'p': pressure};

  factory PointData.fromJson(Map<String, dynamic> json) => PointData(
      json['x'] as double, json['y'] as double, json['p'] as double? ?? 0.5);

  Offset toOffset() => Offset(x, y);
}

// ============================================================
// Base class
// ============================================================

abstract class BoardObject {
  final String id;
  double opacity;
  final int timestamp;
  double rotation; // radians, clockwise

  BoardObject({
    required this.id,
    this.opacity = 1.0,
    this.rotation = 0.0,
    int? timestamp,
  }) : timestamp = timestamp ?? DateTime.now().millisecondsSinceEpoch;

  Map<String, dynamic> toJson();

  /// Every object must provide a bounding rect for hit testing & selection
  Rect getBounds();

  /// Move the object by a delta offset
  void translate(Offset delta);

  /// Scale the object around its center by [factor].
  void scaleBy(double factor);

  /// The center of the object's bounding box.
  Offset get center => getBounds().center;

  /// Creates a deep copy of this object.
  /// Unlike toJson()/fromJson(), this is efficient and doesn't allocate
  /// large temporary strings (e.g., base64 for images).
  BoardObject clone();

  factory BoardObject.fromJson(Map<String, dynamic> json) {
    switch (json['type'] as String) {
      case 'stroke':
        return StrokeObject.fromJson(json);
      case 'line':
        return LineObject.fromJson(json);
      case 'arrow':
        return ArrowObject.fromJson(json);
      case 'shape':
        return ShapeObject.fromJson(json);
      case 'text':
        return TextObject.fromJson(json);
      case 'image':
        return ImageObject.fromJson(json);
      case 'eraser':
        return EraserObject.fromJson(json);
      case 'ruler':
        return RulerObject.fromJson(json);
      default:
        throw Exception('Unknown object type: ${json['type']}');
    }
  }
}

// ============================================================
// Stroke (pen / highlighter)
// ============================================================

class StrokeObject extends BoardObject {
  List<PointData> points;
  Color color;
  double strokeWidth;
  final bool isHighlighter;

  StrokeObject({
    required super.id,
    required this.points,
    required this.color,
    required this.strokeWidth,
    this.isHighlighter = false,
    super.opacity,
    super.rotation,
    super.timestamp,
  });

  @override
  void scaleBy(double factor) {
    final c = getBounds().center;
    points = points
        .map((p) => PointData(c.dx + (p.x - c.dx) * factor,
            c.dy + (p.y - c.dy) * factor, p.pressure))
        .toList();
    strokeWidth = (strokeWidth * factor).clamp(0.5, 50.0);
  }

  @override
  Rect getBounds() {
    if (points.isEmpty) return Rect.zero;
    double minX = double.infinity, minY = double.infinity;
    double maxX = double.negativeInfinity, maxY = double.negativeInfinity;
    for (final p in points) {
      if (p.x < minX) minX = p.x;
      if (p.y < minY) minY = p.y;
      if (p.x > maxX) maxX = p.x;
      if (p.y > maxY) maxY = p.y;
    }
    return Rect.fromLTRB(minX, minY, maxX, maxY).inflate(strokeWidth);
  }

  @override
  void translate(Offset delta) {
    points = points
        .map((p) => PointData(p.x + delta.dx, p.y + delta.dy, p.pressure))
        .toList();
  }

  @override
  Map<String, dynamic> toJson() => {
        'type': 'stroke',
        'id': id,
        'points': points.map((p) => p.toJson()).toList(),
        'color': color.value,
        'strokeWidth': strokeWidth,
        'isHighlighter': isHighlighter,
        'opacity': opacity,
        'rotation': rotation,
        'timestamp': timestamp,
      };

  factory StrokeObject.fromJson(Map<String, dynamic> json) => StrokeObject(
        id: json['id'] as String,
        points: (json['points'] as List)
            .map((p) => PointData.fromJson(p as Map<String, dynamic>))
            .toList(),
        color: Color(json['color'] as int),
        strokeWidth: (json['strokeWidth'] as num).toDouble(),
        isHighlighter: json['isHighlighter'] as bool? ?? false,
        opacity: (json['opacity'] as num?)?.toDouble() ?? 1.0,
        rotation: (json['rotation'] as num?)?.toDouble() ?? 0.0,
        timestamp: json['timestamp'] as int?,
      );

  @override
  StrokeObject clone() => StrokeObject(
        id: id,
        points: points.map((p) => PointData(p.x, p.y, p.pressure)).toList(),
        color: color,
        strokeWidth: strokeWidth,
        isHighlighter: isHighlighter,
        opacity: opacity,
        rotation: rotation,
        timestamp: timestamp,
      );
}

// ============================================================
// Eraser
// ============================================================

class EraserObject extends BoardObject {
  List<PointData> points;
  final double strokeWidth;

  EraserObject({
    required super.id,
    required this.points,
    required this.strokeWidth,
    super.timestamp,
  });

  @override
  Rect getBounds() {
    if (points.isEmpty) return Rect.zero;
    double minX = double.infinity, minY = double.infinity;
    double maxX = double.negativeInfinity, maxY = double.negativeInfinity;
    for (final p in points) {
      if (p.x < minX) minX = p.x;
      if (p.y < minY) minY = p.y;
      if (p.x > maxX) maxX = p.x;
      if (p.y > maxY) maxY = p.y;
    }
    return Rect.fromLTRB(minX, minY, maxX, maxY).inflate(strokeWidth);
  }

  @override
  void translate(Offset delta) {
    points = points
        .map((p) => PointData(p.x + delta.dx, p.y + delta.dy, p.pressure))
        .toList();
  }

  @override
  void scaleBy(double factor) {
    final c = getBounds().center;
    points = points
        .map((p) => PointData(c.dx + (p.x - c.dx) * factor,
            c.dy + (p.y - c.dy) * factor, p.pressure))
        .toList();
  }

  @override
  Map<String, dynamic> toJson() => {
        'type': 'eraser',
        'id': id,
        'points': points.map((p) => p.toJson()).toList(),
        'strokeWidth': strokeWidth,
        'timestamp': timestamp,
      };

  factory EraserObject.fromJson(Map<String, dynamic> json) => EraserObject(
        id: json['id'] as String,
        points: (json['points'] as List)
            .map((p) => PointData.fromJson(p as Map<String, dynamic>))
            .toList(),
        strokeWidth: (json['strokeWidth'] as num).toDouble(),
        timestamp: json['timestamp'] as int?,
      );

  @override
  EraserObject clone() => EraserObject(
        id: id,
        points: points.map((p) => PointData(p.x, p.y, p.pressure)).toList(),
        strokeWidth: strokeWidth,
        timestamp: timestamp,
      );
}

// ============================================================
// Line
// ============================================================

class LineObject extends BoardObject {
  Offset start;
  Offset end;
  Color color;
  double strokeWidth;

  LineObject({
    required super.id,
    required this.start,
    required this.end,
    required this.color,
    required this.strokeWidth,
    super.opacity,
    super.rotation,
    super.timestamp,
  });

  @override
  Rect getBounds() => Rect.fromPoints(start, end).inflate(strokeWidth + 5);

  @override
  void translate(Offset delta) {
    start += delta;
    end += delta;
  }

  @override
  void scaleBy(double factor) {
    final c = Offset((start.dx + end.dx) / 2, (start.dy + end.dy) / 2);
    start = c + (start - c) * factor;
    end = c + (end - c) * factor;
    strokeWidth = (strokeWidth * factor).clamp(0.5, 50.0);
  }

  @override
  Map<String, dynamic> toJson() => {
        'type': 'line',
        'id': id,
        'x1': start.dx,
        'y1': start.dy,
        'x2': end.dx,
        'y2': end.dy,
        'color': color.value,
        'strokeWidth': strokeWidth,
        'opacity': opacity,
        'rotation': rotation,
        'timestamp': timestamp,
      };

  factory LineObject.fromJson(Map<String, dynamic> json) => LineObject(
        id: json['id'] as String,
        start: Offset(
            (json['x1'] as num).toDouble(), (json['y1'] as num).toDouble()),
        end: Offset(
            (json['x2'] as num).toDouble(), (json['y2'] as num).toDouble()),
        color: Color(json['color'] as int),
        strokeWidth: (json['strokeWidth'] as num).toDouble(),
        opacity: (json['opacity'] as num?)?.toDouble() ?? 1.0,
        rotation: (json['rotation'] as num?)?.toDouble() ?? 0.0,
        timestamp: json['timestamp'] as int?,
      );

  @override
  LineObject clone() => LineObject(
        id: id,
        start: start,
        end: end,
        color: color,
        strokeWidth: strokeWidth,
        opacity: opacity,
        rotation: rotation,
        timestamp: timestamp,
      );
}

// ============================================================
// Arrow
// ============================================================

class ArrowObject extends BoardObject {
  Offset start;
  Offset end;
  Color color;
  double strokeWidth;

  ArrowObject({
    required super.id,
    required this.start,
    required this.end,
    required this.color,
    required this.strokeWidth,
    super.opacity,
    super.rotation,
    super.timestamp,
  });

  @override
  Rect getBounds() => Rect.fromPoints(start, end).inflate(strokeWidth + 10);

  @override
  void translate(Offset delta) {
    start += delta;
    end += delta;
  }

  @override
  void scaleBy(double factor) {
    final c = Offset((start.dx + end.dx) / 2, (start.dy + end.dy) / 2);
    start = c + (start - c) * factor;
    end = c + (end - c) * factor;
    strokeWidth = (strokeWidth * factor).clamp(0.5, 50.0);
  }

  @override
  Map<String, dynamic> toJson() => {
        'type': 'arrow',
        'id': id,
        'x1': start.dx,
        'y1': start.dy,
        'x2': end.dx,
        'y2': end.dy,
        'color': color.value,
        'strokeWidth': strokeWidth,
        'opacity': opacity,
        'rotation': rotation,
        'timestamp': timestamp,
      };

  factory ArrowObject.fromJson(Map<String, dynamic> json) => ArrowObject(
        id: json['id'] as String,
        start: Offset(
            (json['x1'] as num).toDouble(), (json['y1'] as num).toDouble()),
        end: Offset(
            (json['x2'] as num).toDouble(), (json['y2'] as num).toDouble()),
        color: Color(json['color'] as int),
        strokeWidth: (json['strokeWidth'] as num).toDouble(),
        opacity: (json['opacity'] as num?)?.toDouble() ?? 1.0,
        rotation: (json['rotation'] as num?)?.toDouble() ?? 0.0,
        timestamp: json['timestamp'] as int?,
      );

  @override
  ArrowObject clone() => ArrowObject(
        id: id,
        start: start,
        end: end,
        color: color,
        strokeWidth: strokeWidth,
        opacity: opacity,
        rotation: rotation,
        timestamp: timestamp,
      );
}

// ============================================================
// Shape
// ============================================================

class ShapeObject extends BoardObject {
  Rect rect;
  final ShapeType shapeType;
  Color color;
  double strokeWidth;
  final bool filled;

  ShapeObject({
    required super.id,
    required this.rect,
    required this.shapeType,
    required this.color,
    required this.strokeWidth,
    this.filled = false,
    super.opacity,
    super.rotation,
    super.timestamp,
  });

  @override
  Rect getBounds() => rect.inflate(strokeWidth);

  @override
  void translate(Offset delta) {
    rect = rect.shift(delta);
  }

  @override
  void scaleBy(double factor) {
    final c = rect.center;
    final nw = rect.width * factor;
    final nh = rect.height * factor;
    rect = Rect.fromCenter(center: c, width: nw.abs(), height: nh.abs());
    strokeWidth = (strokeWidth * factor).clamp(0.5, 50.0);
  }

  @override
  Map<String, dynamic> toJson() => {
        'type': 'shape',
        'id': id,
        'x': rect.left,
        'y': rect.top,
        'w': rect.width,
        'h': rect.height,
        'shapeType': shapeType.index,
        'color': color.value,
        'strokeWidth': strokeWidth,
        'filled': filled,
        'opacity': opacity,
        'rotation': rotation,
        'timestamp': timestamp,
      };

  factory ShapeObject.fromJson(Map<String, dynamic> json) => ShapeObject(
        id: json['id'] as String,
        rect: Rect.fromLTWH(
          (json['x'] as num).toDouble(),
          (json['y'] as num).toDouble(),
          (json['w'] as num).toDouble(),
          (json['h'] as num).toDouble(),
        ),
        shapeType: ShapeType.values[json['shapeType'] as int],
        color: Color(json['color'] as int),
        strokeWidth: (json['strokeWidth'] as num).toDouble(),
        filled: json['filled'] as bool? ?? false,
        opacity: (json['opacity'] as num?)?.toDouble() ?? 1.0,
        rotation: (json['rotation'] as num?)?.toDouble() ?? 0.0,
        timestamp: json['timestamp'] as int?,
      );

  @override
  ShapeObject clone() => ShapeObject(
        id: id,
        rect: rect,
        shapeType: shapeType,
        color: color,
        strokeWidth: strokeWidth,
        filled: filled,
        opacity: opacity,
        rotation: rotation,
        timestamp: timestamp,
      );
}

// ============================================================
// Text
// ============================================================

class TextObject extends BoardObject {
  Offset position;
  String text;
  Color color;
  double fontSize;
  String fontFamily;

  TextObject({
    required super.id,
    required this.position,
    required this.text,
    required this.color,
    this.fontSize = 20,
    this.fontFamily = 'Roboto',
    super.opacity,
    super.rotation,
    super.timestamp,
  });

  @override
  void scaleBy(double factor) {
    fontSize = (fontSize * factor).clamp(8.0, 200.0);
  }

  @override
  Rect getBounds() {
    // Approximate text bounds
    final charWidth = fontSize * 0.55;
    final lines = text.split('\n');
    final maxLineLen =
        lines.fold<int>(0, (m, l) => l.length > m ? l.length : m);
    final w = maxLineLen * charWidth + 16;
    final h = lines.length * fontSize * 1.3 + 8;
    return Rect.fromLTWH(position.dx - 4, position.dy - 4, w, h);
  }

  @override
  void translate(Offset delta) {
    position += delta;
  }

  @override
  Map<String, dynamic> toJson() => {
        'type': 'text',
        'id': id,
        'x': position.dx,
        'y': position.dy,
        'text': text,
        'color': color.value,
        'fontSize': fontSize,
        'fontFamily': fontFamily,
        'opacity': opacity,
        'rotation': rotation,
        'timestamp': timestamp,
      };

  factory TextObject.fromJson(Map<String, dynamic> json) => TextObject(
        id: json['id'] as String,
        position: Offset(
            (json['x'] as num).toDouble(), (json['y'] as num).toDouble()),
        text: json['text'] as String,
        color: Color(json['color'] as int),
        fontSize: (json['fontSize'] as num?)?.toDouble() ?? 20,
        fontFamily: json['fontFamily'] as String? ?? 'Roboto',
        opacity: (json['opacity'] as num?)?.toDouble() ?? 1.0,
        rotation: (json['rotation'] as num?)?.toDouble() ?? 0.0,
        timestamp: json['timestamp'] as int?,
      );

  @override
  TextObject clone() => TextObject(
        id: id,
        position: position,
        text: text,
        color: color,
        fontSize: fontSize,
        fontFamily: fontFamily,
        opacity: opacity,
        rotation: rotation,
        timestamp: timestamp,
      );
}

// ============================================================
// Image
// ============================================================

class ImageObject extends BoardObject {
  Offset position;
  Size size;
  final String imageUrl; // kept for serialization / sync
  Uint8List? imageBytes; // actual image data for rendering

  ImageObject({
    required super.id,
    required this.position,
    required this.size,
    required this.imageUrl,
    this.imageBytes,
    super.opacity,
    super.rotation,
    super.timestamp,
  });

  @override
  Rect getBounds() =>
      Rect.fromLTWH(position.dx, position.dy, size.width, size.height);

  @override
  void translate(Offset delta) {
    position += delta;
  }

  @override
  void scaleBy(double factor) {
    final c = getBounds().center;
    size = Size(size.width * factor, size.height * factor);
    position = Offset(c.dx - size.width / 2, c.dy - size.height / 2);
  }

  @override
  Map<String, dynamic> toJson() => {
        'type': 'image',
        'id': id,
        'x': position.dx,
        'y': position.dy,
        'w': size.width,
        'h': size.height,
        'imageUrl': imageUrl,
        'imageBase64': imageBytes != null ? base64Encode(imageBytes!) : null,
        'opacity': opacity,
        'rotation': rotation,
        'timestamp': timestamp,
      };

  factory ImageObject.fromJson(Map<String, dynamic> json) {
    Uint8List? bytes;
    if (json['imageBase64'] != null) {
      bytes = base64Decode(json['imageBase64'] as String);
    }
    return ImageObject(
      id: json['id'] as String,
      position:
          Offset((json['x'] as num).toDouble(), (json['y'] as num).toDouble()),
      size: Size((json['w'] as num).toDouble(), (json['h'] as num).toDouble()),
      imageUrl: json['imageUrl'] as String? ?? '',
      imageBytes: bytes,
      opacity: (json['opacity'] as num?)?.toDouble() ?? 1.0,
      rotation: (json['rotation'] as num?)?.toDouble() ?? 0.0,
      timestamp: json['timestamp'] as int?,
    );
  }

  @override
  ImageObject clone() => ImageObject(
        id: id,
        position: position,
        size: size,
        imageUrl: imageUrl,
        // Share reference to imageBytes - it's immutable data, no need to copy
        imageBytes: imageBytes,
        opacity: opacity,
        rotation: rotation,
        timestamp: timestamp,
      );
}

// ============================================================
// Ruler (measured line showing distance)
// ============================================================

class RulerObject extends BoardObject {
  Offset start;
  Offset end;
  final Color color;
  final double strokeWidth;

  RulerObject({
    required super.id,
    required this.start,
    required this.end,
    required this.color,
    this.strokeWidth = 2,
    super.opacity,
    super.timestamp,
  });

  double get length => (end - start).distance;

  @override
  Rect getBounds() => Rect.fromPoints(start, end).inflate(20);

  @override
  void translate(Offset delta) {
    start += delta;
    end += delta;
  }

  @override
  void scaleBy(double factor) {
    final c = Offset((start.dx + end.dx) / 2, (start.dy + end.dy) / 2);
    start = c + (start - c) * factor;
    end = c + (end - c) * factor;
  }

  @override
  Map<String, dynamic> toJson() => {
        'type': 'ruler',
        'id': id,
        'x1': start.dx,
        'y1': start.dy,
        'x2': end.dx,
        'y2': end.dy,
        'color': color.value,
        'strokeWidth': strokeWidth,
        'opacity': opacity,
        'timestamp': timestamp,
      };

  factory RulerObject.fromJson(Map<String, dynamic> json) => RulerObject(
        id: json['id'] as String,
        start: Offset(
            (json['x1'] as num).toDouble(), (json['y1'] as num).toDouble()),
        end: Offset(
            (json['x2'] as num).toDouble(), (json['y2'] as num).toDouble()),
        color: Color(json['color'] as int),
        strokeWidth: (json['strokeWidth'] as num?)?.toDouble() ?? 2,
        opacity: (json['opacity'] as num?)?.toDouble() ?? 1.0,
        timestamp: json['timestamp'] as int?,
      );

  @override
  RulerObject clone() => RulerObject(
        id: id,
        start: start,
        end: end,
        color: color,
        strokeWidth: strokeWidth,
        opacity: opacity,
        timestamp: timestamp,
      );
}

// ============================================================
// Board Page
// ============================================================

class BoardPage {
  final List<BoardObject> objects;
  final String id;

  BoardPage({required this.id, List<BoardObject>? objects})
      : objects = objects ?? [];

  Map<String, dynamic> toJson() => {
        'id': id,
        'objects': objects.map((o) => o.toJson()).toList(),
      };
}
