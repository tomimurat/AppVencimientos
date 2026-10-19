import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import '../models/lote.dart';

/// Match de un barcode contra el catálogo maestro.
class ProductoMatch {
  final String barcode;
  final String? nombre; // null = producto desconocido (no está en catálogo)
  final String? categoria;
  bool get conocido => nombre != null;

  const ProductoMatch({required this.barcode, this.nombre, this.categoria});
}

/// Resumen agregado de estados, calculado en SQL (para inventarios grandes).
/// OJO: usa umbrales GLOBALES, así que es una aproximación frente al cálculo
/// por categoría que hace `lote.estado` en Dart. Para el KPI de un tablero con
/// decenas de miles de filas el matiz por categoría es aceptable; si necesitás
/// exactitud por categoría, segui tallando en Dart con `getLotes()`.
class ResumenEstados {
  final int lotesVencidos, lotesCriticos, lotesProximos, lotesOk;
  final int uVencidas, uCriticas, uProximas, uOk;

  const ResumenEstados({
    required this.lotesVencidos,
    required this.lotesCriticos,
    required this.lotesProximos,
    required this.lotesOk,
    required this.uVencidas,
    required this.uCriticas,
    required this.uProximas,
    required this.uOk,
  });

  int get totalLotes => lotesVencidos + lotesCriticos + lotesProximos + lotesOk;
  int get totalUnidades => uVencidas + uCriticas + uProximas + uOk;

  /// % de unidades en riesgo (vencidas + críticas + próximas).
  double get pctEnRiesgo {
    if (totalUnidades == 0) return 0;
    return (uVencidas + uCriticas + uProximas) / totalUnidades * 100;
  }
}

class DatabaseHelper {
  DatabaseHelper._();
  static final DatabaseHelper instance = DatabaseHelper._();

  static const _dbName = 'stockear.db';
  static const _dbVersion = 1; // subí esto cuando cambies el esquema

  Database? _db;

  Future<Database> get database async => _db ??= await _open();

