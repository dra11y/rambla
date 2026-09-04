#!/usr/bin/env bash
# Rambla incremental build.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Regenerate protocol AOT validators only when their inputs changed.
gen="packages/protocol/src/generated/validation/ws-outbound.aot.ts"
if [ ! -f "$gen" ] || [ -n "$(find packages/protocol/codegen packages/protocol/src/validation -newer "$gen" -print -quit 2>/dev/null)" ]; then
  echo "[rambla-build] regenerating protocol validators"
  node --experimental-strip-types packages/protocol/scripts/generate-validation-aot.mjs 2>/dev/null \
    || (cd packages/protocol && npx tsx scripts/generate-validation-aot.mjs)
fi

echo "[rambla-build] tsc -b (incremental)"
npx tsc -b tsconfig/tsconfig.json

# Bundle the OpenCode bridge plugin; the built daemon fails to boot without it.
node packages/server/scripts/build-opencode-bridge-plugin.mjs

# Build the native audio module for the app.
(cd packages/expo-two-way-audio && npx tsc >/dev/null 2>&1 || true)

# Copy server runtime assets.
server_dist="packages/server/dist/server"
mkdir -p "$server_dist/server/speech/providers/local/sherpa/assets"
[ -f packages/server/src/server/speech/providers/local/sherpa/assets/silero_vad.onnx ] && \
  cp -f packages/server/src/server/speech/providers/local/sherpa/assets/silero_vad.onnx \
       "$server_dist/server/speech/providers/local/sherpa/assets/"
rm -rf "$server_dist/skills"
cp -R skills "$server_dist/skills"
# shell-integration is resolved relative to the compiled file (import.meta.url)
cp -R packages/server/src/terminal/shell-integration "$server_dist/terminal/shell-integration" 2>/dev/null || true
mkdir -p packages/server/dist/src/terminal
cp -R packages/server/src/terminal/shell-integration packages/server/dist/src/terminal/shell-integration 2>/dev/null || true
cp -f packages/server/src/terminal/terminal-ts-loader.mjs "$server_dist/terminal/" 2>/dev/null || true

# Mirror the supervisor's src imports (dist/src/...) from the server output.
src_out="packages/server/dist/src"
mkdir -p "$src_out/server" "$src_out/server/agent" "$src_out/utils" "$src_out/executable-resolution" "$src_out/server/speech/providers/local/sherpa"
for f in pid-lock private-files paseo-home paseo-env persisted-config; do
  cp -f "$server_dist/server/$f.js" "$server_dist/server/$f.d.ts" "$src_out/server/" 2>/dev/null || true
done
for f in windows-command spawn tree-kill; do
  cp -f "$server_dist/utils/$f.js" "$server_dist/utils/$f.d.ts" "$src_out/utils/" 2>/dev/null || true
done
cp -f "$server_dist/executable-resolution/executable-resolution.js" "$server_dist/executable-resolution/executable-resolution.d.ts" "$src_out/executable-resolution/" 2>/dev/null || true
cp -f "$server_dist/executable-resolution/windows.js" "$server_dist/executable-resolution/windows.d.ts" "$src_out/executable-resolution/" 2>/dev/null || true
cp -f "$server_dist/server/agent/provider-launch-config.js" "$server_dist/server/agent/provider-launch-config.d.ts" "$src_out/server/agent/" 2>/dev/null || true
cp -f "$server_dist/server/speech/providers/local/sherpa/sherpa-runtime-env.js" \
      "$server_dist/server/speech/providers/local/sherpa/sherpa-runtime-env.d.ts" \
      "$src_out/server/speech/providers/local/sherpa/" 2>/dev/null || true

echo "[rambla-build] done: $(ls -d packages/*/dist 2>/dev/null | wc -l) packages built"

# The supervisor entrypoint imports ../src/server/* relative to dist/scripts/,
# which upstream's scripts build emits as dist/src/. Our server project emits
# those files as dist/server/server/, so mirror them to dist/src/.
