#!/bin/bash
set -e

ARCH=$1
if [ -z "$ARCH" ]; then
    echo "Usage: $0 <arch>"
    exit 1
fi

echo "Starting LOCAL build for architecture: $ARCH"

# Environment Setup
export DEBIAN_FRONTEND=noninteractive
export TZ=Etc/UTC
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
ln -fs /usr/share/zoneinfo/Etc/UTC /etc/localtime



# Install Dependencies
echo "Installing system dependencies..."
apt-get update
apt-get install -y --no-install-recommends tzdata
dpkg-reconfigure --frontend noninteractive tzdata
apt-get install -y git python3-pip nasm libgbm-dev libdrm-dev libfreetype-dev libasound2-dev \
    libdbus-1-dev libegl1-mesa-dev libgl1-mesa-dev libgles2-mesa-dev libglu1-mesa-dev libibus-1.0-dev libpulse-dev libudev-dev libx11-dev libxcursor-dev \
    libxext-dev libxi-dev libxinerama-dev libxkbcommon-dev libxrandr-dev libxss-dev libxt-dev libxv-dev libxxf86vm-dev libxcb-dri3-dev libx11-xcb-dev \
    wayland-protocols libopus-dev libvdpau-dev libgl-dev wget build-essential autoconf automake libtool pkg-config ninja-build curl xz-utils libssl-dev libfontconfig1-dev libxkbcommon-x11-dev file libxcb-cursor-dev fuse squashfs-tools \
    libxcb-icccm4-dev libxcb-image0-dev libxcb-keysyms1-dev libxcb-randr0-dev libxcb-render-util0-dev libxcb-shape0-dev libxcb-sync-dev libxcb-xfixes0-dev libxcb-xinerama0-dev libxcb-xkb-dev libxcb-util-dev

# Fix git safety issues in Docker (for submodules/version)
git config --global --add safe.directory /workspace

# Install Vulkan SDK
echo "Installing Vulkan SDK..."
if [ "$ARCH" = "x86_64" ]; then
    VULKAN_SDK_VERSION=1.4.313.0
    VULKAN_SDK_DIR=/opt/vulkan-sdk
    VULKAN_SDK_FILENAME="vulkansdk-linux-x86_64-$VULKAN_SDK_VERSION.tar.xz"
    VULKAN_SDK_URL="https://sdk.lunarg.com/sdk/download/$VULKAN_SDK_VERSION/linux/$VULKAN_SDK_FILENAME"
    mkdir -p $VULKAN_SDK_DIR
    
    # Check if already installed
    if [ ! -f "$VULKAN_SDK_DIR/ok" ]; then
        echo "Downloading Vulkan SDK from $VULKAN_SDK_URL"
        if wget -q "$VULKAN_SDK_URL" -O /tmp/vulkan-sdk.tar.xz; then
            tar -xf /tmp/vulkan-sdk.tar.xz -C $VULKAN_SDK_DIR --strip-components=1
            touch $VULKAN_SDK_DIR/ok
        else
            echo "Failed to download Vulkan SDK, falling back to system packages"
            apt-get install -y libvulkan-dev vulkan-tools
        fi
    fi
    
    if [ -d "$VULKAN_SDK_DIR/x86_64" ]; then
        VULKAN_SDK=$VULKAN_SDK_DIR/x86_64
    else
        VULKAN_SDK=$VULKAN_SDK_DIR
    fi
    export VULKAN_SDK
    export PATH=$VULKAN_SDK/bin:$PATH
    export LD_LIBRARY_PATH=$VULKAN_SDK/lib:${LD_LIBRARY_PATH:-}
    export PKG_CONFIG_PATH=$VULKAN_SDK/lib/pkgconfig:${PKG_CONFIG_PATH:-}
else
    echo "Using system Vulkan packages for arm64"
    apt-get install -y libvulkan-dev vulkan-tools vulkan-loader-dev || apt-get install -y libvulkan-dev
fi

# Install pipewire
apt-get install -y libpipewire-0.3-dev 2>/dev/null || echo "libpipewire-0.3-dev not available, skipping"

# Install meson/aqtinstall
# Upgrade pip first
python3 -m pip install --upgrade pip
pip3 install -U meson aqtinstall

# Setup dep_root
mkdir -p dep_root/{bin,include,lib}
export DEP_ROOT=$PWD/dep_root
export PATH=$PWD/dep_root/bin:$PATH
export LD_LIBRARY_PATH=$PWD/dep_root/lib:$PWD/dep_root/lib64:$LD_LIBRARY_PATH

# Install Qt6
echo "Installing Qt6..."
QT_VERSION=6.7.2
QT_DIR=/opt/qt
mkdir -p $QT_DIR

if [ "$ARCH" = "x86_64" ]; then
    QT_HOST="linux"
    QT_ARCH="linux_gcc_64"
else
    QT_HOST="linux_arm64"
    QT_ARCH="linux_gcc_arm64"
fi

