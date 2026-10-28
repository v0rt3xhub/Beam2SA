import 'dart:math' as math;

import 'package:xml/xml.dart';

/// Группа треугольников одного материала внутри меша.
class DaeGroup {
  final String symbol;
  final String materialName; // отображаемое имя
  final List<String> candidates; // варианты для поиска в JSON
  final List<int> indices; // по 3 индекса на треугольник
  DaeGroup(this.symbol, this.materialName, this.candidates, this.indices);
}

class DaeMesh {
  final String name;
  final String geometryId;
  final int frameIndex;
  final List<double> positions; // x,y,z
  final List<double> normals; // x,y,z
  final List<double> uvs; // u,v (V уже инвертирован: 1 - v)
  final List<DaeGroup> groups;
  DaeMesh(this.name, this.geometryId, this.frameIndex, this.positions, this.normals, this.uvs, this.groups);

  int get vertexCount => positions.length ~/ 3;
  int get triangleCount => groups.fold(0, (s, g) => s + g.indices.length ~/ 3);
}

class DaeFrame {
  final String name;
  final int parent;
  final List<double> matrix; // 4x4 row-major, column-vector (Collada)
  DaeFrame(this.name, this.parent, this.matrix);
}

class DaeScene {
  final List<DaeFrame> frames;
  final List<DaeMesh> meshes;
  DaeScene(this.frames, this.meshes);
}

class DaeParseResult {
  final DaeScene scene;
  final List<String> log;
  DaeParseResult(this.scene, this.log);
}

/// Точка входа для compute().
DaeParseResult parseDaeString(String text) {
  final parser = DaeParser();
  final scene = parser.parse(text);
  return DaeParseResult(scene, parser.logs);
}

class _Src {
  final List<double> data;
  final int stride;
  _Src(this.data, this.stride);
}

class _RawGroup {
  final String symbol;
  final List<int> indices;
  _RawGroup(this.symbol, this.indices);
}

class _GeomData {
  final List<double> pos, nor, uv;
  final List<_RawGroup> groups;
  _GeomData(this.pos, this.nor, this.uv, this.groups);
}

class _MatInfo {
  final String display;
  final List<String> candidates;
  _MatInfo(this.display, this.candidates);
}

class DaeParser {
  final List<String> logs = [];
  void _log(String s) => logs.add(s);

  final Map<String, XmlElement> _geomEls = {};
  final Map<String, String> _ctrlSource = {};
  final Map<String, _MatInfo> _mats = {};
  final Map<String, _GeomData?> _geomCache = {};
  final List<DaeFrame> _frames = [];
  final List<DaeMesh> _meshes = [];
  bool _yUp = false;

  DaeScene parse(String text) {
    final doc = XmlDocument.parse(text);

    final up = doc.findAllElements('up_axis').map((e) => e.innerText.trim()).firstOrNull;
    _yUp = up == 'Y_UP';
    _log('up_axis: ${up ?? "Z_UP (по умолчанию)"}');

    for (final lm in doc.findAllElements('library_materials')) {
      for (final m in lm.findElements('material')) {
        final id = m.getAttribute('id') ?? '';
        final name = m.getAttribute('name') ?? '';
        final re = RegExp(r'[-_]?material$', caseSensitive: false);
        final cands = <String>{
          if (name.isNotEmpty) name,
          if (id.isNotEmpty) id,
          if (name.isNotEmpty) name.replaceAll(re, ''),
          if (id.isNotEmpty) id.replaceAll(re, ''),
        }.where((e) => e.isNotEmpty).toList();
        _mats[id] = _MatInfo(name.isNotEmpty ? name : id, cands);
      }
    }
    for (final g in doc.findAllElements('geometry')) {
      final id = g.getAttribute('id');
      if (id != null) _geomEls[id] = g;
    }
    for (final c in doc.findAllElements('controller')) {
      final id = c.getAttribute('id');
      final src = c.getElement('skin')?.getAttribute('source');
      if (id != null && src != null) _ctrlSource[id] = src.replaceFirst('#', '');
    }
    _log('Материалов в DAE: ${_mats.length}, геометрий: ${_geomEls.length}');

    final scenes = doc.findAllElements('visual_scene').toList();
    if (scenes.isNotEmpty) {
      for (final n in scenes.first.findElements('node')) {
        _walk(n, -1, true);
      }
    } else {
      _log('⚠ visual_scene не найден');
    }

    if (_meshes.isEmpty && _geomEls.isNotEmpty) {
      _log('⚠ В сцене нет instance_geometry — беру геометрии напрямую');
      for (final e in _geomEls.entries) {
        final idx = _frames.length;
        _frames.add(DaeFrame(e.value.getAttribute('name') ?? e.key, -1, _identity()));
        _addMesh(e.value.getAttribute('name') ?? e.key, idx, e.key, const {});
      }
    }
    _log('Фреймов: ${_frames.length}, мешей: ${_meshes.length}');
    return DaeScene(_frames, _meshes);
  }

