#!/usr/bin/env bash
# Offline stand-in for a queue-built SpiderMonkey dist/ (no Firefox build).
# Source it; it defines functions only.
#
# make_fixture_dist <dir> lays out, under <dir> (resolved with pwd -P, so the
# paths below are the ones realpath reports):
#   firefox/                         topsrcdir (js/src, js/public, mfbt, config)
#   firefox/obj-nightmonkey-sm/      topobjdir (js/src generated headers, libs)
#   firefox/obj-nightmonkey-sm/dist  the dist: include/ and lib/*.a and bin/js
#                                    are symlinks into topsrcdir/topobjdir
#                                    (absolute, plus one relative link);
#                                    include-private/ and system_wrappers/ are
#                                    real files, as the 0009 writer and mach
#                                    leave them; dist/host/ is not packaged
#   build-manifest.json              build-engine.sh's shape, two toolchain
#                                    artifacts (one with an extra key, which
#                                    the package manifest must drop)
#   tc/clang, tc/sysroot             the producer toolchain directories named
#                                    in js-build-config.json
#   home, mozbuild                   producer $HOME and MOZBUILD_STATE_PATH
# and sets FX_ROOT FX_SRC FX_OBJ FX_DIST FX_MANIFEST FX_CLANG FX_SYSROOT FX_HOME
# FX_MOZBUILD. The archives and the shell embed the objdir path (binaries are
# exempt from the leak scan). js-build-config.json has every key the 0009
# writer emits; cc uses `--sysroot=X`, cxx `--sysroot X` and cxx_base_flags
# both `--sysroot X` and `-isysroot X`.

