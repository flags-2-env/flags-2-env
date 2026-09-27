FROM ghcr.io/gleam-lang/gleam:v1.14.0-erlang

WORKDIR /repo
COPY clients/gleam ./clients/gleam
COPY clients/erlang ./clients/erlang

RUN apt-get update && apt-get install -y --no-install-recommends build-essential make && rm -rf /var/lib/apt/lists/*
RUN mkdir -p /tmp/beam/ebin /tmp/beam/priv /tmp/gleam/src /tmp/erlang_libs/flags2env_native/ebin /tmp/erlang_libs/flags2env_native/priv
RUN erlc -o /tmp/beam/ebin clients/gleam/src/flags2env_native.erl && cp /tmp/beam/ebin/flags2env_native.beam /tmp/erlang_libs/flags2env_native/ebin/
RUN ERL_INCLUDE="$(erl -noshell -eval 'io:format("~s/erts-~s/include", [code:root_dir(), erlang:system_info(version)]), halt().')" && \
  cc -std=c99 -DF2E_BEAM_MODULE_NATIVE -fPIC -shared -I"$ERL_INCLUDE" -Iclients/erlang/c_src clients/erlang/c_src/flags2env_nif.c clients/erlang/c_src/parser.c -o /tmp/beam/priv/flags2env_nif.so && \
  cp /tmp/beam/priv/flags2env_nif.so /tmp/erlang_libs/flags2env_native/priv/
RUN cp clients/gleam/src/flags2env.gleam /tmp/gleam/src/flags2env.gleam && cp clients/gleam/test.gleam /tmp/gleam/src/main.gleam
RUN printf '%s\n' '[flags.port]' 'env = "PORT"' 'aliases = ["port"]' 'type = "integer"' 'default = 3000' '' '[flags.debug]' 'env = "DEBUG"' 'aliases = ["debug"]' 'type = "bool"' 'true_aliases = ["t"]' 'false_aliases = ["f"]' > /tmp/gleam/.cli-flags.toml
RUN printf 'name = "flags2env_test"\nversion = "1.0.0"\n\n[dependencies]\ngleam_stdlib = ">= 0.34.0 and < 2.0.0"\n' > /tmp/gleam/gleam.toml
RUN cd /tmp/gleam && gleam deps download
RUN useradd --create-home --shell /bin/sh flags2env && \
  mkdir -p /tmp/flags2env-cache && \
  chown -R flags2env:flags2env /repo /tmp/beam /tmp/gleam /tmp/erlang_libs /tmp/flags2env-cache

ENV HOME=/home/flags2env
ENV XDG_CACHE_HOME=/tmp/flags2env-cache
USER flags2env

CMD cd /tmp/gleam && ERL_LIBS="/tmp/erlang_libs" ERL_FLAGS="-pa /tmp/beam/ebin" gleam run -m main
