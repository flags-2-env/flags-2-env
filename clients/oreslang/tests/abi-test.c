#include "../abi.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
int main(int argc, char **argv) {
  assert(argc == 2);
  assert(f2e_oreslang_version() != NULL);
  assert(f2e_oreslang_parse_json(NULL) == NULL);
  assert(f2e_oreslang_parse_json_file(NULL, "[]") == NULL);
  assert(f2e_oreslang_parse_json_file(argv[1], NULL) == NULL);
  char *result = f2e_oreslang_parse_json_file(argv[1], "[\"probe\",\"--port\",\"4012\"]");
  assert(result != NULL);
  assert(strstr(result, "4012") != NULL);
  f2e_oreslang_free(result);
  f2e_oreslang_free(NULL);
  puts("Oreslang C ABI passed");
  return 0;
}
