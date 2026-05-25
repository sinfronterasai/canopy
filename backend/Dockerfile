# STEP 1: Build the Elixir Release
FROM hexpm/elixir:1.15.7-erlang-26.1.2-debian-bookworm-slim AS build

# install build dependencies
RUN apt-get update -y && apt-get install -y build-essential git \
    && apt-get clean && rm -f /var/lib/apt/lists/*_*

# prepare build dir
WORKDIR /app

# install hex + rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# set build ENV
ENV MIX_ENV="prod"

# install mix dependencies
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mix deps.compile

# copy compile-time config files before compiling dependencies
COPY config/config.exs config/prod.exs config/
COPY config/runtime.exs config/

# compile assets/code
COPY lib lib
COPY priv priv

RUN mix compile

# Compile release
RUN mix release

# STEP 2: Minimal Runner Image
FROM debian:bookworm-slim AS runner

RUN apt-get update -y && \
    apt-get install -y libstdc++6 openssl libssl-dev ca-certificates locales \
    && apt-get clean && rm -f /var/lib/apt/lists/*_*

# Set the locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

WORKDIR "/app"
RUN chown nobody /app

# Only copy the release build from the builder image
COPY --from=build --chown=nobody:root /app/_build/prod/rel/canopy ./

USER nobody

# Set environment variables
ENV PORT=9089
ENV PHX_SERVER=true

CMD ["sh", "-c", "/app/bin/canopy eval 'Canopy.Release.migrate' && /app/bin/canopy start"]
