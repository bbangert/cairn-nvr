# Optional container build. ffmpeg is required at runtime; plugins bring
# their own runtimes (mount them in and reference from config.yml).
ARG ELIXIR_VERSION=1.20.2
ARG OTP_VERSION=29.0.3
ARG DEBIAN_VERSION=bookworm-20250908-slim

FROM hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION} AS build

RUN apt-get update -y && apt-get install -y build-essential git \
  && apt-get clean && rm -f /var/lib/apt/lists/*_*

WORKDIR /app
ENV MIX_ENV=prod

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
COPY config config
RUN mix deps.compile

COPY priv priv
COPY lib lib
COPY assets assets
RUN mix assets.setup && mix assets.deploy
RUN mix compile && mix release

FROM debian:bookworm-slim AS runtime

RUN apt-get update -y \
  && apt-get install -y ffmpeg libstdc++6 openssl libncurses6 locales ca-certificates \
  && apt-get clean && rm -f /var/lib/apt/lists/*_* \
  && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8
ENV PHX_SERVER=true CAIRN_DATA_DIR=/data CAIRN_CONFIG=/config/config.yml

WORKDIR /app
COPY --from=build /app/_build/prod/rel/cairn ./

VOLUME ["/data", "/config"]
EXPOSE 4000
# UDP plugin/RTP ports are loopback-internal; no need to expose

CMD ["bin/cairn", "start"]
