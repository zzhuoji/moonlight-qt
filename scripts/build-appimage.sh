BUILD_CONFIG="release"

fail()
{
	echo "$1" 1>&2
	exit 1
}

BUILD_ROOT=$PWD/build
SOURCE_ROOT=$PWD
BUILD_FOLDER=$BUILD_ROOT/build-$BUILD_CONFIG
DEPLOY_FOLDER=$BUILD_ROOT/deploy-$BUILD_CONFIG
INSTALLER_FOLDER=$BUILD_ROOT/installer-$BUILD_CONFIG

if [ -n "$CI_VERSION" ]; then
  VERSION=$CI_VERSION
else
  VERSION=`cat $SOURCE_ROOT/app/version.txt`
fi

command -v qmake6 >/dev/null 2>&1 || fail "Unable to find 'qmake6' in your PATH!"
command -v linuxdeployqt >/dev/null 2>&1 || fail "Unable to find 'linuxdeployqt' in your PATH!"

echo Cleaning output directories
rm -rf $BUILD_FOLDER
rm -rf $DEPLOY_FOLDER
rm -rf $INSTALLER_FOLDER
mkdir $BUILD_ROOT
mkdir $BUILD_FOLDER
mkdir $DEPLOY_FOLDER
mkdir $INSTALLER_FOLDER

echo Configuring the project
pushd $BUILD_FOLDER
# Building with Wayland support will cause linuxdeployqt to include libwayland-client.so in the AppImage.
# Since we always use the host implementation of EGL, this can cause libEGL_mesa.so to fail to load due
# to missing symbols from the host's version of libwayland-client.so that aren't present in the older
# version of libwayland-client.so from our AppImage build environment. When this happens, EGL fails to
# work even in X11. To avoid this, we will disable Wayland support for the AppImage.
#
# We disable DRM support because linuxdeployqt doesn't bundle the appropriate libraries for Qt EGLFS.
#
# On arm64, disable libplacebo (Vulkan) support because the system Vulkan headers are too old
# and don't include Vulkan Video extension definitions required by the code.
ARCH=$(uname -m)
QMAKE_ARGS="CONFIG+=disable-wayland CONFIG+=disable-libdrm PREFIX=$DEPLOY_FOLDER/usr DEFINES+=APP_IMAGE"
if [ -n "$VULKAN_SDK" ]; then
  QMAKE_ARGS="$QMAKE_ARGS INCLUDEPATH+=$VULKAN_SDK/include LIBS+=-L$VULKAN_SDK/lib"
fi
if [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
  QMAKE_ARGS="$QMAKE_ARGS CONFIG+=disable-libplacebo"
  echo "Disabling libplacebo (Vulkan) support for arm64 architecture"
fi
qmake6 $SOURCE_ROOT/moonlight-qt.pro $QMAKE_ARGS || fail "Qmake failed!"
popd

echo Compiling Moonlight in $BUILD_CONFIG configuration
pushd $BUILD_FOLDER
make -j$(nproc) $(echo "$BUILD_CONFIG" | tr '[:upper:]' '[:lower:]') || fail "Make failed!"
popd

echo Deploying to staging directory
pushd $BUILD_FOLDER
make install || fail "Make install failed!"
popd

echo Creating AppImage
pushd $INSTALLER_FOLDER
echo Creating AppImage
pushd $INSTALLER_FOLDER
VERSION=$VERSION linuxdeployqt $DEPLOY_FOLDER/usr/share/applications/com.moonlight_stream.Moonlight.desktop -qmake=qmake6 -qmldir=$SOURCE_ROOT/app/gui -appimage -extra-plugins=tls -exclude-libs=libqsqlmimer.so,libqsqlodbc.so || fail "linuxdeployqt failed!"

# Detect architecture and rename AppImage to include architecture
ARCH=$(uname -m)
case "$ARCH" in
  x86_64)
    ARCH_NAME="x86_64"
    ;;
  aarch64|arm64)
    ARCH_NAME="arm64"
    ;;
  *)
    ARCH_NAME="$ARCH"
    ;;
esac

# Find the generated AppImage and rename it
GENERATED_APPIMAGE=$(ls -t Moonlight-*.AppImage 2>/dev/null | head -n 1)
if [ -n "$GENERATED_APPIMAGE" ]; then
  TARGET_NAME="Moonlight-$VERSION-$ARCH_NAME.AppImage"
  mv "$GENERATED_APPIMAGE" "$TARGET_NAME"
  echo "Renamed AppImage to: $TARGET_NAME"
else
  fail "Failed to find generated AppImage"
fi
popd

echo Build successful