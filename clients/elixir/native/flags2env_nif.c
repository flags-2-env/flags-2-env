#include "parser.h"

#include <erl_nif.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
  const char *cursor;
} F2EBeamJson;

static int f2e_beam_copy_term_string(ErlNifEnv *env, ERL_NIF_TERM term, char **out) {
  ErlNifBinary binary;
  if (!enif_inspect_iolist_as_binary(env, term, &binary)) {
    return 0;
  }

  char *copy = (char *)enif_alloc(binary.size + 1);
  if (!copy) {
    return 0;
  }
  memcpy(copy, binary.data, binary.size);
  copy[binary.size] = '\0';
  *out = copy;
  return 1;
}

static void f2e_beam_skip_ws(F2EBeamJson *json) {
  while (*json->cursor == ' ' || *json->cursor == '\n' || *json->cursor == '\r' || *json->cursor == '\t') {
    json->cursor++;
  }
}

static int f2e_beam_parse_json_string(F2EBeamJson *json, char **out, size_t *out_len) {
  f2e_beam_skip_ws(json);
  if (*json->cursor != '"') {
    return 0;
  }
  json->cursor++;

  size_t cap = 32;
  size_t len = 0;
  char *value = (char *)enif_alloc(cap);
  if (!value) {
    return 0;
  }

  while (*json->cursor && *json->cursor != '"') {
    char ch = *json->cursor++;
    if (ch == '\\' && *json->cursor) {
      char escaped = *json->cursor++;
      switch (escaped) {
        case 'b':
          ch = '\b';
          break;
        case 'f':
          ch = '\f';
          break;
        case 'n':
          ch = '\n';
          break;
        case 'r':
          ch = '\r';
          break;
        case 't':
          ch = '\t';
          break;
        case '"':
        case '\\':
        case '/':
          ch = escaped;
          break;
        case 'u':
          if (json->cursor[0] && json->cursor[1] && json->cursor[2] && json->cursor[3]) {
            ch = '?';
            json->cursor += 4;
          }
          break;
        default:
          ch = escaped;
          break;
      }
    }

    if (len + 1 > cap) {
      cap *= 2;
      char *grown = (char *)enif_realloc(value, cap);
      if (!grown) {
        enif_free(value);
        return 0;
      }
      value = grown;
    }
    value[len++] = ch;
  }

  if (*json->cursor != '"') {
    enif_free(value);
    return 0;
  }
  json->cursor++;
  *out = value;
  *out_len = len;
  return 1;
}

static ERL_NIF_TERM f2e_beam_binary(ErlNifEnv *env, const char *value, size_t len) {
  ERL_NIF_TERM term;
  unsigned char *data = enif_make_new_binary(env, len, &term);
  if (len > 0) {
    memcpy(data, value, len);
  }
  return term;
}

static int f2e_beam_json_to_map(ErlNifEnv *env, const char *raw, ERL_NIF_TERM *out) {
  F2EBeamJson json = {raw};
  f2e_beam_skip_ws(&json);
  if (*json.cursor != '{') {
    return 0;
  }
  json.cursor++;

  ERL_NIF_TERM map = enif_make_new_map(env);
  while (*json.cursor) {
    f2e_beam_skip_ws(&json);
    if (*json.cursor == '}') {
      *out = map;
      return 1;
    }

    char *key = NULL;
    char *value = NULL;
    size_t key_len = 0;
    size_t value_len = 0;
    if (!f2e_beam_parse_json_string(&json, &key, &key_len)) {
      return 0;
    }
    f2e_beam_skip_ws(&json);
    if (*json.cursor != ':') {
      enif_free(key);
      return 0;
    }
    json.cursor++;
    if (!f2e_beam_parse_json_string(&json, &value, &value_len)) {
      enif_free(key);
      return 0;
    }

    ERL_NIF_TERM key_term = f2e_beam_binary(env, key, key_len);
    ERL_NIF_TERM value_term = f2e_beam_binary(env, value, value_len);
    enif_make_map_put(env, map, key_term, value_term, &map);
    enif_free(key);
    enif_free(value);

    f2e_beam_skip_ws(&json);
    if (*json.cursor == ',') {
      json.cursor++;
      continue;
    }
    if (*json.cursor == '}') {
      *out = map;
      return 1;
    }
    return 0;
  }

  return 0;
}

