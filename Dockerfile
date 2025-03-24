FROM alpine:latest

ARG BW_CLI_VERSION=1.22.1

# Install dependencies
RUN apk add --no-cache jq npm bash
# Verify installation
RUN jq --version && npm --version && bash --version
# Install Bitwarden CLI
RUN npm install --no-progress --no-audit -g @bitwarden/cli@${BW_CLI_VERSION}
# Verify Bitwarden CLI installation
RUN bw --version 
# Copy and set permissions for the script
COPY entrypoint.sh /app/entrypoint.sh
RUN ls -l /app && chmod +x /app/entrypoint.sh

ENTRYPOINT [ "/app/entrypoint.sh" ]

# Build arugments
ARG BUILD_DATE
ARG BUILD_REF
ARG BUILD_VERSION
ARG BUILD_REPOSITORY

LABEL \
    maintainer="ElVit <https://github.com/ElVit>" \
    org.opencontainers.image.title="bitwarden secrets" \
    org.opencontainers.image.description="bitwarden secrets docker image" \
    org.opencontainers.image.vendor="ElVit" \
    org.opencontainers.image.authors="ElVit <https://github.com/ElVit>" \
    org.opencontainers.image.licenses="MIT" \
    org.opencontainers.image.url="https://github.com/ElVit/bitwarden-secrets" \
    org.opencontainers.image.source="https://github.com/${BUILD_REPOSITORY}" \
    org.opencontainers.image.documentation="https://github.com/${BUILD_REPOSITORY}/blob/main/README.md" \
    org.opencontainers.image.created=${BUILD_DATE} \
    org.opencontainers.image.revision=${BUILD_REF} \
    org.opencontainers.image.version=${BUILD_VERSION}
