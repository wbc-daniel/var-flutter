import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../model/model.dart';
import '../parser/va_json_parser.dart';

// Binary .var magic header: V A B \x01
const _kVarMagic = [0x56, 0x41, 0x42, 0x01];

Future<VectorAnimation> loadVarAsset(String key, {String? package}) async {
  final fullKey = package == null ? key : 'packages/$package/$key';
  final data = await rootBundle.load(fullKey);
  return parseVarBytes(
    data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
  );
}

VectorAnimation parseVarBytes(List<int> bytes) {
  if (bytes.length > 4 &&
      bytes[0] == _kVarMagic[0] &&
      bytes[1] == _kVarMagic[1] &&
      bytes[2] == _kVarMagic[2] &&
      bytes[3] == _kVarMagic[3]) {
    final compressed = bytes is Uint8List
        ? bytes.sublist(4)
        : Uint8List.fromList(bytes).sublist(4);
    final decompressed = GZipDecoder().decodeBytes(compressed);
    return parseVaJson(utf8.decode(decompressed));
  }
  return parseVaJson(utf8.decode(bytes));
}

VectorAnimation parseVarJson(Map<String, dynamic> json) => parseVaJson(json);

VectorAnimation parseVarJsonString(String raw) => parseVaJson(raw);
