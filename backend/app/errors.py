class ApiError(Exception):
    def __init__(self, status_code: int, code: str, message: str) -> None:
        super().__init__(message)
        self.status_code = status_code
        self.code = code
        self.message = message


def build_error_body(error: ApiError) -> dict[str, dict[str, str]]:
    return {"error": {"code": error.code, "message": error.message}}
