FROM alpine:latest

ARG BW_CLI_VERSION=1.22.1

# Install dependencies
RUN apk add --no-cache jq npm
# Verify installation
RUN jq --version && npm --version
# Install Bitwarden CLI
RUN npm install --no-progress --no-audit -g @bitwarden/cli@${BW_CLI_VERSION}
# Verify Bitwarden CLI installation
RUN bw --version 
# Copy and set permissions for the script
COPY entrypoint.sh /app/entrypoint.sh
RUN ls -l /app && chmod +x /app/entrypoint.sh

ENTRYPOINT [ "/app/entrypoint.sh" ]

LABEL \
    maintainer="ElVit (https://github.com/ElVit)" \
    org.opencontainers.image.authors="ElVit (https://github.com/ElVit)" \
    org.opencontainers.image.licenses="MIT" \
    org.opencontainers.image.url="https://github.com/ElVit" \
