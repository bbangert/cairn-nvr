FROM mcr.microsoft.com/devcontainers/base:bookworm

# - build-essential/autoconf/m4/libssl/ncurses: kerl builds Erlang from source
# - ffmpeg: ingest/probe/snapshots (the test suite drives the real binaries)
# - inotify-tools: Phoenix live reload
# - sqlite3: poke the event index by hand
# - python3 + venv: the CPU reference plugin
RUN apt-get update -qq && export DEBIAN_FRONTEND=noninteractive \
  && apt-get install -y -qq --no-install-recommends \
    build-essential autoconf m4 libssl-dev libncurses-dev \
    ffmpeg inotify-tools sqlite3 \
    python3 python3-venv python3-pip \
    curl git unzip ca-certificates \
  && rm -rf /var/lib/apt/lists/*

USER vscode

# mise manages Erlang/Elixir from the repo's mise.toml
RUN curl -fsSL https://mise.run | sh \
  && echo 'eval "$(~/.local/bin/mise activate bash)"' >> ~/.bashrc \
  && echo 'eval "$(~/.local/bin/mise activate zsh)"' >> ~/.zshrc