static ERL_NIF_TERM f2e_beam_map_from_json(ErlNifEnv *env, char *json) {
  ERL_NIF_TERM map;
  if (!json || !f2e_beam_json_to_map(env, json, &map)) {
    return enif_make_new_map(env);
  }
  return map;
}

static ERL_NIF_TERM f2e_beam_owned_json_binary(ErlNifEnv *env, char *json) {
  if (!json) {
    return enif_make_badarg(env);
  }

  size_t len = strlen(json);
  ERL_NIF_TERM result = f2e_beam_binary(env, json, len);
  f2e_free(json);
  return result;
}

static ERL_NIF_TERM f2e_beam_parse_process(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  if (argc != 1) {
    return enif_make_badarg(env);
  }

  char *config_path = NULL;
  if (!f2e_beam_copy_term_string(env, argv[0], &config_path)) {
    return enif_make_badarg(env);
  }

  char *json = f2e_parse_process_from_file(config_path);
  enif_free(config_path);
  ERL_NIF_TERM result = f2e_beam_map_from_json(env, json);
  f2e_free(json);
  return result;
}

static ERL_NIF_TERM f2e_beam_parse_process_default(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argv;
  if (argc != 0) {
    return enif_make_badarg(env);
  }

  char *json = f2e_parse_process();
  ERL_NIF_TERM result = f2e_beam_map_from_json(env, json);
  f2e_free(json);
  return result;
}

static ERL_NIF_TERM f2e_beam_parse_argv(ErlNifEnv *env, ERL_NIF_TERM argv_term, const char *config_path) {
  unsigned int list_len = 0;
  if (!enif_get_list_length(env, argv_term, &list_len)) {
    return enif_make_badarg(env);
  }

  char **items = (char **)enif_alloc(sizeof(char *) * list_len);
  if (!items && list_len > 0) {
    return enif_make_badarg(env);
  }
  memset(items, 0, sizeof(char *) * list_len);

  ERL_NIF_TERM list = argv_term;
  for (unsigned int i = 0; i < list_len; i++) {
    ERL_NIF_TERM head;
    if (!enif_get_list_cell(env, list, &head, &list) || !f2e_beam_copy_term_string(env, head, &items[i])) {
      for (unsigned int j = 0; j < i; j++) {
        enif_free(items[j]);
      }
      enif_free(items);
      return enif_make_badarg(env);
    }
  }

  char *json = config_path ? f2e_parse_from_file(config_path, (int)list_len, (const char *const *)items) : f2e_parse((int)list_len, (const char *const *)items);
  for (unsigned int i = 0; i < list_len; i++) {
    enif_free(items[i]);
  }
  enif_free(items);

  ERL_NIF_TERM result = f2e_beam_map_from_json(env, json);
  f2e_free(json);
  return result;
}

static ERL_NIF_TERM f2e_beam_parse(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  if (argc != 2) {
    return enif_make_badarg(env);
  }

  char *config_path = NULL;
  if (!f2e_beam_copy_term_string(env, argv[1], &config_path)) {
    return enif_make_badarg(env);
  }

  ERL_NIF_TERM result = f2e_beam_parse_argv(env, argv[0], config_path);
  enif_free(config_path);
  return result;
}

static ERL_NIF_TERM f2e_beam_parse_default(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  if (argc != 1) {
    return enif_make_badarg(env);
  }

  return f2e_beam_parse_argv(env, argv[0], NULL);
}


