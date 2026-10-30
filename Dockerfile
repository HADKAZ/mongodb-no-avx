# MongoDB without AVX for use with Omada Controller
# Based on https://github.com/alanedwardes/mongodb-without-avx
# Updated for MongoDB 9.x with SCons build system

FROM debian:12 AS build

# Install build dependencies for MongoDB 7.x with SCons
RUN apt-get update -y && apt-get install -y \
        build-essential \
        libcurl4-openssl-dev \
        liblzma-dev \
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

# Apply the no-AVX patch to disable sandybridge/AVX optimizations
# The patch modifies SConstruct to remove sandybridge from the default
# experimental optimizations, so MongoDB uses a generic x86-64 baseline
COPY ./no_avx_patch.diff /no_avx_patch.diff
RUN patch -p1 < /no_avx_patch.diff

# Apply mozjs (SpiderMonkey JS engine) patch to remove AVX2 requirement
# This patch:
# 1. Removes -mavx2 compiler flag from mozjs SConscript
# 2. Removes SIMD_avx2.cpp from the build (keeps only SSE.cpp)
# 3. Disables AVX2 support check in SIMD.cpp
# Without this, mongod crashes with SIGILL (exit code 132) on non-AVX2 CPUs
# Patch from: https://github.com/GermanAizek/mongodb-without-avx/issues/16
COPY ./mozjs-noavx.patch /mozjs-noavx.patch
RUN patch -p1 < /mozjs-noavx.patch

ARG NUM_JOBS=

# Install Python build dependencies
# MongoDB 7.x requires specific Python packages for the SCons build
RUN export GIT_PYTHON_REFRESH=quiet && \
    python3 -m pip install requirements_parser --break-system-packages && \
    python3 -m pip install -r etc/pip/compile-requirements.txt --break-system-packages

# Build MongoDB using SCons
# --release: Build release binaries (optimized)
# --disable-warnings-as-errors: Ignore compiler warnings that would fail build
# install-mongod: Build only mongod (server) - lighter than install-devcore
# install-mongos: Build mongos (router) for sharding support
RUN if [ -n "${NUM_JOBS}" ] && [ "${NUM_JOBS}" -gt 0 ]; then \
        export JOBS_ARG="-j ${NUM_JOBS}"; \
    fi && \
    python3 buildscripts/scons.py install-mongod install-mongos \
        MONGO_VERSION="${MONGO_VERSION}" \
        --release \
        --disable-warnings-as-errors \
        ${JOBS_ARG} && \
    mv build/install /install

# Strip debug symbols to reduce binary size significantly
RUN strip --strip-debug /install/bin/mongod && \
    strip --strip-debug /install/bin/mongos

# Clean up build artifacts to reduce layer size
RUN rm -rf build

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
