import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

class DrawingPoint {
  final Offset point;
  final Paint paint;
  DrawingPoint(this.point, this.paint);
}

class TextAnnotation {
  Offset position;
  String text;
  Color color;
  double fontSize;
  TextAnnotation({
    required this.position,
    required this.text,
    this.color = Colors.red,
    this.fontSize = 18,
  });
}

class ImageEditorScreen extends StatefulWidget {
  final String imageUrl;
  final Map<String, String>? headers;
  final String targetSessionId;
  final String targetSessionName;

  const ImageEditorScreen({
    super.key,
    required this.imageUrl,
    required this.targetSessionId,
    required this.targetSessionName,
    this.headers,
  });

  @override
  State<ImageEditorScreen> createState() => _ImageEditorScreenState();
}

class _ImageEditorScreenState extends State<ImageEditorScreen> {
  final GlobalKey _repaintKey = GlobalKey();
  final List<DrawingPoint?> _points = [];
  final List<TextAnnotation> _texts = [];
  final List<dynamic> _undoStack = []; // 'line_break' or TextAnnotation

  Color _currentColor = Colors.red;
  double _strokeWidth = 3.0;
  bool _isTextMode = false;
  bool _isSending = false;
  ui.Image? _loadedImage;

  final List<Color> _colors = [
    Colors.red, Colors.blue, Colors.green, Colors.yellow,
    Colors.white, Colors.black, Colors.orange, Colors.purple,
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black87,
        iconTheme: const IconThemeData(color: Colors.white),
        title: const Text('编辑图片',
            style: TextStyle(color: Colors.white, fontSize: 16)),
        actions: [
          if (_undoStack.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.undo, color: Colors.white),
              onPressed: _undo,
            ),
          IconButton(
            icon: _isSending
                ? const SizedBox(width: 20, height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.check, color: Colors.white),
            onPressed: _isSending ? null : _sendImage,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: RepaintBoundary(
              key: _repaintKey,
              child: GestureDetector(
                onPanStart: _isTextMode ? null : _onPanStart,
                onPanUpdate: _isTextMode ? null : _onPanUpdate,
                onPanEnd: _isTextMode ? null : _onPanEnd,
                onTapUp: _isTextMode ? _onTapForText : null,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _buildSourceImage(),
                    CustomPaint(
                      painter: _DrawingPainter(_points),
                      size: Size.infinite,
                    ),
                    for (final ta in _texts)
                      Positioned(
                        left: ta.position.dx,
                        top: ta.position.dy,
                        child: Text(ta.text,
                          style: TextStyle(
                            color: ta.color,
                            fontSize: ta.fontSize,
                            fontWeight: FontWeight.bold,
                            shadows: const [Shadow(color: Colors.black54, blurRadius: 2)],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          _buildToolbar(),
        ],
      ),
    );
  }

  Widget _buildSourceImage() {
    final isNetwork = widget.imageUrl.startsWith('http');
    if (isNetwork) {
      return Image.network(
        widget.imageUrl,
        headers: widget.headers,
        fit: BoxFit.contain,
        loadingBuilder: (context, child, progress) {
          if (progress == null) return child;
          return const Center(child: CircularProgressIndicator(color: Colors.white));
        },
      );
    } else {
      return Image.file(
        File(widget.imageUrl),
        fit: BoxFit.contain,
      );
    }
  }

  Widget _buildToolbar() {
    return Container(
      color: Colors.black87,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                _buildToolButton(
                  icon: Icons.edit,
                  label: '画笔',
                  active: !_isTextMode,
                  onTap: () => setState(() => _isTextMode = false),
                ),
                const SizedBox(width: 8),
                _buildToolButton(
                  icon: Icons.text_fields,
                  label: '文字',
                  active: _isTextMode,
                  onTap: () => setState(() => _isTextMode = true),
                ),
                const SizedBox(width: 16),
                if (!_isTextMode) ...[
                  const Text('粗细', style: TextStyle(color: Colors.white70, fontSize: 11)),
                  SizedBox(
                    width: 100,
                    child: Slider(
                      value: _strokeWidth,
                      min: 1, max: 10,
                      activeColor: _currentColor,
                      onChanged: (v) => setState(() => _strokeWidth = v),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 4),
            SizedBox(
              height: 28,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: _colors.map((c) => GestureDetector(
                  onTap: () => setState(() => _currentColor = c),
                  child: Container(
                    width: 28, height: 28,
                    margin: const EdgeInsets.only(right: 6),
                    decoration: BoxDecoration(
                      color: c,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: _currentColor == c ? Colors.white : Colors.transparent,
                        width: 2,
                      ),
                    ),
                  ),
                )).toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildToolButton({
    required IconData icon,
    required String label,
    required bool active,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: active ? _currentColor.withValues(alpha: 0.3) : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: active ? _currentColor : Colors.white30),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: active ? Colors.white : Colors.white60),
            const SizedBox(width: 4),
            Text(label, style: TextStyle(
              fontSize: 12,
              color: active ? Colors.white : Colors.white60,
            )),
          ],
        ),
      ),
    );
  }

  void _onPanStart(DragStartDetails d) {
    _points.add(DrawingPoint(d.localPosition, _currentPaint));
  }

  void _onPanUpdate(DragUpdateDetails d) {
    setState(() {
      _points.add(DrawingPoint(d.localPosition, _currentPaint));
    });
  }

  void _onPanEnd(DragEndDetails d) {
    _points.add(null); // line break
    _undoStack.add('line_break');
  }

  Paint get _currentPaint => Paint()
    ..color = _currentColor
    ..strokeCap = StrokeCap.round
    ..strokeWidth = _strokeWidth
    ..isAntiAlias = true;

  void _onTapForText(TapUpDetails d) async {
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('添加文字'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '输入文字...'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (text != null && text.isNotEmpty) {
      final ta = TextAnnotation(
        position: d.localPosition,
        text: text,
        color: _currentColor,
      );
      setState(() {
        _texts.add(ta);
        _undoStack.add(ta);
      });
    }
  }

  void _undo() {
    if (_undoStack.isEmpty) return;
    final last = _undoStack.removeLast();
    setState(() {
      if (last is TextAnnotation) {
        _texts.remove(last);
      } else {
        // Remove last stroke (everything back to previous null)
        while (_points.isNotEmpty && _points.last != null) {
          _points.removeLast();
        }
        if (_points.isNotEmpty) _points.removeLast(); // remove the null
      }
    });
  }

  Future<void> _sendImage() async {
    setState(() => _isSending = true);
    try {
      final boundary = _repaintKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2.0);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      final bytes = byteData!.buffer.asUint8List();

      if (mounted) {
        Navigator.pop(context, bytes);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('图片处理失败: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }
}

class _DrawingPainter extends CustomPainter {
  final List<DrawingPoint?> points;
  _DrawingPainter(this.points);

  @override
  void paint(Canvas canvas, Size size) {
    for (int i = 0; i < points.length - 1; i++) {
      if (points[i] != null && points[i + 1] != null) {
        canvas.drawLine(points[i]!.point, points[i + 1]!.point, points[i]!.paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DrawingPainter old) => true;
}
