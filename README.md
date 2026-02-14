# EduBoard — Interactive Whiteboard for Flutter

A production-grade interactive whiteboard widget designed for educational platforms, with full real-time sync support via LiveKit data channels.

## Architecture

```
lib/
├── edu_board.dart              # Barrel export
├── main.dart                   # Demo app
├── models/
│   ├── board_models.dart       # All data models (fully serializable to JSON)
│   └── board_controller.dart   # State management + undo/redo + LiveKit hooks
├── painters/
│   └── board_painter.dart      # CustomPainter with perfect_freehand algorithm
├── widgets/
│   ├── edu_board.dart          # Main widget (plug into any screen)
│   ├── board_toolbar.dart      # Top toolbar with all tools
│   ├── properties_panel.dart   # Right panel (colors, stroke, shapes, text)
│   └── math_symbols_panel.dart # Floating math/science symbols picker
└── utils/
    └── math_symbols.dart       # Symbol data (math, greek, chemistry, music)
```

## Tools Included

| Tool | Key | Description |
|------|-----|-------------|
| Pen | P | Freehand drawing with pressure sensitivity |
| Highlighter | H | Semi-transparent overlay strokes |
| Eraser | E | Erase strokes |
| Line | L | Straight lines |
| Arrow | A | Arrows with heads |
| Shape | S | Rectangle, Circle, Triangle, Diamond, Ellipse, Star |
| Text | T | Click-to-type text with font/size options |
| Math Σ | — | Insert math, greek, calculus, geometry, chemistry, music symbols |
| Select | V | Select, move, delete objects |
| Pan | Space | Pan canvas (also Space+drag) |
| Image | — | Insert images from gallery/camera |
| Laser | — | Laser pointer for presentations |

## Features

- **Multi-page** notebook with page navigation
- **Undo/Redo** with 50-step history per page  
- **Zoom & Pan** (pinch gestures + mouse wheel + keyboard)
- **Canvas backgrounds**: Blank, Grid, Ruled (notebook), Dot grid
- **Dark/Light** canvas toggle
- **24 colors** + opacity control
- **6 stroke widths**
- **6 shapes** with fill toggle
- **5 font families** + 6 font sizes
- **8 symbol categories**: Basic math, Greek, Calculus, Geometry, Sets, Arrows, Chemistry, Music
- **Keyboard shortcuts** for all tools
- **Full JSON serialization** — every object is a serializable event

## LiveKit Integration

Every drawing operation is emitted as a JSON event through `BoardController.onOperation`. This is designed for direct piping into LiveKit data channels:

```dart
final controller = BoardController();

// SEND operations to other participants
controller.onOperation = (Map<String, dynamic> operation) {
  final encoded = utf8.encode(jsonEncode(operation));
  room.localParticipant?.publishData(encoded, reliable: true);
};

// RECEIVE operations from other participants  
room.addListener(RoomListener(
  onDataReceived: (data, participant, topic) {
    final op = jsonDecode(utf8.decode(data)) as Map<String, dynamic>;
    controller.applyRemoteOperation(op);
  },
));
```

### Operation Format

```json
{
  "action": "add",
  "pageId": "1234_1",
  "object": {
    "type": "stroke",
    "id": "1234_5",
    "points": [{"x": 100, "y": 200, "p": 0.5}, ...],
    "color": 4278190080,
    "strokeWidth": 3.0,
    "isHighlighter": false,
    "opacity": 1.0,
    "timestamp": 1700000000000
  }
}
```

### Supported actions: `add`, `delete`, `clear`

## Usage

```dart
import 'package:edu_board/edu_board.dart';

// In your widget:
Scaffold(
  body: EduBoard(
    controller: boardController,
    onExport: (json) => saveToServer(json),
    onInsertImage: () => pickAndUploadImage(),
  ),
)
```

## Upgrading to perfect_freehand package

The painter includes a built-in stroke algorithm, but for better quality:

1. Add `perfect_freehand: ^2.3.0` to pubspec.yaml  
2. In `board_painter.dart`, replace `_getStrokeOutlinePoints()` with:

```dart
import 'package:perfect_freehand/perfect_freehand.dart';

// In _drawPerfectFreehandStroke:
final outlinePoints = getStroke(
  points.map((p) => PointVector(p.x, p.y, p.pressure)).toList(),
  size: size,
  thinning: isHighlighter ? 0.0 : 0.5,
  smoothing: 0.5,
  streamline: 0.5,
);
```

## Subjects This Covers

- **Math**: Full symbol set (basic ops, fractions, calculus, integrals, limits)
- **Physics**: Greek letters, arrows, geometry symbols
- **Chemistry**: Reaction arrows, subscripts, equilibrium
- **French/Languages**: Text tool with multiple fonts
- **History/Geography**: Image insertion, arrows for timelines, text annotations
- **Music**: Note and musical notation symbols
- **Art**: Drawing tools, shapes, colors, opacity
