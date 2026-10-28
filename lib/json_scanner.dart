import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Сканер JSON-материалов BeamNG: ключ материала / name / mapTo -> имя текстуры.
class MaterialResolver {
  static const int maxTextureName = 31;
  static const List<String> _mapKeys = ['baseColorMap', 'colorMap', 'diffuseMap'];

  final Map<String, String> _byKey = {};
  int jsonFiles = 0;
  int jsonFailed = 0;
  int materialsFound = 0;

  int get registeredKeys => _byKey.length;

  Future<void> scan(String rootDir, void Function(String) log) async {
    final dir = Directory(rootDir);
    if (!await dir.exists()) {
      log('✖ Папка не найдена: $rootDir');
      return;
    }
    var counter = 0;
    try {
      await for (final ent in dir.list(recursive: true, followLinks: false).handleError((_) {})) {
        if (ent is! File) continue;
        if (!ent.path.toLowerCase().endsWith('.json')) continue;
        jsonFiles++;
        try {
          final raw = utf8.decode(await ent.readAsBytes(), allowMalformed: true);
          dynamic data;
          try {
            data = jsonDecode(raw);
          } catch (_) {
            data = jsonDecode(_relax(raw));
          }
          _visit(data);
        } catch (_) {
          jsonFailed++;
        }
        if (++counter % 25 == 0) await Future<void>.delayed(Duration.zero);
      }
    } catch (e) {
      log('⚠ Ошибка обхода папки: $e');
    }
    log('JSON: файлов $jsonFiles (с ошибкой разбора: $jsonFailed), '
        'материалов с текстурой: $materialsFound, ключей: ${_byKey.length}');
  }

  /// Убирает комментарии и висячие запятые.
  String _relax(String s) {
    var r = s.replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '');
    r = r.replaceAll(RegExp(r'(^|[^:"\\])//[^\n]*'), r'$1');
    r = r.replaceAll(RegExp(r',\s*([}\]])'), r'$1');
    return r;
  }

  void _visit(dynamic node) {
    if (node is Map) {
      node.forEach((key, value) {
        if (value is Map && (value.containsKey('Stages') || value.containsKey('mapTo'))) {
          _register(key.toString(), value);
        } else {
          _visit(value);
        }
      });
    } else if (node is List) {
      for (final e in node) {
        _visit(e);
      }
    }
  }

  String? _stageTexture(Map m) {
    for (final k in _mapKeys) {
      final v = m[k];
      if (v is String && v.trim().isNotEmpty) return v;
    }
    return null;
  }

  void _register(String key, Map mat) {
    String? tex;
    final stages = mat['Stages'];
    if (stages is List) {
      for (final st in stages) {
        if (st is Map) {
          tex = _stageTexture(st);
          if (tex != null) break;
        }
      }
    } else if (stages is Map) {
      for (final st in stages.values) {
        if (st is Map) {
          tex = _stageTexture(st);
          if (tex != null) break;
        }
      }
    }
    tex ??= _stageTexture(mat);
    if (tex == null) return;
    final name = textureName(tex);
    if (name.isEmpty) return;
    materialsFound++;
    for (final k in [key, mat['name'], mat['mapTo']]) {
      if (k is String && k.isNotEmpty) {
        _byKey.putIfAbsent(k.toLowerCase(), () => name);
      }
    }
  }

  /// "vehicles/common/tires_d.dds" -> "tires_d" (максимум 31 символ).
  static String textureName(String path) {
    final clean = path.replaceAll('\\', '/').trim();
    var base = p.posix.basenameWithoutExtension(clean);
    if (base.length > maxTextureName) base = base.substring(0, maxTextureName);
    return base;
  }

  /// Ищет текстуру по списку имён-кандидатов материала.
  String? resolve(List<String> candidates) {
    for (final c in candidates) {
      if (c.isEmpty) continue;
      final lc = c.toLowerCase();
      final hit = _byKey[lc] ?? _byKey[lc.replaceAll(RegExp(r'[-_]?material$'), '')];
      if (hit != null) return hit;
    }
    return null;
  }
}
