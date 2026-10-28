import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';

import 'dae_parser.dart';
import 'dff_writer.dart';
import 'json_scanner.dart';

const kBg = Color(0xFF0D0F14);
const kCard = Color(0xFF161922);
const kNeon = Color(0xFF00E5FF);
const kEmerald = Color(0xFF00FF9D);
const kWarn = Color(0xFFFFD600);

void main() => runApp(const Beam2SAApp());

class Beam2SAApp extends StatelessWidget {
  const Beam2SAApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Beam2SA',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        scaffoldBackgroundColor: kBg,
        colorScheme: const ColorScheme.dark(primary: kNeon, secondary: kEmerald, surface: kCard),
      ),
      home: const HomePage(),
    );
  }
}

class _Row {
  final String mesh;
  final String material;
  final List<String> candidates;
  final bool fromJson;
  final TextEditingController ctrl;
  _Row(this.mesh, this.material, this.candidates, this.fromJson, String tex)
      : ctrl = TextEditingController(text: tex);
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String? daePath;
  String? resDir;
  DaeScene? scene;
  List<_Row> rows = [];
  final List<String> logs = [];
  final ScrollController logScroll = ScrollController();
  bool busy = false;

  @override
  void dispose() {
    for (final r in rows) {
      r.ctrl.dispose();
    }
    logScroll.dispose();
    super.dispose();
  }