static ERL_NIF_TERM f2e_beam_parse_structured_argv(
    ErlNifEnv *env,
    ERL_NIF_TERM argv_term,
    const char *config_path) {
  unsigned int list_len = 0;
  if (!enif_get_list_length(env, argv_term, &list_len)) {
    return enif_make_badarg(env);
  }

  char **items = (char **)enif_alloc(sizeof(char *) * list_len);
  if (!items && list_len > 0) {
    return enif_make_badarg(env);
  }
  if (list_len > 0) {
    memset(items, 0, sizeof(char *) * list_len);
  }

  ERL_NIF_TERM list = argv_term;
  for (unsigned int i = 0; i < list_len; i++) {
    ERL_NIF_TERM head;
    if (!enif_get_list_cell(env, list, &head, &list)
        || !f2e_beam_copy_term_string(env, head, &items[i])) {
      for (unsigned int j = 0; j < i; j++) {
        enif_free(items[j]);
      }
      enif_free(items);
      return enif_make_badarg(env);
    }
  }

  char *json = config_path
      ? f2e_parse_structured_from_file(
            config_path,
            (int)list_len,
            (const char *const *)items)
      : f2e_parse_structured(
            (int)list_len,
            (const char *const *)items);

  for (unsigned int i = 0; i < list_len; i++) {
    enif_free(items[i]);
  }
  enif_free(items);

  return f2e_beam_owned_json_binary(env, json);
}

static ERL_NIF_TERM f2e_beam_parse_structured(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  if (argc != 2) {
    return enif_make_badarg(env);
  }

  char *config_path = NULL;
  if (!f2e_beam_copy_term_string(env, argv[1], &config_path)) {
    return enif_make_badarg(env);
  }

  ERL_NIF_TERM result = f2e_beam_parse_structured_argv(env, argv[0], config_path);
  enif_free(config_path);
  return result;
}

static ERL_NIF_TERM f2e_beam_parse_structured_default(
    ErlNifEnv *env,
    int argc,
    const ERL_NIF_TERM argv[]) {
  if (argc != 1) {
    return enif_make_badarg(env);
  }

  return f2e_beam_parse_structured_argv(env, argv[0], NULL);
}


static int f2e_beam_copy_argv(
    ErlNifEnv *env,
    ERL_NIF_TERM argv_term,
    char ***items_out,
    unsigned int *count_out) {
  unsigned int list_len = 0;
  if (!enif_get_list_length(env, argv_term, &list_len)) {
    return 0;
  }

  char **items = (char **)enif_alloc(sizeof(char *) * list_len);
  if (!items && list_len > 0) {
    return 0;
  }
  if (list_len > 0) {
    memset(items, 0, sizeof(char *) * list_len);
  }

  ERL_NIF_TERM list = argv_term;
  for (unsigned int i = 0; i < list_len; i++) {
    ERL_NIF_TERM head;
    if (!enif_get_list_cell(env, list, &head, &list)
        || !f2e_beam_copy_term_string(env, head, &items[i])) {
      for (unsigned int j = 0; j < i; j++) {
        enif_free(items[j]);
      }
      enif_free(items);
      return 0;
    }
  }

  *items_out = items;
  *count_out = list_len;
  return 1;
}

static void f2e_beam_free_argv(char **items, unsigned int count) {
  if (!items) {
    return;
  }
  for (unsigned int i = 0; i < count; i++) {
    enif_free(items[i]);
  }
  enif_free(items);
}

static ERL_NIF_TERM f2e_beam_help_requested(
    ErlNifEnv *env,
    int argc,
    const ERL_NIF_TERM argv[]) {
  if (argc != 1) {
    return enif_make_badarg(env);
  }

  char **items = NULL;
  unsigned int count = 0;
  if (!f2e_beam_copy_argv(env, argv[0], &items, &count)) {
    return enif_make_badarg(env);
  }

  int requested = f2e_is_help_requested((int)count, (const char *const *)items);
  f2e_beam_free_argv(items, count);
  return enif_make_atom(env, requested ? "true" : "false");
}

