// Copyright 2016 Google Inc. Use of this source code is governed by an
// MIT-style license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import 'dart:math' as math;

import 'package:charcode/charcode.dart';
import 'package:string_scanner/string_scanner.dart';

import '../../ast/css/node.dart';
import '../../util/character.dart';
import '../../value.dart';
import '../css.dart';

String toCss(CssNode node) {
  var visitor = new _SerializeCssVisitor();
  node.accept(visitor);
  var result = visitor._buffer.toString();
  if (result.codeUnits.any((codeUnit) => codeUnit > 0x7F)) {
    result = '@charset "UTF-8";\n$result';
  }

  // TODO(nweiz): Do this in a way that's not O(n), maybe using a custom buffer
  // that's not append-only.
  return result.trim();
}

class _SerializeCssVisitor extends CssVisitor {
  final _buffer = new StringBuffer();

  var _indentation = 0;

  void visitStylesheet(CssStylesheet node) {
    for (var child in node.children) {
      child.accept(this);
      _buffer.writeln();
    }
  }

  void visitComment(CssComment node) {
    // TODO: format this at all
    _buffer.writeln(node.text);
  }

  void visitAtRule(CssAtRule node) {
    _writeIndentation();
    _buffer.writeCharCode($at);
    _buffer.write(node.name);

    if (node.value != null) {
      _buffer.writeCharCode($space);
      _buffer.write(node.value.value);
    }

    if (node.children == null) {
      _buffer.writeCharCode($semicolon);
    } else {
      _buffer.writeCharCode($space);
      _visitChildren(node.children);
    }
  }

  void visitMediaRule(CssMediaRule node) {
    _writeIndentation();
    _buffer.write("@media ");

    for (var query in node.queries) {
      visitMediaQuery(query);
    }

    _buffer.writeCharCode($space);
    _visitChildren(node.children);
  }

  void visitMediaQuery(CssMediaQuery query) {
    if (query.modifier != null) {
      _buffer.write(query.modifier.value);
      _buffer.writeCharCode($space);
    }

    if (query.type != null) {
      _buffer.write(query.type.value);
      if (query.features.isNotEmpty) _buffer.write(" and ");
    }

    _writeBetween(query.features, " and ", _buffer.write);
  }

  void visitStyleRule(CssStyleRule node) {
    _writeIndentation();
    _buffer.write(node.selector.value);
    _buffer.writeCharCode($space);
    _visitChildren(node.children);

    // TODO: only add an extra newline if this is a group end
    _buffer.writeln();
  }

  void visitDeclaration(CssDeclaration node) {
    _writeIndentation();
    _buffer.write(node.name.value);
    _buffer.writeCharCode($colon);
    if (node.isCustomProperty) {
      _writeCustomPropertyValue(node);
    } else {
      _buffer.writeCharCode($space);
      node.value.value.accept(this);
    }
    _buffer.writeCharCode($semicolon);
  }

  void _writeCustomPropertyValue(CssDeclaration node) {
    var value = (node.value.value as SassIdentifier).text;

    var minimumIndentation = _minimumIndentation(value);
    if (minimumIndentation == null) {
      _buffer.write(value);
      return;
    }

    if (node.value.span != null) {
      minimumIndentation =
          math.min(minimumIndentation, node.name.span.start.column);
    }

    var scanner = new LineScanner(value);
    while (!scanner.isDone && scanner.peekChar() != $lf) {
      _buffer.writeCharCode(scanner.readChar());
    }
    if (scanner.isDone) return;

    while (!scanner.isDone) {
      _buffer.writeCharCode(scanner.readChar());
      for (var i = 0; i < minimumIndentation; i++) scanner.readChar();
      _writeIndentation();
      while (!scanner.isDone && scanner.peekChar() != $lf) {
        _buffer.writeCharCode(scanner.readChar());
      }
    }
  }

