#ifndef FLAGS2ENV_ORESLANG_ABI_H
#define FLAGS2ENV_ORESLANG_ABI_H
#ifdef __cplusplus
extern "C" {
#endif
/* UTF-8 JSON in/out; result ownership transfers to caller. */
const char *f2e_oreslang_version(void);
char *f2e_oreslang_parse_json(const char *argv_json);
char *f2e_oreslang_parse_json_file(const char *config, const char *argv_json);
void f2e_oreslang_free(char *result);
#ifdef __cplusplus
}
#endif
#endif
