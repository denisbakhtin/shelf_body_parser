library body_parser;

import 'dart:async';
import 'dart:convert';
import 'dart:core';
import 'dart:io';

import 'package:http_parser/http_parser.dart';
import 'package:mime/mime.dart';

import 'buffer.dart';
import 'file.dart';

part 'body_parse_result.dart';

Future<BodyParseResult> parseBodyFromStream(
    Stream<List<int>> data, MediaType? contentType, Uri requestUri,
    {bool storeOriginalBuffer = false}) async {
  Stream<List<int>> stream = data;

  Future<List<int>> getBytes() {
    return stream
        .fold<BytesBuilder>(BytesBuilder(copy: false),
            (BytesBuilder a, List<int> b) => a..add(b))
        .then((BytesBuilder b) => b.takeBytes());
  }

  var result = _BodyParseResultImpl();

  if (storeOriginalBuffer) {
    var bytes = await getBytes();
    result.originalBuffer = Buffer(bytes);
    var ctrl = StreamController<List<int>>()..add(bytes);
    stream = ctrl.stream;
    await ctrl.close();
  }

  Future<String> getBody() {
    return utf8.decoder.bind(stream).join();
  }

  /// Taken from Uri.splitQueryString and modified to respect multiple (array) values
  /// Splits the [query] into a map according to the rules
  /// specified for FORM post in the [HTML 4.01 specification section
  /// 17.13.4](http://www.w3.org/TR/REC-html40/interact/forms.html#h-17.13.4 "HTML 4.01 section 17.13.4").
  ///
  /// Each key and value in the returned map has been decoded. If the [query]
  /// is the empty string an empty map is returned.
  ///
  /// Keys in the query string that have no value are mapped to the
  /// empty string.
  ///
  /// Each query component will be decoded using [encoding]. The default encoding
  /// is UTF-8.
  Map<String, dynamic> splitQueryString(String query,
      {Encoding encoding = utf8}) {
    return query.split("&").fold({}, (map, element) {
      int index = element.indexOf("=");
      if (index == -1) {
        if (element != "") {
          map[Uri.decodeQueryComponent(element, encoding: encoding)] = "";
        }
      } else if (index != 0) {
        var key = Uri.decodeQueryComponent(element.substring(0, index),
            encoding: encoding);
        var value = Uri.decodeQueryComponent(element.substring(index + 1),
            encoding: encoding);
        if (key.endsWith("[]")) {
          if (map.containsKey(key))
            (map[key] as List<String>)..add(value);
          else
            map[key] = List<String>.empty(growable: true)..add(value);
        } else {
          map[key] = value;
        }
      }
      return map;
    });
  }

  try {
    if (requestUri.hasQuery) {
      result.query = splitQueryString(requestUri.query);
    }

    if (contentType != null) {
      if (contentType.type == 'multipart' &&
          contentType.parameters.containsKey('boundary')) {
        var parts = stream.cast<List<int>>().transform(
            MimeMultipartTransformer(contentType.parameters['boundary']!));

        await for (MimeMultipart part in parts) {
          var header = HeaderValue.parse(part.headers['content-disposition']!);
          String name = header.parameters['name']!;

          String? filename = header.parameters['filename'];
          if (filename == null) {
            List list = result.postFileParams[name] ?? [];
            BytesBuilder builder = await part.fold(
                BytesBuilder(copy: false),
                (BytesBuilder b, List<int> d) =>
                    b..add(d is! String ? d : (d as String).codeUnits));
            list.add(utf8.decode(builder.takeBytes()));
            result.postFileParams[name] = list;
            continue;
          }
          List list = result.postFileParams[name] ?? [];
          list.add(FileParams(
              mimeType: MediaType.parse(part.headers['content-type']!).mimeType,
              name: name,
              filename: filename,
              part: part));
          result.postFileParams[name] = list;
        }
      } else if (contentType.mimeType == 'application/json') {
        result.postParams.addAll(
            _foldToStringDynamic(json.decode(await getBody()) as Map) ?? {});
      } else if (contentType.mimeType == 'application/x-www-form-urlencoded') {
        result.postParams = splitQueryString(await getBody());
      }
    }
  } catch (e, st) {
    result.error = e;
    result.stack = st;
  }
  return result;
}

class _BodyParseResultImpl implements BodyParseResult {
  @override
  Map<String, dynamic> postParams = {};

  @override
  Map<String, List<dynamic>> postFileParams = {};

  @override
  Buffer? originalBuffer;

  @override
  Map<String, dynamic> query = {};

  @override
  var error;

  @override
  StackTrace? stack;
}

Map<String, dynamic>? _foldToStringDynamic(Map? map) {
  return map == null
      ? null
      : map.keys.fold<Map<String, dynamic>>(
          <String, dynamic>{}, (out, k) => out..[k.toString()] = map[k]);
}
