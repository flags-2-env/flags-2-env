#include "flags2env_ores_bridge.h"
#include "parser.h"

#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static size_t free_calls = 0;

static char *make_string(size_t length) {
  char *value = (char *)malloc(length + 1u);
  if (!value) return NULL;
  memset(value, 'x', length);
  value[length] = '\0';
  return value;
}

char *f2e_parse_json_argv_from_file(const char *config_path,
                                    const char *argv_json) {
  (void)config_path;
  if (strcmp(argv_json, "[\"null\"]") == 0) return NULL;
  if (strcmp(argv_json, "[\"limit\"]") == 0)
    return make_string(F2E_ORES_MAX_RESULT_BYTES);
  if (strcmp(argv_json, "[\"oversized\"]") == 0)
    return make_string(F2E_ORES_MAX_RESULT_BYTES + 1u);
  return make_string(2u);
}

char *f2e_coerce_json_from_file(const char *config_path,
                                const char *values_json) {
  (void)config_path;
  if (strcmp(values_json, "{\"null\":true}") == 0) return NULL;
  return make_string(2u);
}

void f2e_free(char *value) {
  if (value) {
    free_calls += 1u;
    free(value);
  }
}

int main(void) {
  f2e_ores_result r;

  r = f2e_ores_parse("/trusted/config.toml", "[\"null\"]");
  assert(r.status == F2E_ORES_NATIVE_FAILURE);
  assert(r.data == NULL && r.length == 0u);
  f2e_ores_free(&r);
  assert(free_calls == 0u);

  r = f2e_ores_coerce("/trusted/config.toml", "{\"null\":true}");
  assert(r.status == F2E_ORES_NATIVE_FAILURE);
  assert(r.data == NULL && r.length == 0u);
  f2e_ores_free(&r);
  assert(free_calls == 0u);

  r = f2e_ores_parse("/trusted/config.toml", "[\"limit\"]");
  assert(r.status == F2E_ORES_OK);
  assert(r.data != NULL);
  assert(r.length == F2E_ORES_MAX_RESULT_BYTES);
  f2e_ores_free(&r);
  assert(free_calls == 1u);
  assert(r.status == F2E_ORES_RELEASED);

  r = f2e_ores_parse("/trusted/config.toml", "[\"oversized\"]");
  assert(r.status == F2E_ORES_OUTPUT_TOO_LARGE);
  assert(r.data == NULL && r.length == 0u);
  assert(free_calls == 2u);
  f2e_ores_free(&r);
  assert(free_calls == 2u);

  puts("ORES-FLAGS2ENV-BRIDGE-FAULT-PASS|cases=4");
  return 0;
}