if [ ! -d "$QT_DIR/$QT_VERSION" ]; then
    echo "Installing Qt $QT_VERSION for $QT_HOST / $QT_ARCH"
    python3 -m aqt install-qt -O $QT_DIR $QT_HOST desktop $QT_VERSION $QT_ARCH --archives qtbase qtsvg qtdeclarative icu || \
    (echo "Retry with full install..." && python3 -m aqt install-qt -O $QT_DIR $QT_HOST desktop $QT_VERSION $QT_ARCH)
else
    echo "Qt $QT_VERSION already installed."
fi

# Find Qt install dir
QT_INSTALL_DIR=$(find $QT_DIR/$QT_VERSION -name "qmake" -type f | head -1 | xargs dirname | xargs dirname)
if [ -z "$QT_INSTALL_DIR" ]; then
    echo "Error: Qt installation not found"
    exit 1
fi
export PATH=$QT_INSTALL_DIR/bin:$PATH
export QTDIR=$QT_INSTALL_DIR
export LD_LIBRARY_PATH=$QT_INSTALL_DIR/lib:$LD_LIBRARY_PATH

# Create qmake6 symlink
if [ ! -f "$QT_INSTALL_DIR/bin/qmake6" ] && [ -f "$QT_INSTALL_DIR/bin/qmake" ]; then
    ln -sf $QT_INSTALL_DIR/bin/qmake $QT_INSTALL_DIR/bin/qmake6
fi

# Remove problematic SQL drivers
rm -f $QT_INSTALL_DIR/plugins/sqldrivers/libqsqlmimer.so
rm -f $QT_INSTALL_DIR/plugins/sqldrivers/libqsqlodbc.so
rm -f $QT_INSTALL_DIR/plugins/sqldrivers/libqsqlmysql.so
rm -f $QT_INSTALL_DIR/plugins/sqldrivers/libqsqlpsql.so

# Build Dependencies
mkdir -p deps

# Install OpenSSL 3
echo "Checking OpenSSL 3..."
OPENSSL_VER=3.0.13
if [ ! -f "deps/openssl/libssl.so.3" ] && [ ! -f "$DEP_ROOT/lib/libssl.so.3" ] && [ ! -f "$DEP_ROOT/lib64/libssl.so.3" ]; then
    echo "Building OpenSSL 3..."
    if [ ! -d "deps/openssl" ]; then
        wget -q https://www.openssl.org/source/openssl-$OPENSSL_VER.tar.gz
        tar -xzf openssl-$OPENSSL_VER.tar.gz
        mv openssl-$OPENSSL_VER deps/openssl
        rm openssl-$OPENSSL_VER.tar.gz
    fi
    pushd deps/openssl
    ./config --prefix=$DEP_ROOT --openssldir=$DEP_ROOT/ssl shared zlib
    make -j$(nproc)
    make install_sw
    popd
else
    echo "OpenSSL 3 already built."
fi

# SDL
echo "Checking SDL..."
if [ ! -f "$DEP_ROOT/lib/libSDL2.so" ]; then
    if [ ! -d "deps/SDL" ]; then
        git clone https://github.com/libsdl-org/SDL.git deps/SDL
        cd deps/SDL
        git checkout 3eba0b6f8a21392f47b1b53a476e7633048de9b1
        cd ../..
    fi
    pushd deps/SDL
    ./autogen.sh
    ./configure --prefix=$DEP_ROOT
    make -j$(nproc)
    make install
    popd
fi

# SDL_ttf
echo "Checking SDL_ttf..."
if [ ! -f "$DEP_ROOT/lib/libSDL2_ttf.so" ]; then
    if [ ! -d "deps/SDL_ttf" ]; then
        git clone --recursive https://github.com/libsdl-org/SDL_ttf.git deps/SDL_ttf
        cd deps/SDL_ttf
        git checkout release-2.22.0
        cd ../..
    fi
    pushd deps/SDL_ttf
    ./autogen.sh
    ./configure --prefix=$DEP_ROOT
    make -j$(nproc)
    make install
    popd
fi

# libva
echo "Checking libva..."
if [ ! -f "$DEP_ROOT/lib/libva.so" ]; then
    if [ ! -d "deps/libva" ]; then
        git clone https://github.com/intel/libva.git deps/libva
        cd deps/libva
        git checkout 2.23.0
        cd ../..
    fi
    pushd deps/libva
    ./autogen.sh
    ./configure --enable-x11 --prefix=$DEP_ROOT
    make -j$(nproc)
    make install
    popd
fi