  void _walk(XmlElement n, int parent, bool top) {
    final name = n.getAttribute('name') ?? n.getAttribute('id') ?? 'node${_frames.length}';
    var m = _identity();
    for (final c in n.childElements) {
      switch (c.name.local) {
        case 'matrix':
          final f = _floats(c.innerText);
          if (f.length >= 16) m = _mul(m, f.sublist(0, 16));
          break;
        case 'translate':
          final f = _floats(c.innerText);
          if (f.length >= 3) m = _mul(m, _translate(f[0], f[1], f[2]));
          break;
        case 'rotate':
          final f = _floats(c.innerText);
          if (f.length >= 4) m = _mul(m, _rotate(f[0], f[1], f[2], f[3]));
          break;
        case 'scale':
          final f = _floats(c.innerText);
          if (f.length >= 3) m = _mul(m, _scale(f[0], f[1], f[2]));
          break;
      }
    }
    if (top && _yUp) {
      // Y_UP -> Z_UP: x' = x, y' = -z, z' = y
      m = _mul(<double>[1, 0, 0, 0, 0, 0, -1, 0, 0, 1, 0, 0, 0, 0, 0, 1], m);
    }
    final idx = _frames.length;
    _frames.add(DaeFrame(name, parent, m));

    for (final ig in n.findElements('instance_geometry')) {
      final url = (ig.getAttribute('url') ?? '').replaceFirst('#', '');
      _addMesh(name, idx, url, _bindMap(ig));
    }
    for (final ic in n.findElements('instance_controller')) {
      final cid = (ic.getAttribute('url') ?? '').replaceFirst('#', '');
      final gid = _ctrlSource[cid];
      if (gid != null) {
        _log('⚠ "$name": скиннинг игнорируется, берётся исходная геометрия');
        _addMesh(name, idx, gid, _bindMap(ic));
      }
    }
    for (final inode in n.findElements('instance_node')) {
      _log('⚠ "$name": instance_node не поддерживается (${inode.getAttribute("url")})');
    }
    for (final c in n.findElements('node')) {
      _walk(c, idx, false);
    }
  }

  Map<String, String> _bindMap(XmlElement inst) {
    final r = <String, String>{};
    for (final im in inst.findAllElements('instance_material')) {
      final s = im.getAttribute('symbol');
      final t = im.getAttribute('target')?.replaceFirst('#', '');
      if (s != null && t != null) r[s] = t;
    }
    return r;
  }

  void _addMesh(String nodeName, int frameIdx, String gid, Map<String, String> bind) {
    final gel = _geomEls[gid];
    if (gel == null) {
      _log('⚠ Геометрия "$gid" не найдена');
      return;
    }
    if (!_geomCache.containsKey(gid)) {
      _geomCache[gid] = _parseGeometry(gel, gid);
    }
    final data = _geomCache[gid];
    if (data == null) return;
    final groups = <DaeGroup>[];
    for (final rg in data.groups) {
      final matId = bind[rg.symbol] ?? rg.symbol;
      final info = _mats[matId];
      final display = info?.display ?? (matId.isEmpty ? 'default' : matId);
      final cands = info?.candidates ?? [matId, rg.symbol];
      groups.add(DaeGroup(rg.symbol, display, cands, rg.indices));
    }
    final mesh = DaeMesh(nodeName, gid, frameIdx, data.pos, data.nor, data.uv, groups);
    _meshes.add(mesh);
    _log('Меш "$nodeName": вершин ${mesh.vertexCount}, треугольников ${mesh.triangleCount}, '
        'материалов ${groups.map((g) => g.materialName).toSet().length}');
  }

