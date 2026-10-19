import 'package:flutter/material.dart';
import '../models/lote.dart';
import '../repositories/lote_repository.dart';
import '../services/notification_service.dart';
import 'scanner_screen.dart';
import '../services/catalog_import_service.dart';

const _morado = Color(0xFF8A2387);
const _naranja = Color(0xFFF27121);

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final _repo = LoteRepository.instance;

  List<Lote> _lotes = [];
  bool _cargando = true;
  EstadoAlerta? _filtroEstado; // null = todos
  String? _filtroCategoria;
  List<String> _categorias = [];

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    if (mounted) setState(() => _cargando = true);
    try {
      final lotes = await _repo.listar();
      final cats = await _repo.categorias();
      if (!mounted) return;
      setState(() {
        _lotes = lotes;
        _categorias = cats;
      });
      // Notificación FUERA del camino crítico: si falla (típico en release),
      // que NO trabe el dashboard.
      // ignore: unawaited_futures
      _programarDigestSeguro(lotes);
    } catch (e, st) {
      debugPrint('CARGAR ERROR: $e\n$st');
    } finally {
      // Pase lo que pase, salimos del loading.
      if (mounted) setState(() => _cargando = false);
    }
  }

  Future<void> _programarDigestSeguro(List<Lote> lotes) async {
    try {
      await NotificationService.instance.programarDigestDiario(lotes);
    } catch (e) {
      debugPrint('NOTIF ERROR (no crítico): $e');
    }
  }

  List<Lote> get _filtrados => _lotes.where((l) {
        if (_filtroEstado != null && l.estado != _filtroEstado) return false;
        if (_filtroCategoria != null && l.categoria != _filtroCategoria) {
          return false;
        }
        return true;
      }).toList();

  // --- KPIs ---
  int _unidades(bool Function(Lote) test) =>
      _lotes.where(test).fold(0, (s, l) => s + l.cantidad);

  double get _pctProximoAVencer {
    final total = _lotes.fold(0, (s, l) => s + l.cantidad);
    if (total == 0) return 0;
    final riesgo = _unidades(
      (l) =>
          l.estado == EstadoAlerta.critico ||
          l.estado == EstadoAlerta.proximo ||
          l.estado == EstadoAlerta.vencido,
    );
    return riesgo / total * 100;
  }

  Future<void> _editarFecha(Lote lote) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: lote.fechaVencimiento,
      firstDate: DateTime.now().subtract(const Duration(days: 365)),
      lastDate: DateTime.now().add(const Duration(days: 365 * 5)),
      helpText: 'Corregir vencimiento',
    );
    if (picked != null && lote.id != null) {
      await _repo.cambiarFecha(lote.id!, picked);
      _cargar();
    }
  }

  Future<void> _eliminar(Lote lote) async {
    if (lote.id == null) return;
    await _repo.eliminar(lote.id!);
    setState(() => _lotes.removeWhere((l) => l.id == lote.id));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Eliminado: ${lote.nombre}'),
        action: SnackBarAction(
          label: 'Deshacer',
          onPressed: () async {
            await _repo.restaurar(lote);
            _cargar();
          },
        ),
        duration: const Duration(seconds: 5),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey.shade50,
      appBar: AppBar(
        title: const Text('Vencimientos'),
        backgroundColor: _morado,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.notifications_active_outlined),
            tooltip: 'Ver alertas ahora',
            onPressed: () => NotificationService.instance.mostrarAhora(_lotes),
          ),
          IconButton(
            icon: const Icon(Icons.cloud_download_outlined),
            tooltip: 'Importar catálogo',
            onPressed: () async {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Tocaste importar ✓')),
              );
              try {
                final n = await CatalogImportService.instance
                    .importarDesdeAsset('assets/catalogo.csv');
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Catálogo importado: $n productos')),
                );
                _cargar();
              } catch (e, st) {
                debugPrint('IMPORT ERROR: $e\n$st');
                if (!context.mounted) return;
                showDialog(
                  context: context,
                  builder: (_) => AlertDialog(
                    title: const Text('Error al importar'),
                    content: SingleChildScrollView(child: Text('$e')),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('OK'),
                      ),
                    ],
                  ),
                );
              }
            },
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: _naranja,
        icon: const Icon(Icons.qr_code_scanner),
        label: const Text('Escanear'),
        onPressed: () async {
          await Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const ScannerScreen()),
          );
          _cargar();
        },
      ),
      body: _cargando
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _cargar,
              child: CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(child: _kpis()),
                  SliverToBoxAdapter(child: _filtros()),
                  if (_filtrados.isEmpty)
                    const SliverFillRemaining(
                      hasScrollBody: false,
                      child: Center(child: Text('Sin lotes para mostrar')),
                    )
                  else
                    SliverList.builder(
                      itemCount: _filtrados.length,
                      itemBuilder: (_, i) => _loteTile(_filtrados[i]),
                    ),
                  const SliverToBoxAdapter(child: SizedBox(height: 90)),
                ],
              ),
            ),
    );
  }

  Widget _kpis() {
    final vencidos =
        _lotes.where((l) => l.estado == EstadoAlerta.vencido).length;
    final criticos =
        _lotes.where((l) => l.estado == EstadoAlerta.critico).length;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [_morado, Color(0xFFE94057)],
              ),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Stock en riesgo',
                  style: TextStyle(color: Colors.white70, fontSize: 13),
                ),
                Text(
                  '${_pctProximoAVencer.toStringAsFixed(1)}%',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 36,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Text(
                  'de las unidades vence pronto',
                  style: TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _kpiMini('Vencidos', vencidos, EstadoAlerta.vencido.color),
              const SizedBox(width: 12),
              _kpiMini('Críticos', criticos, EstadoAlerta.critico.color),
              const SizedBox(width: 12),
              _kpiMini('Total lotes', _lotes.length, _morado),
            ],
          ),
        ],
      ),
    );
  }

  Widget _kpiMini(String label, int valor, Color color) => Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: color.withValues(alpha: 0.3)),
          ),
          child: Column(
            children: [
              Text(
                '$valor',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: color,
                ),
              ),
              Text(
                label,
                style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
              ),
            ],
          ),
        ),
      );

  Widget _filtros() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          _filtroChip(
            'Todos',
            _filtroEstado == null,
            () => setState(() => _filtroEstado = null),
          ),
          for (final e in EstadoAlerta.values)
            _filtroChip(
              e.label,
              _filtroEstado == e,
              () => setState(() => _filtroEstado = e),
              color: e.color,
            ),
          if (_categorias.isNotEmpty) ...[
            const SizedBox(width: 8),
            const VerticalDivider(),
            _filtroChip(
              'Toda cat.',
              _filtroCategoria == null,
              () => setState(() => _filtroCategoria = null),
            ),
            for (final c in _categorias)
              _filtroChip(
                c,
                _filtroCategoria == c,
                () => setState(() => _filtroCategoria = c),
              ),
          ],
        ],
      ),
    );
  }

  Widget _filtroChip(
    String label,
    bool sel,
    VoidCallback onTap, {
    Color? color,
  }) =>
      Padding(
        padding: const EdgeInsets.only(right: 8),
        child: FilterChip(
          label: Text(label),
          selected: sel,
          onSelected: (_) => onTap(),
          selectedColor: (color ?? _morado).withValues(alpha: 0.18),
          checkmarkColor: color ?? _morado,
        ),
      );

  Widget _loteTile(Lote lote) {
    return Dismissible(
      key: ValueKey(lote.id),
      direction: DismissDirection.endToStart,
      background: Container(
        color: Colors.red,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      onDismissed: (_) => _eliminar(lote),
      child: Card(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: ListTile(
          leading: CircleAvatar(
            backgroundColor: lote.estado.color.withValues(alpha: 0.15),
            child: Icon(lote.estado.icon, color: lote.estado.color),
          ),
          title: Text(
            lote.nombre,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            '${lote.estado.label} · ${_textoDias(lote)} · ${lote.categoria ?? "Sin cat."}',
            style: TextStyle(color: lote.estado.color, fontSize: 12),
          ),
          trailing: Text(
            'x${lote.cantidad}',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          // Tap = corregir fecha (el error más común del escaneo).
          onTap: () => _editarFecha(lote),
        ),
      ),
    );
  }

  String _textoDias(Lote l) {
    final d = l.diasRestantes;
    if (d < 0) return 'venció hace ${-d} d';
    if (d == 0) return 'vence hoy';
    return 'en $d d';
  }
}
