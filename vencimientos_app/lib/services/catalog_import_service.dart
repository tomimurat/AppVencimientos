import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/services.dart' show rootBundle;
import 'package:csv/csv.dart';
import 'database_helper.dart';

/// Parsea un catálogo en CSV y lo carga en la tabla `productos`.
/// CSV se lee como texto liviano (sin modelo de objetos como xlsx), así que
/// aguanta decenas de miles de filas sin problemas de memoria.
/// El parseo corre en un isolate de fondo (compute) para no trabar la UI.
class CatalogImportService {
  CatalogImportService._();
  static final CatalogImportService instance = CatalogImportService._();

  final _db = DatabaseHelper.instance;

  // ===================== CONFIGURACIÓN =====================
  // static para que el isolate de fondo pueda leerlas. Índices 0-based (0 = A).
  static const int colCodigoInterno = 0; // A
  static const int colBarcode = 1; // B
  static const int colNombre = 2; // C

  // Categoría: índice de columna si tu CSV la tiene; -1 si no.
  static const int colCategoria = -1;

  // ¿La primera fila es encabezado? Si desaparece tu primer producto, ponelo false.
  static const bool tieneEncabezado = true;

  // Separador: null = autodetectar (Excel es-AR usa ';'). Forzá ';' o ',' si querés.
  static const String? delimitador = null;
  // =========================================================

  /// Importa desde un asset embebido (ej. 'assets/catalogo.csv'). Cero permisos.
  Future<int> importarDesdeAsset(
    String assetPath, {
    bool reemplazar = true,
  }) async {
    // Leemos como bytes (no loadString) para manejar nosotros la codificación.
    final data = await rootBundle.load(assetPath);
    final bytes = data.buffer.asUint8List();
    return importarDesdeBytes(bytes, reemplazar: reemplazar);
  }

  /// Importa desde bytes ya obtenidos (ej. con file_picker).
  Future<int> importarDesdeBytes(
    Uint8List bytes, {
    bool reemplazar = true,
  }) async {
    final filas = await compute(_parsear, bytes);
    return _db.importarCatalogo(filas, reemplazar: reemplazar);
  }

  // =========== Parseo: estático y puro, apto para isolate de fondo ===========

  static List<Map<String, dynamic>> _parsear(Uint8List bytes) {
    var texto = _decodificar(bytes);
    // Normaliza saltos de línea y saca el BOM si Excel lo metió.
    texto = texto.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    if (texto.startsWith('\uFEFF')) texto = texto.substring(1);

    final delim = delimitador ?? _detectarDelimitador(texto);

    final filas = CsvToListConverter(
      fieldDelimiter: delim,
      eol: '\n',
      shouldParseNumbers: false, // todo como String => barcodes intactos
    ).convert(texto);

    final productos = <Map<String, dynamic>>[];
    final vistos = <String>{}; // dedup por barcode

    for (var i = 0; i < filas.length; i++) {
      if (tieneEncabezado && i == 0) continue;
      final row = filas[i];

      final barcode = _col(row, colBarcode);
      if (barcode.isEmpty) continue; // sin código no sirve
      if (!vistos.add(barcode)) continue; // duplicado en el archivo

      productos.add({
        'barcode': barcode,
        'codigo_interno': _col(row, colCodigoInterno),
        'nombre': _col(row, colNombre),
        'categoria':
            colCategoria >= 0 ? _nullSiVacio(_col(row, colCategoria)) : null,
      });
    }
    return productos;
  }

  /// Decodifica bytes: intenta UTF-8 y, si falla, cae a latin1 (Windows-1252),
  /// que es lo que suele exportar Excel en español.
  static String _decodificar(Uint8List bytes) {
    try {
      return const Utf8Decoder(allowMalformed: false).convert(bytes);
    } on FormatException {
      return latin1.decode(bytes);
    }
  }

  /// Mira la primera línea y elige el separador más frecuente (; o ,).
  static String _detectarDelimitador(String texto) {
    final nl = texto.indexOf('\n');
    final primera = nl >= 0 ? texto.substring(0, nl) : texto;
    final puntoComa = ';'.allMatches(primera).length;
    final coma = ','.allMatches(primera).length;
    return puntoComa > coma ? ';' : ',';
  }

  static String _col(List<dynamic> row, int idx) =>
      (idx >= 0 && idx < row.length) ? row[idx].toString().trim() : '';

  static String? _nullSiVacio(String s) => s.trim().isEmpty ? null : s.trim();
}
