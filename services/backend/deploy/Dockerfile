FROM rust:1.97.0-trixie@sha256:b92b8c8574f8f3b207fcb0912fb3e2de4041580b5934d90312d53938c9a038a9 AS build
WORKDIR /src
COPY . .
RUN cargo build --manifest-path services/backend/Cargo.toml --release --locked

FROM python:3.14-slim-trixie@sha256:cd89c30eda26ee911a4611b18680086e0ea42e6f5f8cbe653d07fa7958c9cec8
COPY --from=build /src/services/backend/target/release/agentty-backend /usr/local/bin/agentty-backend
COPY services/backend/deploy/entrypoint /usr/local/bin/agentty-entrypoint
USER 65534:65534
ENTRYPOINT ["/usr/local/bin/agentty-entrypoint"]
