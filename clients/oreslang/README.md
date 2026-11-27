# flags-2-env for Oreslang: native C ABI

This binding exports the **canonical** flags-2-env C parser, not a fork or
subprocess parser, as an ownership-explicit UTF-8 ABI:

`f2e_oreslang_parse_json(argv_json)`,
`f2e_oreslang_parse_json_file(config_path, argv_json)`,
`f2e_oreslang_version()`,
`f2e_oreslang_free(ptr)`.

Arguments are JSON-encoded string arrays. Results are heap-owned UTF-8 JSON.
Foreign callers must copy result bytes and call `f2e_oreslang_free` exactly once;
never call system `free` from another runtime.

Run `make oreslang-abi-test` and `make oreslang-abi-shared`.

**Integration status:** these symbols are callable from an Oreslang host's
C/JNI/FFM adapter. The language-level `flags2env.parse()` facade still
requires an explicit Oreslang runtime binding and permission enforcement.
The ABI alone is **not** a demonstrated language-level invocation.
