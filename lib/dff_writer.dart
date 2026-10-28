import 'dart:math' as math;
import 'dart:typed_data';

import 'dae_parser.dart';

/// Запрос на сборку (передаётся в compute()).
class DffRequest {
  final DaeScene scene;
  final Map<String, String> textures; // имя материала -> имя текстуры
  DffRequest(this.scene, this.textures);
}

class DffBuildResult {
  final Uint8List bytes;
  final List<String> log;
  DffBuildResult(this.bytes, this.log);
}

DffBuildResult buildDffTask(DffRequest r) {
  final w = DffWriter(r.textures);
  final bytes = w.build(r.scene);
  return DffBuildResult(bytes, w.logs);
}

/// Растущий little-endian буфер.
class _Buf {
  Uint8List _d = Uint8List(1024);
  late ByteData _v = ByteData.view(_d.buffer);
  int len = 0;

  void _ensure(int n) {
    if (len + n <= _d.length) return;
    var c = _d.length * 2;
    while (c < len + n) {
      c *= 2;
    }
    final nd = Uint8List(c);
    nd.setRange(0, len, _d);
    _d = nd;
    _v = ByteData.view(nd.buffer);
  }

  void u8(int x) {
    _ensure(1);
    _d[len++] = x & 0xFF;
  }

  void u16(int x) {
    _ensure(2);
    _v.setUint16(len, x, Endian.little);
    len += 2;
  }

  void u32(int x) {
    _ensure(4);
    _v.setUint32(len, x & 0xFFFFFFFF, Endian.little);
    len += 4;
  }

  void i32(int x) {
    _ensure(4);
    _v.setInt32(len, x, Endian.little);
    len += 4;
  }

  void f32(double x) {
    _ensure(4);
    _v.setFloat32(len, x, Endian.little);
    len += 4;
  }

  void bytes(List<int> b) {
    _ensure(b.length);
    _d.setRange(len, len + b.length, b);
    len += b.length;
  }

  Uint8List toBytes() => Uint8List.sublistView(_d, 0, len);
}

class DffWriter {
  static const int libraryId = 0x1803FFFF;

  static const int idStruct = 0x0001;
  static const int idString = 0x0002;
  static const int idExtension = 0x0003;
  static const int idTexture = 0x0006;
  static const int idMaterial = 0x0007;
  static const int idMaterialList = 0x0008;
  static const int idFrameList = 0x000E;
  static const int idGeometry = 0x000F;
  static const int idClump = 0x0010;
  static const int idAtomic = 0x0014;
  static const int idGeometryList = 0x001A;
  static const int idBinMesh = 0x050E;
  static const int idNodeName = 0x0253F2FE;

  // rpGEOMETRY* флаги: TRILIST (0, без TRISTRIP) | POSITIONS | TEXTURED | PRELIT | NORMALS | LIGHT | MODULATEMATERIALCOLOR,
  // плюс 1 набор UV в старшем байте.
  static const int geomFlags = 0x02 | 0x04 | 0x08 | 0x10 | 0x20 | 0x40 | (1 << 16);

  final Map<String, String> textures;
  final List<String> logs = [];
  DffWriter(this.textures);

  void _log(String s) => logs.add(s);

  // ---------- чанки ----------
  Uint8List _wrap(int type, Uint8List body) {
    final b = _Buf();
    b.u32(type);
    b.u32(body.length);
    b.u32(libraryId);
    b.bytes(body);
    return b.toBytes();
  }

  Uint8List _leaf(int type, void Function(_Buf) fill) {
    final b = _Buf();
    fill(b);
    return _wrap(type, b.toBytes());
  }

  Uint8List _node(int type, List<Uint8List> kids) {
    final b = _Buf();
    for (final k in kids) {
      b.bytes(k);
    }
    return _wrap(type, b.toBytes());
  }

  Uint8List _emptyExt() => _wrap(idExtension, Uint8List(0));

  Uint8List _string(String s) {
    final codes = _ascii(s);
    return _leaf(idString, (b) {
      b.bytes(codes);
      final padded = (codes.length + 1 + 3) & ~3;
      for (var i = codes.length; i < padded; i++) {
        b.u8(0);
      }
    });
  }

