#include <jni.h>
#include "abi.h"
#include <stdlib.h>
#include <string.h>

/* Java 25 host binding: copy UTF-8 bytes across both ownership boundaries. */
static char *copy_input(JNIEnv *env, jbyteArray value) {
  if (!value) return NULL;
  jsize len = (*env)->GetArrayLength(env, value);
  if (len <= 0 || len > (1 << 20)) return NULL;
  char *buffer = (char *)malloc((size_t)len + 1);
  if (!buffer) return NULL;
  (*env)->GetByteArrayRegion(env, value, 0, len, (jbyte *)buffer);
  if ((*env)->ExceptionCheck(env)) { free(buffer); return NULL; }
  if (memchr(buffer, 0, (size_t)len)) { free(buffer); return NULL; }
  buffer[len] = 0;
  return buffer;
}

JNIEXPORT jbyteArray JNICALL
Java_dev_oreslang_runtime_Flags2EnvNative_parseFileBytes(
  JNIEnv *env, jclass type, jbyteArray config_bytes, jbyteArray argv_bytes) {
  (void)type;
  char *config = copy_input(env, config_bytes);
  char *argv = copy_input(env, argv_bytes);
  if (!config || !argv) { free(config); free(argv); return NULL; }
  char *json = f2e_oreslang_parse_json_file(config, argv);
  free(config);
  free(argv);
  if (!json) return NULL;
  size_t len = strlen(json);
  if (len > 16777216) { f2e_oreslang_free(json); return NULL; }
  jbyteArray out = (*env)->NewByteArray(env, (jsize)len);
  if (out) (*env)->SetByteArrayRegion(env, out, 0, (jsize)len, (jbyte *)json);
  f2e_oreslang_free(json);
  return out;
}