  _GeomData? _parseGeometry(XmlElement g, String gid) {
    final mesh = g.getElement('mesh');
    if (mesh == null) {
      _log('⚠ "$gid": нет <mesh>');
      return null;
    }
    final sources = <String, _Src>{};
    for (final s in mesh.findElements('source')) {
      final id = s.getAttribute('id');
      final fa = s.getElement('float_array');
      if (id == null || fa == null) continue;
      final acc = s.getElement('technique_common')?.getElement('accessor');
      final stride = int.tryParse(acc?.getAttribute('stride') ?? '') ?? 1;
      sources[id] = _Src(_floats(fa.innerText), stride);
    }
    final vPos = <String, String>{};
    final vNor = <String, String>{};
    for (final v in mesh.findElements('vertices')) {
      final id = v.getAttribute('id');
      if (id == null) continue;
      for (final i in v.findElements('input')) {
        final sem = i.getAttribute('semantic');
        final src = (i.getAttribute('source') ?? '').replaceFirst('#', '');
        if (sem == 'POSITION') vPos[id] = src;
        if (sem == 'NORMAL') vNor[id] = src;
      }
    }

    final pos = <double>[];
    final nor = <double>[];
    final uv = <double>[];
    final vmap = <int, int>{};
    final groups = <_RawGroup>[];
    var needNormals = false;

    for (final prim in mesh.childElements) {
      final kind = prim.name.local;
      if (kind == 'lines' || kind == 'linestrips' || kind == 'trifans' || kind == 'tristrips') {
        _log('⚠ "$gid": примитив <$kind> не поддерживается');
        continue;
      }
      if (kind != 'triangles' && kind != 'polylist' && kind != 'polygons') continue;

      var offV = -1, offN = -1, offT = -1, maxOff = 0, tSet = 1 << 30;
      _Src? sP, sN, sT;
      for (final inp in prim.findElements('input')) {
        final sem = inp.getAttribute('semantic');
        final off = int.tryParse(inp.getAttribute('offset') ?? '0') ?? 0;
        final srcId = (inp.getAttribute('source') ?? '').replaceFirst('#', '');
        maxOff = math.max(maxOff, off);
        switch (sem) {
          case 'VERTEX':
            offV = off;
            sP = sources[vPos[srcId]];
            final nid = vNor[srcId];
            if (nid != null && sN == null) {
              sN = sources[nid];
              offN = off;
            }
            break;
          case 'NORMAL':
            offN = off;
            sN = sources[srcId];
            break;
          case 'TEXCOORD':
            final set = int.tryParse(inp.getAttribute('set') ?? '0') ?? 0;
            if (set < tSet) {
              tSet = set;
              offT = off;
              sT = sources[srcId];
            }
            break;
        }
      }
      if (sP == null || offV < 0) {
        _log('⚠ "$gid": у примитива нет POSITION');
        continue;
      }
      final stride = maxOff + 1;
      final hasN = sN != null && offN >= 0;
      final hasT = sT != null && offT >= 0;
      if (!hasN) needNormals = true;
      final posSrc = sP;

      int emit(List<int> p, int base) {
        final pi = p[base + offV];
        final ni = hasN ? p[base + offN] : 0;
        final ti = hasT ? p[base + offT] : 0;
        final key = (pi << 42) | (ni << 21) | ti;
        final ex = vmap[key];
        if (ex != null) return ex;
        final id = pos.length ~/ 3;
        vmap[key] = id;
        final pb = pi * posSrc.stride;
        pos.addAll([posSrc.data[pb], posSrc.data[pb + 1], posSrc.data[pb + 2]]);
        if (hasN) {
          final nb = ni * sN!.stride;
          nor.addAll([sN.data[nb], sN.data[nb + 1], sN.data[nb + 2]]);
        } else {
          nor.addAll([0, 0, 0]);
        }
        if (hasT) {
          final tb = ti * sT!.stride;
          uv.addAll([sT.data[tb], 1.0 - sT.data[tb + 1]]);
        } else {
          uv.addAll([0, 0]);
        }
        return id;
      }

      final idxs = <int>[];
      void fan(List<int> p, int startCorner, int count) {
        if (count < 3) return;
        final c0 = emit(p, startCorner * stride);
        for (var k = 1; k < count - 1; k++) {
          idxs.add(c0);
          idxs.add(emit(p, (startCorner + k) * stride));
          idxs.add(emit(p, (startCorner + k + 1) * stride));
        }
      }

      if (kind == 'triangles') {
        final p = _ints(prim.getElement('p')?.innerText ?? '');
        final corners = p.length ~/ stride;
        for (var c = 0; c + 2 < corners; c += 3) {
          fan(p, c, 3);
        }
      } else if (kind == 'polylist') {
        final p = _ints(prim.getElement('p')?.innerText ?? '');
        final vc = _ints(prim.getElement('vcount')?.innerText ?? '');
        var c = 0;
        for (final n in vc) {
          fan(p, c, n);
          c += n;
        }
      } else {
        for (final pe in prim.findElements('p')) {
          final p = _ints(pe.innerText);
          fan(p, 0, p.length ~/ stride);
        }
      }
      groups.add(_RawGroup(prim.getAttribute('material') ?? '', idxs));
    }

    if (groups.isEmpty || pos.isEmpty) {
      _log('⚠ "$gid": нет полигонов');
      return null;
    }
    if (needNormals) _fillNormals(pos, nor, groups);
    return _GeomData(pos, nor, uv, groups);
  }

