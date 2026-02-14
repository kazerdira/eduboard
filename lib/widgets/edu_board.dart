import 'dart:async';
import 'dart:math' show pi;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/board_models.dart';
import '../models/board_controller.dart';
import '../painters/board_painter.dart';
import 'board_toolbar.dart';
import 'properties_panel.dart';
import 'math_symbols_panel.dart';
import 'recording_overlay.dart';
import '../models/recording_models.dart';
import '../services/board_recorder.dart';

class EduBoard extends StatefulWidget {
  final BoardController controller;
  final VoidCallback? onInsertImage;
  final void Function(String json)? onExport;
  final void Function(Uint8List pngBytes)? onExportImage;
  final void Function(RecordingResult result)? onRecordingComplete;
  final bool enableRecording;

  const EduBoard({
    super.key,
    required this.controller,
    this.onInsertImage,
    this.onExport,
    this.onExportImage,
    this.onRecordingComplete,
    this.enableRecording = true,
  });

  @override
  State<EduBoard> createState() => _EduBoardState();
}

class _EduBoardState extends State<EduBoard> with TickerProviderStateMixin {
  bool _showMathPanel = false;
  bool _showToolbar = true;
  bool _showSidePanel = true;
  bool _isTextEditing = false;
  Offset? _textEditPosition;
  int _editingTextIndex = -1; // -1 = new text, >=0 = editing existing

  final TextEditingController _textCtrl = TextEditingController();
  final FocusNode _textFocus = FocusNode();

  // Recording
  BoardRecorder? _recorder;

  // Gesture state
  double _baseZoom = 1.0;
  Offset _lastFocalPoint = Offset.zero;
  bool _isMultiTouch = false;
  bool _isMarqueeDragging = false;
  bool _isMultiMoving = false;

  // Long-press → marquee activation
  Timer? _longPressTimer;
  Offset? _longPressOrigin;
  static const _longPressDuration = Duration(milliseconds: 400);

  // Canvas virtual size
  static const double _canvasSize = 10000.0;

  late final AnimationController _fabAnimCtrl;

  BoardController get ctrl => widget.controller;

  bool _isMobile(BuildContext context) =>
      MediaQuery.of(context).size.width < 768;

