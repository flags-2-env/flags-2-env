#include "flags2env_ores_bridge.h"
#include "parser.h"

#include <stddef.h>

static size_t f2e_ores_bounded_len(const char *value, size_t max) {
  size_t i = 0;
  if (!value) return 0;
  while (i <= max && value[i] != '\0') i += 1;
  return i;
}

static int f2e_ores_absolute_path(const char *path, size_t len) {
  if (!path || len == 0) return 0;
#ifdef _WIN32
  if (len >= 3 &&
      ((path[0] >= 'A' && path[0] <= 'Z') ||
       (path[0] >= 'a' && path[0] <= 'z')) &&
      path[1] == ':' && (path[2] == '/' || path[2] == '\\')) {
    return 1;
  }
  return len >= 2 &&
         ((path[0] == '\\' && path[1] == '\\') ||
          (path[0] == '/' && path[1] == '/'));
#else
  return path[0] == '/';
#endif
}

static int f2e_ores_json_envelope(const char *json, char first, char last) {
  size_t len;
  size_t left = 0;
  size_t right;

  if (!json) return 0;
  len = f2e_ores_bounded_len(json, F2E_ORES_MAX_JSON_BYTES);
  if (len == 0 || len > F2E_ORES_MAX_JSON_BYTES) return 0;

  while (left < len &&
         (json[left] == ' ' || json[left] == '\t' ||
          json[left] == '\r' || json[left] == '\n')) {
    left += 1;
  }
  if (left == len || json[left] != first) return 0;

  right = len;
  while (right > left &&
         (json[right - 1] == ' ' || json[right - 1] == '\t' ||
          json[right - 1] == '\r' || json[right - 1] == '\n')) {
    right -= 1;
  }
  return right > left && json[right - 1] == last;
}

static f2e_ores_result f2e_ores_result_with_status(int status) {
  f2e_ores_result result = {0, 0, status};
  return result;
}

static int f2e_ores_validate_common(const char *config, const char *json,
                                    char first, char last) {
  size_t config_len;
  size_t json_len;

  if (!config || !json) {
    return F2E_ORES_INVALID_INPUT;
  }

  config_len = f2e_ores_bounded_len(config, F2E_ORES_MAX_PATH_BYTES);
  json_len = f2e_ores_bounded_len(json, F2E_ORES_MAX_JSON_BYTES);
  if (config_len > F2E_ORES_MAX_PATH_BYTES ||
      json_len > F2E_ORES_MAX_JSON_BYTES) {
    return F2E_ORES_INPUT_TOO_LARGE;
  }
  if (config_len == 0 || json_len == 0 ||
      !f2e_ores_absolute_path(config, config_len) ||
      !f2e_ores_json_envelope(json, first, last)) {
    return F2E_ORES_INVALID_INPUT;
  }
  return F2E_ORES_OK;
}

static f2e_ores_result f2e_ores_wrap(char *ptr) {
  size_t len;
  if (!ptr) {
    return f2e_ores_result_with_status(F2E_ORES_NATIVE_FAILURE);
  }

  len = f2e_ores_bounded_len(ptr, F2E_ORES_MAX_RESULT_BYTES);
  if (len > F2E_ORES_MAX_RESULT_BYTES) {
    f2e_free(ptr);
    return f2e_ores_result_with_status(F2E_ORES_OUTPUT_TOO_LARGE);
  }

  {
    f2e_ores_result result = {ptr, len, F2E_ORES_OK};
    return result;
  }
}

f2e_ores_result f2e_ores_parse(const char *config, const char *argv_json) {
  int status = f2e_ores_validate_common(config, argv_json, '[', ']');
  if (status != F2E_ORES_OK) {
    return f2e_ores_result_with_status(status);
  }
  return f2e_ores_wrap(f2e_parse_json_argv_from_file(config, argv_json));
}

f2e_ores_result f2e_ores_coerce(const char *config, const char *values_json) {
  int status = f2e_ores_validate_common(config, values_json, '{', '}');
  if (status != F2E_ORES_OK) {
    return f2e_ores_result_with_status(status);
  }
  return f2e_ores_wrap(f2e_coerce_json_from_file(config, values_json));
}

void f2e_ores_free(f2e_ores_result *result) {
  if (!result) return;
  if (result->data) f2e_free(result->data);
  result->data = 0;
  result->length = 0;
  result->status = F2E_ORES_RELEASED;
}

const char *f2e_ores_status_name(int status) {
  switch (status) {
    case F2E_ORES_OK: return "ok";
    case F2E_ORES_INVALID_INPUT: return "invalid_input";
    case F2E_ORES_NATIVE_FAILURE: return "native_failure";
    case F2E_ORES_INPUT_TOO_LARGE: return "input_too_large";
    case F2E_ORES_OUTPUT_TOO_LARGE: return "output_too_large";
    case F2E_ORES_RELEASED: return "released";
    default: return "unknown";
  }
}
