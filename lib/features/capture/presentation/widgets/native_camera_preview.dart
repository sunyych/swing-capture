import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Embeds the native camera preview ([PreviewView] on Android, preview layer on iOS).
class NativeCameraPreview extends StatelessWidget {
  const NativeCameraPreview({super.key});

  static const String viewType = 'swingcapture/native_preview';

  @override
  Widget build(BuildContext context) {
    const params = <String, dynamic>{};
    if (Platform.isAndroid) {
      return AndroidView(
        viewType: viewType,
        layoutDirection: TextDirection.ltr,
        creationParams: params,
        creationParamsCodec: const StandardMessageCodec(),
      );
    }
    if (Platform.isIOS) {
      return UiKitView(
        viewType: viewType,
        layoutDirection: TextDirection.ltr,
        creationParams: params,
        creationParamsCodec: const StandardMessageCodec(),
      );
    }
    return const SizedBox.shrink();
  }
}
