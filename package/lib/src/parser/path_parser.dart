import 'dart:ui' as ui;

/// Parses an SVG `d` attribute into a [ui.Path].
///
/// Supports: M/m, L/l, H/h, V/v, C/c, S/s, Q/q, T/t, A/a, Z/z. Unknown
/// commands throw [FormatException].
ui.Path parseSvgPath(String d) {
  final path = ui.Path();
  final tokens = _tokenize(d);
  if (tokens.isEmpty) return path;

  var i = 0;
  double cx = 0, cy = 0; // current point
  double sx = 0, sy = 0; // start of subpath (for Z)
  double lastCtrlX = 0, lastCtrlY = 0; // for S/s (reflection of last C)
  double lastQCtrlX = 0, lastQCtrlY = 0; // for T/t (reflection of last Q)
  String lastCmdKind = ''; // one of C, Q, or '' (controls whether S/T can reflect)

  String cmd = '';
  while (i < tokens.length) {
    final tok = tokens[i];
    if (tok is _CmdToken) {
      cmd = tok.letter;
      i++;
      if (cmd == 'Z' || cmd == 'z') {
        path.close();
        cx = sx;
        cy = sy;
        lastCmdKind = '';
        continue;
      }
    } else if (cmd.isEmpty) {
      throw const FormatException('path data must start with a command');
    }

    double readNum() {
      if (i >= tokens.length || tokens[i] is! _NumToken) {
        throw FormatException('expected number after $cmd at token $i');
      }
      final v = (tokens[i] as _NumToken).value;
      i++;
      return v;
    }

    final rel = cmd.toLowerCase() == cmd;
    switch (cmd.toUpperCase()) {
      case 'M':
        var x = readNum();
        var y = readNum();
        if (rel) {
          x += cx;
          y += cy;
        }
        path.moveTo(x, y);
        cx = x;
        cy = y;
        sx = x;
        sy = y;
        // Subsequent implicit pairs are lineto (per SVG spec).
        cmd = rel ? 'l' : 'L';
        lastCmdKind = '';
      case 'L':
        var x = readNum();
        var y = readNum();
        if (rel) {
          x += cx;
          y += cy;
        }
        path.lineTo(x, y);
        cx = x;
        cy = y;
        lastCmdKind = '';
      case 'H':
        var x = readNum();
        if (rel) x += cx;
        path.lineTo(x, cy);
        cx = x;
        lastCmdKind = '';
      case 'V':
        var y = readNum();
        if (rel) y += cy;
        path.lineTo(cx, y);
        cy = y;
        lastCmdKind = '';
      case 'C':
        var x1 = readNum(), y1 = readNum();
        var x2 = readNum(), y2 = readNum();
        var x = readNum(), y = readNum();
        if (rel) {
          x1 += cx;
          y1 += cy;
          x2 += cx;
          y2 += cy;
          x += cx;
          y += cy;
        }
        path.cubicTo(x1, y1, x2, y2, x, y);
        lastCtrlX = x2;
        lastCtrlY = y2;
        cx = x;
        cy = y;
        lastCmdKind = 'C';
      case 'S':
        var x2 = readNum(), y2 = readNum();
        var x = readNum(), y = readNum();
        if (rel) {
          x2 += cx;
          y2 += cy;
          x += cx;
          y += cy;
        }
        final x1 = lastCmdKind == 'C' ? 2 * cx - lastCtrlX : cx;
        final y1 = lastCmdKind == 'C' ? 2 * cy - lastCtrlY : cy;
        path.cubicTo(x1, y1, x2, y2, x, y);
        lastCtrlX = x2;
        lastCtrlY = y2;
        cx = x;
        cy = y;
        lastCmdKind = 'C';
      case 'Q':
        var x1 = readNum(), y1 = readNum();
        var x = readNum(), y = readNum();
        if (rel) {
          x1 += cx;
          y1 += cy;
          x += cx;
          y += cy;
        }
        path.quadraticBezierTo(x1, y1, x, y);
        lastQCtrlX = x1;
        lastQCtrlY = y1;
        cx = x;
        cy = y;
        lastCmdKind = 'Q';
      case 'T':
        var x = readNum(), y = readNum();
        if (rel) {
          x += cx;
          y += cy;
        }
        final x1 = lastCmdKind == 'Q' ? 2 * cx - lastQCtrlX : cx;
        final y1 = lastCmdKind == 'Q' ? 2 * cy - lastQCtrlY : cy;
        path.quadraticBezierTo(x1, y1, x, y);
        lastQCtrlX = x1;
        lastQCtrlY = y1;
        cx = x;
        cy = y;
        lastCmdKind = 'Q';
      case 'A':
        final rx = readNum(), ry = readNum();
        final xAxisRot = readNum();
        final largeArc = readNum() != 0;
        final sweep = readNum() != 0;
        var x = readNum(), y = readNum();
        if (rel) {
          x += cx;
          y += cy;
        }
        path.arcToPoint(
          ui.Offset(x, y),
          radius: ui.Radius.elliptical(rx, ry),
          rotation: xAxisRot,
          largeArc: largeArc,
          clockwise: sweep,
        );
        cx = x;
        cy = y;
        lastCmdKind = '';
      default:
        throw FormatException('unknown path command: $cmd');
    }
  }
  return path;
}

sealed class _Token {}

class _CmdToken extends _Token {
  final String letter;
  _CmdToken(this.letter);
}

class _NumToken extends _Token {
  final double value;
  _NumToken(this.value);
}

final _pathTokenRe = RegExp(
  r'[MmLlHhVvCcSsQqTtAaZz]|-?\d*\.?\d+(?:[eE][-+]?\d+)?',
);

List<_Token> _tokenize(String d) {
  final out = <_Token>[];
  for (final m in _pathTokenRe.allMatches(d)) {
    final s = m.group(0)!;
    final c = s.codeUnitAt(0);
    final isLetter =
        (c >= 65 && c <= 90) || (c >= 97 && c <= 122); // A-Z | a-z
    if (isLetter) {
      out.add(_CmdToken(s));
    } else {
      out.add(_NumToken(double.parse(s)));
    }
  }
  return out;
}