make_fixture_dist() {
  mkdir -p "$1" || return 1
  FX_ROOT=$(cd "$1" && pwd -P) || return 1
  FX_SRC=$FX_ROOT/firefox
  FX_OBJ=$FX_SRC/obj-nightmonkey-sm
  FX_DIST=$FX_OBJ/dist
  FX_MANIFEST=$FX_ROOT/build-manifest.json
  FX_CLANG=$FX_ROOT/tc/clang
  FX_SYSROOT=$FX_ROOT/tc/sysroot
  FX_HOME=$FX_ROOT/home
  FX_MOZBUILD=$FX_ROOT/mozbuild
  local d
  for d in "$FX_SRC/js/src/vm" "$FX_SRC/js/public" "$FX_SRC/mfbt" "$FX_SRC/config" \
    "$FX_OBJ/js/src/build" "$FX_DIST/include/js" "$FX_DIST/include/mozilla" \
    "$FX_DIST/include-private/vm" "$FX_DIST/system_wrappers" "$FX_DIST/lib" \
    "$FX_DIST/bin" "$FX_DIST/host/bin" "$FX_CLANG/bin" "$FX_SYSROOT/include" \
    "$FX_HOME" "$FX_MOZBUILD"; do
    mkdir -p "$d" || return 1
  done

  # Sources the dist links to.
  printf '#ifndef jsapi_h\n#define jsapi_h\n#include "js/Value.h"\n#endif\n' >"$FX_SRC/js/src/jsapi.h" || return 1
  printf '#ifndef js_Value_h\n#define js_Value_h\nnamespace JS { class Value; }\n#endif\n' \
    >"$FX_SRC/js/public/Value.h" || return 1
  printf '#ifndef mozilla_Types_h\n#define mozilla_Types_h\n#endif\n' >"$FX_SRC/mfbt/Types.h" || return 1
  printf '#pragma GCC visibility push(default)\n' >"$FX_SRC/config/gcc_hidden.h" || return 1
  printf 'MACRO(Nop, nop, NULL, 1, 0, 0, JOF_BYTE)\nMACRO(Undefined, undefined, "", 1, 0, 1, JOF_BYTE)\n' \
    >"$FX_SRC/js/src/vm/Opcodes.h" || return 1
  printf '#define JS_CODEGEN_WASM32 1\n#define MOZ_DEBUG 0\n' >"$FX_OBJ/js/src/js-confdefs.h" || return 1
  local lib
  for lib in libjs_static libjsrust libjsshell libpure_virtual; do
    printf '!<arch>\n%s.o built in %s/js/src\n' "$lib" "$FX_OBJ" >"$FX_OBJ/js/src/build/$lib.a" || return 1
    ln -s "$FX_OBJ/js/src/build/$lib.a" "$FX_DIST/lib/$lib.a" || return 1
  done
  printf '\0asm\1\0\0\0 compiled in %s\n' "$FX_OBJ" >"$FX_OBJ/js/src/js" || return 1
  chmod +x "$FX_OBJ/js/src/js" || return 1
  ln -s "$FX_OBJ/js/src/js" "$FX_DIST/bin/js" || return 1

  # dist/include: absolute links (as mach makes them) and one relative link.
  ln -s "$FX_SRC/js/src/jsapi.h" "$FX_DIST/include/jsapi.h" || return 1
  ln -s "$FX_SRC/js/public/Value.h" "$FX_DIST/include/js/Value.h" || return 1
  ln -s ../../../../mfbt/Types.h "$FX_DIST/include/mozilla/Types.h" || return 1

  # dist/include-private: real copies (shutil.copy2 in the 0009 writer).
  cp "$FX_SRC/js/src/vm/Opcodes.h" "$FX_DIST/include-private/vm/Opcodes.h" || return 1
  cp "$FX_SRC/js/src/jsapi.h" "$FX_DIST/include-private/jsapi.h" || return 1
  cp "$FX_SRC/config/gcc_hidden.h" "$FX_DIST/include-private/gcc_hidden.h" || return 1
  cp "$FX_OBJ/js/src/js-confdefs.h" "$FX_DIST/include-private/js-confdefs.h" || return 1

  printf '#pragma GCC system_header\n#include_next <stdio.h>\n' >"$FX_DIST/system_wrappers/stdio.h" || return 1
  # Not part of the package; carries a producer path to prove it is left out.
  printf 'host tool from %s\n' "$FX_OBJ" >"$FX_DIST/host/bin/nsinstall" || return 1

  python3 - "$FX_DIST/include-private/js-build-config.json" "$FX_SRC" "$FX_OBJ" "$FX_CLANG" "$FX_SYSROOT" <<'PY' || return 1
import json, sys
out, src, obj, clang, sysroot = sys.argv[1:]
config = {
    "topsrcdir": src,
    "topobjdir": obj,
    "cxx": "%s/bin/clang++ --sysroot %s -std=gnu++20 --target=wasm32-wasi" % (clang, sysroot),
    "cc": "%s/bin/clang --sysroot=%s -std=gnu17 --target=wasm32-wasi" % (clang, sysroot),
    "ar": "%s/bin/llvm-ar" % clang,
    "cxx_base_flags": ["--sysroot", sysroot, "-isysroot", sysroot, "-fno-exceptions"],
    "os_cxxflags": ["-fno-sized-deallocation", "-fno-aligned-new"],
    "optimize_flags": ["-O2"],
    "debug_flags": [],
    "warnings_cxxflags": ["-Wall"],
    "debug_defines": ["NDEBUG", "TRIMMED=1"],
    "extra_cxxflags": ["-fno-strict-aliasing", "-ffp-contract=off"],
    "library_defines": ["MOZILLA_CLIENT", "EXPORT_JS_API", "MOZ_HAS_MOZGLUE",
                        "MOZ_SUPPORT_LEAKCHECKING"],
    "force_includes": ["gcc_hidden.h", "js-confdefs.h"],
    "include_dirs": ["include-private", "include", "system_wrappers"],
    "os_ldflags": ["-Wl,--export-dynamic"],
    "rust_target": "wasm32-wasip1",
    "os_arch": "WASI",
    "moz_debug": False,
    "js_shell_wizer": True,
    "libraries": ["lib/libjsshell.a", "lib/libjs_static.a", "lib/libjsrust.a",
                  "lib/libpure_virtual.a"],
}
with open(out, "w") as f:
    json.dump(config, f, indent=2, sort_keys=True)
PY

  python3 - "$FX_MANIFEST" <<'PY' || return 1
import json, sys
m = {
    "tag": "FIREFOX_147_0_4_RELEASE",
    "commit": "310a0cc30b21a4ddf7f0826a67f73bed6b050349",
    "tree": "092cc9d0409ebc66acc52def28a2ed8f30a92b5d",
    "ics_path": "js/src/ics",
    "queue_sha256": "1" * 64,
    "data_ics_sha256": "2" * 64,
    "mozconfig_sha256": "3" * 64,
    "toolchain_artifacts": [
        {"name": "clang.tar.zst", "url": "https://example.invalid/clang/clang.tar.zst",
         "sha256": "a" * 64, "size": 12345},
        {"name": "sysroot-wasm32-wasi.tar.zst",
         "url": "https://example.invalid/sysroot/sysroot-wasm32-wasi.tar.zst", "sha256": "b" * 64},
    ],
    "rust_version": "rustc 1.98.1 (fixture)",
}
with open(sys.argv[1], "x") as f:
    json.dump(m, f, indent=2)
    f.write("\n")
PY
}
