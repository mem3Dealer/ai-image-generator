sealed class ApiException implements Exception {
  const ApiException();
}

class ApiTransportException extends ApiException {
  const ApiTransportException();
}

class ApiUnexpectedResponseException extends ApiException {
  const ApiUnexpectedResponseException();
}

class ApiResponseException extends ApiException {
  const ApiResponseException({
    required this.statusCode,
    required this.code,
    required this.message,
  });

  final int statusCode;
  final String code;
  final String message;
}
