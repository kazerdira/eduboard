import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'board_models.dart';

/// Which part of the selection box is being interacted with.
enum SelectionHandle {
  none, // drag / move
  topLeft,
  topRight,
  bottomLeft,
  bottomRight,
  rotate, // rotation handle above top-center
}

typedef OnBoardOperation = void Function(Map<String, dynamic> operation);

class BoardController extends ChangeNotifier {
  // === Tool State ===
  BoardToolType _activeTool = BoardToolType.pen;
  Color _activeColor = const Color(0xFF1a1a2e);
  double _strokeWidth = 3.0;
  double _opacity = 1.0;
  ShapeType _shapeType = ShapeType.rectangle;
  bool _shapeFilled = false;
  double _fontSize = 24.0;
  String _fontFamily = 'Roboto';
  CanvasBackground _canvasBackground = CanvasBackground.blank;
  bool _darkMode = false;

  // === Canvas State ===
  double _zoom = 1.0;
  Offset _panOffset = Offset.zero;

  // === Pages ===
  final List<BoardPage> _pages = [BoardPage(id: _generateId())];
  int _currentPageIndex = 0;

  // === History (per page) ===
  final Map<String, List<List<BoardObject>>> _pageHistory = {};
  final Map<String, int> _pageHistoryIndex = {};

  // === Current drawing ===
  List<PointData>? _currentStrokePoints;
  Offset? _shapeStartPoint;
  Offset? _shapeCurrentPoint;

  // === Selection ===
  int? _selectedObjectIndex;
  Offset? _dragStartPos;
  Offset? _objectStartPos; // position at drag start for clean delta calc
  SelectionHandle _activeHandle = SelectionHandle.none;
  double _rotateStartAngle = 0.0;

  /// Index of the text object currently being edited inline.
  /// The painter should skip drawing this object to avoid doubling.
  int? editingTextIndex;

  // === Multi-selection (marquee) ===
  final Set<int> _multiSelectedIndices = {};
  Offset? _marqueeStart;
  Offset? _marqueeEnd;
  Offset? _multiDragStart;

  // === Laser (ring buffer for efficiency) ===
  static const int _laserBufferSize = 60;
  final List<Offset> _laserBuffer = List.filled(_laserBufferSize, Offset.zero);
  int _laserHead = 0; // write position
  int _laserCount = 0; // number of valid points

  /// Returns laser points in order (oldest to newest).
  List<Offset> get laserPoints {
    if (_laserCount == 0) return const [];
    final result = <Offset>[];
    final start =
        _laserCount < _laserBufferSize ? 0 : _laserHead; // start from oldest
    for (int i = 0; i < _laserCount; i++) {
      result.add(_laserBuffer[(start + i) % _laserBufferSize]);
    }
    return result;
  }

  // === Frame-batched notifyListeners ===
  bool _notifyScheduled = false;

