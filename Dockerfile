# Build the site with a pinned Hugo, so only sources are committed.
FROM ghcr.io/gohugoio/hugo:v0.168.0 AS build
COPY --chown=hugo:hugo hugo/ /project/
RUN hugo

# Serve it with nginx running as a non-root user on port 8080.
FROM nginxinc/nginx-unprivileged:1.31.7-alpine
COPY --from=build /project/public/ /usr/share/nginx/html/
