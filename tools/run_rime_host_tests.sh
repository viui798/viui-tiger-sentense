#!/usr/bin/env bash
# CI-only, owned temporary builds; no installed Rime user data is modified.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${RUNNER_TEMP:?RUNNER_TEMP must point to the CI scratch directory}"

# Keep the distribution's older engine as a compatibility test for the base chain.
g++ -std=c++17 -O2 tools/rime_api_probe.cpp -lrime -ldl -o "$RUNNER_TEMP/rime-api-probe-old"
old_plugin=$(dpkg -L librime-plugin-lua | grep -E '/librime-lua\.so$' | head -n 1)
test -n "$old_plugin"
python3 tools/rime_integration_test.py --exe "$RUNNER_TEMP/rime-api-probe-old" --plugin "$old_plugin"

# _hide_candidate only suppresses C API menus in librime >= 1.16 (#1115).
# Build a pinned modern core AND plugin; mixing a new core with an old plugin
# would make ABI compatibility, rather than this scheme, determine the result.
sudo apt-get update
sudo apt-get install -y cmake ninja-build libboost-dev libboost-regex-dev \
  libleveldb-dev libmarisa-dev libopencc-dev libyaml-cpp-dev liblua5.4-dev libx11-dev
root=$(mktemp -d "$RUNNER_TEMP/tiger-rime-modern-XXXXXX")
trap 'rm -rf "$root"' EXIT
core=33e78140250125871856cdc5b42ddc6a5fcd3cd4
lua=ad1e4a6c98abf634dd34242a747f9b1d5d069fbe
checkout() {
  git init -q "$3"
  git -C "$3" fetch -q --depth=1 "$1" "$2"
  git -C "$3" checkout -q --detach FETCH_HEAD
  test "$(git -C "$3" rev-parse HEAD)" = "$2"
}
checkout https://github.com/rime/librime.git "$core" "$root/src"
checkout https://github.com/hchunhui/librime-lua.git "$lua" "$root/src/plugins/lua"
echo "Modern host: librime 1.17.0 $core; librime-lua $lua"
RIME_PLUGINS=lua cmake -S "$root/src" -B "$root/build" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DBUILD_TEST=OFF -DBUILD_STATIC=OFF \
  -DBUILD_SHARED_LIBS=ON -DBUILD_MERGED_PLUGINS=OFF -DENABLE_LOGGING=OFF \
  -DLUA_VERSION=lua5.4
cmake --build "$root/build" --target rime rime-lua --parallel 2
export LD_LIBRARY_PATH="$root/build/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
plugin="$root/build/lib/rime-plugins/librime-lua.so"
test -f "$plugin"
for name in api preedit options correction_levels; do
  g++ -std=c++17 -O2 "tools/rime_${name}_probe.cpp" -I"$root/src/src" \
    -L"$root/build/lib" -Wl,-rpath,"$root/build/lib" -lrime -ldl -o "$root/rime-$name-probe"
done
python3 tools/rime_integration_test.py --exe "$root/rime-api-probe" --plugin "$plugin"
python3 tools/test_rime_preedit_integration.py --exe "$root/rime-preedit-probe" --plugin "$plugin"
python3 tools/test_rime_options_integration.py --exe "$root/rime-options-probe" --plugin "$plugin"
python3 tools/test_rime_options_integration.py --exe "$root/rime-options-probe" --plugin "$plugin" --negative-control

python3 tools/test_rime_correction_levels_integration.py --exe "$root/rime-correction_levels-probe" --plugin "$plugin"
