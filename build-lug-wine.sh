#!/usr/bin/env bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WINE_TKG_SRC="$SCRIPT_DIR/wine-tkg-git"
PATCHES_DIR="$SCRIPT_DIR/patches/wine"
TMP_BUILD_DIR="$SCRIPT_DIR/wine-tkg-build-tmp-$(mktemp -u XXXXXX)"

######### error codes ################################################
invalid_args=-1


######## environment #################################################
preset="default"
wine_version=""
lug_rev="-1"

patches=("10.2+_eac_fix"
         "eac_locale"
         "dummy_dlls"
         "enables_dxvk-nvapi"
         "nvngx_dlls"
         "cache-committed-size"
         "0079-HACK-winewayland-add-support-for-picking-primary-mon"
         "0088-fixup-HACK-winewayland-add-support-for-picking-prima"
         "silence-sc-unsupported-os"
         "reg_show_wine"
         "eac_60101_timeout"
         "unopenable-device-is-bad"
         "append_cmd"
         "sc_gpumem"
)

cleanup() {
  rm -rf "$TMP_BUILD_DIR"
  echo "Cleaned up temporary build directory."
}
trap cleanup EXIT

parse_adhoc() {
  IFS=',' read -r -a adhoc <<< "$1"
  patches+=("${adhoc[@]}")
}

# prepare preset
prepare_preset() {
  case "$preset" in
    default)
      export config="lug-wine-tkg-default.cfg"
      ;;
    staging-default)
      export config="lug-wine-tkg-staging-default.cfg"
      ;;
    staging-wayland)
      export config="lug-wine-tkg-staging-wayland.cfg"
      parse_adhoc "default-to-wayland"
      ;;
    *)
      echo "Usage: $0 {default|staging-default|staging-wayland} [build args...]"
      exit $invalid_args
      ;;
  esac

  cp -a "$WINE_TKG_SRC/wine-tkg-git" "$TMP_BUILD_DIR/"
  echo "Created temporary build directory: $TMP_BUILD_DIR"

  cp "./config/$config" "$TMP_BUILD_DIR"

  cd "$TMP_BUILD_DIR"

  mkdir -p ./wine-tkg-userpatches
  for file in "${patches[@]}"; do
    cp "$PATCHES_DIR/$file.patch" "./wine-tkg-userpatches/${file}.mypatch"
  done

  echo "Copied LUG patches to ./wine-tkg-userpatches/"

  if [ -n "$wine_version" ]; then
    sed -i "s/staging_version=\"\"/staging_version=\"v$wine_version\"/" "$TMP_BUILD_DIR/$config"
    sed -i "s/plain_version=\"\"/plain_version=\"wine-$wine_version\"/" "$TMP_BUILD_DIR/$config"
  fi
}

build_lug_wine() {
  yes|./non-makepkg-build.sh --config "$TMP_BUILD_DIR/$config" "$@"
  echo "Build completed successfully."
}

package_artifact() {
  echo "Packaging build artifact..."
  local workdir lug_name archive_path
  local built_dir
  built_dir="$(find ./non-makepkg-builds -maxdepth 1 -type d -name 'wine-*' -printf '%f\n' | head -n1)"
  if [[ -z "$built_dir" ]]; then
    echo "No build directory found in non-makepkg-builds/"
    exit 1
  fi
  lug_name="lug-$(echo "$built_dir" | cut -d. -f1-2)${lug_rev}"
  archive_path="/tmp/lug-wine-tkg/${lug_name}.tar.gz"
  mkdir -p "$(dirname "$archive_path")"
  mv "./non-makepkg-builds/$built_dir" "./non-makepkg-builds/$lug_name"
  tar --remove-files -czf "$archive_path" -C "./non-makepkg-builds" "$lug_name"
  mkdir -p "$SCRIPT_DIR/output"
  mv "$archive_path" "$SCRIPT_DIR/output/"
  echo "Build artifact collected in $SCRIPT_DIR/output/${lug_name}.tar.gz"
}

usage() {
  printf "Linux Users Group Wine Build Script\n
Usage: ./build-lug-wine <options>
./build-lug-wine -p default -v 10.23 -r 1 -a default-to-wayland
  -h, --help                    Display this help message and exit
  -v, --version                 Wine version to build e.g. "10.23" (default: latest git)
  -a, --adhoc                   Comma-separated list of adhoc patches to apply
  -p, --preset                  Select a preset configuration (default|staging-default)
  -o, --output                  Output directory for the build artifact (default: ./output)
  -r, --revision                Revision number for the build (default: 1)
"
}

# MARK: Cmdline arguments
# If invoked with command line arguments, process them and exit
if [ "$#" -gt 0 ]; then
    while [ "$#" -gt 0 ]
    do
        case "$1" in
            --help | -h )
                usage
                exit 0
                ;;
            --preset | -p )
                preset="$2"
                shift
                ;;
            --version | -v )
                wine_version="$2"
                shift
                ;;
            --revision | -r )
                lug_rev="-${2:-1}"
                shift
                ;;
            --adhoc | -a )
                parse_adhoc "$2"
                shift
                ;;
            * )
                printf "%s: Invalid option '%s'\n" "$0" "$1"
                usage
                exit 0
                ;;
        esac
        # Shift forward to the next argument and loop again
        shift
    done
fi

prepare_preset
build_lug_wine
package_artifact
