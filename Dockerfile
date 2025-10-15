FROM alpine:latest

LABEL maintainer="buxxdev"
LABEL description="ContainerNetwork AutoFix (CNAF) - Automatically recreates dependent containers when master container restarts"
LABEL version="1.0.0"

# Install required packages
RUN apk add --no-cache bash docker-cli

# Create app directory
WORKDIR /app

# Copy the script
COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

# Run the script
ENTRYPOINT ["/app/entrypoint.sh"]
