import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../models/lote.dart';
import '../repositories/lote_repository.dart';
import '../services/scanner_service.dart';

const _morado = Color(0xFF8A2387);
const _naranja = Color(0xFFF27121);

/// Altura del visor de cámara. Subila/bajala para dar más o menos lugar
/// a la zona de abajo donde se ve el producto escaneado.
const double _alturaCamara = 260;

/// Escaneo continuo orientado a velocidad:
///  - Se fija UNA fecha de vencimiento activa para la partida.
///  - Cada lectura crea un lote con esa fecha automáticamente.
///  - Feedback corto (vibración) y contador en vivo, sin diálogos que frenen.
class ScannerScreen extends StatefulWidget {
  const ScannerScreen({super.key});

  @override
  State<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends State<ScannerScreen> {
  final _repo = LoteRepository.instance;
  final _source = CameraBarcodeSource();
  StreamSubscription<String>? _sub;

  DateTime? _fechaActiva;
  int _cantidadPorScan = 1;
  int _contadorSesion = 0;
  final List<Lote> _recientes = [];
  bool _procesando = false;

  @override
  void initState() {
    super.initState();
    _sub = _source.scans.listen(_onScan);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _source.dispose();
    super.dispose();
  }

  Future<void> _onScan(String barcode) async {
    if (_procesando) return;
    if (_fechaActiva == null) {
      _toast('Fijá primero la fecha de vencimiento', error: true);
      HapticFeedback.heavyImpact();
      return;
    }
    _procesando = true;
    try {
      final draft = await _repo.resolver(barcode);
      final lote = await _repo.registrar(
        barcode: barcode,
        nombre: draft.nombreCatalogo ?? 'Nuevo ($barcode)',
        categoria: draft.categoria,
        fechaVencimiento: _fechaActiva!,
        cantidad: _cantidadPorScan,
      );
      HapticFeedback.mediumImpact();
      if (mounted) {
        setState(() {
          _contadorSesion += _cantidadPorScan;
          _recientes.insert(0, lote);
          if (_recientes.length > 6) _recientes.removeLast();
        });
      }
    } finally {
      _procesando = false;
    }
  }

  Future<void> _elegirFecha() async {
    final hoy = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _fechaActiva ?? hoy,
      firstDate: hoy.subtract(const Duration(days: 30)),
      lastDate: hoy.add(const Duration(days: 365 * 5)),
      helpText: 'Vencimiento de esta partida',
    );
    if (picked != null) setState(() => _fechaActiva = picked);
  }

  void _atajo(int meses) {
    final base = DateTime.now();
    setState(
        () => _fechaActiva = DateTime(base.year, base.month + meses, base.day));
  }

  void _finDeMes() {
    final n = DateTime.now();
    setState(() => _fechaActiva = DateTime(n.year, n.month + 1, 0));
  }

  Future<void> _deshacerUltimo() async {
    if (_recientes.isEmpty) return;
    final ultimo = _recientes.first;
    // En modo merge no borramos por id: restamos la cantidad de este escaneo
    // del lote (barcode + vencimiento). Si llega a 0, el repo lo elimina solo.
    await _repo.decrementar(
      ultimo.barcode,
      ultimo.fechaVencimiento,
      cantidad: ultimo.cantidad,
    );
    setState(() {
      _contadorSesion -= ultimo.cantidad;
      _recientes.removeAt(0);
    });
  }

  void _toast(String msg, {bool error = false}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: error ? Colors.red.shade700 : _morado,
      duration: const Duration(seconds: 2),
      behavior: SnackBarBehavior.floating,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final tieneFecha = _fechaActiva != null;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Escaneo continuo'),
        backgroundColor: _morado,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.flash_on),
            onPressed: () => _source.controller.toggleTorch(),
            tooltip: 'Linterna',
          ),
        ],
      ),
      body: Column(
        children: [
          // --- Cámara (visor de altura fija; cambiá _alturaCamara a gusto) ---
          SizedBox(
            height: _alturaCamara,
            child: Stack(
              fit: StackFit.expand,
              children: [
                MobileScanner(
                  controller: _source.controller,
                  fit: BoxFit.cover,
                ),
                // Marco guía
                Center(
                  child: Container(
                    width: 240,
                    height: 140,
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: tieneFecha ? _naranja : Colors.red,
                        width: 3,
                      ),
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
                // Contador de sesión
                Positioned(
                  top: 12,
                  right: 12,
                  child: _chip('Sesión: $_contadorSesion', _morado),
                ),
              ],
            ),
          ),

          // --- Controles (toman todo el espacio restante) ---
          Expanded(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              color: Colors.white,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Fecha activa
                  GestureDetector(
                    onTap: _elegirFecha,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 14),
                      decoration: BoxDecoration(
                        color: tieneFecha
                            ? _naranja.withValues(alpha: 0.12)
                            : Colors.red.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: tieneFecha ? _naranja : Colors.red,
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.event,
                              color: tieneFecha ? _naranja : Colors.red),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              tieneFecha
                                  ? 'Vence: ${Lote.formatFecha(_fechaActiva!)}'
                                  : 'Tocá para fijar la fecha de vencimiento',
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                color: tieneFecha
                                    ? Colors.black87
                                    : Colors.red.shade700,
                              ),
                            ),
                          ),
                          const Icon(Icons.edit, size: 18),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  // Atajos
                  Wrap(
                    spacing: 8,
                    children: [
                      _atajoChip('+1 mes', () => _atajo(1)),
                      _atajoChip('+3 meses', () => _atajo(3)),
                      _atajoChip('+6 meses', () => _atajo(6)),
                      _atajoChip('Fin de mes', _finDeMes),
                    ],
                  ),
                  const SizedBox(height: 12),
                  // Cantidad por scan + deshacer
                  Row(
                    children: [
                      const Text('Cant. por lectura:'),
                      const SizedBox(width: 8),
                      _stepper(),
                      const Spacer(),
                      TextButton.icon(
                        onPressed: _recientes.isEmpty ? null : _deshacerUltimo,
                        icon: const Icon(Icons.undo),
                        label: const Text('Deshacer'),
                      ),
                    ],
                  ),
                  const Divider(),
                  // Últimos escaneados
                  Expanded(
                    child: _recientes.isEmpty
                        ? const Center(
                            child: Text('Apuntá un código para empezar',
                                style: TextStyle(color: Colors.grey)))
                        : ListView(
                            children: _recientes
                                .map((l) => ListTile(
                                      dense: true,
                                      leading: Icon(l.estado.icon,
                                          color: l.estado.color, size: 20),
                                      title: Text(l.nombre,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis),
                                      trailing: Text('x${l.cantidad}'),
                                    ))
                                .toList(),
                          ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
            color: color, borderRadius: BorderRadius.circular(20)),
        child: Text(text,
            style: const TextStyle(
                color: Colors.white, fontWeight: FontWeight.bold)),
      );

  Widget _atajoChip(String label, VoidCallback onTap) =>
      ActionChip(label: Text(label), onPressed: onTap);

  Widget _stepper() => Row(
        children: [
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.remove_circle_outline),
            onPressed: _cantidadPorScan > 1
                ? () => setState(() => _cantidadPorScan--)
                : null,
          ),
          Text('$_cantidadPorScan',
              style: const TextStyle(fontWeight: FontWeight.bold)),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.add_circle_outline),
            onPressed: () => setState(() => _cantidadPorScan++),
          ),
        ],
      );
}
