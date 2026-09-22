#!/usr/bin/env bash
# Builds wrk2 (https://github.com/giltene/wrk2) into loadtest/.wrk2/wrk.
#
# Upstream wrk2 bundles LuaJIT 2.0 and includes <x86intrin.h>, neither of which
# builds on Apple Silicon. On macOS this links against Homebrew's LuaJIT 2.1 and
# OpenSSL instead and drops the (unused) x86 header; on x86_64 Linux the stock
# build works as-is.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)/.wrk2"

if [[ -x "$DIR/wrk" ]]; then
  echo "wrk2 already built: $DIR/wrk"
  exit 0
fi

rm -rf "$DIR"
git clone --depth 1 https://github.com/giltene/wrk2 "$DIR"
cd "$DIR"

if [[ "$(uname -s)" == "Darwin" ]]; then
  brew list luajit >/dev/null 2>&1 || brew install luajit
  brew list openssl@3 >/dev/null 2>&1 || brew install openssl@3
  LUAJIT="$(brew --prefix luajit)"
  OPENSSL="$(brew --prefix openssl@3)"

  # Stand-in for deps/luajit/src with the pieces the Makefile expects there.
  SHIM="$DIR/luajit-shim"
  mkdir -p "$SHIM"
  ln -sf "$LUAJIT/lib/libluajit-5.1.a" "$SHIM/libluajit.a"
  ln -sf "$LUAJIT/bin/luajit" "$SHIM/luajit"
  ln -sf "$LUAJIT"/include/luajit-2.1/*.h "$SHIM/"

  sed -i '' '/x86intrin.h/d' src/hdr_histogram.c

  make -j"$(sysctl -n hw.ncpu)" \
    LDIR="$SHIM" \
    CFLAGS="-std=c99 -O2 -D_REENTRANT -DluaL_reg=luaL_Reg -I$SHIM -I$OPENSSL/include" \
    LDFLAGS="-L$SHIM" \
    LIBS="-lluajit -lpthread -lm -L$OPENSSL/lib -lcrypto -lssl"
else
  make -j"$(nproc)"
fi

echo "Built: $DIR/wrk"
