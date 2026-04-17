# Derived image: upstream OpenClaw + lsof pre-installed.
# Built once by install.sh and rebuilt by openclaw-new --pull / openclaw-update.
# Eliminates the ~10s apt-get install tax on every container recreate.
FROM ghcr.io/openclaw/openclaw:latest
USER root
RUN apt-get update -qq \
 && apt-get install -y --no-install-recommends lsof \
 && rm -rf /var/lib/apt/lists/*
USER node
