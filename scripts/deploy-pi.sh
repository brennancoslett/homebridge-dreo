#!/usr/bin/env bash
# Deploy this checkout to the Homebridge Pi.
#
# The plugin is installed with `npm install --save` from a packed tarball rather than
# rsynced into node_modules, so it is recorded in the Pi's storage package.json. Anything
# that later runs `npm install` there (the homebridge apt package's postinst, or hb-service
# re-installing a missing homebridge module on start) then reinstalls this build instead of
# pruning the plugin, which makes Homebridge drop its accessories and their HomeKit rooms.
#
# Usage: scripts/deploy-pi.sh            (HB_HOST overrides the ssh host, default "hb")
set -euo pipefail

HOST="${HB_HOST:-hb}"
STORAGE=/var/lib/homebridge
LOG="$STORAGE/homebridge.log"

cd "$(dirname "$0")/.."

echo "==> Preflight on $HOST"
ssh "$HOST" STORAGE="$STORAGE" bash -s <<'EOF'
set -euo pipefail
if pgrep -x apt >/dev/null || pgrep -x apt-get >/dev/null || pgrep -x dpkg >/dev/null; then
  echo "apt/dpkg is running on the Pi; wait for it to finish" >&2
  exit 1
fi
state=$(dpkg-query -W -f='${db:Status-Abbrev}' homebridge)
if [[ "$state" != ii* ]]; then
  echo "homebridge package is not fully installed (state '$state'); run: sudo dpkg --configure -a" >&2
  exit 1
fi
if [ ! -f "$STORAGE/node_modules/homebridge/package.json" ]; then
  echo "homebridge module is missing; a restart would reinstall it and prune plugins" >&2
  exit 1
fi
if ! grep -q '"keepOrphans": *true' "$STORAGE/.uix-hb-service-homebridge-startup.json"; then
  echo "warning: keepOrphans is off, a plugin that fails to load will lose its accessories" >&2
fi
EOF

echo "==> Packing"
sha=$(git rev-parse --short HEAD)
if [ -n "$(git status --porcelain -- src package.json)" ]; then
  sha="$sha-dirty"
fi
pack_dir=$(mktemp -d)
trap 'rm -rf "$pack_dir"' EXIT
npm pack --silent --pack-destination "$pack_dir" >/dev/null
tarball="homebridge-dreo-$sha.tgz"
mv "$pack_dir"/homebridge-dreo-*.tgz "$pack_dir/$tarball"

echo "==> Installing $tarball"
ssh "$HOST" "mkdir -p $STORAGE/local-plugins"
scp -q "$pack_dir/$tarball" "$HOST:$STORAGE/local-plugins/$tarball"
# A unique file name per build changes the dependency spec, so npm always reinstalls it.
# The homebridge postinst writes package.json as root, so make sure pi can update it.
ssh "$HOST" "sudo chown pi:pi $STORAGE/package.json && cd $STORAGE && \
  PATH=/opt/homebridge/bin:\$PATH npm --prefix $STORAGE install --save ./local-plugins/$tarball && \
  find $STORAGE/local-plugins -name 'homebridge-dreo-*.tgz' ! -name '$tarball' -delete"

echo "==> Verifying installed build"
local_hash=$(find dist -name '*.js' | sort | xargs shasum | shasum)
remote_hash=$(ssh "$HOST" "cd $STORAGE/node_modules/homebridge-dreo && find dist -name '*.js' | sort | xargs shasum | shasum")
if [ "$local_hash" != "$remote_hash" ]; then
  echo "installed dist does not match local build" >&2
  exit 1
fi

echo "==> Restarting Homebridge"
start_line=$(ssh "$HOST" "wc -l < $LOG")
ssh "$HOST" "sudo hb-service restart" >/dev/null

# Wait for startup, then report the plugin's startup lines and anything alarming
ssh "$HOST" START="$start_line" LOG="$LOG" bash -s <<'EOF'
new_lines() { tail -n +"$((START + 1))" "$LOG" | sed 's/\x1b\[[0-9;]*m//g'; }
for _ in $(seq 1 120); do
  new_lines | grep -a -q 'is running on port' && break
  sleep 5
done
sleep 10
new_lines | grep -a -E 'No plugin was found|Removing orphaned|Removing accessories|\[Dreo Platform\].*([Ee]rror|WebSocket Opened|Refreshing)|is running on port'
if new_lines | grep -a -q -E 'No plugin was found|Removing orphaned|Removing accessories'; then
  echo "Homebridge dropped plugins or accessories, check the log" >&2
  exit 1
fi
EOF
echo "==> Deployed $sha"