# libplacebo
echo "Checking libplacebo..."
if [ ! -f "$DEP_ROOT/lib/libplacebo.so" ]; then
    if [ ! -d "deps/libplacebo" ]; then
        git clone --recursive https://github.com/haasn/libplacebo.git deps/libplacebo
        cd deps/libplacebo
        git checkout bc90ef94944a3dcaab324b86d3e3769ad1d8698b
        cd ../..
    fi
    pushd deps/libplacebo
    # Apply patches
    if ls ../../app/deploy/linux/appimage/*.patch 1> /dev/null 2>&1; then
        git apply ../../app/deploy/linux/appimage/*.patch || true
    fi
    meson setup build -Dvulkan=enabled -Dopengl=disabled -Ddemos=false --prefix=$DEP_ROOT --libdir=lib
    ninja -C build
    ninja install -C build
    popd
fi

# dav1d
echo "Checking dav1d..."
DAV1D_VER=1.5.2
if [ ! -f "$DEP_ROOT/lib/libdav1d.a" ]; then
    if [ ! -d "deps/dav1d" ]; then
        git clone --branch $DAV1D_VER --depth 1 https://code.videolan.org/videolan/dav1d.git deps/dav1d
    fi
    pushd deps/dav1d
    meson setup build -Ddefault_library=static -Dbuildtype=release -Denable_tools=false -Denable_tests=false --prefix=$DEP_ROOT --libdir=lib
    ninja -C build
    ninja install -C build
    popd
fi

# FFmpeg
echo "Checking FFmpeg..."
if [ ! -f "$DEP_ROOT/lib/libavcodec.so" ]; then
    if [ ! -d "deps/FFmpeg" ]; then
        git clone https://github.com/FFmpeg/FFmpeg.git deps/FFmpeg
        cd deps/FFmpeg
        git checkout n8.0.1
        cd ../..
    fi
    pushd deps/FFmpeg
    export PKG_CONFIG_PATH=$DEP_ROOT/lib/pkgconfig:$DEP_ROOT/lib64/pkgconfig:$PKG_CONFIG_PATH
    FFMPEG_CONF="--prefix=$DEP_ROOT --enable-pic --disable-static --enable-shared --disable-all --disable-autodetect --enable-avcodec --enable-avformat --enable-swscale \
        --enable-decoder=h264 --enable-decoder=hevc --enable-decoder=av1 \
        --enable-vaapi --enable-hwaccel=h264_vaapi --enable-hwaccel=hevc_vaapi --enable-hwaccel=av1_vaapi \
        --enable-vdpau --enable-hwaccel=h264_vdpau  --enable-hwaccel=hevc_vdpau --enable-hwaccel=av1_vdpau \
        --enable-libdrm \
        --enable-libdav1d --enable-decoder=libdav1d"
    
    if [ "$ARCH" = "x86_64" ]; then
        if [ -f "$VULKAN_SDK/lib/pkgconfig/vulkan.pc" ]; then
            export PKG_CONFIG_PATH=$VULKAN_SDK/lib/pkgconfig:$PKG_CONFIG_PATH
        fi
        FFMPEG_CONF="$FFMPEG_CONF --enable-vulkan --enable-hwaccel=h264_vulkan --enable-hwaccel=hevc_vulkan --enable-hwaccel=av1_vulkan --extra-cflags=-I$VULKAN_SDK/include --extra-ldflags=-L$VULKAN_SDK/lib"
    else
        echo "Disabling Vulkan for FFmpeg on arm64"
    fi
    
    ./configure $FFMPEG_CONF || { cat ffbuild/config.log; exit 1; }
    make -j$(nproc)
    make install
    popd
fi

# Install linuxdeployqt
echo "Installing linuxdeployqt..."
if [ "$ARCH" = "x86_64" ]; then
    LD_ARCH="x86_64"
else
    LD_ARCH="aarch64"
fi

# Download AppImage
if [ ! -f "dep_root/bin/linuxdeployqt" ]; then
    mkdir -p dep_root/bin
    if [ ! -f "dep_root/bin/linuxdeployqt-appimage" ]; then
        wget -O dep_root/bin/linuxdeployqt-appimage "https://github.com/probonopd/linuxdeployqt/releases/download/continuous/linuxdeployqt-continuous-$LD_ARCH.AppImage"
    fi
    chmod a+x dep_root/bin/linuxdeployqt-appimage
    
    # Extract AppImage manually to avoid FUSE/execution issues in Docker/QEMU
    pushd dep_root/bin
    echo "Extracting AppImage (scanning for offsets)..."
    
    # Ensure loop device exists (for mount)
    if [ ! -b /dev/loop0 ]; then
        mknod /dev/loop0 b 7 0 || true
    fi
    
    OFFSETS=$(grep -a -b -o 'hsqs' linuxdeployqt-appimage | cut -f 1 -d :)
    EXTRACTED=0
    mkdir -p linuxdeployqt-root mountpoint
    
    for OFFSET in $OFFSETS; do
        echo "Trying extraction at offset: $OFFSET"
        # Mount method (privileged)
        if mount -t squashfs -o loop,offset="$OFFSET",ro linuxdeployqt-appimage mountpoint >/dev/null 2>&1; then
            echo "Mount success at offset $OFFSET"
            cp -a mountpoint/. linuxdeployqt-root/
            umount mountpoint
            EXTRACTED=1
            break
        fi
    done
    
    rm -rf mountpoint
    
    if [ "$EXTRACTED" -eq 1 ]; then
        # Force Link the entry point
        ln -sf linuxdeployqt-root/AppRun linuxdeployqt
        chmod +x linuxdeployqt
        # rm -f linuxdeployqt-appimage # Keep it cached
    else
        echo "Error: Failed to extract AppImage via mount"
        exit 1
    fi
    popd
else
    echo "linuxdeployqt already installed."
fi

# Build Project
echo "Building AppImage..."
ldconfig
scripts/build-appimage.sh