  @override
  void initState() {
    super.initState();
    if (widget.enableRecording) {
      _recorder = BoardRecorder(controller: ctrl);
      _recorder!.addListener(_onRecorderStateChanged);
    }
    _fabAnimCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
      value: 1.0,
    );
    _textFocus.addListener(() {
      if (!_textFocus.hasFocus && _isTextEditing && !_showMathPanel) {
        _commitText();
      }
    });
    // Auto-commit text when user switches to a different tool
    ctrl.addListener(_onControllerChanged);
  }

  BoardToolType? _lastTool;

  void _onControllerChanged() {
    final currentTool = ctrl.activeTool;
    if (_isTextEditing &&
        _lastTool == BoardToolType.text &&
        currentTool != BoardToolType.text) {
      _commitText();
    }
    _lastTool = currentTool;
  }

  @override
  void dispose() {
    _longPressTimer?.cancel();
    ctrl.removeListener(_onControllerChanged);
    _recorder?.removeListener(_onRecorderStateChanged);
    _recorder?.dispose();
    _fabAnimCtrl.dispose();
    _textCtrl.dispose();
    _textFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isMobile = _isMobile(context);

    return SafeArea(
      child: Container(
        color: const Color(0xFF1a1a2e),
        child: Column(
          children: [
            if (_showToolbar)
              BoardToolbar(
                controller: ctrl,
                onUndo: ctrl.undo,
                onRedo: ctrl.redo,
                onClear: _handleClear,
                onExport: _handleExport,
                onInsertImage: widget.onInsertImage ?? () {},
                onMathSymbols: () =>
                    setState(() => _showMathPanel = !_showMathPanel),
                onRecord: _recorder != null ? _handleRecord : null,
                isRecording: _recorder?.state == RecordingState.recording ||
                    _recorder?.state == RecordingState.paused,
              ),
            Expanded(
              child: Stack(
                children: [
                  Row(
                    children: [
                      Expanded(child: _buildCanvasArea()),
                      if (!isMobile)
                        ClipRect(
                          child: AnimatedSize(
                            duration: const Duration(milliseconds: 250),
                            curve: Curves.easeInOut,
                            alignment: Alignment.centerRight,
                            child: SizedBox(
                              width: _showSidePanel ? 220 : 0,
                              child: _showSidePanel
                                  ? ListenableBuilder(
                                      listenable: ctrl,
                                      builder: (context, _) =>
                                          PropertiesPanel(controller: ctrl),
                                    )
                                  : const SizedBox.shrink(),
                            ),
                          ),
                        ),
                    ],
                  ),

                  // Floating controls
                  _buildFloatingControls(isMobile),

                  // Recording overlay
                  if (_recorder != null)
                    Positioned(
                      top: 8,
                      right: 12,
                      child: RecordingOverlay(
                        recorder: _recorder!,
                        onStop: _onOverlayStop,
                      ),
                    ),

                  // Selection action bar
                  _buildSelectionBar(),

                  // Text overlay
                  if (_isTextEditing && _textEditPosition != null)
                    _buildTextOverlay(),

                  // Math panel
                  if (_showMathPanel)
                    Positioned(
                      top: 4,
                      left: 0,
                      right: 0,
                      child: Center(
                        child: MathSymbolsPanel(
                          onSymbolSelected: _handleMathSymbol,
                          onClose: () => setState(() => _showMathPanel = false),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ============================================================
  // CANVAS
  // ============================================================

  BoxConstraints? _vpConstraints;

  /// Convert screen-space position to canvas-space position.
  Offset _toCanvas(Offset screen) {
    final vw = _vpConstraints!.maxWidth;
    final vh = _vpConstraints!.maxHeight;
    final z = ctrl.zoom;
    final px = ctrl.panOffset.dx;
    final py = ctrl.panOffset.dy;
    return Offset(
      _canvasSize / 2 + (screen.dx - px - vw / 2) / z,
      _canvasSize / 2 + (screen.dy - py - vh / 2) / z,
    );
  }

  /// Convert canvas-space position to screen-space position (inverse of _toCanvas).
  Offset _toScreen(Offset canvas) {
    final vw = _vpConstraints!.maxWidth;
    final vh = _vpConstraints!.maxHeight;
    final z = ctrl.zoom;
    final px = ctrl.panOffset.dx;
    final py = ctrl.panOffset.dy;
    return Offset(
      (canvas.dx - _canvasSize / 2) * z + px + vw / 2,
      (canvas.dy - _canvasSize / 2) * z + py + vh / 2,
    );
  }

  Widget _buildCanvasArea() {
    return LayoutBuilder(
      builder: (context, constraints) {
        _vpConstraints = constraints;
        return GestureDetector(
          onScaleStart: _onScaleStart,
          onScaleUpdate: _onScaleUpdate,
          onScaleEnd: _onScaleEnd,
          child: ClipRect(
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: _onPointerDown,
              onPointerMove: _onPointerMove,
              onPointerUp: _onPointerUp,
              child: ListenableBuilder(
                listenable: ctrl,
                builder: (context, _) {
                  final vw = constraints.maxWidth;
                  final vh = constraints.maxHeight;
                  final z = ctrl.zoom;

                  return Container(
                    color:
                        ctrl.darkMode ? const Color(0xFF1e1e2e) : Colors.white,
                    child: Transform(
                      transform: Matrix4.identity()
                        ..translate(
                          ctrl.panOffset.dx + vw / 2,
                          ctrl.panOffset.dy + vh / 2,
                        )
                        ..scale(z)
                        ..translate(-_canvasSize / 2, -_canvasSize / 2),
                      child: OverflowBox(
                        alignment: Alignment.topLeft,
                        minWidth: _canvasSize,
                        maxWidth: _canvasSize,
                        minHeight: _canvasSize,
                        maxHeight: _canvasSize,
                        child: CustomPaint(
                          painter: BoardPainter(ctrl),
                          size: const Size(_canvasSize, _canvasSize),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }

  // ============================================================
  // POINTER EVENTS
  // ============================================================

  void _onPointerDown(PointerDownEvent event) {
    if (_vpConstraints == null) return;
    final pos = _toCanvas(event.localPosition);
    final pressure = event.pressure;

    if (ctrl.activeTool == BoardToolType.pan)
      return; // handled by GestureDetector

    switch (ctrl.activeTool) {
      case BoardToolType.pen:
      case BoardToolType.highlighter:
        ctrl.startStroke(pos, pressure: pressure);
        break;
      case BoardToolType.eraser:
        ctrl.eraseAt(pos);
        break;
      case BoardToolType.line:
      case BoardToolType.arrow:
      case BoardToolType.shape:
      case BoardToolType.ruler:
        ctrl.startShape(pos);
        break;
      case BoardToolType.text:
        _startTextEdit(pos);
        break;
      case BoardToolType.select:
        // If we have multi-selection and tap inside the group → move them
        if (ctrl.hasMultiSelection && ctrl.isPointInMultiSelection(pos)) {
          _isMultiMoving = true;
          ctrl.startMultiMove(pos);
        } else {
          ctrl.selectObjectAt(pos);

          // Arm long-press timer
          _longPressOrigin = pos;
          _longPressTimer?.cancel();
          _longPressTimer = Timer(_longPressDuration, () {
            if (_longPressOrigin == null) return;

            if (ctrl.isPointOnObject(_longPressOrigin!)) {
              // Long-press ON an object → toggle it in/out of multi-selection
              ctrl.toggleObjectInMultiSelection(_longPressOrigin!);
              HapticFeedback.mediumImpact();
            } else {
              // Long-press on EMPTY space → start marquee rectangle
              setState(() {
                _isMarqueeDragging = true;
                ctrl.deselectAll();
                ctrl.startMarquee(_longPressOrigin!);
              });
              HapticFeedback.mediumImpact();
            }
            _longPressOrigin = null;
          });
        }
        break;
      case BoardToolType.laser:
        ctrl.addLaserPoint(pos);
        break;
      default:
        break;
    }
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (_isMultiTouch) return;
    if (_vpConstraints == null) return;

    final pos = _toCanvas(event.localPosition);
    final pressure = event.pressure;

    switch (ctrl.activeTool) {
      case BoardToolType.pen:
      case BoardToolType.highlighter:
        ctrl.addStrokePoint(pos, pressure: pressure);
        break;
      case BoardToolType.eraser:
        ctrl.eraseAt(pos);
        break;
      case BoardToolType.line:
      case BoardToolType.arrow:
      case BoardToolType.shape:
      case BoardToolType.ruler:
        ctrl.updateShape(pos);
        break;
      case BoardToolType.select:
        // Cancel long-press if finger moved too far
        if (_longPressOrigin != null &&
            (pos - _longPressOrigin!).distance > 15) {
          _longPressTimer?.cancel();
          _longPressTimer = null;
          _longPressOrigin = null;
        }
        if (_isMarqueeDragging) {
          ctrl.updateMarquee(pos);
        } else if (_isMultiMoving) {
          ctrl.moveMultiSelected(pos);
        } else {
          ctrl.moveSelected(pos);
        }
        break;
      case BoardToolType.laser:
        ctrl.addLaserPoint(pos);
        break;
      default:
        break;
    }
  }

  void _onPointerUp(PointerUpEvent event) {
    switch (ctrl.activeTool) {
      case BoardToolType.pen:
      case BoardToolType.highlighter:
        ctrl.endStroke();
        break;
      case BoardToolType.eraser:
        // eraseAt already handled in down/move — just save history
        ctrl.endErase();
        break;
      case BoardToolType.line:
      case BoardToolType.arrow:
      case BoardToolType.shape:
      case BoardToolType.ruler:
        ctrl.endShape();
        break;
      case BoardToolType.select:
        _longPressTimer?.cancel();
        _longPressTimer = null;
        _longPressOrigin = null;
        if (_isMarqueeDragging) {
          ctrl.endMarquee();
          _isMarqueeDragging = false;
        } else if (_isMultiMoving) {
          ctrl.endMultiMove();
          _isMultiMoving = false;
        } else {
          ctrl.endMoveSelected();
        }
        break;
      case BoardToolType.laser:
        Future.delayed(
            const Duration(milliseconds: 800), () => ctrl.clearLaser());
        break;
      default:
        break;
    }
  }

  // ============================================================
  // PINCH ZOOM & PAN
  // ============================================================

  void _onScaleStart(ScaleStartDetails details) {
    _baseZoom = ctrl.zoom;
    _lastFocalPoint = details.focalPoint;
    _isMultiTouch = details.pointerCount >= 2;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    if (details.pointerCount >= 2) {
      if (!_isMultiTouch) {
        // Just became multi-touch — cancel any in-progress drawing
        ctrl.cancelCurrentDrawing();
      }
      _isMultiTouch = true;
      final newZoom = (_baseZoom * details.scale).clamp(0.1, 10.0);
      ctrl.setZoom(newZoom);
      final delta = details.focalPoint - _lastFocalPoint;
      ctrl.pan(delta);
      _lastFocalPoint = details.focalPoint;
    } else if (ctrl.activeTool == BoardToolType.pan) {
      final delta = details.focalPoint - _lastFocalPoint;
      ctrl.pan(delta);
      _lastFocalPoint = details.focalPoint;
    }
  }

  void _onScaleEnd(ScaleEndDetails details) {
    _baseZoom = ctrl.zoom;
    _isMultiTouch = false;
  }

  // ============================================================
  // TEXT INPUT
  // ============================================================

  double _editingOriginalRotation = 0.0;

  void _startTextEdit(Offset position) {
    // Check if tapping an existing text object
    final idx = ctrl.findTextIndexAt(position);
    if (idx >= 0) {
      // Edit existing text
      final obj = ctrl.currentObjects[idx] as TextObject;
      _editingOriginalRotation = obj.rotation;
      setState(() {
        _isTextEditing = true;
        _textEditPosition = obj.position;
        _editingTextIndex = idx;
        _textCtrl.text = obj.text;
        _textCtrl.selection = TextSelection.fromPosition(
          TextPosition(offset: obj.text.length),
        );
      });
      // Tell the controller so the painter skips drawing this object
      ctrl.editingTextIndex = idx;
      // Deselect to hide selection handles while editing
      ctrl.deselectAll();
    } else {
      // New text
      _editingOriginalRotation = 0.0;
      setState(() {
        _isTextEditing = true;
        _textEditPosition = position;
        _editingTextIndex = -1;
        _textCtrl.clear();
      });
    }
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _textFocus.requestFocus());
  }

  void _commitText() {
    final text = _textCtrl.text;
    if (_editingTextIndex >= 0) {
      // Restore the original rotation before updating
      if (_editingTextIndex < ctrl.currentObjects.length) {
        ctrl.currentObjects[_editingTextIndex].rotation =
            _editingOriginalRotation;
      }
      // Update existing text object
      ctrl.updateTextAt(_editingTextIndex, text);
    } else if (text.trim().isNotEmpty && _textEditPosition != null) {
      // Create new text object
      ctrl.addText(text, _textEditPosition!);
    }
    // Clear editing state on controller
    ctrl.editingTextIndex = null;
    setState(() {
      _isTextEditing = false;
      _textEditPosition = null;
      _editingTextIndex = -1;
      _editingOriginalRotation = 0.0;
    });
    // Switch to select tool so user can reposition the text they just placed
    ctrl.setTool(BoardToolType.select);
  }

  /// Detects if text starts with RTL characters (Arabic, Hebrew, etc.)
  TextDirection _detectTextDirection(String text) {
    if (text.isEmpty) return TextDirection.ltr;
    // Check first non-whitespace character for RTL unicode ranges
    final trimmed = text.trimLeft();
    if (trimmed.isEmpty) return TextDirection.ltr;
    final firstChar = trimmed.codeUnitAt(0);
    // Arabic: 0x0600–0x06FF, 0x0750–0x077F, 0xFB50–0xFDFF, 0xFE70–0xFEFF
    // Hebrew: 0x0590–0x05FF
    if ((firstChar >= 0x0590 && firstChar <= 0x05FF) ||
        (firstChar >= 0x0600 && firstChar <= 0x06FF) ||
        (firstChar >= 0x0750 && firstChar <= 0x077F) ||
        (firstChar >= 0xFB50 && firstChar <= 0xFDFF) ||
        (firstChar >= 0xFE70 && firstChar <= 0xFEFF)) {
      return TextDirection.rtl;
    }
    return TextDirection.ltr;
  }

  Widget _buildTextOverlay() {
    if (_vpConstraints == null || _textEditPosition == null) {
      return const SizedBox.shrink();
    }

    // Convert the canvas-space text position to screen-space
    final screenPos = _toScreen(_textEditPosition!);
    final z = ctrl.zoom;
    // Scale the font size by zoom so the text visually matches the canvas
    final scaledFontSize = ((_editingTextIndex >= 0
                ? (ctrl.currentObjects[_editingTextIndex] as TextObject)
                    .fontSize
                : ctrl.fontSize) *
            z)
        .clamp(10.0, 120.0);
    final textColor = _editingTextIndex >= 0
        ? (ctrl.currentObjects[_editingTextIndex] as TextObject).color
        : ctrl.activeColor;
    final fontFamily = _editingTextIndex >= 0
        ? (ctrl.currentObjects[_editingTextIndex] as TextObject).fontFamily
        : ctrl.fontFamily;

    // Determine if text color is too dark for the canvas background
    final bgIsDark = ctrl.darkMode;
    final cursorColor = bgIsDark ? Colors.white : const Color(0xFF4361ee);

    return Positioned(
      left: screenPos.dx,
      top: screenPos.dy,
      child: Transform.rotate(
        angle: _editingOriginalRotation,
        alignment: Alignment.topLeft,
        child: Material(
          color: Colors.transparent,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // Inline text field directly on canvas
              IntrinsicWidth(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minWidth: 40,
                    maxWidth: (_vpConstraints!.maxWidth - screenPos.dx - 16)
                        .clamp(100, 600),
                  ),
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border(
                        bottom: BorderSide(
                          color: const Color(0xFF4361ee).withValues(alpha: 0.4),
                          width: 1,
                        ),
                      ),
                    ),
                    child: EditableText(
                      controller: _textCtrl,
                      focusNode: _textFocus,
                      style: TextStyle(
                        fontSize: scaledFontSize,
                        fontFamily: fontFamily,
                        color: textColor,
                        height: 1.3,
                      ),
                      strutStyle: StrutStyle(
                        fontSize: scaledFontSize,
                        height: 1.3,
                        forceStrutHeight: true,
                        leading: 0,
                      ),
                      cursorColor: cursorColor,
                      backgroundCursorColor: Colors.grey,
                      maxLines: null,
                      keyboardType: TextInputType.multiline,
                      textDirection: _detectTextDirection(_textCtrl.text),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 2),
              // Compact action buttons below the text
              _buildInlineTextActions(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInlineTextActions() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFF1a1f3a).withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 6)
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _inlineBtn(Icons.functions, 'Symbol', () {
            setState(() => _showMathPanel = !_showMathPanel);
          }),
          _inlineBtn(Icons.check, 'Done', _commitText,
              color: const Color(0xFF22c55e)),
          _inlineBtn(Icons.close, 'Cancel', () {
            // Restore original rotation if we were editing
            if (_editingTextIndex >= 0 &&
                _editingTextIndex < ctrl.currentObjects.length) {
              ctrl.currentObjects[_editingTextIndex].rotation =
                  _editingOriginalRotation;
            }
            ctrl.editingTextIndex = null;
            setState(() {
              _isTextEditing = false;
              _textEditPosition = null;
              _editingTextIndex = -1;
              _editingOriginalRotation = 0.0;
            });
            ctrl.refresh();
          }, color: const Color(0xFFef4444)),
        ],
      ),
    );
  }

  Widget _inlineBtn(IconData icon, String tooltip, VoidCallback onTap,
      {Color color = Colors.white70}) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(icon, size: 18, color: color),
        ),
      ),
    );
  }

  // ============================================================
  // MATH SYMBOLS
  // ============================================================

  void _handleMathSymbol(String symbol) {
    if (_isTextEditing) {
      final pos = _textCtrl.selection.baseOffset;
      final text = _textCtrl.text;
      final newText = text.substring(0, pos < 0 ? text.length : pos) +
          symbol +
          text.substring(pos < 0 ? text.length : pos);
      _textCtrl.text = newText;
      _textCtrl.selection = TextSelection.fromPosition(
          TextPosition(offset: (pos < 0 ? text.length : pos) + symbol.length));
      _textFocus.requestFocus();
    } else {
      // Open text editor with symbol pre-filled
      _startTextEdit(Offset(_canvasSize / 2, _canvasSize / 2));
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _textCtrl.text = symbol;
        _textCtrl.selection =
            TextSelection.fromPosition(TextPosition(offset: symbol.length));
      });
    }
  }

  // ============================================================
  // SELECTION ACTION BAR (appears when object selected)
  // ============================================================

  Widget _buildSelectionBar() {
    return ListenableBuilder(
      listenable: ctrl,
      builder: (context, _) {
        // Show multi-selection bar
        if (ctrl.hasMultiSelection && ctrl.activeTool == BoardToolType.select) {
          return _buildMultiSelectionBar();
        }

        // Show single-selection bar
        if (ctrl.selectedObject == null ||
            ctrl.activeTool != BoardToolType.select) {
          return const SizedBox.shrink();
        }

        return Positioned(
          bottom: 16,
          left: 0,
          right: 0,
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFF1a1f3a).withValues(alpha: 0.95),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
                boxShadow: [
                  BoxShadow(
                      color: Colors.black.withValues(alpha: 0.4),
                      blurRadius: 16)
                ],
              ),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _selectionAction(Icons.flip_to_front, 'Front', () {
                      ctrl.bringToFront();
                    }),
                    _selectionDivider(),
                    _selectionAction(Icons.flip_to_back, 'Back', () {
                      ctrl.sendToBack();
                    }),
                    _selectionDivider(),
                    _selectionAction(Icons.copy, 'Duplicate', () {
                      ctrl.duplicateSelected();
                    }),
                    _selectionDivider(),
                    _selectionAction(Icons.delete_outline, 'Delete', () {
                      ctrl.deleteSelected();
                    }, color: const Color(0xFFef4444)),
                    _selectionDivider(),
                    _selectionAction(Icons.close, 'Deselect', () {
                      ctrl.deselectAll();
                    }),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildMultiSelectionBar() {
    final count = ctrl.multiSelectedIndices.length;
    return Positioned(
      bottom: 16,
      left: 0,
      right: 0,
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xFF1a1f3a).withValues(alpha: 0.95),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
            boxShadow: [
              BoxShadow(
                  color: Colors.black.withValues(alpha: 0.4), blurRadius: 16)
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text(
                  '$count selected',
                  style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 12,
                      fontWeight: FontWeight.w600),
                ),
              ),
              _selectionDivider(),
              _selectionAction(Icons.delete_outline, 'Delete', () {
                ctrl.deleteMultiSelected();
              }, color: const Color(0xFFef4444)),
              _selectionDivider(),
              _selectionAction(Icons.close, 'Deselect', () {
                ctrl.deselectAll();
              }),
            ],
          ),
        ),
      ),
    );
  }

  Widget _selectionAction(IconData icon, String label, VoidCallback onTap,
      {Color? color}) {
    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color ?? Colors.white70, size: 22),
            const SizedBox(height: 2),
            Text(label,
                style: TextStyle(color: color ?? Colors.white54, fontSize: 10)),
          ],
        ),
      ),
    );
  }

  Widget _selectionDivider() {
    return Container(
        width: 1, height: 30, color: Colors.white.withValues(alpha: 0.1));
  }

  // ============================================================
  // FLOATING CONTROLS  (water-drop stagger animation)
  // ============================================================

  void _toggleFabControls() {
    if (_fabAnimCtrl.isCompleted ||
        _fabAnimCtrl.status == AnimationStatus.forward) {
      _fabAnimCtrl.reverse();
    } else {
      _fabAnimCtrl.forward();
    }
  }

  /// Wraps a single control item with staggered scale + slide + opacity.
  /// Bottom items appear first (show) / top items hide first (hide).
  Widget _staggeredItem(int index, int total, Widget child) {
    final reversedIdx = total - 1 - index;
    final step = total > 1 ? 0.5 / (total - 1) : 0.0;
    final begin = (reversedIdx * step).clamp(0.0, 0.6);
    final end = (begin + 0.5).clamp(0.0, 1.0);

    final parentVal = _fabAnimCtrl.value;
    final localT = end > begin
        ? ((parentVal - begin) / (end - begin)).clamp(0.0, 1.0)
        : parentVal;

    // Elastic overshoot when showing, smooth ease when hiding
    final isForward = _fabAnimCtrl.status == AnimationStatus.forward ||
        _fabAnimCtrl.isCompleted;
    final curved = isForward
        ? Curves.elasticOut.transform(localT)
        : Curves.easeInBack.transform(localT);

    return Align(
      alignment: Alignment.centerRight,
      heightFactor: localT,
      child: Opacity(
        opacity: localT,
        child: Transform.translate(
          offset: Offset(24.0 * (1.0 - localT), 0),
          child: Transform.scale(
            scale: curved.clamp(0.0, 1.5),
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: child,
            ),
          ),
        ),
      ),
    );
  }

  /// Small pill-shaped arrow that is always visible.
  /// Rotates to indicate show (←) / hide (→) direction.
  Widget _buildFabToggle() {
    return GestureDetector(
      onTap: _toggleFabControls,
      child: Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          color: const Color(0xFF1a1f3a).withValues(alpha: 0.85),
          borderRadius: BorderRadius.circular(15),
          border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withValues(alpha: 0.25), blurRadius: 5),
          ],
        ),
        child: Transform.rotate(
          angle: (1 - _fabAnimCtrl.value) * pi,
          child:
              const Icon(Icons.chevron_right, color: Colors.white60, size: 20),
        ),
      ),
    );
  }

  Widget _buildHandButton() {
    return ListenableBuilder(
      listenable: ctrl,
      builder: (context, _) => GestureDetector(
        onTap: () => ctrl.setTool(
          ctrl.activeTool == BoardToolType.pan
              ? BoardToolType.pen
              : BoardToolType.pan,
        ),
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: ctrl.activeTool == BoardToolType.pan
                ? const Color(0xFF4361ee).withValues(alpha: 0.3)
                : const Color(0xFF1a1f3a).withValues(alpha: 0.9),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: ctrl.activeTool == BoardToolType.pan
                  ? const Color(0xFF4361ee)
                  : Colors.white.withValues(alpha: 0.1),
            ),
            boxShadow: [
              BoxShadow(
                  color: Colors.black.withValues(alpha: 0.3), blurRadius: 6)
            ],
          ),
          child: Icon(Icons.pan_tool_outlined,
              color: ctrl.activeTool == BoardToolType.pan
                  ? const Color(0xFF4361ee)
                  : Colors.white70,
              size: 20),
        ),
      ),
    );
  }

  Widget _buildZoomIndicator() {
    return ListenableBuilder(
      listenable: ctrl,
      builder: (context, _) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: const Color(0xFF1a1f3a).withValues(alpha: 0.9),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
        ),
        child: Text('${(ctrl.zoom * 100).round()}%',
            style: const TextStyle(
                color: Colors.white70,
                fontSize: 11,
                fontWeight: FontWeight.w500)),
      ),
    );
  }

  Widget _buildFloatingControls(bool isMobile) {
    final items = <Widget>[
      if (isMobile)
        _fab(Icons.expand_less,
            () => setState(() => _showToolbar = !_showToolbar)),
      _buildPaletteButton(isMobile),
      _buildHandButton(),
      _fab(Icons.zoom_in, ctrl.zoomIn),
      _fab(Icons.zoom_out, ctrl.zoomOut),
      _fab(Icons.center_focus_strong, ctrl.resetZoom),
      _buildZoomIndicator(),
    ];
    final total = items.length;

    return Positioned(
      right: 8,
      bottom: 56,
      child: AnimatedBuilder(
        animation: _fabAnimCtrl,
        builder: (context, _) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // Staggered animated control buttons
            IgnorePointer(
              ignoring: _fabAnimCtrl.isDismissed,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: List.generate(
                    total, (i) => _staggeredItem(i, total, items[i])),
              ),
            ),
            const SizedBox(height: 4),
            // Toggle arrow – always visible
            _buildFabToggle(),
          ],
        ),
      ),
    );
  }

  Widget _fab(IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: const Color(0xFF1a1f3a).withValues(alpha: 0.9),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
          boxShadow: [
            BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 6)
          ],
        ),
        child: Icon(icon, color: Colors.white70, size: 20),
      ),
    );
  }

  /// Palette button – opens bottom sheet on mobile, toggles side panel on wide.
  /// Highlighted when the side panel is visible (wide) or always normal on mobile.
  Widget _buildPaletteButton(bool isMobile) {
    final isActive = !isMobile && _showSidePanel;
    return GestureDetector(
      onTap: () {
        if (isMobile) {
          _showPropertiesSheet(context);
        } else {
          setState(() => _showSidePanel = !_showSidePanel);
        }
      },
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: isActive
              ? const Color(0xFF4361ee).withValues(alpha: 0.3)
              : const Color(0xFF1a1f3a).withValues(alpha: 0.9),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isActive
                ? const Color(0xFF4361ee)
                : Colors.white.withValues(alpha: 0.1),
          ),
          boxShadow: [
            BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 6)
          ],
        ),
        child: Icon(Icons.palette,
            color: isActive ? Colors.white : Colors.white70, size: 20),
      ),
    );
  }

  // ============================================================
  // MOBILE PROPERTIES BOTTOM SHEET
  // ============================================================

  void _showPropertiesSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => Container(
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 24),
        decoration: BoxDecoration(
          color: const Color(0xFF0f1729),
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withValues(alpha: 0.4), blurRadius: 20)
          ],
        ),
        child: DraggableScrollableSheet(
          initialChildSize: 0.55,
          minChildSize: 0.3,
          maxChildSize: 0.85,
          expand: false,
          builder: (context, scrollCtrl) => ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: SingleChildScrollView(
              controller: scrollCtrl,
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
              child: Column(
                children: [
                  Container(
                      width: 36,
                      height: 5,
                      decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.3),
                          borderRadius: BorderRadius.circular(3))),
                  const SizedBox(height: 20),
                  PropertiesPanel(controller: ctrl, isInBottomSheet: true),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ============================================================
  // ACTIONS
  // ============================================================

  void _handleClear() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1a1f3a),
        title: const Text('Clear Page', style: TextStyle(color: Colors.white)),
        content: Text('Clear all objects on this page?',
            style: TextStyle(color: Colors.white.withValues(alpha: 0.7))),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            onPressed: () {
              ctrl.clearPage();
              Navigator.pop(ctx);
            },
            child:
                const Text('Clear', style: TextStyle(color: Color(0xFFef4444))),
          ),
        ],
      ),
    );
  }

  // ============================================================
  // RECORDING
  // ============================================================

  /// Called by the recorder's ChangeNotifier whenever state changes.
  void _onRecorderStateChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _handleRecord() async {
    final rec = _recorder;
    if (rec == null) return;

    if (rec.state == RecordingState.idle) {
      // Get actual viewport size for screen-accurate recording
      final renderBox = context.findRenderObject() as RenderBox?;
      final vw = renderBox?.size.width ?? 1280;
      final vh = renderBox?.size.height ?? 720;

      // Get device pixel ratio for native screen resolution (like phone screen recorders)
      final dpr = MediaQuery.of(context).devicePixelRatio;

      // Set viewport dimensions so recorder captures exactly what user sees
      rec.viewportWidth = vw;
      rec.viewportHeight = vh;

      final config = RecordingConfig.fromViewport(
        viewportWidth: vw,
        viewportHeight: vh,
        devicePixelRatio: dpr,
        recordAudio: true,
      );

      final ok = await rec.start(config);
      if (ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
                '🔴 Recording ${config.width}×${config.height} @${config.fps}fps'),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 2),
          ),
        );
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content:
                Text('Failed to start recording. Check microphone permission.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } else {
      // Already recording → stop
      final result = await rec.stop();
      _showRecordingDone(result);
    }
  }

  /// Called when the overlay stop button is pressed.
  void _onOverlayStop(RecordingResult? result) {
    _showRecordingDone(result);
  }

  void _showRecordingDone(RecordingResult? result) {
    if (result != null) {
      widget.onRecordingComplete?.call(result);
    }
    if (!mounted) return;
    final dur = result?.duration ?? Duration.zero;
    final m = dur.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = dur.inSeconds.remainder(60).toString().padLeft(2, '0');
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.check_circle, color: Color(0xFF22c55e), size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Recording saved ($m:$s)',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 4),
      ),
    );
  }

  void _handleExport() {
    final hasJson = widget.onExport != null;
    final hasImage = widget.onExportImage != null;

    // If only one option, skip the choice sheet
    if (hasImage && !hasJson) {
      _exportAsImage();
      return;
    }
    if (hasJson && !hasImage) {
      _exportAsJson();
      return;
    }
    // Neither? Still export image with built-in preview fallback
    if (!hasJson && !hasImage) {
      _exportAsImage();
      return;
    }

    // Both callbacks provided → show the choice sheet
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 24),
        decoration: BoxDecoration(
          color: const Color(0xFF0f1729),
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withValues(alpha: 0.4), blurRadius: 20)
          ],
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 36,
                  height: 5,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                const SizedBox(height: 16),
                const Text('Save Board',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 20),
                ListTile(
                  leading: const Icon(Icons.image_outlined,
                      color: Color(0xFF22c55e)),
                  title: const Text('Save as Image',
                      style: TextStyle(color: Colors.white)),
                  subtitle: Text('Export board as PNG image',
                      style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.4),
                          fontSize: 12)),
                  onTap: () {
                    Navigator.pop(ctx);
                    _exportAsImage();
                  },
                ),
                ListTile(
                  leading:
                      const Icon(Icons.data_object, color: Color(0xFF3b82f6)),
                  title: const Text('Save as JSON',
                      style: TextStyle(color: Colors.white)),
                  subtitle: Text(
                      'For sync & backup (${ctrl.currentObjects.length} objects)',
                      style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.4),
                          fontSize: 12)),
                  onTap: () {
                    Navigator.pop(ctx);
                    _exportAsJson();
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _exportAsJson() {
    final json = ctrl.exportToJson();
    widget.onExport?.call(json);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content:
              Text('JSON exported (${ctrl.currentObjects.length} objects)'),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2)),
    );
  }

  Future<void> _exportAsImage() async {
    if (ctrl.currentObjects.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Nothing to export – the board is empty'),
            behavior: SnackBarBehavior.floating),
      );
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
          content: Text('Rendering image…'),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 1)),
    );

    try {
      final bytes = await BoardPainter.exportToImage(ctrl);
      if (bytes != null && mounted) {
        widget.onExportImage?.call(bytes);
        if (widget.onExportImage == null) {
          // Fallback: show a preview dialog
          _showImagePreview(bytes);
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Image export failed: $e'),
              behavior: SnackBarBehavior.floating),
        );
      }
    }
  }

  void _showImagePreview(Uint8List bytes) {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: const Color(0xFF0f1729),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Board Image',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.memory(bytes, fit: BoxFit.contain),
              ),
              const SizedBox(height: 8),
              Text(
                '${(bytes.length / 1024).toStringAsFixed(0)} KB',
                style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.4), fontSize: 12),
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Close'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
