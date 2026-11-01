#ifndef FLAGS2ENV_ORES_BRIDGE_H
#define FLAGS2ENV_ORES_BRIDGE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define F2E_ORES_MAX_PATH_BYTES 4096u
#define F2E_ORES_MAX_JSON_BYTES (1024u * 1024u)
#define F2E_ORES_MAX_RESULT_BYTES (4u * 1024u * 1024u)

typedef enum {
  F2E_ORES_OK = 0,
  F2E_ORES_INVALID_INPUT = 1,
  F2E_ORES_NATIVE_FAILURE = 2,
  F2E_ORES_INPUT_TOO_LARGE = 3,
  F2E_ORES_OUTPUT_TOO_LARGE = 4,
  F2E_ORES_RELEASED = 5
} f2e_ores_status;

/*
 * Host-facing Oreslang ABI. data is owned by the result until
 * f2e_ores_free() is called. length excludes the trailing NUL.
 *
 * Public Oreslang APIs must copy data into actor-owned memory before release;
 * they must not expose this native pointer or rely on pointer syntax.
 */
typedef struct {
  char *data;
  size_t length;
  int status;
} f2e_ores_result;

f2e_ores_result f2e_ores_parse(const char *absolute_config_path,
                                const char *argv_json);
f2e_ores_result f2e_ores_coerce(const char *absolute_config_path,
                                 const char *values_json);
void f2e_ores_free(f2e_ores_result *result);
const char *f2e_ores_status_name(int status);

#ifdef __cplusplus
}
#endif

#endif