  List<int> _ascii(String s) => s.codeUnits.map((c) => c < 128 && c >= 32 ? c : 0x5F).toList();

  // ---------- сборка ----------
  Uint8List build(DaeScene scene) {
    if (scene.meshes.isEmpty) {
      throw const FormatException('В DAE нет мешей для конвертации');
    }
    _log('Сборка FrameList (${scene.frames.length} фреймов)');
    final frameList = _frameList(scene.frames);

    _log('Сборка GeometryList (${scene.meshes.length} геометрий)');
    final geoms = <Uint8List>[];
    for (final m in scene.meshes) {
      geoms.add(_geometry(m));
    }
    final geomList = _node(idGeometryList, [
      _leaf(idStruct, (b) => b.u32(geoms.length)),
      ...geoms,
    ]);

    final atomics = <Uint8List>[];
    for (var i = 0; i < scene.meshes.length; i++) {
      final fi = scene.meshes[i].frameIndex;
      atomics.add(_node(idAtomic, [
        _leaf(idStruct, (b) {
          b.u32(fi);
          b.u32(i);
          b.u32(5); // render | collision test
          b.u32(0);
        }),
        _emptyExt(),
      ]));
    }

    final clump = _node(idClump, [
      _leaf(idStruct, (b) {
        b.u32(atomics.length);
        b.u32(0); // lights
        b.u32(0); // cameras
      }),
      frameList,
      geomList,
      ...atomics,
      _emptyExt(),
    ]);
    _log('Итого: ${clump.length} байт, версия 0x${libraryId.toRadixString(16).toUpperCase()}');
    return clump;
  }

  Uint8List _frameList(List<DaeFrame> frames) {
    final st = _leaf(idStruct, (b) {
      b.u32(frames.length);
      for (final f in frames) {
        final m = f.matrix;
        // строки RW-матрицы = столбцы Collada-матрицы
        b.f32(m[0]);
        b.f32(m[4]);
        b.f32(m[8]); // right
        b.f32(m[1]);
        b.f32(m[5]);
        b.f32(m[9]); // up
        b.f32(m[2]);
        b.f32(m[6]);
        b.f32(m[10]); // at
        b.f32(m[3]);
        b.f32(m[7]);
        b.f32(m[11]); // pos
        b.i32(f.parent);
        b.u32(0x00020003);
      }
    });
    final exts = <Uint8List>[];
    for (var i = 0; i < frames.length; i++) {
      var name = String.fromCharCodes(_ascii(frames[i].name));
      if (name.isEmpty) name = 'frame$i';
      if (name.length > 23) name = name.substring(0, 23);
      final nameChunk = _wrap(idNodeName, Uint8List.fromList(name.codeUnits));
      exts.add(_node(idExtension, [nameChunk]));
    }
    return _node(idFrameList, [st, ...exts]);
  }

  String? _textureFor(String material) {
    var t = textures[material]?.trim();
    if (t == null || t.isEmpty) return null;
    final dot = t.lastIndexOf('.');
    if (dot > 0 && t.length - dot <= 5) t = t.substring(0, dot);
    if (t.length > 31) t = t.substring(0, 31);
    return t;
  }

