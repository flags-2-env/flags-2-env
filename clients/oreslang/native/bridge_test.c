#include "flags2env_ores_bridge.h"

#include <assert.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#if !defined(_WIN32)
#include <unistd.h>
#endif

static void expect_empty(f2e_ores_result value, int status) {
  assert(value.status == status);
  assert(value.data == NULL);
  assert(value.length == 0);
  f2e_ores_free(&value);
  assert(value.status == F2E_ORES_RELEASED);
  assert(value.data == NULL);
  assert(value.length == 0);
  f2e_ores_free(&value);
  assert(value.status == F2E_ORES_RELEASED);
}

static char *absolute_fixture(const char *relative) {
#if defined(_WIN32)
  (void)relative;
  return NULL;
#else
  char cwd[F2E_ORES_MAX_PATH_BYTES + 1u];
  size_t need;
  char *out;
  assert(getcwd(cwd, sizeof(cwd)) != NULL);
  {
    const size_t cwd_len = strlen(cwd);
    const size_t relative_len = strlen(relative);
    need = cwd_len + 1u + relative_len + 1u;
    assert(need <= F2E_ORES_MAX_PATH_BYTES + 1u);
    out = (char *)malloc(need);
    assert(out != NULL);
    memcpy(out, cwd, cwd_len);
    out[cwd_len] = '/';
    memcpy(out + cwd_len + 1u, relative, relative_len);
    out[cwd_len + 1u + relative_len] = '\0';
  }
  return out;
#endif
}

int main(void) {
  char *fixture;
  char *typed;
  f2e_ores_result result;
  char *oversized;
  char *oversized_path;

  expect_empty(f2e_ores_parse(NULL, "[]"), F2E_ORES_INVALID_INPUT);
  expect_empty(f2e_ores_parse("relative.toml", "[]"), F2E_ORES_INVALID_INPUT);
  expect_empty(f2e_ores_parse("/tmp/config.toml", "{}"), F2E_ORES_INVALID_INPUT);
  expect_empty(f2e_ores_parse("/tmp/config.toml", "   "), F2E_ORES_INVALID_INPUT);
  expect_empty(f2e_ores_coerce(NULL, "{}"), F2E_ORES_INVALID_INPUT);
  expect_empty(f2e_ores_coerce("relative.toml", "{}"), F2E_ORES_INVALID_INPUT);
  expect_empty(f2e_ores_coerce("/tmp/config.toml", "[]"), F2E_ORES_INVALID_INPUT);
  expect_empty(f2e_ores_coerce("/tmp/config.toml", ""), F2E_ORES_INVALID_INPUT);

  oversized_path = (char *)malloc(F2E_ORES_MAX_PATH_BYTES + 2u);
  assert(oversized_path != NULL);
  oversized_path[0] = '/';
  memset(oversized_path + 1, 'a', F2E_ORES_MAX_PATH_BYTES);
  oversized_path[F2E_ORES_MAX_PATH_BYTES + 1u] = '\0';
  expect_empty(f2e_ores_parse(oversized_path, "[]"), F2E_ORES_INPUT_TOO_LARGE);
  free(oversized_path);

  oversized = (char *)malloc(F2E_ORES_MAX_JSON_BYTES + 2u);
  assert(oversized != NULL);
  memset(oversized, 'x', F2E_ORES_MAX_JSON_BYTES + 1u);
  oversized[F2E_ORES_MAX_JSON_BYTES + 1u] = '\0';
  expect_empty(f2e_ores_parse("/tmp/config.toml", oversized),
               F2E_ORES_INPUT_TOO_LARGE);
  free(oversized);

  assert(strcmp(f2e_ores_status_name(F2E_ORES_OK), "ok") == 0);
  assert(strcmp(f2e_ores_status_name(F2E_ORES_INVALID_INPUT), "invalid_input") == 0);
  assert(strcmp(f2e_ores_status_name(F2E_ORES_NATIVE_FAILURE), "native_failure") == 0);
  assert(strcmp(f2e_ores_status_name(F2E_ORES_INPUT_TOO_LARGE), "input_too_large") == 0);
  assert(strcmp(f2e_ores_status_name(F2E_ORES_OUTPUT_TOO_LARGE), "output_too_large") == 0);
  assert(strcmp(f2e_ores_status_name(F2E_ORES_RELEASED), "released") == 0);
  assert(strcmp(f2e_ores_status_name(999), "unknown") == 0);
  f2e_ores_free(NULL);

#if !defined(_WIN32)
  fixture = absolute_fixture("tests/fixtures/.cli-flags.toml");
  result = f2e_ores_parse(fixture, "[\"app\",\"--port\",\"8181\",\"--debug\"]");
  assert(result.status == F2E_ORES_OK);
  assert(result.data != NULL);
  assert(result.length == strlen(result.data));
  assert(strcmp(result.data,
                "{\"PORT\":\"8181\",\"DEBUG\":\"true\",\"COLOR\":\"true\"}") == 0);
  f2e_ores_free(&result);
  free(fixture);

  typed = absolute_fixture("tests/codegen/.cli-flags.toml");
  result = f2e_ores_coerce(typed, "{\"PORT\":\"8181\",\"DEBUG\":\"true\"}");
  assert(result.status == F2E_ORES_OK);
  assert(result.data != NULL);
  assert(result.length == strlen(result.data));
  assert(strstr(result.data, "\"ok\":true") != NULL);
  f2e_ores_free(&result);
  free(typed);
#endif

  puts("ORES-FLAGS2ENV-BRIDGE-PASS|cases=20");
  return 0;
}