  void _fillNormals(List<double> pos, List<double> nor, List<_RawGroup> groups) {
    final acc = List<double>.filled(nor.length, 0);
    for (final g in groups) {
      for (var i = 0; i + 2 < g.indices.length; i += 3) {
        final a = g.indices[i] * 3, b = g.indices[i + 1] * 3, c = g.indices[i + 2] * 3;
        final e1x = pos[b] - pos[a], e1y = pos[b + 1] - pos[a + 1], e1z = pos[b + 2] - pos[a + 2];
        final e2x = pos[c] - pos[a], e2y = pos[c + 1] - pos[a + 1], e2z = pos[c + 2] - pos[a + 2];
        final nx = e1y * e2z - e1z * e2y, ny = e1z * e2x - e1x * e2z, nz = e1x * e2y - e1y * e2x;
        for (final v in [a, b, c]) {
          acc[v] += nx;
          acc[v + 1] += ny;
          acc[v + 2] += nz;
        }
      }
    }
    for (var v = 0; v < nor.length; v += 3) {
      final len0 = nor[v] * nor[v] + nor[v + 1] * nor[v + 1] + nor[v + 2] * nor[v + 2];
      if (len0 > 1e-12) continue;
      final l = math.sqrt(acc[v] * acc[v] + acc[v + 1] * acc[v + 1] + acc[v + 2] * acc[v + 2]);
      if (l < 1e-12) {
        nor[v] = 0;
        nor[v + 1] = 0;
        nor[v + 2] = 1;
      } else {
        nor[v] = acc[v] / l;
        nor[v + 1] = acc[v + 1] / l;
        nor[v + 2] = acc[v + 2] / l;
      }
    }
  }

  // ---------- токенайзеры ----------
  static bool _ws(int c) => c == 32 || c == 10 || c == 13 || c == 9;

  static List<double> _floats(String s) {
    final out = <double>[];
    final n = s.length;
    var i = 0;
    while (i < n) {
      while (i < n && _ws(s.codeUnitAt(i))) {
        i++;
      }
      if (i >= n) break;
      var j = i;
      while (j < n && !_ws(s.codeUnitAt(j))) {
        j++;
      }
      out.add(double.parse(s.substring(i, j)));
      i = j;
    }
    return out;
  }

  static List<int> _ints(String s) {
    final out = <int>[];
    final n = s.length;
    var i = 0;
    while (i < n) {
      while (i < n && _ws(s.codeUnitAt(i))) {
        i++;
      }
      if (i >= n) break;
      var j = i;
      while (j < n && !_ws(s.codeUnitAt(j))) {
        j++;
      }
      out.add(int.parse(s.substring(i, j)));
      i = j;
    }
    return out;
  }

  // ---------- матрицы 4x4 row-major ----------
  static List<double> _identity() => <double>[1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1];

  static List<double> _translate(double x, double y, double z) =>
      <double>[1, 0, 0, x, 0, 1, 0, y, 0, 0, 1, z, 0, 0, 0, 1];

  static List<double> _scale(double x, double y, double z) =>
      <double>[x, 0, 0, 0, 0, y, 0, 0, 0, 0, z, 0, 0, 0, 0, 1];

  static List<double> _rotate(double x, double y, double z, double deg) {
    final l = math.sqrt(x * x + y * y + z * z);
    if (l < 1e-12) return _identity();
    x /= l;
    y /= l;
    z /= l;
    final a = deg * math.pi / 180.0;
    final c = math.cos(a), s = math.sin(a), t = 1 - c;
    return <double>[
      t * x * x + c, t * x * y - s * z, t * x * z + s * y, 0,
      t * x * y + s * z, t * y * y + c, t * y * z - s * x, 0,
      t * x * z - s * y, t * y * z + s * x, t * z * z + c, 0,
      0, 0, 0, 1,
    ];
  }

  static List<double> _mul(List<double> a, List<double> b) {
    final r = List<double>.filled(16, 0);
    for (var i = 0; i < 4; i++) {
      for (var j = 0; j < 4; j++) {
        var s = 0.0;
        for (var k = 0; k < 4; k++) {
          s += a[i * 4 + k] * b[k * 4 + j];
        }
        r[i * 4 + j] = s;
      }
    }
    return r;
  }
}