  Future<Database> _open() async {
    final path = p.join(await getDatabasesPath(), _dbName);
    return openDatabase(
      path,
      version: _dbVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    // Catálogo maestro: lo poblás importando tu Excel. Resuelve nombre y
    // categoría a partir del barcode. NO hay foreign key hacia `lotes` a
    // propósito: queremos poder escanear productos que todavía no están en
    // el catálogo (se guardan como "Nuevo").
    await db.execute('''
      CREATE TABLE productos (
        barcode TEXT PRIMARY KEY,
        codigo_interno TEXT,
        nombre TEXT NOT NULL,
        categoria TEXT
      )
    ''');

    // Lotes: el corazón de la vertical de vencimientos.
    await db.execute('''
      CREATE TABLE lotes (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        barcode TEXT NOT NULL,
        nombre TEXT NOT NULL,
        categoria TEXT,
        fecha_ingreso TEXT NOT NULL,
        fecha_vencimiento TEXT NOT NULL,
        cantidad INTEGER NOT NULL DEFAULT 1
      )
    ''');

    // Índice para el dashboard (ordena/filtra siempre por vencimiento).
    await db.execute(
      'CREATE INDEX idx_lotes_venc ON lotes(fecha_vencimiento)',
    );

    // Índice ÚNICO que habilita el "merge": un mismo barcode con el mismo
    // vencimiento es UN solo lote. Sin esto, 50 unidades del mismo producto
    // generan 50 filas. Con esto, suman cantidad en una sola.
    await db.execute(
      'CREATE UNIQUE INDEX ux_lotes_barcode_venc '
      'ON lotes(barcode, fecha_vencimiento)',
    );
  }

  /// Patrón de migración para cuando el esquema evolucione SIN perder datos.
  /// Subí `_dbVersion` y agregá un bloque por cada salto de versión.
  Future<void> _onUpgrade(Database db, int oldV, int newV) async {
    // if (oldV < 2) {
    //   await db.execute('ALTER TABLE lotes ADD COLUMN proveedor TEXT');
    // }
  }

  // ====================== CATÁLOGO (productos) ======================

  Future<ProductoMatch> buscarProducto(String barcode) async {
    final db = await database;
    final rows = await db.query(
      'productos',
      where: 'barcode = ?',
      whereArgs: [barcode],
      limit: 1,
    );
    if (rows.isEmpty) return ProductoMatch(barcode: barcode);
    final r = rows.first;
    return ProductoMatch(
      barcode: barcode,
      nombre: r['nombre'] as String?,
      categoria: r['categoria'] as String?,
    );
  }

  /// Importa el catálogo en una transacción (todo o nada).
  /// `reemplazar = true` borra el catálogo previo; `false` hace upsert.
  /// El PARSEO del Excel vive en otra capa (CatalogImportService); acá solo
  /// recibimos filas ya normalizadas: {barcode, codigo_interno, nombre, categoria}.
  ///
  /// Optimizado para catálogos grandes (10k+ filas): una sola transacción,
  /// inserción por chunks con multi-row INSERT (mucho más rápido que insertar
  /// fila por fila). Aun así conviene llamarlo desde un punto donde la UI
  /// muestre un loader, porque escribir miles de filas igual lleva un momento.
  Future<int> importarCatalogo(
    List<Map<String, dynamic>> productos, {
    bool reemplazar = true,
    int chunkSize = 500,
  }) async {
    if (productos.isEmpty) return 0;
    final db = await database;
    return db.transaction<int>((txn) async {
      if (reemplazar) await txn.delete('productos');

      int total = 0;
      for (var i = 0; i < productos.length; i += chunkSize) {
        final fin = (i + chunkSize < productos.length)
            ? i + chunkSize
            : productos.length;
        final chunk = productos.sublist(i, fin);

        // Construye: INSERT OR REPLACE INTO productos (...) VALUES (?,?,?,?),(?,?,?,?)...
        final placeholders = List.filled(chunk.length, '(?,?,?,?)').join(',');
        final args = <Object?>[];
        for (final p in chunk) {
          args.add(p['barcode']);
          args.add(p['codigo_interno']);
          args.add(p['nombre']);
          args.add(p['categoria']);
        }

        await txn.rawInsert(
          'INSERT OR REPLACE INTO productos '
          '(barcode, codigo_interno, nombre, categoria) VALUES $placeholders',
          args,
        );
        total += chunk.length;
      }
      return total;
    });
  }

  Future<int> contarProductos() async {
    final db = await database;
    final r = await db.rawQuery('SELECT COUNT(*) AS c FROM productos');
    return Sqflite.firstIntValue(r) ?? 0;
  }

  // ====================== LOTES (vencimientos) ======================

  /// Inserta un lote nuevo SIN merge (cada llamada = fila nueva).
  /// Úsalo para restaurar tras un "Deshacer".
  Future<int> insertLote(Lote lote) async {
    final db = await database;
    return db.insert('lotes', lote.toMap());
  }

  /// Registra un escaneo CON merge: si ya existe ese barcode+vencimiento,
  /// suma la cantidad en vez de crear otra fila. Es el método que debería
  /// usar el scanner en modo batch.
  Future<void> registrarOIncrementar(Lote lote) async {
    final db = await database;
    await db.rawInsert('''
      INSERT INTO lotes
        (barcode, nombre, categoria, fecha_ingreso, fecha_vencimiento, cantidad)
      VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT(barcode, fecha_vencimiento)
      DO UPDATE SET cantidad = cantidad + excluded.cantidad
    ''', [
      lote.barcode,
      lote.nombre,
      lote.categoria,
      lote.fechaIngreso.toIso8601String(),
      Lote.formatFecha(lote.fechaVencimiento),
      lote.cantidad,
    ]);
  }

  /// Resta cantidad de un lote (deshacer un escaneo). Si llega a 0, lo borra.
  Future<void> decrementar(
    String barcode,
    DateTime fechaVencimiento, {
    int cantidad = 1,
  }) async {
    final db = await database;
    final f = Lote.formatFecha(fechaVencimiento);
    await db.rawUpdate(
      'UPDATE lotes SET cantidad = cantidad - ? '
      'WHERE barcode = ? AND fecha_vencimiento = ?',
      [cantidad, barcode, f],
    );
    await db.delete(
      'lotes',
      where: 'barcode = ? AND fecha_vencimiento = ? AND cantidad <= 0',
      whereArgs: [barcode, f],
    );
  }

  /// Todos los lotes, lo más urgente primero (vencimiento ASC).
  Future<List<Lote>> getLotes({String? categoria}) async {
    final db = await database;
    final rows = await db.query(
      'lotes',
      where: categoria != null ? 'categoria = ?' : null,
      whereArgs: categoria != null ? [categoria] : null,
      orderBy: 'fecha_vencimiento ASC',
    );
    return rows.map(Lote.fromMap).toList();
  }

  /// Conteo agregado por estado, hecho en SQL. Eficiente para inventarios
  /// grandes (no trae todas las filas a memoria). Ver nota en ResumenEstados.
  Future<ResumenEstados> getResumenEstados({
    int criticoDias = 7,
    int proximoDias = 30,
  }) async {
    final db = await database;
    // Los días son ints de nuestra config => interpolarlos es seguro.
    final hoy = "date('now','localtime')";
    final critico = "date('now','localtime','+$criticoDias days')";
    final proximo = "date('now','localtime','+$proximoDias days')";

    final rows = await db.rawQuery('''
      SELECT
        SUM(CASE WHEN fecha_vencimiento <  $hoy THEN 1 ELSE 0 END) AS lv,
        SUM(CASE WHEN fecha_vencimiento >= $hoy AND fecha_vencimiento <= $critico THEN 1 ELSE 0 END) AS lc,
        SUM(CASE WHEN fecha_vencimiento >  $critico AND fecha_vencimiento <= $proximo THEN 1 ELSE 0 END) AS lp,
        SUM(CASE WHEN fecha_vencimiento >  $proximo THEN 1 ELSE 0 END) AS lo,
        SUM(CASE WHEN fecha_vencimiento <  $hoy THEN cantidad ELSE 0 END) AS uv,
        SUM(CASE WHEN fecha_vencimiento >= $hoy AND fecha_vencimiento <= $critico THEN cantidad ELSE 0 END) AS uc,
        SUM(CASE WHEN fecha_vencimiento >  $critico AND fecha_vencimiento <= $proximo THEN cantidad ELSE 0 END) AS up,
        SUM(CASE WHEN fecha_vencimiento >  $proximo THEN cantidad ELSE 0 END) AS uo
      FROM lotes
    ''');

    final r = rows.first;
    int n(String k) => (r[k] as int?) ?? 0;
    return ResumenEstados(
      lotesVencidos: n('lv'),
      lotesCriticos: n('lc'),
      lotesProximos: n('lp'),
      lotesOk: n('lo'),
      uVencidas: n('uv'),
      uCriticas: n('uc'),
      uProximas: n('up'),
      uOk: n('uo'),
    );
  }

  Future<int> updateFechaVencimiento(int id, DateTime nueva) async {
    final db = await database;
    return db.update(
      'lotes',
      {'fecha_vencimiento': Lote.formatFecha(nueva)},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<int> updateCantidad(int id, int cantidad) async {
    final db = await database;
    return db.update(
      'lotes',
      {'cantidad': cantidad},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<int> deleteLote(int id) async {
    final db = await database;
    return db.delete('lotes', where: 'id = ?', whereArgs: [id]);
  }

  Future<int> contarLotes() async {
    final db = await database;
    final r = await db.rawQuery('SELECT COUNT(*) AS c FROM lotes');
    return Sqflite.firstIntValue(r) ?? 0;
  }

  /// Categorías presentes (para los chips de filtro del dashboard).
  Future<List<String>> getCategorias() async {
    final db = await database;
    final rows = await db.rawQuery(
      'SELECT DISTINCT categoria FROM lotes '
      'WHERE categoria IS NOT NULL ORDER BY categoria',
    );
    return rows.map((r) => r['categoria'] as String).toList();
  }

  /// Cierra la conexión (útil en tests o al cerrar sesión).
  Future<void> cerrar() async {
    await _db?.close();
    _db = null;
  }
}
