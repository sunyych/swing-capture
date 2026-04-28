import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/capture_location_metadata.dart';

/// Reads optional field location metadata if the user allows it.
class LocationMetadataService {
  const LocationMetadataService();

  Future<CaptureLocationMetadata?> getCurrentLocationMetadata() async {
    try {
      final permissionStatus = await Permission.locationWhenInUse.request();
      if (!permissionStatus.isGranted) {
        return null;
      }

      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        return null;
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: Duration(seconds: 4),
        ),
      );

      String? label;
      try {
        final placemarks = await placemarkFromCoordinates(
          position.latitude,
          position.longitude,
        );
        if (placemarks.isNotEmpty) {
          final placemark = placemarks.first;
          final parts = [placemark.locality, placemark.administrativeArea]
              .where((part) => part != null && part.trim().isNotEmpty)
              .cast<String>();
          if (parts.isNotEmpty) {
            label = parts.join(', ');
          }
        }
      } catch (_) {
        // Reverse geocoding is best effort only.
      }

      label ??=
          '${position.latitude.toStringAsFixed(5)}, ${position.longitude.toStringAsFixed(5)}';

      return CaptureLocationMetadata(
        latitude: position.latitude,
        longitude: position.longitude,
        label: label,
      );
    } catch (_) {
      return null;
    }
  }
}