  Uint8List _geometry(DaeMesh m) {
    final nv = m.vertexCount;
    if (nv > 65535) {
      throw FormatException('Меш "${m.name}": $nv вершин, максимум для DFF — 65535');
    }

    // материалы геометрии (уникальные, в порядке появления)
    final matNames = <String>[];
    final groupMat = <int>[];
    for (final g in m.groups) {
      var idx = matNames.indexOf(g.materialName);
      if (idx < 0) {
        matNames.add(g.materialName);
        idx = matNames.length - 1;
      }
      groupMat.add(idx);
    }

    var ntri = 0;
    for (final g in m.groups) {
      ntri += g.indices.length ~/ 3;
    }

    // bounding sphere
    var minX = double.infinity, minY = double.infinity, minZ = double.infinity;
    var maxX = -double.infinity, maxY = -double.infinity, maxZ = -double.infinity;
    for (var i = 0; i < nv; i++) {
      final x = m.positions[i * 3], y = m.positions[i * 3 + 1], z = m.positions[i * 3 + 2];
      minX = math.min(minX, x);
      maxX = math.max(maxX, x);
      minY = math.min(minY, y);
      maxY = math.max(maxY, y);
      minZ = math.min(minZ, z);
      maxZ = math.max(maxZ, z);
    }
    final cx = (minX + maxX) / 2, cy = (minY + maxY) / 2, cz = (minZ + maxZ) / 2;
    var r2 = 0.0;
    for (var i = 0; i < nv; i++) {
      final dx = m.positions[i * 3] - cx, dy = m.positions[i * 3 + 1] - cy, dz = m.positions[i * 3 + 2] - cz;
      r2 = math.max(r2, dx * dx + dy * dy + dz * dz);
    }
    final radius = math.sqrt(r2);

    final struct = _leaf(idStruct, (b) {
      b.u32(geomFlags);
      b.u32(ntri);
      b.u32(nv);
      b.u32(1); // morph targets
      for (var i = 0; i < nv; i++) {
        b.u32(0xFFFFFFFF); // prelit RGBA
      }
      for (var i = 0; i < nv * 2; i++) {
        b.f32(m.uvs[i]);
      }
      for (var gi = 0; gi < m.groups.length; gi++) {
        final idx = m.groups[gi].indices;
        final mat = groupMat[gi];
        for (var i = 0; i + 2 < idx.length; i += 3) {
          b.u16(idx[i + 1]); // vertex2
          b.u16(idx[i]); // vertex1
          b.u16(mat); // material id
          b.u16(idx[i + 2]); // vertex3
        }
      }
      b.f32(cx);
      b.f32(cy);
      b.f32(cz);
      b.f32(radius);
      b.u32(1); // has vertices
      b.u32(1); // has normals
      for (var i = 0; i < nv * 3; i++) {
        b.f32(m.positions[i]);
      }
      for (var i = 0; i < nv * 3; i++) {
        b.f32(m.normals[i]);
      }
    });

    // MaterialList
    final mats = <Uint8List>[];
    for (final name in matNames) {
      mats.add(_material(name));
    }
    final matList = _node(idMaterialList, [
      _leaf(idStruct, (b) {
        b.u32(matNames.length);
        for (var i = 0; i < matNames.length; i++) {
          b.i32(-1);
        }
      }),
      ...mats,
    ]);

    // BinMeshPLG: индексы по материалам
    final perMat = List.generate(matNames.length, (_) => <int>[]);
    for (var gi = 0; gi < m.groups.length; gi++) {
      perMat[groupMat[gi]].addAll(m.groups[gi].indices);
    }
    final used = <int>[];
    var total = 0;
    for (var i = 0; i < perMat.length; i++) {
      if (perMat[i].isNotEmpty) {
        used.add(i);
        total += perMat[i].length;
      }
    }
    final binMesh = _leaf(idBinMesh, (b) {
      b.u32(0); // trilist
      b.u32(used.length);
      b.u32(total);
      for (final mi in used) {
        b.u32(perMat[mi].length);
        b.u32(mi);
        for (final ix in perMat[mi]) {
          b.u32(ix);
        }
      }
    });

    return _node(idGeometry, [struct, matList, _node(idExtension, [binMesh])]);
  }

  Uint8List _material(String name) {
    final tex = _textureFor(name);
    final kids = <Uint8List>[
      _leaf(idStruct, (b) {
        b.u32(0); // flags
        b.u32(0xFFFFFFFF); // color RGBA
        b.u32(0); // unused
        b.u32(tex != null ? 1 : 0);
        b.f32(1.0); // ambient
        b.f32(0.0); // specular
        b.f32(1.0); // diffuse
      }),
    ];
    if (tex != null) {
      kids.add(_node(idTexture, [
        _leaf(idStruct, (b) => b.u32(0x00001106)), // filter + addressing
        _string(tex),
        _string(''), // alpha mask
        _emptyExt(),
      ]));
    }
    kids.add(_emptyExt());
    return _node(idMaterial, kids);
  }
}
