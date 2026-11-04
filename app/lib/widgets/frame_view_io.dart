import 'dart:ui' show Color;

import 'model_stage.dart' show ModelView;

/// Only a browser draws the 3D stage in a frame; a phone uses its WebView.
Future<ModelView?> openFrameView(Uri page, Color ink, void Function(String message) onMessage) async => null;

/// Only a browser's frame needs telling when something lies over it.
void setFrameTouchable(ModelView view, bool on) {}
