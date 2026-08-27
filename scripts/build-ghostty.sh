#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script_path="${script_dir}/$(basename "${BASH_SOURCE[0]}")"
srcroot="${SRCROOT:-$(cd "${script_dir}/.." && pwd)}"
repo_root="${srcroot}"

# Pin a Zig-linkable Xcode for `zig build`'s SDK lookups (see select-developer-dir.sh).
# Always delegate so an inherited DEVELOPER_DIR is validated, not trusted blindly.
# Plain assignment, separate export, so a selector failure aborts under set -e.
DEVELOPER_DIR="$("${script_dir}/select-developer-dir.sh")"
export DEVELOPER_DIR
ghostty_dir="${srcroot}/ThirdParty/ghostty"
ghostty_submodule_path="${ghostty_dir#"${repo_root}/"}"
ghostty_build_root="${srcroot}/.build/ghostty"
ghostty_local_cache_dir="${ghostty_build_root}/.zig-cache"
ghostty_global_cache_dir="${ghostty_build_root}/.zig-global-cache"
ghostty_fingerprint_path="${ghostty_build_root}/fingerprint"
ghostty_legacy_prefix_path="${ghostty_dir}/zig-out"
ghostty_legacy_share_path="${ghostty_legacy_prefix_path}/share"
xcframework_path="${ghostty_build_root}/GhosttyKit.xcframework"
ghostty_resources_path="${ghostty_build_root}/share/ghostty"
ghostty_terminfo_path="${ghostty_build_root}/share/terminfo"
# Out-of-tree patches applied to the pinned ghostty submodule at build time.
# The submodule pointer stays on upstream; we never fork or commit into it.
ghostty_patches_dir="${srcroot}/patches/ghostty"

