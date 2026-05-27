# syntax=docker/dockerfile:1.7
#
# Distroless PostgreSQL image for CloudNativePG.
#
# Three stages:
#   builder    — compiles PostgreSQL with the meson flag set from docker-bake.hcl.
#   collector  — assembles the final filesystem in /rootfs (binaries, ldd-resolved
#                shared libraries, dynamic loader, tzdata, NSS modules, baked /etc).
#   final      — FROM scratch; only /rootfs.
#
# No ENTRYPOINT / CMD — CNPG's instance manager invokes binaries directly.

ARG DEBIAN_BASE=debian:trixie-slim

# -----------------------------------------------------------------------------
# Stage A: builder
# -----------------------------------------------------------------------------
FROM ${DEBIAN_BASE} AS builder

ARG PG_VERSION
ARG PG_TARBALL_SHA256
ARG PG_MAJOR
ARG MESON_FLAGS

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        meson \
        ninja-build \
        make \
        gcc \
        g++ \
        pkg-config \
        bison \
        flex \
        perl \
        python3 \
        libssl-dev \
        libicu-dev \
        liblz4-dev \
        libzstd-dev \
        zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src

RUN set -eux; \
    : "${PG_VERSION:?PG_VERSION is required}"; \
    : "${PG_MAJOR:?PG_MAJOR is required}"; \
    : "${PG_TARBALL_SHA256:?PG_TARBALL_SHA256 is required}"; \
    curl -fsSL "https://ftp.postgresql.org/pub/source/v${PG_VERSION}/postgresql-${PG_VERSION}.tar.gz" \
        -o postgresql.tar.gz; \
    echo "${PG_TARBALL_SHA256}  postgresql.tar.gz" | sha256sum -c -; \
    tar -xzf postgresql.tar.gz --strip-components=1; \
    rm postgresql.tar.gz

# PGDG-style install layout:
# /usr/lib/postgresql/${PG_MAJOR}/{bin,lib} + /usr/share/postgresql/${PG_MAJOR}.
# meson's --libdir/--datadir are relative to --prefix.
# PostgreSQL 16 release tarballs include generated files that Meson rejects;
# maintainer-clean restores the clean source tree Meson expects.
RUN set -eux; \
    if [ "${PG_MAJOR}" = "16" ]; then \
        ./configure \
            --without-readline \
            --with-ssl=openssl \
            --with-icu \
            --with-lz4 \
            --with-zstd; \
        make maintainer-clean; \
    fi; \
    meson setup build \
        --prefix=/usr \
        --bindir=lib/postgresql/${PG_MAJOR}/bin \
        --libdir=lib/postgresql/${PG_MAJOR}/lib \
        --datadir=share/postgresql/${PG_MAJOR} \
        --includedir=include/postgresql/${PG_MAJOR} \
        --sysconfdir=/etc/postgresql \
        --buildtype=release \
        --strip \
        ${MESON_FLAGS}; \
    ninja -C build; \
    DESTDIR=/out ninja -C build install

# -----------------------------------------------------------------------------
# Stage B: collector
# -----------------------------------------------------------------------------
FROM ${DEBIAN_BASE} AS collector

ARG PG_MAJOR

RUN apt-get update && apt-get install -y --no-install-recommends \
        file binutils \
        libssl3 libicu76 liblz4-1 libzstd1 zlib1g \
        tzdata \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /out /out
COPY rootfs/ /rootfs-static/
COPY scripts/collect-rootfs.sh /usr/local/bin/collect-rootfs

RUN /usr/local/bin/collect-rootfs

# -----------------------------------------------------------------------------
# Stage C: final
# -----------------------------------------------------------------------------
FROM scratch

ARG PG_MAJOR

COPY --from=collector /rootfs/ /

USER 26:26
WORKDIR /var/lib/postgresql

ENV PATH=/usr/lib/postgresql/${PG_MAJOR}/bin
ENV PGDATA=/var/lib/postgresql/data
