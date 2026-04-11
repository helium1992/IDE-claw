import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

class ImagePreviewScreen extends StatefulWidget {
  final String imageUrl;
  final String heroTag;
  final Map<String, String>? headers;
  final VoidCallback? onSave;
  final String? saveTooltip;

  const ImagePreviewScreen({
    super.key,
    required this.imageUrl,
    required this.heroTag,
    this.headers,
    this.onSave,
    this.saveTooltip,
  });

  @override
  State<ImagePreviewScreen> createState() => _ImagePreviewScreenState();
}

class _ImagePreviewScreenState extends State<ImagePreviewScreen> {
  final TransformationController _transformationController =
      TransformationController();

  @override
  void dispose() {
    _transformationController.dispose();
    super.dispose();
  }

  void _resetZoom() {
    _transformationController.value = Matrix4.identity();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
        actions: [
          if (widget.onSave != null)
            IconButton(
              onPressed: widget.onSave,
              icon: const Icon(Icons.download),
              tooltip: widget.saveTooltip ?? '保存到本地',
            ),
          IconButton(
            onPressed: _resetZoom,
            icon: const Icon(Icons.center_focus_strong),
            tooltip: '重置缩放',
          ),
        ],
      ),
      extendBodyBehindAppBar: true,
      body: LayoutBuilder(
        builder: (context, constraints) {
          return InteractiveViewer(
            transformationController: _transformationController,
            minScale: 1.0,
            maxScale: 5.0,
            boundaryMargin: const EdgeInsets.all(80),
            clipBehavior: Clip.none,
            child: SizedBox(
              width: constraints.maxWidth,
              height: constraints.maxHeight,
              child: Center(
                child: Hero(
                  tag: widget.heroTag,
                  child: CachedNetworkImage(
                    imageUrl: widget.imageUrl,
                    httpHeaders: widget.headers,
                    fit: BoxFit.contain,
                    placeholder: (context, _) => const Center(
                      child: CircularProgressIndicator(color: Colors.white),
                    ),
                    errorWidget: (context, error, stackTrace) => const Center(
                      child: Icon(
                        Icons.broken_image,
                        size: 64,
                        color: Colors.white54,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
