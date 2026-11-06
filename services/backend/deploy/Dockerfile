FROM rust:1.99.0-trixie@sha256:81015672d6939b0265f09adf96d5de125482bb1330106076956b0518e74edc90 AS build
WORKDIR /src
COPY . .
RUN cargo build --manifest-path services/backend/Cargo.toml --release --locked

FROM python:3.14-slim-trixie@sha256:cd89c30eda26ee911a4611b18680086e0ea42e6f5f8cbe653d07fa7958c9cec8
COPY --from=build /src/services/backend/target/release/agentty-backend /usr/local/bin/agentty-backend
COPY services/backend/deploy/entrypoint /usr/local/bin/agentty-entrypoint
USER 65534:65534
ENTRYPOINT ["/usr/local/bin/agentty-entrypoint"]
