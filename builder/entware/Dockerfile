FROM ubuntu:24.04@sha256:52df9b1ee71626e0088f7d400d5c6b5f7bb916f8f0c82b474289a4ece6cf3faf AS runtime-base

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
	&& apt-get install -y --no-install-recommends \
		build-essential \
		ca-certificates \
		ccache \
		curl \
		file \
		gawk \
		g++-multilib \
		gcc-multilib \
		genisoimage \
		git \
		jq \
		libdw-dev \
		libelf-dev \
		libncurses5-dev \
		libssl-dev \
		locales \
		python-is-python3 \
		python3 \
		python3-pip \
		qemu-utils \
		rsync \
		signify-openbsd \
		subversion \
		swig \
		unzip \
		wget \
		zstd \
	&& python3 -m pip install --break-system-packages --no-cache-dir \
		attrs==26.1.0 \
		cffi==2.1.0 \
		cryptography==49.0.0 \
		pycparser==3.0 \
		pyelftools==0.33 \
		pyOpenSSL==26.3.0 \
		service_identity==26.1.0 \
		typing_extensions==4.16.0 \
	&& rm -rf /var/lib/apt/lists/*

FROM runtime-base

ARG BUILDER_ID
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# GNU host tools reject UID 0 by default. The build runs inside an isolated
# image stage and never installs into the GitHub runner host.
ENV ENTWARE_DIR=/opt/entware
ENV FORCE_UNSAFE_CONFIGURE=1
ENV MORS_ENTWARE_BUILDER_ID=${BUILDER_ID}
ENV MORS_ENTWARE_BUILDER_MANIFEST=/opt/mors-builder/manifest.env

RUN mkdir -p /src/mors

# BuildKit bind mounts expose only the allowlisted build inputs for this RUN.
# They are never copied into an OCI layer; the reusable buildroot is created
# directly in the final stage so Entware stamp and directory mtimes survive.
RUN --mount=type=bind,source=Makefile,target=/src/mors/Makefile,readonly \
	--mount=type=bind,source=opt,target=/src/mors/opt,readonly \
	--mount=type=bind,source=builder/entware,target=/src/mors/builder/entware,readonly \
	--mount=type=bind,source=scripts/qa,target=/src/mors/scripts/qa,readonly \
	cd /src/mors \
	&& actual_builder_id="$(bash scripts/qa/entware-builder-id.sh)" \
	&& test -n "${BUILDER_ID}" \
	&& test "${actual_builder_id}" = "${BUILDER_ID}" \
	&& ENTWARE_DIR=/opt/entware bash scripts/qa/entware-build.sh \
	&& test ! -e /opt/entware/package/mors \
	&& test -z "$(find /opt/entware/bin/targets -type f \
		-name 'mors_*_all.ipk' -print -quit)" \
	&& mkdir -p /opt/mors-builder \
	&& bash scripts/qa/entware-builder-id.sh --manifest \
		>/opt/mors-builder/manifest.env \
	&& rm -rf /src/mors/packages

LABEL org.opencontainers.image.source="https://github.com/ivni/mors"
LABEL org.opencontainers.image.description="Pinned Entware buildroot for Mors release packaging"
LABEL org.opencontainers.image.version="${BUILDER_ID}"

RUN rm -rf /src/mors \
	&& test ! -e /src/mors

WORKDIR /github/workspace
