import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:timezone/data/latest_all.dart' as tzdata;
import '../models/lote.dart';

/// Estrategia de bajo costo:
///  - UNA sola notificación diaria recurrente (no una por producto).
///  - Su texto se recalcula y reprograma cada vez que se abre la app o se
///    cierra una sesión de escaneo, así muestra números reales y frescos.
///  - El trabajo pesado (contar lotes) es UNA query barata, no miles de timers.
///
/// Para un digest 100% confiable los días que el usuario NO abre la app,
/// el upgrade es agregar `workmanager` con una tarea diaria que corra
/// `construirDigest()` en background y llame a `_mostrar()`. La interfaz
/// queda igual.
class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final _plugin = FlutterLocalNotificationsPlugin();
  static const _channelId = 'vencimientos';
  static const _dailyId = 1001;

  Future<void> init() async {
    tzdata.initializeTimeZones();
    // Idealmente resolver la TZ del dispositivo con flutter_timezone;
    // como fallback usamos la del sistema.
    tz.setLocalLocation(tz.getLocation(tz.local.name));

    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const ios = DarwinInitializationSettings();
    await _plugin.initialize(
      const InitializationSettings(android: android, iOS: ios),
    );

    // Permisos (Android 13+ y iOS).
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
    await _plugin
        .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin>()
        ?.requestPermissions(alert: true, badge: true, sound: true);
  }

  NotificationDetails get _details => const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          'Vencimientos',
          channelDescription: 'Alertas de productos próximos a vencer',
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(),
      );

  /// Programa (o reprograma) el recordatorio diario con el digest actual.
  /// Llamala en main() al iniciar y al volver del scanner.
  Future<void> programarDigestDiario(
    List<Lote> lotes, {
    int hora = 9,
    int minuto = 0,
  }) async {
    final (titulo, cuerpo) = _construirDigest(lotes);

    await _plugin.zonedSchedule(
      _dailyId,
      titulo,
      cuerpo,
      _proximaHora(hora, minuto),
      _details,
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      // Requerido en flutter_local_notifications v17 (eliminado en v18+).
      // Solo afecta iOS < 10, así que el valor es indistinto en la práctica.
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
      matchDateTimeComponents: DateTimeComponents.time, // se repite a diario
    );
  }

  /// Notificación inmediata (útil para "ver alertas ahora" o testing).
  Future<void> mostrarAhora(List<Lote> lotes) async {
    final (titulo, cuerpo) = _construirDigest(lotes);
    await _plugin.show(_dailyId + 1, titulo, cuerpo, _details);
  }

  (String, String) _construirDigest(List<Lote> lotes) {
    final vencidos =
        lotes.where((l) => l.estado == EstadoAlerta.vencido).length;
    final criticos =
        lotes.where((l) => l.estado == EstadoAlerta.critico).length;
    final proximos =
        lotes.where((l) => l.estado == EstadoAlerta.proximo).length;

    if (vencidos == 0 && criticos == 0 && proximos == 0) {
      return ('StockeAr · Todo en orden', 'No hay vencimientos próximos. 👍');
    }
    final partes = <String>[];
    if (vencidos > 0) partes.add('$vencidos vencidos');
    if (criticos > 0) partes.add('$criticos críticos');
    if (proximos > 0) partes.add('$proximos próximos');
    return ('StockeAr · Revisá tus vencimientos', partes.join(' · '));
  }

  tz.TZDateTime _proximaHora(int hora, int minuto) {
    final now = tz.TZDateTime.now(tz.local);
    var fecha =
        tz.TZDateTime(tz.local, now.year, now.month, now.day, hora, minuto);
    if (fecha.isBefore(now)) fecha = fecha.add(const Duration(days: 1));
    return fecha;
  }
}
