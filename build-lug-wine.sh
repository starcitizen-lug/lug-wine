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
  lug_name="lug-$(echo "$built_dir" | cut -d. -f1-2)"
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

patches=("10.2+_eac_fix"
         "dummy_dlls"
         "enables_dxvk-nvapi"
         "nvngx_dlls"
         "winefacewarehacks-minimal"
         "cache-committed-size"
         "0079-HACK-winewayland-add-support-for-picking-primary-mon"
         "silence-sc-unsupported-os"
         "reg_show_wine"
)

mkdir -p ./wine-tkg-userpatches
for file in "${patches[@]}"; do
    cp "$PATCHES_DIR/$file.patch" "./wine-tkg-userpatches/${file}.mypatch"
done

echo "Copied LUG patches to ./wine-tkg-userpatches/"

# advanced-customization.cfg settings
sed -i 's/staging_userargs="-W ntdll-NtAlertThreadByThreadId"/staging_userargs="-W ntdll-NtAlertThreadByThreadId -W ntdll-ForceBottomUpAlloc -W ntdll-Hide_Wine_Exports"/' $TMP_BUILD_DIR/wine-tkg-profiles/advanced-customization.cfg
sed -i 's/NOLIB32="false"/NOLIB32="wow64"/' $TMP_BUILD_DIR/wine-tkg-profiles/advanced-customization.cfg

yes|./non-makepkg-build.sh --config "$SCRIPT_DIR/$CONFIG" "$@"
echo "Build completed successfully."
echo "Packaging build artifact..."
package_artifact
