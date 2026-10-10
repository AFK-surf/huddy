# syntax=docker/dockerfile:1
# Build: docker build -t huddy .
# Run:   docker run -p 8080:8080 -v huddy-data:/var/lib/huddy \
#          -v $PWD/huddy.json:/etc/huddy/huddy.json:ro \
#          -e HUDDY_SECRET_KEY=... huddy

ARG OTP_VERSION=29.0.6
ARG GLEAM_VERSION=1.19.1

FROM erlang:${OTP_VERSION} AS build
ARG GLEAM_VERSION
RUN set -eux; \
    arch="$(uname -m)"; \
    curl -fsSL "https://github.com/gleam-lang/gleam/releases/download/v${GLEAM_VERSION}/gleam-v${GLEAM_VERSION}-${arch}-unknown-linux-musl.tar.gz" \
      | tar xz -C /usr/local/bin gleam; \
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
