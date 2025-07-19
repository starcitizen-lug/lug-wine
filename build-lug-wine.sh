#!/usr/bin/env bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WINE_TKG_SRC="$SCRIPT_DIR/wine-tkg-git"
PATCHES_DIR="$SCRIPT_DIR/patches/wine"
TMP_BUILD_DIR="$SCRIPT_DIR/wine-tkg-build-tmp-$(mktemp -u XXXXXX)"

cleanup() {
  #rm -rf "$TMP_BUILD_DIR"
  echo "Cleaned up temporary build directory."
}
trap cleanup EXIT

package_artifact() {
  local type="$1"
  local workdir lug_name archive_path
  if [[ "$type" == "makepkg" ]]; then
    local archive_name
    archive_name="$(find "$PKGDEST" -maxdepth 1 -type f -name 'wine-*.tar.zst' -printf '%f\n' | head -n1)"
    if [[ -z "$archive_name" ]]; then
      echo "No archive found in $PKGDEST"
      exit 1
    fi
    lug_name="lug-$(echo "$archive_name" | cut -d. -f1-2)"
    local pkgdir
    pkgdir="$(find ./pkg -maxdepth 1 -type d -name 'wine-*' -printf '%f\n' | head -n1)"
    if [[ -z "$pkgdir" || ! -d "./pkg/$pkgdir/usr" ]]; then
      echo "No built package directory found in ./pkg"
      exit 1
    fi
    workdir="/tmp/lug-wine-tkg/$lug_name"
    mkdir -p "$(dirname "$workdir")"
    mv "./pkg/$pkgdir/usr" "$workdir"
  elif [[ "$type" == "nonmakepkg" ]]; then
    local built_dir
    built_dir="$(find ./non-makepkg-builds -maxdepth 1 -type d -name 'wine-*' -printf '%f\n' | head -n1)"
    if [[ -z "$built_dir" ]]; then
      echo "No build directory found in non-makepkg-builds/"
      exit 1
    fi
    lug_name="lug-$(echo "$built_dir" | cut -d. -f1-2)"
    workdir="./non-makepkg-builds/$built_dir"
  else
    echo "Unknown packaging type: $type"
    exit 1
  fi

  archive_path="/tmp/lug-wine-tkg/${lug_name}.tar.zst"
  mkdir -p "$(dirname "$archive_path")"
  tar --remove-files -I zstd -C "$workdir" -cf "$archive_path" .
  mkdir -p "$SCRIPT_DIR/output"
  mv "$archive_path" "$SCRIPT_DIR/output/"
  echo "Build artifact collected in $SCRIPT_DIR/output/${lug_name}.tar.zst"
}

# Parse preset argument
PRESET="$1"
shift || true

case "$PRESET" in
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
    echo "Usage: $0 {fsync|ntsync|staging-fsync|staging-ntsync} [build args...]"
    exit 1
    ;;
esac

cp -a "$WINE_TKG_SRC/wine-tkg-git" "$TMP_BUILD_DIR/"
echo "Created temporary build directory: $TMP_BUILD_DIR"

cd "$TMP_BUILD_DIR"

patches=("silence-sc-unsupported-os"
         "dummy_dlls"
         "enables_dxvk-nvapi"
         "nvngx_dlls"
         "winefacewarehacks-minimal"
         "cache-committed-size"
)

mkdir -p ./wine-tkg-userpatches
for file in "${patches[@]}"; do
    cp "$PATCHES_DIR/$file.patch" "./wine-tkg-userpatches/${file}.mypatch"
done

echo "Copied LUG patches to ./wine-tkg-userpatches/"

if command -v makepkg >/dev/null 2>&1; then
  echo "makepkg found, using it to build..."
  export PKGDEST="${PKGDEST:-/tmp/wine-tkg}"
  rm -rf "$PKGDEST" /tmp/lug-wine-tkg
  mkdir -p "$PKGDEST" /tmp/lug-wine-tkg
  makepkg --config "$SCRIPT_DIR/$CONFIG" "$@"
  echo "Build completed successfully."
  echo "Packaging makepkg build artifact..."
  package_artifact makepkg
else
  echo "makepkg not found, falling back to non-makepkg-build.sh..."
  ./non-makepkg-build.sh --config "$SCRIPT_DIR/$CONFIG" "$@"
  echo "Build completed successfully."
  echo "Packaging non-makepkg build artifact..."
  package_artifact nonmakepkg
fi