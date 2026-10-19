import 'package:flutter/material.dart';

/// Estado del semáforo. SIEMPRE se calcula en runtime a partir de la fecha
/// de vencimiento y los umbrales. NUNCA se guarda en la base.
enum EstadoAlerta { vencido, critico, proximo, ok }

/// Umbrales (en días) que definen los cortes del semáforo.
/// Se pueden ajustar por categoría: un yogur a 5 días es rojo,
/// una lata a 5 días sigue siendo verde.
class Umbrales {
  final int criticoDias; // <= esto => rojo
  final int proximoDias; // <= esto => amarillo

  const Umbrales({this.criticoDias = 7, this.proximoDias = 30});

  /// Config por defecto + overrides por categoría.
  /// En v0 vive en código; cuando crezca, movelo a una tabla `config`.
  static const Umbrales _default = Umbrales(criticoDias: 7, proximoDias: 30);

  static const Map<String, Umbrales> _porCategoria = {
    'Lácteos': Umbrales(criticoDias: 3, proximoDias: 10),
    'Frescos': Umbrales(criticoDias: 2, proximoDias: 7),
    'Carnicería': Umbrales(criticoDias: 2, proximoDias: 5),
    'Panadería': Umbrales(criticoDias: 1, proximoDias: 4),
    'Almacén': Umbrales(criticoDias: 15, proximoDias: 60),
    'Limpieza': Umbrales(criticoDias: 30, proximoDias: 120),
  };

  static Umbrales para(String? categoria) =>
      _porCategoria[categoria] ?? _default;
}

/// Calcula el estado del semáforo. Función pura: misma entrada, misma salida.
EstadoAlerta calcularEstado(DateTime fechaVencimiento, {String? categoria}) {
  final u = Umbrales.para(categoria);
  // Comparamos por día (ignorando la hora) para que "hoy" sea consistente.
  final hoy = DateTime.now();
  final hoySoloFecha = DateTime(hoy.year, hoy.month, hoy.day);
  final dias = fechaVencimiento.difference(hoySoloFecha).inDays;

  if (dias < 0) return EstadoAlerta.vencido;
  if (dias <= u.criticoDias) return EstadoAlerta.critico;
  if (dias <= u.proximoDias) return EstadoAlerta.proximo;
  return EstadoAlerta.ok;
}

/// Entidad central de la app. Un mismo barcode puede tener N lotes
/// (distintas partidas con distintos vencimientos).
class Lote {
  final int? id;
  final String barcode;
  final String nombre;
  final String? categoria;
  final DateTime fechaIngreso;
  final DateTime fechaVencimiento;
  final int cantidad;

  const Lote({
    this.id,
    required this.barcode,
    required this.nombre,
    this.categoria,
    required this.fechaIngreso,
    required this.fechaVencimiento,
    this.cantidad = 1,
  });

  // --- Propiedades CALCULADAS (no se persisten) ---

  EstadoAlerta get estado =>
      calcularEstado(fechaVencimiento, categoria: categoria);

  int get diasRestantes {
    final hoy = DateTime.now();
    final hoySoloFecha = DateTime(hoy.year, hoy.month, hoy.day);
    return fechaVencimiento.difference(hoySoloFecha).inDays;
  }

  // --- Serialización SQLite ---
  // Guardamos la fecha de vencimiento como 'YYYY-MM-DD' para que las
  // comparaciones de fecha en SQL sean limpias y rápidas.

  Map<String, dynamic> toMap() => {
    if (id != null) 'id': id,
    'barcode': barcode,
    'nombre': nombre,
    'categoria': categoria,
    'fecha_ingreso': fechaIngreso.toIso8601String(),
    'fecha_vencimiento': formatFecha(fechaVencimiento),
    'cantidad': cantidad,
  };

  factory Lote.fromMap(Map<String, dynamic> m) => Lote(
    id: m['id'] as int?,
    barcode: m['barcode'] as String,
    nombre: m['nombre'] as String,
    categoria: m['categoria'] as String?,
    fechaIngreso: DateTime.parse(m['fecha_ingreso'] as String),
    fechaVencimiento: DateTime.parse(m['fecha_vencimiento'] as String),
    cantidad: (m['cantidad'] as int?) ?? 1,
  );

  Lote copyWith({
    int? id,
    String? nombre,
    String? categoria,
    DateTime? fechaVencimiento,
    int? cantidad,
  }) => Lote(
    id: id ?? this.id,
    barcode: barcode,
    nombre: nombre ?? this.nombre,
    categoria: categoria ?? this.categoria,
    fechaIngreso: fechaIngreso,
    fechaVencimiento: fechaVencimiento ?? this.fechaVencimiento,
    cantidad: cantidad ?? this.cantidad,
  );

  static String formatFecha(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}

/// Mapeo de estado -> presentación (color, etiqueta, ícono).
/// Vive acá para tener una sola fuente de verdad del semáforo.
extension EstadoAlertaUI on EstadoAlerta {
  Color get color => switch (this) {
    EstadoAlerta.vencido => const Color(0xFF7B1113),
    EstadoAlerta.critico => const Color(0xFFE53935),
    EstadoAlerta.proximo => const Color(0xFFF9A825),
    EstadoAlerta.ok => const Color(0xFF2E7D32),
  };

  String get label => switch (this) {
    EstadoAlerta.vencido => 'Vencido',
    EstadoAlerta.critico => 'Crítico',
    EstadoAlerta.proximo => 'Próximo',
    EstadoAlerta.ok => 'OK',
  };

  IconData get icon => switch (this) {
    EstadoAlerta.vencido => Icons.dangerous_outlined,
    EstadoAlerta.critico => Icons.error_outline,
    EstadoAlerta.proximo => Icons.warning_amber_rounded,
    EstadoAlerta.ok => Icons.check_circle_outline,
  };
}
