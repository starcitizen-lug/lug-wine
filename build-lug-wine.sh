#!/usr/bin/env bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WINE_TKG_SRC="$SCRIPT_DIR/wine-tkg-git"
PATCHES_DIR="$SCRIPT_DIR/patches/wine"
TMP_BUILD_DIR="$SCRIPT_DIR/wine-tkg-build-tmp-$(mktemp -u XXXXXX)"

cleanup() {
  rm -rf "$TMP_BUILD_DIR"
  echo "Cleaned up temporary build directory."
}
trap cleanup EXIT

package_artifact() {
  local workdir lug_name archive_path
  local built_dir
  built_dir="$(find ./non-makepkg-builds -maxdepth 1 -type d -name 'wine-*' -printf '%f\n' | head -n1)"
  if [[ -z "$built_dir" ]]; then
    echo "No build directory found in non-makepkg-builds/"
    exit 1
  fi
  lug_name="lug-$(echo "$built_dir" | cut -d. -f1-2)${LUG_REV}"
  archive_path="/tmp/lug-wine-tkg/${lug_name}.tar.gz"
  mkdir -p "$(dirname "$archive_path")"
  mv "./non-makepkg-builds/$built_dir" "./non-makepkg-builds/$lug_name"
  tar --remove-files -czf "$archive_path" -C "./non-makepkg-builds" "$lug_name"
  mkdir -p "$SCRIPT_DIR/output"
  mv "$archive_path" "$SCRIPT_DIR/output/"
  echo "Build artifact collected in $SCRIPT_DIR/output/${lug_name}.tar.gz"
}

# Parse preset argument
PRESET="$1"
shift || true

case "$PRESET" in
  default)
    CONFIG="lug-wine-tkg-default.cfg"
    ;;
  staging-default)
    CONFIG="lug-wine-tkg-staging-default.cfg"
    ;;
  fsync)
    CONFIG="lug-wine-tkg-fsync.cfg"
    ;;
  ntsync)
    CONFIG="lug-wine-tkg-ntsync.cfg"
    ;;
  staging-fsync)
    CONFIG="lug-wine-tkg-staging-fsync.cfg"
    ;;
  staging-ntsync)
    CONFIG="lug-wine-tkg-staging-ntsync.cfg"
    ;;
  *)
    echo "Usage: $0 {default|staging-default|fsync|ntsync|staging-fsync|staging-ntsync} [build args...]"
    exit 1
    ;;
esac

export WINE_VERSION="$1"
shift || true

export LUG_REV="-${1:-1}"
shift || true

cp -a "$WINE_TKG_SRC/wine-tkg-git" "$TMP_BUILD_DIR/"
echo "Created temporary build directory: $TMP_BUILD_DIR"

cp "$CONFIG" "$TMP_BUILD_DIR"

cd "$TMP_BUILD_DIR"

patches=("10.2+_eac_fix"
         "eac_locale"
         "dummy_dlls"
         "enables_dxvk-nvapi"
         "nvngx_dlls"
         "cache-committed-size"
         "silence-sc-unsupported-os"
         "reg_show_wine"
         "eac_60101_timeout"
         "unopenable-device-is-bad"
)

mkdir -p ./wine-tkg-userpatches
for file in "${patches[@]}"; do
    cp "$PATCHES_DIR/$file.patch" "./wine-tkg-userpatches/${file}.mypatch"
done

echo "Copied LUG patches to ./wine-tkg-userpatches/"

# customization.cfg settings
case "$PRESET" in
  staging*)
    if [ -n "$WINE_VERSION" ]; then
      sed -i "s/staging_version=\"\"/staging_version=\"v$WINE_VERSION\"/" "$TMP_BUILD_DIR/$CONFIG"
    fi
  ;;
  *)
    if [ -n "$WINE_VERSION" ]; then
      sed -i "s/plain_version=\"\"/plain_version=\"wine-$WINE_VERSION\"/" "$TMP_BUILD_DIR/$CONFIG"
    fi
  ;;
esac

yes|./non-makepkg-build.sh --config "$TMP_BUILD_DIR/$CONFIG" "$@"
echo "Build completed successfully."
echo "Packaging build artifact..."
package_artifact
