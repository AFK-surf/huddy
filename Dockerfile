# syntax=docker/dockerfile:1
# Build: docker build -t huddy .
# Run:   see docker-compose.yml, or
#        docker run -p 8080:8080 -v huddy-data:/var/lib/huddy \
#          -v $PWD/huddy.json:/etc/huddy/huddy.json:ro -e HUDDY_SECRET_KEY=... huddy
#
# Offline / restricted builds:
# - GLEAM_SOURCE=context takes the gleam binary from a build context named
#   `gleam` instead of GitHub:  --build-arg GLEAM_SOURCE=context \
#                                --build-context gleam=/path/to/dir-with-gleam
# - Behind a TLS-intercepting proxy, pass its CA as a build secret:
#   --secret id=extra_ca,src=/path/to/ca.crt

ARG OTP_VERSION=29.0.6
ARG GLEAM_VERSION=1.19.1
ARG GLEAM_SOURCE=github

FROM erlang:${OTP_VERSION} AS gleam-github
ARG GLEAM_VERSION
RUN set -eux; \
    curl -fsSL "https://github.com/gleam-lang/gleam/releases/download/v${GLEAM_VERSION}/gleam-v${GLEAM_VERSION}-$(uname -m)-unknown-linux-musl.tar.gz" \
      | tar xz -C /usr/local/bin gleam

FROM erlang:${OTP_VERSION} AS gleam-context
COPY --from=gleam gleam /usr/local/bin/gleam

FROM gleam-${GLEAM_SOURCE} AS build
RUN --mount=type=secret,id=extra_ca,required=false \
    if [ -s /run/secrets/extra_ca ]; then \
      cp /run/secrets/extra_ca /usr/local/share/ca-certificates/extra-ca.crt \
      && update-ca-certificates; \
    fi; \
    gleam --version
WORKDIR /src
COPY gleam.toml manifest.toml ./
RUN gleam deps download
COPY src ./src
COPY priv ./priv
RUN gleam export erlang-shipment

FROM erlang:${OTP_VERSION}-slim
RUN useradd --system --home /var/lib/huddy --create-home huddy \
    && mkdir -p /etc/huddy && chown huddy /var/lib/huddy
COPY --from=build /src/build/erlang-shipment /app
USER huddy
VOLUME ["/var/lib/huddy"]
EXPOSE 8080
ENTRYPOINT ["/app/entrypoint.sh", "run"]
CMD ["--config", "/etc/huddy/huddy.json"]