  /// Schedules a notifyListeners call for the next frame.
  /// Multiple calls within the same frame are batched into one.
  void _scheduleNotify() {
    if (_notifyScheduled) return;
    _notifyScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _notifyScheduled = false;
      notifyListeners();
    });
  }

  // === LiveKit sync callback ===
  OnBoardOperation? onOperation;

  // === Getters ===
  BoardToolType get activeTool => _activeTool;
  Color get activeColor => _activeColor;
  double get strokeWidth => _strokeWidth;
  double get opacity => _opacity;
  ShapeType get shapeType => _shapeType;
  bool get shapeFilled => _shapeFilled;
  double get fontSize => _fontSize;
  String get fontFamily => _fontFamily;
  CanvasBackground get canvasBackground => _canvasBackground;
  bool get darkMode => _darkMode;
  double get zoom => _zoom;
  Offset get panOffset => _panOffset;
  int get currentPageIndex => _currentPageIndex;
  int get pageCount => _pages.length;
  List<BoardObject> get currentObjects => _pages[_currentPageIndex].objects;
  List<PointData>? get currentStrokePoints => _currentStrokePoints;
  Offset? get shapeStartPoint => _shapeStartPoint;
  Offset? get shapeCurrentPoint => _shapeCurrentPoint;
  int? get selectedObjectIndex => _selectedObjectIndex;
  SelectionHandle get activeHandle => _activeHandle;
  // laserPoints getter defined above with ring buffer

  BoardObject? get selectedObject {
    if (_selectedObjectIndex == null) return null;
    if (_selectedObjectIndex! >= currentObjects.length) return null;
    return currentObjects[_selectedObjectIndex!];
  }

  /// Multi-selection state
  Set<int> get multiSelectedIndices => _multiSelectedIndices;
  bool get hasMultiSelection => _multiSelectedIndices.length > 1;
  Offset? get marqueeStart => _marqueeStart;
  Offset? get marqueeEnd => _marqueeEnd;

  /// Get the bounding rect that encloses all multi-selected objects.
  Rect? get multiSelectionBounds {
    if (_multiSelectedIndices.isEmpty) return null;
    Rect? bounds;
    for (final i in _multiSelectedIndices) {
      if (i >= currentObjects.length) continue;
      final b = currentObjects[i].getBounds();
      bounds = bounds == null ? b : bounds.expandToInclude(b);
    }
    return bounds;
  }

  /// Public method to trigger a repaint (used by painter after async image decode).
  void refresh() => notifyListeners();

  // === Tool Setters ===
  void setTool(BoardToolType tool) {
    _activeTool = tool;
    if (tool != BoardToolType.select) {
      _selectedObjectIndex = null;
      _multiSelectedIndices.clear();
    }
    notifyListeners();
  }

  void setColor(Color color) {
    _activeColor = color;
    // Apply to selected object in real-time
    final obj = selectedObject;
    if (obj != null) {
      _saveHistory();
      if (obj is StrokeObject) obj.color = color;
      if (obj is LineObject) obj.color = color;
      if (obj is ArrowObject) obj.color = color;
      if (obj is ShapeObject) obj.color = color;
      if (obj is TextObject) obj.color = color;
    }
    notifyListeners();
  }

  void setStrokeWidth(double width) {
    _strokeWidth = width;
    // Apply to selected object (skip TextObject – width is irrelevant)
    final obj = selectedObject;
    if (obj != null) {
      _saveHistory();
      if (obj is StrokeObject) obj.strokeWidth = width;
      if (obj is LineObject) obj.strokeWidth = width;
      if (obj is ArrowObject) obj.strokeWidth = width;
      if (obj is ShapeObject) obj.strokeWidth = width;
    }
    notifyListeners();
  }

  void setOpacity(double opacity) {
    _opacity = opacity;
    // Apply to selected object in real-time
    final obj = selectedObject;
    if (obj != null) {
      _saveHistory();
      obj.opacity = opacity;
    }
    notifyListeners();
  }

  void setShapeType(ShapeType type) {
    _shapeType = type;
    notifyListeners();
  }

  void toggleShapeFilled() {
    _shapeFilled = !_shapeFilled;
    notifyListeners();
  }

  void setFontSize(double size) {
    _fontSize = size;
    // Apply to selected text object
    final obj = selectedObject;
    if (obj != null && obj is TextObject) {
      _saveHistory();
      obj.fontSize = size;
    }
    notifyListeners();
  }

  void setFontFamily(String family) {
    _fontFamily = family;
    // Apply to selected text object
    final obj = selectedObject;
    if (obj != null && obj is TextObject) {
      _saveHistory();
      obj.fontFamily = family;
    }
    notifyListeners();
  }

  void setCanvasBackground(CanvasBackground bg) {
    _canvasBackground = bg;
    notifyListeners();
  }

  void toggleDarkMode() {
    _darkMode = !_darkMode;
    notifyListeners();
  }

  // === Zoom & Pan ===
  void setZoom(double z) {
    _zoom = z.clamp(0.1, 10.0);
    _clampPan(); // re-clamp after zoom changes
    notifyListeners();
  }

  void zoomIn() => setZoom(_zoom * 1.2);
  void zoomOut() => setZoom(_zoom / 1.2);

  void resetZoom() {
    _zoom = 1.0;
    _panOffset = Offset.zero;
    notifyListeners();
  }

  void centerView() {
    _panOffset = Offset.zero;
    notifyListeners();
  }

  /// Virtual canvas size — all drawing happens within this area.
  static const double canvasSize = 10000.0;

  void pan(Offset delta) {
    _panOffset += delta;
    _clampPan();
    notifyListeners();
  }

  /// Keep the view inside the canvas bounds so you can never
  /// pan past the edge of the paper.
  void _clampPan() {
    // At the extremes the canvas edge should just touch the
    // viewport edge, not go past it.  Since we don't know the
    // viewport size here we use a generous limit of half the
    // scaled canvas – this prevents runaway panning while the
    // visual clamp in the widget keeps things pixel-perfect.
    final limit = canvasSize * _zoom / 2;
    _panOffset = Offset(
      _panOffset.dx.clamp(-limit, limit),
      _panOffset.dy.clamp(-limit, limit),
    );
  }

  /// Cancel any in-progress drawing (stroke or shape) without committing.
  void cancelCurrentDrawing() {
    bool changed = false;
    if (_currentStrokePoints != null) {
      _currentStrokePoints = null;
      changed = true;
    }
    if (_shapeStartPoint != null) {
      _shapeStartPoint = null;
      _shapeCurrentPoint = null;
      changed = true;
    }
    if (changed) notifyListeners();
  }

  // === Drawing Lifecycle ===
  void startStroke(Offset point, {double pressure = 0.5}) {
    _currentStrokePoints = [PointData(point.dx, point.dy, pressure)];
    notifyListeners();
  }

  void addStrokePoint(Offset point, {double pressure = 0.5}) {
    _currentStrokePoints?.add(PointData(point.dx, point.dy, pressure));
    _scheduleNotify(); // batched notify for smooth drawing
  }

  void endStroke() {
    if (_currentStrokePoints == null || _currentStrokePoints!.length < 2) {
      _currentStrokePoints = null;
      notifyListeners();
      return;
    }

    final obj = StrokeObject(
      id: _generateId(),
      points: List.from(_currentStrokePoints!),
      color: _activeColor,
      strokeWidth: _strokeWidth,
      isHighlighter: _activeTool == BoardToolType.highlighter,
      opacity: _activeTool == BoardToolType.highlighter ? 0.35 : _opacity,
    );

    _addObject(obj);
    _currentStrokePoints = null;
    notifyListeners();
  }

  // === Eraser — removes objects touched by the eraser path ===
  bool _eraserDidRemove = false;

  /// Check all objects and remove any whose bounds contain [point].
  /// Uses a generous radius based on strokeWidth.
  void eraseAt(Offset point) {
    final eraserRadius = _strokeWidth * 2;
    bool removed = false;

    for (int i = currentObjects.length - 1; i >= 0; i--) {
      final obj = currentObjects[i];
      if (obj is EraserObject) continue; // skip legacy eraser objects

      // Use the object's local space for rotated objects
      final lp = _toLocalSpace(obj, point);
      final bounds = obj.getBounds();

      // For strokes, check point-level proximity for precision
      if (obj is StrokeObject) {
        bool hit = false;
        for (final p in obj.points) {
          if ((Offset(p.x, p.y) - lp).distance <=
              eraserRadius + obj.strokeWidth) {
            hit = true;
            break;
          }
        }
        if (hit) {
          currentObjects.removeAt(i);
          removed = true;
          continue;
        }
      } else if (bounds.inflate(eraserRadius).contains(lp)) {
        currentObjects.removeAt(i);
        removed = true;
      }
    }

    if (removed) {
      _eraserDidRemove = true;
      _selectedObjectIndex = null;
      notifyListeners();
    }
  }

  void endErase() {
    if (_eraserDidRemove) {
      _saveHistory();
      _eraserDidRemove = false;
    }
  }

  // === Shape Drawing ===
  void startShape(Offset point) {
    _shapeStartPoint = point;
    _shapeCurrentPoint = point;
    notifyListeners();
  }

  void updateShape(Offset point) {
    _shapeCurrentPoint = point;
    _scheduleNotify(); // batched notify for smooth shape preview
  }

  void endShape() {
    if (_shapeStartPoint == null || _shapeCurrentPoint == null) return;

    final s = _shapeStartPoint!;
    final c = _shapeCurrentPoint!;

    // Min distance check
    if ((c - s).distance < 5) {
      _shapeStartPoint = null;
      _shapeCurrentPoint = null;
      notifyListeners();
      return;
    }

    BoardObject obj;

    if (_activeTool == BoardToolType.line) {
      obj = LineObject(
          id: _generateId(),
          start: s,
          end: c,
          color: _activeColor,
          strokeWidth: _strokeWidth,
          opacity: _opacity);
    } else if (_activeTool == BoardToolType.arrow) {
      obj = ArrowObject(
          id: _generateId(),
          start: s,
          end: c,
          color: _activeColor,
          strokeWidth: _strokeWidth,
          opacity: _opacity);
    } else if (_activeTool == BoardToolType.ruler) {
      obj = RulerObject(
          id: _generateId(),
          start: s,
          end: c,
          color: _activeColor,
          strokeWidth: _strokeWidth,
          opacity: _opacity);
    } else {
      final rect = Rect.fromPoints(s, c);
      obj = ShapeObject(
          id: _generateId(),
          rect: rect,
          shapeType: _shapeType,
          color: _activeColor,
          strokeWidth: _strokeWidth,
          filled: _shapeFilled,
          opacity: _opacity);
    }

    _addObject(obj);
    _shapeStartPoint = null;
    _shapeCurrentPoint = null;
    notifyListeners();
  }

  // === Text ===
  void addText(String text, Offset position) {
    if (text.trim().isEmpty) return;
    _addObject(TextObject(
      id: _generateId(),
      position: position,
      text: text,
      color: _activeColor,
      fontSize: _fontSize,
      fontFamily: _fontFamily,
      opacity: _opacity,
    ));
  }

  /// Update the text content of an existing object at [index].
  void updateTextAt(int index, String newText) {
    if (index < 0 || index >= currentObjects.length) return;
    final obj = currentObjects[index];
    if (obj is! TextObject) return;
    if (newText.trim().isEmpty) {
      // Empty text → delete the object
      currentObjects.removeAt(index);
    } else {
      obj.text = newText;
    }
    _saveHistory();
    notifyListeners();
  }

  /// Find a TextObject at the given [point]. Returns its index or -1.
  int findTextIndexAt(Offset point) {
    for (int i = currentObjects.length - 1; i >= 0; i--) {
      final obj = currentObjects[i];
      if (obj is TextObject && obj.getBounds().inflate(10).contains(point)) {
        return i;
      }
    }
    return -1;
  }

  // === Image ===
  void addImage(String imageUrl, Offset position, Size size) {
    _addObject(ImageObject(
      id: _generateId(),
      position: position,
      size: size,
      imageUrl: imageUrl,
      opacity: _opacity,
    ));
  }

  /// Add an image from raw bytes (e.g. from image_picker or file_picker).
  /// The bytes are stored in the object and decoded by the painter.
  /// [maxSide] limits the display size (aspect ratio is preserved).
  void addImageFromBytes(Uint8List bytes, Offset position,
      {double maxSide = 300}) {
    // Decode image dimensions from bytes to compute aspect ratio
    // We'll use a sensible default; the painter will use actual decoded size.
    _addObject(ImageObject(
      id: _generateId(),
      position: position,
      size: Size(maxSide, maxSide), // will be corrected on first paint
      imageUrl: 'bytes://${_generateId()}',
      imageBytes: bytes,
      opacity: _opacity,
    ));
  }

  // === Selection — works for ALL object types ===

  /// Size of corner handles in canvas coords.
  static const double handleRadius = 7.0;

  /// Distance from top-center to the rotation handle.
  static const double rotateHandleOffset = 28.0;

  /// Transform a canvas-space [point] into the object's local (un-rotated)
  /// coordinate space so hit-testing works even after rotation.
  Offset _toLocalSpace(BoardObject obj, Offset point) {
    if (obj.rotation == 0.0) return point;
    final c = obj.center;
    final cosA = math.cos(-obj.rotation);
    final sinA = math.sin(-obj.rotation);
    final dx = point.dx - c.dx;
    final dy = point.dy - c.dy;
    return Offset(c.dx + dx * cosA - dy * sinA, c.dy + dx * sinA + dy * cosA);
  }

  /// Hit-test which handle (if any) is at [point] for the currently selected
  /// object. Returns [SelectionHandle.none] if not on a handle.
  SelectionHandle hitTestHandle(Offset point) {
    final obj = selectedObject;
    if (obj == null) return SelectionHandle.none;

    // Un-rotate the tap point so we can test against axis-aligned handles
    final lp = _toLocalSpace(obj, point);
    final b = obj.getBounds().inflate(4);
    final r = handleRadius + 4; // generous tap target

    // Rotation handle (circle above top-center)
    final rotPos = Offset(b.center.dx, b.top - rotateHandleOffset);
    if ((lp - rotPos).distance <= r + 4) return SelectionHandle.rotate;

    // Corner handles
    if ((lp - b.topLeft).distance <= r) return SelectionHandle.topLeft;
    if ((lp - b.topRight).distance <= r) return SelectionHandle.topRight;
    if ((lp - b.bottomLeft).distance <= r) return SelectionHandle.bottomLeft;
    if ((lp - b.bottomRight).distance <= r) return SelectionHandle.bottomRight;

    return SelectionHandle.none;
  }

  void selectObjectAt(Offset point) {
    // If something is already selected, check handles first
    if (_selectedObjectIndex != null) {
      final selObj = selectedObject;
      if (selObj == null) {
        // Index became stale (e.g. after undo) – clear and fall through
        _selectedObjectIndex = null;
      } else {
        final handle = hitTestHandle(point);
        if (handle != SelectionHandle.none) {
          _activeHandle = handle;
          _dragStartPos = point;
          if (handle == SelectionHandle.rotate) {
            final c = selObj.center;
            _rotateStartAngle = math.atan2(point.dy - c.dy, point.dx - c.dx);
          }
          notifyListeners();
          return;
        }

        // Tap still inside the same object? Keep it selected (plain move).
        final lp = _toLocalSpace(selObj, point);
        if (selObj.getBounds().inflate(10).contains(lp)) {
          _activeHandle = SelectionHandle.none;
          _dragStartPos = point;
          notifyListeners();
          return;
        }
      }
    }

    // Otherwise do normal selection
    _selectedObjectIndex = null;
    _dragStartPos = null;
    _activeHandle = SelectionHandle.none;

    for (int i = currentObjects.length - 1; i >= 0; i--) {
      final obj = currentObjects[i];
      if (obj is EraserObject) continue;

      final lp = _toLocalSpace(obj, point);
      final bounds = obj.getBounds();
      if (bounds.inflate(10).contains(lp)) {
        _selectedObjectIndex = i;
        _dragStartPos = point;
        break;
      }
    }
    notifyListeners();
  }

  void moveSelected(Offset currentPoint) {
    if (_selectedObjectIndex == null || _dragStartPos == null) return;
    if (_selectedObjectIndex! >= currentObjects.length) return;
    final obj = currentObjects[_selectedObjectIndex!];

    switch (_activeHandle) {
      case SelectionHandle.none:
        // Plain drag / move
        final delta = currentPoint - _dragStartPos!;
        obj.translate(delta);
        _dragStartPos = currentPoint;
        break;

      case SelectionHandle.rotate:
        final c = obj.center;
        final angle =
            math.atan2(currentPoint.dy - c.dy, currentPoint.dx - c.dx);
        obj.rotation += angle - _rotateStartAngle;
        _rotateStartAngle = angle;
        break;

      case SelectionHandle.topLeft:
      case SelectionHandle.topRight:
      case SelectionHandle.bottomLeft:
      case SelectionHandle.bottomRight:
        _resizeFromCorner(obj, currentPoint);
        _dragStartPos = currentPoint;
        break;
    }
    notifyListeners();
  }

  /// Uniform scale based on corner drag distance from center.
  void _resizeFromCorner(BoardObject obj, Offset currentPoint) {
    final c = obj.center;
    final prevDist = (_dragStartPos! - c).distance;
    final newDist = (currentPoint - c).distance;
    if (prevDist < 1) return;
    final factor = (newDist / prevDist).clamp(0.5, 3.0);
    obj.scaleBy(factor);
  }

  void endMoveSelected() {
    if (_selectedObjectIndex != null) {
      _saveHistory();
      _emitOperation({
        'action': 'move',
        'objectId': currentObjects[_selectedObjectIndex!].id,
        'object': currentObjects[_selectedObjectIndex!].toJson(),
        'pageId': _pages[_currentPageIndex].id,
      });
    }
    _dragStartPos = null;
    _activeHandle = SelectionHandle.none;
  }

  void deleteSelected() {
    if (_selectedObjectIndex == null) return;
    if (_selectedObjectIndex! >= currentObjects.length) return;

    final objId = currentObjects[_selectedObjectIndex!].id;
    currentObjects.removeAt(_selectedObjectIndex!);
    _selectedObjectIndex = null;
    _saveHistory();
    _emitOperation({
      'action': 'delete',
      'objectId': objId,
      'pageId': _pages[_currentPageIndex].id
    });
    notifyListeners();
  }

  void duplicateSelected() {
    if (_selectedObjectIndex == null) return;
    if (_selectedObjectIndex! >= currentObjects.length) return;

    final original = currentObjects[_selectedObjectIndex!];
    final json = original.toJson();
    json['id'] = _generateId(); // new ID
    final copy = BoardObject.fromJson(json);
    copy.translate(const Offset(20, 20)); // offset so it's visible

    _addObject(copy);
    _selectedObjectIndex = currentObjects.length - 1;
    notifyListeners();
  }

  /// Move selected object to the top (drawn last = visually on top)
  void bringToFront() {
    if (_selectedObjectIndex == null) return;
    final i = _selectedObjectIndex!;
    if (i >= currentObjects.length - 1) return; // already on top
    _saveHistory();
    final obj = currentObjects.removeAt(i);
    currentObjects.add(obj);
    _selectedObjectIndex = currentObjects.length - 1;
    notifyListeners();
  }

  /// Move selected object to the bottom (drawn first = visually behind)
  void sendToBack() {
    if (_selectedObjectIndex == null) return;
    final i = _selectedObjectIndex!;
    if (i <= 0) return; // already at back
    _saveHistory();
    final obj = currentObjects.removeAt(i);
    currentObjects.insert(0, obj);
    _selectedObjectIndex = 0;
    notifyListeners();
  }

  void deselectAll() {
    _selectedObjectIndex = null;
    _multiSelectedIndices.clear();
    _marqueeStart = null;
    _marqueeEnd = null;
    notifyListeners();
  }

  // === Marquee (Rectangle Lasso) Multi-Selection ===

  void startMarquee(Offset point) {
    _marqueeStart = point;
    _marqueeEnd = point;
    _multiSelectedIndices.clear();
    _selectedObjectIndex = null;
    notifyListeners();
  }

  void updateMarquee(Offset point) {
    _marqueeEnd = point;
    notifyListeners();
  }

  /// Finalize the marquee: select all objects whose bounds intersect the rect.
  void endMarquee() {
    if (_marqueeStart == null || _marqueeEnd == null) return;

    final rect = Rect.fromPoints(_marqueeStart!, _marqueeEnd!);
    _multiSelectedIndices.clear();

    for (int i = 0; i < currentObjects.length; i++) {
      final obj = currentObjects[i];
      if (obj is EraserObject) continue;
      final objBounds = obj.getBounds();
      if (rect.overlaps(objBounds)) {
        _multiSelectedIndices.add(i);
      }
    }

    _marqueeStart = null;
    _marqueeEnd = null;

    // If only one object caught, promote to single selection
    if (_multiSelectedIndices.length == 1) {
      _selectedObjectIndex = _multiSelectedIndices.first;
      _multiSelectedIndices.clear();
    }

    notifyListeners();
  }

  /// Begin dragging all multi-selected objects.
  void startMultiMove(Offset point) {
    _multiDragStart = point;
  }

  /// Move all multi-selected objects by the drag delta.
  void moveMultiSelected(Offset currentPoint) {
    if (_multiDragStart == null || _multiSelectedIndices.isEmpty) return;
    final delta = currentPoint - _multiDragStart!;
    for (final i in _multiSelectedIndices) {
      if (i < currentObjects.length) {
        currentObjects[i].translate(delta);
      }
    }
    _multiDragStart = currentPoint;
    notifyListeners();
  }

  void endMultiMove() {
    if (_multiSelectedIndices.isNotEmpty) {
      _saveHistory();
    }
    _multiDragStart = null;
  }

  /// Delete all multi-selected objects.
  void deleteMultiSelected() {
    if (_multiSelectedIndices.isEmpty) return;
    // Remove in reverse index order so indices stay valid
    final sorted = _multiSelectedIndices.toList()
      ..sort((a, b) => b.compareTo(a));
    for (final i in sorted) {
      if (i < currentObjects.length) {
        currentObjects.removeAt(i);
      }
    }
    _multiSelectedIndices.clear();
    _saveHistory();
    notifyListeners();
  }

  /// Check if a point is inside the multi-selection bounding rect.
  bool isPointInMultiSelection(Offset point) {
    final bounds = multiSelectionBounds;
    if (bounds == null) return false;
    return bounds.inflate(15).contains(point);
  }

  /// Toggle an object in/out of the multi-selection (long-press on object).
  /// If no multi-selection exists yet, starts one from the tapped object.
  void toggleObjectInMultiSelection(Offset point) {
    // Find which object was tapped
    int? tappedIndex;
    for (int i = currentObjects.length - 1; i >= 0; i--) {
      final obj = currentObjects[i];
      if (obj is EraserObject) continue;
      final lp = _toLocalSpace(obj, point);
      if (obj.getBounds().inflate(10).contains(lp)) {
        tappedIndex = i;
        break;
      }
    }

    if (tappedIndex == null) return;

    if (_multiSelectedIndices.contains(tappedIndex)) {
      // Remove from multi-selection
      _multiSelectedIndices.remove(tappedIndex);
      if (_multiSelectedIndices.length == 1) {
        // Collapse to single selection
        _selectedObjectIndex = _multiSelectedIndices.first;
        _multiSelectedIndices.clear();
      } else if (_multiSelectedIndices.isEmpty) {
        _selectedObjectIndex = null;
      }
    } else {
      // Add to multi-selection
      // If we had a single selection, promote it to multi first
      if (_selectedObjectIndex != null) {
        _multiSelectedIndices.add(_selectedObjectIndex!);
        _selectedObjectIndex = null;
      }
      _multiSelectedIndices.add(tappedIndex);
    }

    notifyListeners();
  }

  /// Check if a point hits any object (for deciding long-press behavior).
  bool isPointOnObject(Offset point) {
    for (int i = currentObjects.length - 1; i >= 0; i--) {
      final obj = currentObjects[i];
      if (obj is EraserObject) continue;
      final lp = _toLocalSpace(obj, point);
      if (obj.getBounds().inflate(10).contains(lp)) return true;
    }
    return false;
  }

  // === Laser ===
  void addLaserPoint(Offset point) {
    _laserBuffer[_laserHead] = point;
    _laserHead = (_laserHead + 1) % _laserBufferSize;
    if (_laserCount < _laserBufferSize) _laserCount++;
    _scheduleNotify(); // batched notify for high-frequency updates
  }

  void clearLaser() {
    _laserCount = 0;
    _laserHead = 0;
    notifyListeners();
  }

  // === Pages ===
  void addPage() {
    _pages.add(BoardPage(id: _generateId()));
    _currentPageIndex = _pages.length - 1;
    _initPageHistory();
    notifyListeners();
  }

  void goToPage(int index) {
    if (index < 0 || index >= _pages.length) return;
    _currentPageIndex = index;
    _selectedObjectIndex = null;
    notifyListeners();
  }

  void nextPage() => goToPage(_currentPageIndex + 1);
  void prevPage() => goToPage(_currentPageIndex - 1);

  // === Undo/Redo ===
  void undo() {
    final pageId = _pages[_currentPageIndex].id;
    final history = _pageHistory[pageId];
    final index = _pageHistoryIndex[pageId] ?? 0;
    if (history == null || index <= 0) return;

    _pageHistoryIndex[pageId] = index - 1;
    _pages[_currentPageIndex].objects
      ..clear()
      ..addAll(_cloneObjects(history[index - 1]));
    _selectedObjectIndex = null;
    notifyListeners();
  }

  void redo() {
    final pageId = _pages[_currentPageIndex].id;
    final history = _pageHistory[pageId];
    final index = _pageHistoryIndex[pageId] ?? 0;
    if (history == null || index >= history.length - 1) return;

    _pageHistoryIndex[pageId] = index + 1;
    _pages[_currentPageIndex].objects
      ..clear()
      ..addAll(_cloneObjects(history[index + 1]));
    _selectedObjectIndex = null;
    notifyListeners();
  }

  // === Clear ===
  void clearPage() {
    currentObjects.clear();
    _selectedObjectIndex = null;
    _saveHistory();
    notifyListeners();
  }

  // === Export ===
  String exportToJson() {
    return jsonEncode(_pages.map((p) => p.toJson()).toList());
  }

  /// Import board state from JSON (restores all pages and objects).
  /// Clears current state and replaces with imported data.
  void importFromJson(String json) {
    final List<dynamic> pagesData = jsonDecode(json) as List<dynamic>;
    _pages.clear();
    _pageHistory.clear();
    _pageHistoryIndex.clear();

    for (final pageData in pagesData) {
      final pageMap = pageData as Map<String, dynamic>;
      final pageId = pageMap['id'] as String;
      final objectsData = pageMap['objects'] as List<dynamic>;
      final objects = objectsData
          .map((o) => BoardObject.fromJson(o as Map<String, dynamic>))
          .toList();
      _pages.add(BoardPage(id: pageId, objects: objects));
      _pageHistory[pageId] = [_cloneObjects(objects)];
      _pageHistoryIndex[pageId] = 0;
    }

    // Ensure at least one page exists
    if (_pages.isEmpty) {
      final defaultPage = BoardPage(id: _generateId());
      _pages.add(defaultPage);
      _pageHistory[defaultPage.id] = [[]];
      _pageHistoryIndex[defaultPage.id] = 0;
    }

    _currentPageIndex = 0;
    notifyListeners();
  }

  // === Remote sync (LiveKit) ===
  void applyRemoteOperation(Map<String, dynamic> operation) {
    final action = operation['action'] as String;
    final pageId = operation['pageId'] as String?;
    final page = _pages.firstWhere((p) => p.id == pageId,
        orElse: () => _pages[_currentPageIndex]);

    if (action == 'add') {
      page.objects.add(
          BoardObject.fromJson(operation['object'] as Map<String, dynamic>));
    } else if (action == 'delete') {
      final objId = operation['objectId'] as String;
      page.objects.removeWhere((o) => o.id == objId);
    } else if (action == 'move') {
      final objId = operation['objectId'] as String;
      final idx = page.objects.indexWhere((o) => o.id == objId);
      if (idx >= 0) {
        page.objects[idx] =
            BoardObject.fromJson(operation['object'] as Map<String, dynamic>);
      }
    } else if (action == 'clear') {
      page.objects.clear();
    }
    notifyListeners();
  }

  // === Internal ===
  void _addObject(BoardObject obj) {
    currentObjects.add(obj);
    _saveHistory();
    _emitOperation({
      'action': 'add',
      'object': obj.toJson(),
      'pageId': _pages[_currentPageIndex].id,
    });
    notifyListeners();
  }

  void _emitOperation(Map<String, dynamic> op) {
    onOperation?.call(op);
  }

  void _initPageHistory() {
    final pageId = _pages[_currentPageIndex].id;
    _pageHistory[pageId] = [[]];
    _pageHistoryIndex[pageId] = 0;
  }

  void _saveHistory() {
    final pageId = _pages[_currentPageIndex].id;
    if (!_pageHistory.containsKey(pageId)) _initPageHistory();

    final index = _pageHistoryIndex[pageId]!;
    final history = _pageHistory[pageId]!;

    if (index < history.length - 1) {
      _pageHistory[pageId] = history.sublist(0, index + 1);
    }

    _pageHistory[pageId]!.add(_cloneObjects(currentObjects));
    _pageHistoryIndex[pageId] = _pageHistory[pageId]!.length - 1;

    if (_pageHistory[pageId]!.length > 50) {
      _pageHistory[pageId]!.removeAt(0);
      _pageHistoryIndex[pageId] = _pageHistory[pageId]!.length - 1;
    }
  }

  List<BoardObject> _cloneObjects(List<BoardObject> objects) {
    return objects.map((o) => o.clone()).toList();
  }

  static int _idCounter = 0;
  static String _generateId() {
    _idCounter++;
    return '${DateTime.now().millisecondsSinceEpoch}_$_idCounter';
  }
}
