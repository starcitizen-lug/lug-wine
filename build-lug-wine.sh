#!/usr/bin/env bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WINE_TKG_SRC="$SCRIPT_DIR/wine-tkg-git"
PROTON_TKG_SRC="$SCRIPT_DIR/wine-tkg-git/proton-tkg"
PATCHES_DIR="$SCRIPT_DIR/patches/wine"
TMP_BUILD_DIR="$SCRIPT_DIR/wine-tkg-build-tmp-$(mktemp -u XXXXXX)"

######### error codes ################################################
invalid_args=-1


######## environment #################################################
preset="default"
wine_version=""
lug_rev="-1"
build_type="wine"


# Common patches applied to BOTH Wine and Proton builds
common_patches=("eac_locale"
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

# Patches specific to Wine builds (includes common patches)
# the 10.2+_eac_fix patch may be needed when Proton moves to a Wine 11.0+ base
wine_patches=("10.2+_eac_fix"
        "${common_patches[@]}"
)

# Patches specific to Proton builds (includes common patches)
proton_patches=("${common_patches[@]}"
)

# Temporary patches passed via --adhoc argument
adhoc_patches=()

cleanup() {
  rm -rf "$TMP_BUILD_DIR"
  echo "Cleaned up temporary build directory."
}
trap cleanup EXIT

parse_adhoc() {
  IFS=',' read -r -a adhoc <<< "$1"
  adhoc_patches+=("${adhoc[@]}")
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
    proton)
      export config="lug-proton-tkg-default.cfg"
      build_type="proton"
      ;;
    *)
      echo "Usage: $0 {default|staging-default|staging-wayland|proton} [build args...]"
      exit $invalid_args
      ;;
  esac

  if [ "$build_type" = "proton" ]; then
    patches=("${proton_patches[@]}" "${adhoc_patches[@]}")
  else
    patches=("${wine_patches[@]}" "${adhoc_patches[@]}")
  fi

  if [ "$build_type" = "proton" ]; then
    # Proton builds: proton-tkg.sh expects wine-tkg-git to be at ../wine-tkg-git
    # So we copy the entire wine-tkg-git structure and cd into proton-tkg
    mkdir -p "$TMP_BUILD_DIR"
    cp -a "$WINE_TKG_SRC"/* "$TMP_BUILD_DIR/"
    echo "Created temporary build directory: $TMP_BUILD_DIR"

    # Copy config to proton-tkg subdirectory
    cp "$SCRIPT_DIR/config/$config" "$TMP_BUILD_DIR/proton-tkg/"

    cd "$TMP_BUILD_DIR/proton-tkg"

    # Wine patches go to wine-tkg-git/wine-tkg-userpatches (not proton-tkg-userpatches)
    # proton-tkg-userpatches is for proton-specific patches (.myprotonpatch)
    mkdir -p "$TMP_BUILD_DIR/wine-tkg-git/wine-tkg-userpatches"
    
    # Proton Override Logic
    # 1. Check patches/proton/ (Override)
    # 2. Check patches/wine/ (Fallback)
    PROTON_PATCH_DIR="$SCRIPT_DIR/patches/proton"
    
    for file in "${patches[@]}"; do
      if [ -f "$PROTON_PATCH_DIR/$file.patch" ]; then
          echo "Applying Proton override for: $file"
          cp "$PROTON_PATCH_DIR/$file.patch" "$TMP_BUILD_DIR/wine-tkg-git/wine-tkg-userpatches/${file}.mypatch"
      else
          cp "$PATCHES_DIR/$file.patch" "$TMP_BUILD_DIR/wine-tkg-git/wine-tkg-userpatches/${file}.mypatch"
      fi
    done

    echo "Copied LUG patches to wine-tkg-git/wine-tkg-userpatches/"

  else
    # Wine builds: copy wine-tkg-git directory contents
    mkdir -p "$TMP_BUILD_DIR"
    cp -a "$WINE_TKG_SRC/wine-tkg-git"/* "$TMP_BUILD_DIR/"
    echo "Created temporary build directory: $TMP_BUILD_DIR"

    cp "$SCRIPT_DIR/config/$config" "$TMP_BUILD_DIR/"

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
  fi
}

build_lug_wine() {
  yes|./non-makepkg-build.sh --config "$TMP_BUILD_DIR/$config" "$@"
  echo "Build completed successfully."
}

build_lug_proton() {
  # proton-tkg.sh accepts a config path as $1 to set _EXT_CONFIG_PATH
  # We're in $TMP_BUILD_DIR/proton-tkg, config was copied here
  
  # Force Docker container usage for Sniper runtime
  sed -i 's/_no_container="true"/_no_container="false"/' proton-tkg.sh
  
  # Fix for Docker on SELinux systems
  # If SELinux is enabled, we need to pass --relabel-volumes to configure.sh
  if command -v selinuxenabled >/dev/null 2>&1 && selinuxenabled; then
      echo "SELinux detected: Enabling --relabel-volumes for Proton build container..."
      sed -i 's|\.\./configure\.sh|\.\./configure\.sh --relabel-volumes|' proton-tkg.sh
  fi
  
  yes|./proton-tkg.sh "./$config" "$@"
  echo "Proton build completed successfully."
}


package_artifact() {
  echo "Packaging build artifact..."
  local lug_name archive_path built_dir search_dir temp_subdir

  if [ "$build_type" = "proton" ]; then
    search_dir="./built"
    # Find the directory starting with proton_tkg_
    built_dir="$(find "$search_dir" -maxdepth 1 -type d -name 'proton_tkg_*' -printf '%f\n' | head -n1)"
    
    if [[ -z "$built_dir" ]]; then
       echo "No build directory found in $search_dir/"
       exit 1
    fi
    local version_part="${built_dir#proton_tkg_}"
    lug_name="lug-proton-${version_part}${lug_rev}"
    temp_subdir="lug-proton-tkg"
  else
    search_dir="./non-makepkg-builds"
    # Find the directory starting with wine-
    built_dir="$(find "$search_dir" -maxdepth 1 -type d -name 'wine-*' -printf '%f\n' | head -n1)"
    
    if [[ -z "$built_dir" ]]; then
       echo "No build directory found in $search_dir/"
       exit 1
    fi
    lug_name="lug-$(echo "$built_dir" | cut -d. -f1-2)${lug_rev}"
    temp_subdir="lug-wine-tkg"
  fi

  # Common packaging logic
  archive_path="/tmp/${temp_subdir}/${lug_name}.tar.gz"
  mkdir -p "$(dirname "$archive_path")"
  
  # Rename the build dir to the lug name
  mv "${search_dir}/${built_dir}" "${search_dir}/${lug_name}"
  
  # Tar it up
  tar --remove-files -czf "$archive_path" -C "${search_dir}" "$lug_name"
  
  # Move to output
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
  -p, --preset                  Select a preset configuration:
                                  Wine:   default, staging-default, staging-wayland
                                  Proton: proton-default
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
if [ "$build_type" = "proton" ]; then
  build_lug_proton
else
  build_lug_wine
fi
package_artifact