print_fingerprint() {
  (
    cd "${ghostty_dir}"
    {
      git rev-parse HEAD
      git diff --no-ext-diff --no-color HEAD -- . | shasum -a 256
      git ls-files --others --exclude-standard | LC_ALL=C sort | shasum -a 256
      shasum -a 256 "${script_path}" | awk '{print $1}'
      shasum -a 256 "${srcroot}/mise.toml" | awk '{print $1}'
      # The patches are applied at build time, so an edited patch must bust the cache.
      for patch in "${ghostty_patches_dir}"/*.patch; do
        [ -e "${patch}" ] || continue
        basename "${patch}"
        shasum -a 256 "${patch}" | awk '{print $1}'
      done | shasum -a 256
    } | shasum -a 256 | awk '{print $1}'
  )
}

# Local escape hatch (uncommitted): Xcode 26.6's libtool silently drops every
# archive member that is "not 8-byte aligned" (zig's main libghostty_zcu.o,
# zlib's zutil.o, gettext's textdomain.o, ...) when merging the static
# archives, so the xcframework's macOS slice ends up missing the ghostty C API
# and zlib/gettext/macos-bridge symbols, and the app link fails. ar(1) has no
# such alignment rule, so rebuild the slice from the libtool step's original
# inputs (recorded in the zig cache manifests), re-lipo'd.
repair_xcframework_macos_slice() {
  local slice="${xcframework_path}/macos-arm64_x86_64/libghostty.a"
  [ -f "${slice}" ] || return 0
  # NOTE: `grep -c`, not `grep -q`. `grep -q` exits on the first match and
  # closes the pipe, so `nm` dies with SIGPIPE while still streaming its ~65k
  # lines; under `set -o pipefail` that makes a *successful* match report
  # failure, and this repair then runs on every build — silently rebuilding
  # the slice from whatever stale manifest the cache scan happens to find.
  local have_c_api
  have_c_api="$(nm "${slice}" 2>/dev/null | grep -c " T _ghostty_surface_text" || true)"
  if [ "${have_c_api}" -gt 0 ]; then
    return 0
  fi
  echo "note: xcframework macOS slice lacks the ghostty C API (libtool dropped unaligned members); rebuilding it with ar" >&2
  local cache="${ghostty_local_cache_dir}"
  local work
  work="$(mktemp -d)"
  local arch
  for arch in arm64 x86_64; do
    # Find the libtool run-step manifest (it lists a dozen archives) whose
    # main ghostty archive targets macOS on this arch.
    local manifest="" m main_lib
    for m in "${cache}"/h/*.txt; do
      [ "$(strings "${m}" | grep -c '\.a$')" -gt 5 ] || continue
      main_lib="${cache}/$(strings "${m}" | grep '/libghostty\.a$' | awk '{print $NF}')"
      [ -f "${main_lib}" ] || continue
      [ "$(lipo -info "${main_lib}" 2>/dev/null | awk '{print $NF}')" = "${arch}" ] || continue
      mkdir -p "${work}/probe"
      (cd "${work}/probe" && ar -x "${main_lib}" base64.o && chmod u+rw base64.o)
      if [ "$(vtool -show-build "${work}/probe/base64.o" 2>/dev/null | awk '/platform/{print $2; exit}')" = "MACOS" ]; then
        manifest="${m}"
      fi
      rm -rf "${work}/probe"
      [ -n "${manifest}" ] && break
    done
    if [ -z "${manifest}" ]; then
      echo "error: no macOS ${arch} libtool manifest found in the zig cache" >&2
      exit 1
    fi
    local i=0 rel objs=()
    mkdir -p "${work}/${arch}"
    while IFS= read -r rel; do
      i=$((i + 1))
      local d="${work}/${arch}/${i}"
      mkdir -p "${d}"
      (cd "${d}" && ar -x "${cache}/${rel}")
      chmod -R u+rw "${d}"
      rm -f "${d}/__.SYMDEF"
      objs+=("${d}"/*)
    done < <(strings "${manifest}" | grep '\.a$' | awk '{print $NF}')
    ar rcs "${work}/${arch}.a" "${objs[@]}"
    ranlib "${work}/${arch}.a"
  done
  lipo -create "${work}/arm64.a" "${work}/x86_64.a" -output "${slice}"
  rm -rf "${work}"
}

# Fail loudly if the installed slice isn't the one this build just produced.
# `repair_xcframework_macos_slice` rebuilds the slice from zig cache manifests,
# and those can belong to an *earlier* build — which links and exports the full
# C API, so nothing else notices, and the app silently ships stale renderer
# code. Compare against zig's own output; sizes match iff the install is current.
assert_installed_slice_current() {
  local built="${ghostty_dir}/macos/GhosttyKit.xcframework/macos-arm64_x86_64/libghostty.a"
  local slice="${xcframework_path}/macos-arm64_x86_64/libghostty.a"
  [ -f "${built}" ] && [ -f "${slice}" ] || return 0
  local built_size slice_size
  built_size="$(stat -f '%z' "${built}")"
  slice_size="$(stat -f '%z' "${slice}")"
  if [ "${built_size}" != "${slice_size}" ]; then
    echo "error: installed xcframework slice does not match this build's output" >&2
    echo "       built:     ${built_size} bytes  ${built}" >&2
    echo "       installed: ${slice_size} bytes  ${slice}" >&2
    echo "       The slice was rebuilt from a stale zig cache manifest. Remove" >&2
    echo "       .build/ghostty/.zig-cache and .build/ghostty/fingerprint, then retry." >&2
    exit 1
  fi
}

prepare_xcframework() {
  local modulemap
  find "${xcframework_path}" -path '*/Headers/module.modulemap' -print0 | while IFS= read -r -d '' modulemap; do
    cat > "${modulemap}" <<'EOF'
module GhosttyKit {
    header "ghostty.h"
    export *
}
EOF
  done
}

ensure_ghostty_checkout() {
  if [ -f "${ghostty_dir}/build.zig" ]; then
    return
  fi

  git -C "${repo_root}" submodule sync --recursive -- "${ghostty_submodule_path}"
  git -C "${repo_root}" submodule update --init --recursive -- "${ghostty_submodule_path}"

  if [ ! -f "${ghostty_dir}/build.zig" ]; then
    echo "error: missing ${ghostty_dir} after submodule update" >&2
    exit 1
  fi
}

# Apply our out-of-tree patches to the submodule working tree. Idempotent: a
# patch that already applies in reverse is treated as present. Fails loudly if
# a patch no longer applies (e.g. after an upstream bump) so it's never silently
# skipped. The submodule's committed SHA is untouched; `revert_ghostty_patches`
# restores a pristine working tree on exit.
# Repo-relative paths a patch touches. Parses the patch itself, not the tree, so
# it works even when the working tree is dirty.
ghostty_patch_files() {
  git -C "${ghostty_dir}" apply --numstat "$1" 2>/dev/null | awk '{ print $3 }'
}

# Reset just the files a patch touches back to the pinned SHA. Reads the file
# list line by line (bash 3.2 compatible) so a path with spaces stays intact.
reset_ghostty_patch_files() {
  local f
  local files=()
  while IFS= read -r f; do
    [ -n "${f}" ] && files+=("${f}")
  done < <(ghostty_patch_files "$1")
  [ "${#files[@]}" -eq 0 ] || git -C "${ghostty_dir}" checkout -- "${files[@]}" 2>/dev/null || true
}

apply_ghostty_patches() {
  [ -d "${ghostty_patches_dir}" ] || return 0
  local patch
  for patch in "${ghostty_patches_dir}"/*.patch; do
    [ -e "${patch}" ] || continue
    if git -C "${ghostty_dir}" apply --reverse --check "${patch}" 2>/dev/null; then
      continue # already fully applied
    fi
    if ! git -C "${ghostty_dir}" apply --check "${patch}" 2>/dev/null; then
      # Neither pristine nor cleanly applied: most likely a prior build was killed
      # (SIGKILL / power loss) mid-apply and left the patched files dirty. Reset
      # just those files to the pinned SHA and retry before blaming an upstream bump.
      reset_ghostty_patch_files "${patch}"
      if ! git -C "${ghostty_dir}" apply --check "${patch}" 2>/dev/null; then
        echo "error: ${patch} does not apply cleanly to ${ghostty_submodule_path}." >&2
        echo "       The submodule may have been bumped (refresh the patch), or a" >&2
        echo "       previous build left it dirty: git -C ${ghostty_submodule_path} checkout . && retry." >&2
        exit 1
      fi
    fi
    git -C "${ghostty_dir}" apply "${patch}"
  done
}

revert_ghostty_patches() {
  [ -d "${ghostty_patches_dir}" ] || return 0
  local patch
  for patch in "${ghostty_patches_dir}"/*.patch; do
    [ -e "${patch}" ] || continue
    # Prefer a clean reverse-apply; fall back to resetting just the patched files.
    # The fallback also guards against `set -e` aborting the trap mid-revert if the
    # reverse-apply fails (e.g. a partially-applied tree).
    if git -C "${ghostty_dir}" apply --reverse --check "${patch}" 2>/dev/null; then
      git -C "${ghostty_dir}" apply --reverse "${patch}" 2>/dev/null || reset_ghostty_patch_files "${patch}"
    else
      reset_ghostty_patch_files "${patch}"
    fi
  done
}

ensure_ghostty_checkout

# Patch the pinned submodule in place for this build only, restoring it on exit
# so `git status` stays clean and the pin is never disturbed. Applied before the
# fingerprint so patched source is reflected in the rebuild trigger.
#
# Revert on signals too (not just EXIT): a cancelled Xcode build or Ctrl-C sends
# SIGINT/SIGTERM, which would otherwise skip the EXIT trap and leave the tree
# patched (dirty status + poisoned fingerprint). On signal we revert, clear the
# traps to avoid a double revert, and exit with the conventional 128+signal code.
revert_and_signal_exit() {
  revert_ghostty_patches
  trap - EXIT INT TERM
  case "$1" in
    TERM) exit 143 ;;
    *) exit 130 ;;
  esac
}
trap revert_ghostty_patches EXIT
trap 'revert_and_signal_exit INT' INT
trap 'revert_and_signal_exit TERM' TERM
apply_ghostty_patches

if [ "${1:-}" = "--print-fingerprint" ]; then
  print_fingerprint
  exit 0
fi

fingerprint="$(print_fingerprint)"

rm -rf "${ghostty_legacy_prefix_path}"
mkdir -p "${ghostty_build_root}" "${ghostty_legacy_prefix_path}"
ln -s "${ghostty_build_root}/share" "${ghostty_legacy_share_path}"

if [ -f "${ghostty_fingerprint_path}" ] &&
  [ -d "${xcframework_path}" ] &&
  [ -d "${ghostty_resources_path}" ] &&
  [ -d "${ghostty_terminfo_path}" ] &&
  [ "$(cat "${ghostty_fingerprint_path}")" = "${fingerprint}" ]; then
  exit 0
fi

# LOCAL BUILD HATCHES (not for upstream) — see scripts/local/libtool.
#   SUPACODE_GHOSTTY_SKIP_APP=1  skip ghostty's own .app bundle; its xcodebuild link
#                                fails on this toolchain and supacode only consumes
#                                the xcframework.
#   The libtool shim on PATH repairs Xcode 26.6's dropped-member archive merge.
ghostty_emit_macos_app=true
if [ -n "${SUPACODE_GHOSTTY_SKIP_APP:-}" ]; then
  ghostty_emit_macos_app=false
fi
if [ -x "${srcroot}/scripts/local/libtool" ]; then
  PATH="${srcroot}/scripts/local:${PATH}"
  export PATH
fi

cd "${ghostty_dir}"
mise exec -- zig build -Doptimize=ReleaseFast -Demit-xcframework=true -Demit-macos-app="${ghostty_emit_macos_app}" -Dsentry=false --prefix "${ghostty_build_root}" --cache-dir "${ghostty_local_cache_dir}" --global-cache-dir "${ghostty_global_cache_dir}"
rsync -a --delete "${ghostty_dir}/macos/GhosttyKit.xcframework/" "${xcframework_path}/"
repair_xcframework_macos_slice
prepare_xcframework
assert_installed_slice_current
printf '%s\n' "${fingerprint}" > "${ghostty_fingerprint_path}"
