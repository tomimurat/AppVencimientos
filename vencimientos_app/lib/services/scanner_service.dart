import 'package:mobile_scanner/mobile_scanner.dart';

/// Abstracción de la fuente de códigos. Hoy es la cámara; mañana podría ser
/// una pistola/PDA que emite eventos de teclado, sin tocar el repositorio
/// ni las pantallas: sólo se implementa otra clase con esta interfaz.
abstract class BarcodeSource {
  /// Emite cada código válido, ya filtrado de duplicados.
  Stream<String> get scans;
  Future<void> start();
  Future<void> stop();
  Future<void> dispose();
}

/// Implementación con cámara (mobile_scanner 7.x).
class CameraBarcodeSource implements BarcodeSource {
  /// Ventana de tiempo para ignorar relecturas del MISMO código.
  /// Evita que un código quieto en cámara sume 20 veces.
  final Duration debounce;

  CameraBarcodeSource({this.debounce = const Duration(milliseconds: 1500)});

  /// El controller se expone para alimentar el widget de preview.
  final MobileScannerController controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.normal,
    // Limitar a formatos de retail acelera la detección y reduce falsos.
    formats: const [
      BarcodeFormat.ean13,
      BarcodeFormat.ean8,
      BarcodeFormat.upcA,
      BarcodeFormat.upcE,
      BarcodeFormat.code128,
      BarcodeFormat.code39,
    ],
  );

  String? _ultimo;
  DateTime _ultimoTs = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  Stream<String> get scans => controller.barcodes
      .map(_extraer)
      .where((code) => code != null)
      .cast<String>()
      .where(_pasaDebounce);

  String? _extraer(BarcodeCapture capture) {
    if (capture.barcodes.isEmpty) return null;
    final raw = capture.barcodes.first.rawValue;
    return (raw != null && raw.isNotEmpty) ? raw : null;
  }

  bool _pasaDebounce(String code) {
    final ahora = DateTime.now();
    final esMismo = code == _ultimo;
    final dentroDeVentana = ahora.difference(_ultimoTs) < debounce;
    if (esMismo && dentroDeVentana) return false;
    _ultimo = code;
    _ultimoTs = ahora;
    return true;
  }

  /// Permite escanear de nuevo el mismo código a propósito (ej. cargar otra
  /// unidad del mismo lote de inmediato).
  void resetDebounce() {
    _ultimo = null;
    _ultimoTs = DateTime.fromMillisecondsSinceEpoch(0);
  }

  @override
  Future<void> start() => controller.start();

  @override
  Future<void> stop() => controller.stop();

  @override
  Future<void> dispose() => controller.dispose();
}