  void _log(String s) {
    final t = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    if (!mounted) return;
    setState(() => logs.add('[${two(t.hour)}:${two(t.minute)}:${two(t.second)}] $s'));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (logScroll.hasClients) logScroll.jumpTo(logScroll.position.maxScrollExtent);
    });
  }

  Color _logColor(String s) {
    if (s.contains('✔')) return kEmerald;
    if (s.contains('⚠')) return kWarn;
    if (s.contains('✖')) return Colors.redAccent;
    return const Color(0xFF9FB3C8);
  }

  Future<void> _ensureStorage() async {
    if (!Platform.isAndroid) return;
    var s = await Permission.manageExternalStorage.status;
    if (!s.isGranted) s = await Permission.manageExternalStorage.request();
    if (!s.isGranted) {
      final st = await Permission.storage.request();
      if (!st.isGranted) _log('⚠ Нет доступа к хранилищу — чтение папки ресурсов может не работать');
    }
  }

  Future<void> _pickDae() async {
    await _ensureStorage();
    final r = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['dae']);
    final path = r?.files.single.path;
    if (path == null) return;
    setState(() => daePath = path);
    _log('Выбран DAE: $path');
    if (resDir != null) _analyze();
  }

  Future<void> _pickDir() async {
    await _ensureStorage();
    final d = await FilePicker.platform.getDirectoryPath(dialogTitle: 'Папка мода / ресурсов');
    if (d == null) return;
    setState(() => resDir = d);
    _log('Папка ресурсов: $d');
    if (daePath != null) _analyze();
  }

  Future<void> _analyze() async {
    if (daePath == null || busy) return;
    setState(() => busy = true);
    try {
      _log('[1/2] Парсинг XML: ${p.basename(daePath!)}');
      final text = utf8.decode(await File(daePath!).readAsBytes(), allowMalformed: true);
      final res = await compute(parseDaeString, text);
      res.log.forEach(_log);
      scene = res.scene;

      final resolver = MaterialResolver();
      if (resDir != null) {
        _log('[2/2] Сканирование JSON…');
        await resolver.scan(resDir!, _log);
      } else {
        _log('⚠ Папка ресурсов не выбрана — имена текстур вводятся вручную');
      }

      for (final r in rows) {
        r.ctrl.dispose();
      }
      final newRows = <_Row>[];
      final cache = <String, String?>{};
      for (final m in scene!.meshes) {
        final seen = <String>{};
        for (final g in m.groups) {
          if (!seen.add(g.materialName)) continue;
          final tex = cache.putIfAbsent(g.materialName, () => resolver.resolve(g.candidates));
          newRows.add(_Row(m.name, g.materialName, g.candidates, tex != null, tex ?? ''));
        }
      }
      setState(() => rows = newRows);
      final miss = newRows.where((r) => !r.fromJson).length;
      _log(miss == 0
          ? '✔ Анализ завершён: все материалы сопоставлены (${newRows.length})'
          : '⚠ Анализ завершён: текстура не найдена для $miss из ${newRows.length} — впишите вручную');
    } catch (e) {
      _log('✖ Ошибка анализа: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void _onEdit(_Row row, String v) {
    for (final r in rows) {
      if (r != row && r.material == row.material && r.ctrl.text != v) {
        r.ctrl.text = v;
      }
    }
    setState(() {});
  }

  Future<void> _build() async {
    final sc = scene;
    if (sc == null || busy) return;
    setState(() => busy = true);
    try {
      final tex = <String, String>{};
      for (final r in rows) {
        final t = r.ctrl.text.trim();
        if (t.isNotEmpty) tex[r.material] = t;
      }
      _log('[3/4] Триангуляция выполнена в парсере; сборка бинарных чанков…');
      final res = await compute(buildDffTask, DffRequest(sc, tex));
      res.log.forEach(_log);

      _log('[4/4] Сохранение .dff…');
      final name = '${p.basenameWithoutExtension(daePath ?? 'model')}.dff';
      String? out;
      if (Platform.isAndroid || Platform.isIOS) {
        out = await FilePicker.platform.saveFile(dialogTitle: 'Сохранить DFF', fileName: name, bytes: res.bytes);
      } else {
        out = await FilePicker.platform.saveFile(
          dialogTitle: 'Сохранить DFF',
          fileName: name,
          type: FileType.custom,
          allowedExtensions: ['dff'],
        );
        if (out != null) {
          if (!out.toLowerCase().endsWith('.dff')) out = '$out.dff';
          await File(out).writeAsBytes(res.bytes);
        }
      }
      if (out == null) {
        _log('⚠ Сохранение отменено (или путь не возвращён системой)');
      } else {
        _log('✔ Сборка успешна: $out (${res.bytes.length} байт)');
      }
    } catch (e) {
      _log('✖ Ошибка сборки: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  // ---------------- UI ----------------
  Widget _card({required Widget child, EdgeInsets pad = const EdgeInsets.all(12)}) => Container(
        width: double.infinity,
        padding: pad,
        decoration: BoxDecoration(
          color: kCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: kNeon.withOpacity(0.15)),
        ),
        child: child,
      );

  Widget _pickTile(IconData icon, String title, String? value, VoidCallback onTap) {
    return InkWell(
      onTap: busy ? null : onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          border: Border.all(color: value == null ? Colors.white24 : kNeon.withOpacity(0.6)),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(children: [
          Icon(icon, color: kNeon),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
              Text(value ?? 'не выбрано',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: value == null ? Colors.white38 : Colors.white70)),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _rowView(_Row r) {
    final empty = r.ctrl.text.trim().isEmpty;
    final Color c = r.fromJson ? kEmerald : (empty ? kWarn : kNeon);
    final tag = r.fromJson ? 'JSON' : (empty ? 'НЕТ' : 'ВРУЧНУЮ');
    final field = TextField(
      controller: r.ctrl,
      onChanged: (v) => _onEdit(r, v),
      style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
      decoration: InputDecoration(
        isDense: true,
        hintText: 'имя текстуры',
        prefixText: '[$tag] ',
        prefixStyle: TextStyle(color: c, fontSize: 11, fontWeight: FontWeight.bold),
        enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: c.withOpacity(0.7))),
        focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: c, width: 1.6)),
        filled: empty,
        fillColor: empty ? kWarn.withOpacity(0.08) : null,
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: LayoutBuilder(builder: (ctx, cs) {
        final meshMat = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(r.mesh, style: const TextStyle(fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis),
          Text(r.material,
              style: const TextStyle(fontSize: 12, color: Colors.white60), overflow: TextOverflow.ellipsis),
        ]);
        if (cs.maxWidth > 620) {
          return Row(children: [
            Expanded(flex: 5, child: meshMat),
            const SizedBox(width: 10),
            Expanded(flex: 5, child: field),
          ]);
        }
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          meshMat,
          const SizedBox(height: 4),
          field,
        ]);
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final canBuild = scene != null && !busy;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(children: [
            Row(children: [
              const Icon(Icons.directions_car_filled, color: kNeon),
              const SizedBox(width: 8),
              const Text('BEAM2SA',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, letterSpacing: 3, color: kNeon)),
              const SizedBox(width: 8),
              const Text('DAE → DFF', style: TextStyle(color: Colors.white54)),
              const Spacer(),
              if (busy)
                const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: kNeon)),
            ]),
            const SizedBox(height: 10),
            _card(
              child: Column(children: [
                _pickTile(Icons.view_in_ar, 'Модель .dae', daePath == null ? null : p.basename(daePath!), _pickDae),
                const SizedBox(height: 8),
                _pickTile(Icons.folder_open, 'Папка мода / ресурсов (JSON + текстуры)', resDir, _pickDir),
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: (daePath != null && !busy) ? _analyze : null,
                      icon: const Icon(Icons.search),
                      label: const Text('Анализ'),
                      style: OutlinedButton.styleFrom(foregroundColor: kNeon, side: const BorderSide(color: kNeon)),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: canBuild ? _build : null,
                      icon: const Icon(Icons.build),
                      label: const Text('Собрать .dff'),
                      style: FilledButton.styleFrom(backgroundColor: kEmerald, foregroundColor: Colors.black),
                    ),
                  ),
                ]),
              ]),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: _card(
                child: rows.isEmpty
                    ? const Center(
                        child: Text('Выберите .dae и папку ресурсов —\nздесь появится таблица мешей и материалов',
                            textAlign: TextAlign.center, style: TextStyle(color: Colors.white38)))
                    : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('Меши и материалы (${rows.length})',
                            style: const TextStyle(color: kNeon, fontWeight: FontWeight.bold)),
                        const Divider(height: 14),
                        Expanded(
                          child: ListView.builder(
                            itemCount: rows.length,
                            itemBuilder: (_, i) => _rowView(rows[i]),
                          ),
                        ),
                      ]),
              ),
            ),
            const SizedBox(height: 10),
            Container(
              height: 170,
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: kEmerald.withOpacity(0.35)),
              ),
              child: ListView.builder(
                controller: logScroll,
                itemCount: logs.length,
                itemBuilder: (_, i) => Text(
                  logs[i],
                  style: TextStyle(fontFamily: 'monospace', fontSize: 11.5, color: _logColor(logs[i])),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
