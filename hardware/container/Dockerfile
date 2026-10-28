# neond in a container, for hotspots and servers that are not set up from the SD image or setup.sh:
# units that run containers only, or whose own packet forwarder stays (it sends to neond over the
# Semtech UDP protocol, port 1700), and electrodes on ordinary servers. docs/INSTALL.md "Container".
#
# Build from the repository's root (the context needs only the release keys and the fetch script):
#   docker build -f hardware/container/Dockerfile -t neond .
#   docker build -f hardware/container/Dockerfile --build-arg NEON_VERSION=0.4.136 -t neond:0.4.136 .
# The binary is the signed release for this machine's architecture (arm64 or x86_64), checked against
# hardware/release-keys.txt at build time: nothing is compiled here.

FROM debian:bookworm-slim AS fetch
ARG NEON_VERSION=latest
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl openssl \
    && rm -rf /var/lib/apt/lists/*
COPY hardware/release-keys.txt hardware/container/fetch-release.sh /tmp/
RUN sh /tmp/fetch-release.sh /tmp/release-keys.txt /usr/local/bin/neond "$NEON_VERSION"

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=fetch /usr/local/bin/neond /usr/local/bin/neond
# Settings (neond.toml, written by the panel's first-run setup), the station key and every other
# state file: keep this volume, it is the atom's identity.
VOLUME /opt/neon
ENV RUST_LOG=info
# The panel (8080), the Semtech UDP packets from the forwarder (1700), the Plasma (4001).
EXPOSE 8080/tcp 1700/udp 4001/tcp
ENTRYPOINT ["/usr/local/bin/neond"]
# Updates come with a new image (the panel's updater would change only this container's copy).
# neond restarts itself by exiting after a settings change: run it with a restart policy
# (--restart unless-stopped).
CMD ["--web", "0.0.0.0:8080", "--listen", "0.0.0.0:1700", "--no-updates"]