static ERL_NIF_TERM f2e_beam_help_table_for_argv(
    ErlNifEnv *env,
    int argc,
    const ERL_NIF_TERM argv[]) {
  if (argc != 4) {
    return enif_make_badarg(env);
  }

  char **items = NULL;
  unsigned int count = 0;
  char *command_name = NULL;
  char *config_path = NULL;
  int columns = 0;

  if (!f2e_beam_copy_argv(env, argv[0], &items, &count)
      || !f2e_beam_copy_term_string(env, argv[1], &command_name)
      || !enif_get_int(env, argv[2], &columns)
      || !f2e_beam_copy_term_string(env, argv[3], &config_path)) {
    f2e_beam_free_argv(items, count);
    if (command_name) {
      enif_free(command_name);
    }
    if (config_path) {
      enif_free(config_path);
    }
    return enif_make_badarg(env);
  }

  char *table = f2e_help_table_for_argv_from_file(
      config_path,
      command_name,
      (int)count,
      (const char *const *)items,
      columns);

  f2e_beam_free_argv(items, count);
  enif_free(command_name);
  enif_free(config_path);
  return f2e_beam_owned_json_binary(env, table);
}

static ERL_NIF_TERM f2e_beam_audit_config(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  if (argc != 1) {
    return enif_make_badarg(env);
  }

  char *config_path = NULL;
  if (!f2e_beam_copy_term_string(env, argv[0], &config_path)) {
    return enif_make_badarg(env);
  }

  char *json = f2e_audit_config_from_file(config_path);
  enif_free(config_path);
  return f2e_beam_owned_json_binary(env, json);
}

static ERL_NIF_TERM f2e_beam_audit_config_default(
    ErlNifEnv *env,
    int argc,
    const ERL_NIF_TERM argv[]) {
  (void)argv;
  if (argc != 0) {
    return enif_make_badarg(env);
  }

  return f2e_beam_owned_json_binary(env, f2e_audit_config());
}

static ERL_NIF_TERM f2e_beam_audit_config_status(
    ErlNifEnv *env,
    int argc,
    const ERL_NIF_TERM argv[]) {
  if (argc != 1) {
    return enif_make_badarg(env);
  }

  char *config_path = NULL;
  if (!f2e_beam_copy_term_string(env, argv[0], &config_path)) {
    return enif_make_badarg(env);
  }

  int status = f2e_audit_config_status_from_file(config_path);
  enif_free(config_path);
  return enif_make_int(env, status);
}

static ERL_NIF_TERM f2e_beam_audit_config_status_default(
    ErlNifEnv *env,
    int argc,
    const ERL_NIF_TERM argv[]) {
  (void)argv;
  if (argc != 0) {
    return enif_make_badarg(env);
  }

  return enif_make_int(env, f2e_audit_config_status());
}

static ErlNifFunc f2e_beam_funcs[] = {
  {"parse_process", 0, f2e_beam_parse_process_default, 0},
  {"parse_process", 1, f2e_beam_parse_process, 0},
  {"parse", 1, f2e_beam_parse_default, 0},
  {"parse", 2, f2e_beam_parse, 0},
  {"parse_structured_json", 1, f2e_beam_parse_structured_default, 0},
  {"parse_structured_json", 2, f2e_beam_parse_structured, 0},
  {"help_requested", 1, f2e_beam_help_requested, 0},
  {"help_table_for_argv", 4, f2e_beam_help_table_for_argv, 0},
  {"audit_config_json", 0, f2e_beam_audit_config_default, 0},
  {"audit_config_json", 1, f2e_beam_audit_config, 0},
  {"audit_config_status", 0, f2e_beam_audit_config_status_default, 0},
  {"audit_config_status", 1, f2e_beam_audit_config_status, 0}
};

#ifdef F2E_BEAM_MODULE_NATIVE
ERL_NIF_INIT(flags2env_native, f2e_beam_funcs, NULL, NULL, NULL, NULL)
#else
ERL_NIF_INIT(flags2env, f2e_beam_funcs, NULL, NULL, NULL, NULL)
#endif
