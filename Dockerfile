FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

# Buildroot + Wazuh deps (Ubuntu 24.04: no python3-distutils)
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl wget git \
    build-essential gawk bison flex gettext \
    perl python3 python3-venv python3-setuptools \
    pkg-config file rsync unzip xz-utils \
    cpio bc \
    patch sed \
    libssl-dev zlib1g-dev \
 && rm -rf /var/lib/apt/lists/*

# Create unprivileged user (NO fixed UID) and writable workspace
RUN useradd -m -s /bin/bash builder && mkdir -p /work && chown -R builder:builder /work

USER builder
WORKDIR /work

# Fetch sources as builder so Buildroot can write output/ and dl/
RUN git clone --depth 1 -b "v4.14.0" https://github.com/wazuh/wazuh.git wazuh-4.14.0
RUN curl -L "https://buildroot.org/downloads/buildroot-2024.02.11.tar.gz" | tar -xz

# ---- Buildroot toolchain (MIPS32 big-endian, uClibc) ----
WORKDIR /work/buildroot-2024.02.11

RUN cat > .config <<'EOF'
BR2_mips=y
BR2_ENDIAN_BIG=y
BR2_MIPS_CPU_MIPS32=y
BR2_TOOLCHAIN_BUILDROOT=y
BR2_TOOLCHAIN_BUILDROOT_UCLIBC=y
BR2_TOOLCHAIN_BUILDROOT_CXX=y
EOF

RUN make olddefconfig
RUN make -j$(nproc) toolchain

# ---- Cross toolchain path ----
ENV BR_HOST=/work/buildroot-2024.02.11/output/host
ENV CROSS_TRIPLET=mips-buildroot-linux-uclibc
ENV CROSS_PREFIX=/work/buildroot-2024.02.11/output/host/bin/${CROSS_TRIPLET}-
ENV PATH=${BR_HOST}/bin:${PATH}

# sanity check so you don't waste time later
RUN test -x "${CROSS_PREFIX}gcc" && "${CROSS_PREFIX}gcc" -v >/dev/null 2>&1 || true

# ---- Wazuh deps fetch ----
WORKDIR /work/wazuh-4.14.0/src
RUN make clean-deps || true && make clean || true
RUN make TARGET=agent deps EXTERNAL_SRC_ONLY=yes

# ---- OpenSSL for MIPS (FIX: do NOT export CC/CROSS_COMPILE; use --cross-compile-prefix) ----
WORKDIR /work/wazuh-4.14.0/src/external/openssl

RUN ./Configure linux-mips32 no-shared no-tests no-apps enable-weak-ssl-ciphers \
      --cross-compile-prefix="${CROSS_PREFIX}" \
      --prefix=/work/wazuh-4.14.0/src/external/openssl/install \
      --openssldir=/work/wazuh-4.14.0/src/external/openssl/install/ssl \
 && make -j"$(nproc)" build_libs \
 && make install_sw

WORKDIR /work
CMD ["/bin/bash"]
