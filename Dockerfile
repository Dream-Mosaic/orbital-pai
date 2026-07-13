# Find eligible builder and runner images on Docker Hub. We use Ubuntu/Debian
# instead of Alpine to avoid DNS resolution issues in production.
#
# https://hub.docker.com/r/hexpm/elixir/tags?name=ubuntu
# https://hub.docker.com/_/ubuntu/tags
#
# This file is based on these images:
#
#   - https://hub.docker.com/r/hexpm/elixir/tags - for the build image
#   - https://hub.docker.com/_/debian/tags?name=trixie-20260610-slim - for the release image
#   - https://pkgs.org/ - resource for finding needed packages
#   - Ex: docker.io/hexpm/elixir:1.19.5-erlang-28.3.2-debian-trixie-20260610-slim
#
ARG ELIXIR_VERSION=1.19.5
ARG OTP_VERSION=28.3.2
ARG DEBIAN_VERSION=trixie-20260610-slim

ARG BUILDER_IMAGE="docker.io/hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="docker.io/debian:${DEBIAN_VERSION}"

FROM ${BUILDER_IMAGE} AS builder

# install build dependencies
# nodejs + npm are needed by the assets pipeline: `mix assets.setup` runs
# `npm install --prefix assets` (the JS the esbuild bundle imports).
RUN apt-get update \
  && apt-get install -y --no-install-recommends build-essential git nodejs npm curl ca-certificates \
  && rm -rf /var/lib/apt/lists/*

# Rust toolchain — the Ortex speaker-embedding NIF (Voice Lock) is a `rustler` crate compiled
# from source during `mix deps.compile`. EXLA's C++ NIF uses build-essential's g++ (already above).
# Installed via rustup for a modern, complete stable toolchain; cargo goes on PATH for mix.
ENV RUSTUP_HOME=/opt/rustup \
    CARGO_HOME=/opt/cargo \
    PATH=/opt/cargo/bin:$PATH
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
      | sh -s -- -y --profile minimal --default-toolchain stable \
  && rustc --version && cargo --version

# prepare build dir
WORKDIR /app

# install hex + rebar
RUN mix local.hex --force \
  && mix local.rebar --force

# set build ENV
ENV MIX_ENV="prod"

# install mix dependencies
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

# copy compile-time config files before we compile dependencies
# to ensure any relevant config change will trigger the dependencies
# to be re-compiled.
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

# Copy assets BEFORE assets.setup: this project's `assets.setup` runs
# `npm install --prefix assets`, which needs assets/package.json present.
COPY assets assets
RUN mix assets.setup

COPY priv priv

COPY lib lib

# Compile the release
RUN mix compile

# compile assets (tailwind + esbuild + digest)
RUN mix assets.deploy

# Changes to config/runtime.exs don't require recompiling the code
COPY config/runtime.exs config/

COPY rel rel
RUN mix release

# start a new build stage so that the final image will only contain
# the compiled release and other runtime necessities
FROM ${RUNNER_IMAGE} AS final

RUN apt-get update \
  && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 locales ca-certificates curl \
  && rm -rf /var/lib/apt/lists/*

# Voice Lock speaker-embedding model — baked into the image. It's gitignored + ~25MB, so it is NOT in
# the git checkout Coolify builds from; without this the container boots "model unavailable" and Voice
# Lock fails open (never verifies). Own layer above the release COPY so it caches across code changes;
# checksum-verified so a partial/corrupt download fails the build loudly instead of shipping a bad model.
ARG SPEAKER_MODEL_URL="https://huggingface.co/Wespeaker/wespeaker-ecapa-tdnn512-LM/resolve/main/voxceleb_ECAPA512_LM.onnx"
ARG SPEAKER_MODEL_SHA256="d71b85d9b48058ef68004f04f1b78acebefb9dfcf542e19b976a12a5ad1f10b0"
RUN mkdir -p /app/models \
  && curl -fL --retry 3 -o /app/models/speaker_ecapa.onnx "$SPEAKER_MODEL_URL" \
  && echo "${SPEAKER_MODEL_SHA256}  /app/models/speaker_ecapa.onnx" | sha256sum -c -
ENV SPEAKER_MODEL_PATH=/app/models/speaker_ecapa.onnx

# Prefer IPv4 in glibc name resolution. The deploy host has no working IPv6 egress, so resolving
# AAAA-first makes the BEAM stall on unreachable IPv6 for every outbound call (Google OAuth, Gemini,
# Cartesia). Raising IPv4-mapped precedence makes getaddrinfo hand back IPv4 first.
RUN printf 'precedence ::ffff:0:0/96  100\n' >> /etc/gai.conf

# Set the locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
  && locale-gen

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

WORKDIR "/app"
RUN chown nobody /app

# set runner ENV
ENV MIX_ENV="prod"

# Only copy the final release from the build stage
COPY --from=builder --chown=nobody:root /app/_build/${MIX_ENV}/rel/app ./

# NOTE: we intentionally run as root (no `USER nobody`). The SQLite DB lives on a Coolify
# persistent volume, bind-mounted root-owned; running as `nobody` would fail to create/write
# app.db. Acceptable for this single-tenant, auth-gated home app — harden with gosu (chown the
# volume, then drop privileges) later if desired.

RUN chmod +x /app/bin/docker-entrypoint.sh

# Ensure the DB volume dir exists, run migrations, then start the server.
CMD ["/app/bin/docker-entrypoint.sh"]
