import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Embeds the Android [PreviewView] provided by [NativeCapturePipeline].
class AndroidNativeCameraPreview extends StatelessWidget {
  const AndroidNativeCameraPreview({super.key});

  static const String viewType = 'swingcapture/native_preview';

  @override
  Widget build(BuildContext context) {
    return AndroidView(
      viewType: viewType,
      layoutDirection: TextDirection.ltr,
      creationParamsCodec: const StandardMessageCodec(),
    );
  }
}
