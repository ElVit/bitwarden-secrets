FROM alpine:latest

ARG BW_CLI_VERSION=1.22.1

COPY run.sh /

RUN apk add --no-cache jq npm && \
    npm install --no-progress --no-audit -g @bitwarden/cli@${BW_CLI_VERSION} && \
    chmod +x run.sh

CMD [ "/run.sh" ]

LABEL \
    maintainer="ElVit (https://github.com/ElVit)" \
    org.opencontainers.image.authors="ElVit (https://github.com/ElVit)" \
    org.opencontainers.image.licenses="MIT" \
    org.opencontainers.image.url="https://github.com/ElVit" \
