#include "abi.h"
#include "../../src/parser.h"
const char *f2e_oreslang_version(void) { return f2e_version(); }
char *f2e_oreslang_parse_json(const char *argv) {
  return argv ? f2e_parse_json_argv(argv) : NULL;
}
char *f2e_oreslang_parse_json_file(const char *config, const char *argv) {
  return config && *config && argv ? f2e_parse_json_argv_from_file(config, argv) : NULL;
}
void f2e_oreslang_free(char *value) {
  if (value) f2e_free(value);
}
