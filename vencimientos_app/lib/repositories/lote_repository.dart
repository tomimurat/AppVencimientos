import '../models/lote.dart';
import '../services/database_helper.dart';

/// Resultado de resolver un barcode contra el catálogo, listo para crear lote.
class LoteDraft {
  final String barcode;
  final String? nombreCatalogo; // null = producto desconocido
  final String? categoria;
  bool get conocido => nombreCatalogo != null;

  const LoteDraft({
    required this.barcode,
    this.nombreCatalogo,
    this.categoria,
  });
}

/// Capa de negocio. Las pantallas hablan SOLO con el repositorio,
/// nunca directo con la base o el scanner.
class LoteRepository {
  LoteRepository._();
  static final LoteRepository instance = LoteRepository._();

  final _db = DatabaseHelper.instance;

  /// Paso 1 del escaneo: ¿conocemos este código?
  Future<LoteDraft> resolver(String barcode) async {
    final match = await _db.buscarProducto(barcode);
    return LoteDraft(
      barcode: barcode,
      nombreCatalogo: match.nombre,
      categoria: match.categoria,
    );
  }

  /// Paso 2: registrar el lote con la fecha de vencimiento activa.
  Future<Lote> registrar({
    required String barcode,
    required String nombre,
    String? categoria,
    required DateTime fechaVencimiento,
    int cantidad = 1,
  }) async {
    final lote = Lote(
      barcode: barcode,
      nombre: nombre,
      categoria: categoria,
      fechaIngreso: DateTime.now(),
      fechaVencimiento: fechaVencimiento,
      cantidad: cantidad,
    );
    // Modo merge: mismo barcode + mismo vencimiento => suma cantidad.
    // No devolvemos id porque la fila puede ser preexistente; el scanner
    // identifica el lote por (barcode, fechaVencimiento).
    await _db.registrarOIncrementar(lote);
    return lote;
  }

  // --- Consultas para el dashboard ---
  Future<List<Lote>> listar({String? categoria}) =>
      _db.getLotes(categoria: categoria);

  Future<List<String>> categorias() => _db.getCategorias();

  // --- Edición rápida ---
  Future<void> cambiarFecha(int id, DateTime nueva) =>
      _db.updateFechaVencimiento(id, nueva);

  Future<void> cambiarCantidad(int id, int cantidad) =>
      _db.updateCantidad(id, cantidad);

  Future<void> eliminar(int id) => _db.deleteLote(id);

  /// Deshacer un escaneo en modo merge: resta cantidad (borra si llega a 0).
  Future<void> decrementar(String barcode, DateTime fechaVencimiento,
          {int cantidad = 1}) =>
      _db.decrementar(barcode, fechaVencimiento, cantidad: cantidad);

  /// Re-inserta un lote eliminado (para el "Deshacer" del dashboard).
  /// Usa el upsert para no chocar con el índice único si, en la ventana del
  /// snackbar, se escaneó el mismo barcode+vencimiento.
  Future<void> restaurar(Lote lote) => _db.registrarOIncrementar(lote);
}