  int _minimumIndentation(String text) {
    var scanner = new LineScanner(text);
    while (!scanner.isDone && scanner.readChar() != $lf) {}
    if (scanner.isDone) return null;

    var min = null;
    while (!scanner.isDone) {
      while (!scanner.isDone && scanner.scanChar($space)) {}
      if (scanner.isDone || scanner.scanChar($lf)) continue;
      min = min == null ? scanner.column : math.min(min, scanner.column);
      while (!scanner.isDone && scanner.readChar() != $lf) {}
    }

    return min;
  }

  void visitBoolean(SassBoolean value) =>
      _buffer.write(value.value.toString());

  // TODO(nweiz): Use color names for named colors.
  void visitColor(SassColor value) => _buffer.write(value.toString());

  void visitIdentifier(SassIdentifier value) =>
      _buffer.write(value.text.replaceAll("\n", " "));

  void visitList(SassList value) {
    if (value.isBracketed) {
      _buffer.writeCharCode($lbracket);
    } else if (value.contents.isEmpty) {
      throw "() isn't a valid CSS value";
    }

    _writeBetween(
        value.contents.where((element) => !element.isBlank),
        value.separator == ListSeparator.space ? " " : ", ",
        (element) => element.accept(this));

    if (value.isBracketed) _buffer.writeCharCode($rbracket);
  }

  // TODO(nweiz): Support precision and don't support exponent notation.
  void visitNumber(SassNumber value) {
    _buffer.write(value.value.toString());
  }

  void visitString(SassString string) =>
      _buffer.write(_visitString(string.text));

  String _visitString(String string, {bool forceDoubleQuote: false}) {
    var includesSingleQuote = false;
    var includesDoubleQuote = false;
    var buffer = new StringBuffer();
    for (var i = 0; i < string.length; i++) {
      var char = string.codeUnitAt(i);
      switch (char) {
        case $single_quote:
          if (forceDoubleQuote) {
            buffer.writeCharCode($single_quote);
          } else if (includesDoubleQuote) {
            return _visitString(string, forceDoubleQuote: true);
          } else {
            includesSingleQuote = true;
            buffer.writeCharCode($single_quote);
          }
          break;

        case $double_quote:
          if (forceDoubleQuote) {
            buffer.writeCharCode($backslash);
            buffer.writeCharCode($double_quote);
          } else if (includesSingleQuote) {
            return _visitString(string, forceDoubleQuote: true);
          } else {
            includesDoubleQuote = true;
            buffer.writeCharCode($double_quote);
          }
          break;

        case $cr:
        case $lf:
        case $ff:
          buffer.writeCharCode($backslash);
          buffer.writeCharCode(hexCharFor(char));
          if (string.length == i + 1) break;

          var next = string.codeUnitAt(i + 1);
          if (isHex(next) || next == $space || next == $tab) {
            buffer.writeCharCode($space);
          }
          break;

        case $backslash:
          buffer.writeCharCode($backslash);
          buffer.writeCharCode($backslash);
          break;

        default:
          buffer.writeCharCode(char);
          break;
      }
    }

    var doubleQuote = forceDoubleQuote || !includesDoubleQuote;
    return doubleQuote ? '"$buffer"' : "'$buffer'";
  }

  void _visitChildren(Iterable<CssNode> children) {
    _buffer.writeCharCode($lbrace);
    _buffer.writeln();
    _indent(() {
      for (var child in children) {
        child.accept(this);
        _buffer.writeln();
      }
    });
    _writeIndentation();
    _buffer.writeCharCode($rbrace);
  }

  void _writeIndentation() {
    for (var i = 0; i < _indentation; i++) {
      _buffer.writeCharCode($space);
      _buffer.writeCharCode($space);
    }
  }

  void _writeBetween/*<T>*/(Iterable/*<T>*/ iterable, String text,
      void callback(/*=T*/ value)) {
    var first = true;
    for (var value in iterable) {
      if (first) {
        first = false;
      } else {
        _buffer.write(text);
      }
      callback(value);
    }
  }

  void _indent(void callback()) {
    _indentation++;
    callback();
    _indentation--;
  }
}