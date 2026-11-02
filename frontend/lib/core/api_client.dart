import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'api_exception.dart';
import 'generation_options.dart';
import 'remote_generation.dart';
import 'subscription_status.dart';

const String apiBaseUrl = 'http://127.0.0.1:8000';

class ApiClient {
  ApiClient({
    required this.baseUrl,
    required this.userId,
    http.Client? client,
  }) : _client = client ?? http.Client();

  final String baseUrl;
  final String userId;
  final http.Client _client;

  Future<SubscriptionStatus> getSubscription() {
    return _readSubscription(_get('/api/subscription'));
  }

  Future<SubscriptionStatus> purchasePremium() {
    return _readSubscription(_post('/api/subscription/purchase'));
  }

  Future<String> createGeneration({
    required String prompt,
    required GenerationOptions options,
  }) async {
    final http.Response response = await _post(
      '/api/generations',
      jsonEncode(_generationBody(prompt, options)),
    );
    if (response.statusCode != 201) {
      throw _exceptionForResponse(response);
    }
    return _createdId(_decodeObject(response.body));
  }

  Future<RemoteGeneration> getGeneration(String id) async {
    final http.Response response = await _get('/api/generations/$id');
    if (response.statusCode != 200) {
      throw _exceptionForResponse(response);
    }
    return _remoteGeneration(_decodeObject(response.body));
  }

  Future<Uint8List> downloadImage(String imageUrl) async {
    final http.Response response = await _send(
      _client.get(
        _resolveImage(imageUrl),
        headers: _headers(accept: 'image/png'),
      ),
    );
    if (response.statusCode != 200) {
      throw _exceptionForResponse(response);
    }
    if (response.bodyBytes.isEmpty) {
      throw const ApiUnexpectedResponseException();
    }
    return response.bodyBytes;
  }

  void close() {
    _client.close();
  }

  Future<SubscriptionStatus> _readSubscription(Future<http.Response> request) async {
    final http.Response response = await request;
    if (response.statusCode != 200) {
      throw _exceptionForResponse(response);
    }
    return _subscriptionStatus(_decodeObject(response.body));
  }

  Future<http.Response> _get(String path) {
    return _send(
      _client.get(_uri(path), headers: _headers(accept: 'application/json')),
    );
  }

  Future<http.Response> _post(String path, [String? body]) {
    return _send(
      _client.post(
        _uri(path),
        headers: _headers(
          accept: 'application/json',
          jsonBody: body != null,
        ),
        body: body,
      ),
    );
  }

  Future<http.Response> _send(Future<http.Response> request) async {
    try {
      return await request;
    } on http.ClientException {
      throw const ApiTransportException();
    } on SocketException {
      throw const ApiTransportException();
    }
  }

  Uri _uri(String path) {
    return Uri.parse(baseUrl).resolve(path);
  }

  Uri _resolveImage(String imageUrl) {
    final Uri parsed = Uri.parse(imageUrl);
    final String path = parsed.hasScheme ? parsed.path : imageUrl;
    return _uri(path);
  }

  Map<String, String> _headers({required String accept, bool jsonBody = false}) {
    return <String, String>{
      'X-User-Id': userId,
      'Accept': accept,
      if (jsonBody) 'Content-Type': 'application/json',
    };
  }
}

Map<String, Object?> _generationBody(String prompt, GenerationOptions options) {
  return <String, Object?>{
    'prompt': prompt,
    'options': <String, String>{
      'style': options.style,
      'aspectRatio': options.aspectRatio,
      'quality': options.quality,
    },
  };
}

String _createdId(Map<String, Object?> payload) {
  final Object? id = payload['id'];
  final Object? status = payload['status'];
  if (id is! String || id.isEmpty || status != 'pending') {
    throw const ApiUnexpectedResponseException();
  }
  return id;
}

SubscriptionStatus _subscriptionStatus(Map<String, Object?> payload) {
  final Object? status = payload['status'];
  if (status == 'free') {
    return SubscriptionStatus.free;
  }
  if (status == 'premium') {
    return SubscriptionStatus.premium;
  }
  throw const ApiUnexpectedResponseException();
}

RemoteGeneration _remoteGeneration(Map<String, Object?> payload) {
  final String id = _text(payload, 'id');
  final Object? status = payload['status'];
  if (status == 'processing') {
    return RemoteGeneration.processing(id: id);
  }
  if (status == 'completed') {
    return RemoteGeneration.completed(id: id, imageUrl: _optionalText(payload, 'imageUrl'));
  }
  if (status == 'failed') {
    return _failedGeneration(id, payload['error']);
  }
  throw const ApiUnexpectedResponseException();
}

RemoteGeneration _failedGeneration(String id, Object? error) {
  if (error is! Map) {
    throw const ApiUnexpectedResponseException();
  }
  final Map<String, Object?> body = _stringMap(error);
  return RemoteGeneration.failed(
    id: id,
    errorCode: _text(body, 'code'),
    errorMessage: _text(body, 'message'),
  );
}

ApiException _exceptionForResponse(http.Response response) {
  try {
    final Map<String, Object?> payload = _decodeObject(response.body);
    final Object? error = payload['error'];
    if (error is! Map) {
      return const ApiUnexpectedResponseException();
    }
    final Map<String, Object?> body = _stringMap(error);
    return ApiResponseException(
      statusCode: response.statusCode,
      code: _text(body, 'code'),
      message: _text(body, 'message'),
    );
  } on ApiUnexpectedResponseException {
    return const ApiUnexpectedResponseException();
  } on FormatException {
    return const ApiUnexpectedResponseException();
  }
}

Map<String, Object?> _decodeObject(String body) {
  try {
    final Object? decoded = jsonDecode(body);
    if (decoded is! Map) {
      throw const ApiUnexpectedResponseException();
    }
    return _stringMap(decoded);
  } on FormatException {
    throw const ApiUnexpectedResponseException();
  }
}

Map<String, Object?> _stringMap(Map<dynamic, dynamic> source) {
  final Map<String, Object?> result = <String, Object?>{};
  for (final MapEntry<dynamic, dynamic> entry in source.entries) {
    if (entry.key is! String) {
      throw const ApiUnexpectedResponseException();
    }
    result[entry.key as String] = entry.value;
  }
  return result;
}

String _text(Map<String, Object?> payload, String key) {
  final Object? value = payload[key];
  if (value is! String || value.isEmpty) {
    throw const ApiUnexpectedResponseException();
  }
  return value;
}

String? _optionalText(Map<String, Object?> payload, String key) {
  final Object? value = payload[key];
  if (value == null) {
    return null;
  }
  if (value is! String || value.isEmpty) {
    throw const ApiUnexpectedResponseException();
  }
  return value;
}
