# syntax=docker/dockerfile:1
#
# Multi-arch image: the same Dockerfile is built for linux/amd64 and linux/arm64 by the workflow.
# The base image tag comes from a build argument, so it is changed in one place (or by Dependabot).
ARG PYTHON_IMAGE=python:3.14-alpine

FROM ${PYTHON_IMAGE}

# Set by the workflow to the git commit, shown by the app at GET /
ARG APP_VERSION=dev

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    APP_VERSION=${APP_VERSION} \
    PORT=8080

WORKDIR /srv

# Run as a normal user, never as root.
RUN addgroup -S -g 10001 app && adduser -S -u 10001 -G app -H -s /sbin/nologin app

COPY --chown=root:root app/ ./app/

# A numeric user lets Kubernetes "runAsNonRoot" check it without reading /etc/passwd.
USER 10001:10001
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD ["python", "-c", "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8080/health', timeout=2).status == 200 else 1)"]

CMD ["python", "-m", "app.main"]
