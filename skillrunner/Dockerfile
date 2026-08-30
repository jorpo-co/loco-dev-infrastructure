FROM docker:dind

ENV INFRA_DIR=/infra
ENV PROJECTS_DIR=/projects
ENV DOCKER_HOST=unix:///var/run/docker.sock

# Install tooling
RUN apk add --no-cache python3 curl bash py3-yaml just

# Install kind
ARG KIND_VERSION=v0.27.0
RUN curl -fsSLo /usr/local/bin/kind \
    "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-amd64" && \
    chmod +x /usr/local/bin/kind

# Install kubectl
RUN curl -fsSL \
    "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" \
    -o /usr/local/bin/kubectl && \
    chmod +x /usr/local/bin/kubectl

# Install mkcert (single Go binary, Alpine-compatible)
ARG MKCERT_VERSION=v1.4.4
RUN curl -fsSLo /usr/local/bin/mkcert \
    "https://github.com/FiloSottile/mkcert/releases/download/${MKCERT_VERSION}/mkcert-${MKCERT_VERSION}-linux-amd64" && \
    chmod +x /usr/local/bin/mkcert

# HTTP API server + project module
# NOTE: At runtime, the compose.yml copies these from /infra/skillrunner/ to /
# so the volume-mounted copies take precedence over the baked-in ones.
COPY server.py projects.py /

EXPOSE 8080
CMD ["python3", "/server.py"]
