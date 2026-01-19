#!/bin/bash
set -e

# Helper script to run the build locally using Docker
# Usage: ./scripts/build-local.sh [arm64|x86_64]

HOST_ARCH=$(uname -m)
# Normalize MacOS m1 arch
if [ "$HOST_ARCH" == "arm64" ]; then
    HOST_ARCH="arm64"
elif [ "$HOST_ARCH" == "x86_64" ]; then
    HOST_ARCH="x86_64"
fi

TARGET_ARCH=$1
if [ -z "$TARGET_ARCH" ]; then
    TARGET_ARCH=$HOST_ARCH
    echo "No target architecture specified, defaulting to host: $TARGET_ARCH"
fi

if [ "$TARGET_ARCH" == "arm64" ]; then
    DOCKER_PLATFORM="linux/arm64"
elif [ "$TARGET_ARCH" == "x86_64" ]; then
    DOCKER_PLATFORM="linux/amd64"
else
    echo "Error: Unsupported architecture: $TARGET_ARCH"
    echo "Supported: arm64, x86_64"
    exit 1
fi

echo "=================================================="
echo "Moonlight-QT Local Docker Build"
echo "--------------------------------------------------"
echo "Target Architecture : $TARGET_ARCH"
echo "Docker Platform     : $DOCKER_PLATFORM"
echo "Host Architecture   : $HOST_ARCH"
echo "=================================================="

# Check if running on M1/Apple Silicon attempting to build x86_64
if [ "$HOST_ARCH" == "arm64" ] && [ "$TARGET_ARCH" == "x86_64" ]; then
    echo "WARNING: Building x86_64 on Apple Silicon (arm64) will use QEMU emulation."
    echo "This will be significantly slower than native builds."
    echo "Sleeping for 3 seconds..."
    sleep 3
fi

# Check for Docker
if ! command -v docker >/dev/null 2>&1; then
    echo "Error: 'docker' command not found. Please install Docker Desktop."
    exit 1
fi

# Ensure submodules are initialized locally before mounting
echo "Initializing submodules..."
git submodule update --init --recursive

# Run the build container
# We use the DEDICATED local build script
docker run --rm -it \
    --platform $DOCKER_PLATFORM \
    --privileged \
    -v "$(pwd)":/workspace \
    -w /workspace \
    -e CI_VERSION="local-dev-$(date +%Y%m%d)" \
    ubuntu:20.04 \
    /bin/bash /workspace/scripts/local-docker-build.sh $TARGET_ARCH
