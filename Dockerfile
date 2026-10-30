# MongoDB without AVX for use with Omada Controller
# Based on https://github.com/alanedwardes/mongodb-without-avx
# Updated for MongoDB 9.x with the Bazel build system

FROM debian:12 AS build

# Install build dependencies for MongoDB with Bazel
RUN apt-get update -y && apt-get install -y \
        build-essential \
        libcurl4-openssl-dev \
        liblzma-dev \
        libncurses6 \
        libssl-dev \
        python-dev-is-python3 \
        python3-pip \
        python3-venv \
        lld \
        curl \
        git \
        pkg-config \
    && rm -rf /var/lib/apt/lists/*

ARG MONGO_VERSION=9.0.4

# Download MongoDB source
RUN mkdir /src && \
    curl -o /tmp/mongo.tar.gz -L "https://github.com/mongodb/mongo/archive/refs/tags/r${MONGO_VERSION}.tar.gz" && \
    tar xaf /tmp/mongo.tar.gz --strip-components=1 -C /src && \
    rm /tmp/mongo.tar.gz

WORKDIR /src

# Apply the no-AVX patch (single unified diff, see no_avx_patch.diff):
# 1. Toolchain: -march=sandybridge -> -march=nehalem (no AVX)
# 2. mozjs: drop -mavx2 and SIMD_avx2.cpp from the Bazel build
# 3. mozjs: SIMD.cpp never reports AVX2 support (avoids SIGILL on non-AVX2 CPUs)
COPY ./no_avx_patch.diff /no_avx_patch.diff
RUN patch -p1 < /no_avx_patch.diff

ARG NUM_JOBS=

# Install Bazel (bazelisk, pinned by .bazelversion) and build mongod + mongos
# install-core: only mongod and mongos
RUN python3 buildscripts/install_bazel.py && \
    export PATH="$HOME/.local/bin:$PATH" && \
    if [ -n "${NUM_JOBS}" ] && [ "${NUM_JOBS}" -gt 0 ]; then \
        export JOBS_ARG="--jobs=${NUM_JOBS}"; \
    fi && \
    bazel build install-core \
        --disable_warnings_as_errors=True \
        ${JOBS_ARG} && \
    cp -rL bazel-bin/install /install

# Strip debug symbols to reduce binary size significantly
RUN strip --strip-debug /install/bin/mongod && \
    strip --strip-debug /install/bin/mongos

# Final image
FROM debian:12-slim

# OCI labels for GitHub Container Registry
LABEL org.opencontainers.image.source=https://github.com/fenio/mongodb-no-avx
LABEL org.opencontainers.image.description="MongoDB 9.0 compiled without AVX/AVX2 CPU requirements"
LABEL org.opencontainers.image.licenses=MIT

# Install runtime dependencies
RUN apt-get update -y && \
    apt-get install -y --no-install-recommends \
        libcurl4 \
        libssl3 \
        liblzma5 \
        ca-certificates \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Copy MongoDB binaries
COPY --from=build /install/bin/mongod /usr/local/bin/
COPY --from=build /install/bin/mongos /usr/local/bin/

# Create data directory with proper permissions
RUN mkdir -p /data/db /data/configdb && \
    chmod -R 750 /data && \
    chown -R 999:999 /data

# Create mongodb user
RUN groupadd -r mongodb --gid=999 && \
    useradd -r -g mongodb --uid=999 mongodb

# Set volume for data persistence
VOLUME ["/data/db", "/data/configdb"]

# Expose MongoDB default port
EXPOSE 27017

USER mongodb

ENTRYPOINT ["/usr/local/bin/mongod"]
CMD ["--bind_ip_all"]
