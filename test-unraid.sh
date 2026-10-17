#!/bin/bash
# Check the plugin on a given Unraid release, without Unraid: unpack the release's root
# filesystem and, in a chroot, install the .plg with Unraid's own plugin manager, query the
# agent, run the settings page's save.php under Unraid's PHP and remove the plugin.
# Not covered: the real emhttpd state files (faked below) and the page in a browser.
# Usage: ./test-unraid.sh <unraid-version>      Needs docker (privileged, for /proc), jq, python3.
set -euo pipefail
cd "$(dirname "$0")"

VER=${1:?usage: $0 <unraid-version>}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

read -r URL SHA < <(curl -fsSL https://releases.unraid.net/json |
  jq -r --arg v "$VER" '.[] | select(.version == $v) | "\(.url) \(.sha256)"') || true
if [ -z "${URL:-}" ]; then   # not stable: try the current beta/rc (the zip sits next to its changelog .txt)
  read -r URL SHA < <(curl -fsSL "https://releases.unraid.net/os?branch=next" |
    jq -r --arg v "$VER" 'select(.version == $v) | "\(.changelog | sub("\\.txt$"; ".zip")) \(.sha256)"') || true
fi
[ -n "${URL:-}" ] || { echo "Unraid $VER not found in release list" >&2; exit 1; }

echo "Downloading Unraid $VER"
# Big download: a stalled connection never ends on its own, so abort below 100 kB/s for 60 s and retry.
curl -fsSL --retry 3 --retry-all-errors --speed-limit 102400 --speed-time 60 -o "$WORK/unraid.zip" "$URL"
echo "$SHA  $WORK/unraid.zip" | sha256sum -c --quiet -
python3 -I -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2], ["bzroot", "bzmodules", "bzfirmware"])' \
  "$WORK/unraid.zip" "$WORK"
rm "$WORK/unraid.zip"
sed 's/@VERSION@/2099.01.01/' zabbix-agent.plg > "$WORK/zabbix-agent.plg"

docker run --rm --privileged -v "$WORK:/w:ro" debian:trixie-slim bash -euc '
  apt-get -qq update >/dev/null && DEBIAN_FRONTEND=noninteractive apt-get -qq install -y xz-utils zstd cpio squashfs-tools jq >/dev/null
  fail() { echo "FAIL: $*"; exit 1; }
  ok() { echo "ok: $*"; }
  run() { chroot /r "$@"; }

  # bzroot = uncompressed microcode cpio, then the root cpio compressed with zstd (7.3) or xz.
  # /usr is not in bzroot but in a squashfs: bzfirmware up to 7.2, bzmodules from 7.3.
  END=$(grep -obUa "TRAILER!!!" /w/bzroot | head -1 | cut -d: -f1)
  tail -c +$((END + 1)) /w/bzroot > /tmp/rest
  ZST=$(grep -obUaP "\x28\xB5\x2F\xFD" /tmp/rest | head -1 | cut -d: -f1); ZST=${ZST:-999999999}
  XZ=$(grep -obUaP "\xFD7zXZ\x00" /tmp/rest | head -1 | cut -d: -f1); XZ=${XZ:-999999999}
  if [ "$ZST" -lt "$XZ" ]; then OFF=$ZST; DEC="zstd -dc"; else OFF=$XZ; DEC="xz -dc"; fi
  mkdir /r && cd /r
  tail -c +$((OFF + 1)) /tmp/rest | $DEC | cpio -idm --quiet 2>/dev/null || true
  [ -f /r/etc/unraid-version ] || fail "could not unpack bzroot"
  for IMG in /w/bzmodules /w/bzfirmware; do   # whichever image carries lib64 is /usr
    if unsquashfs -l "$IMG" lib64 2>/dev/null | grep -q "^squashfs-root/lib64/"; then
      unsquashfs -q -n -f -d /r/usr "$IMG" >/dev/null
    fi
  done
  echo "Unraid root: $(cat /r/etc/unraid-version)"
  mount -t proc proc /r/proc
  mkdir -p /r/dev && cp -a /dev/null /dev/random /dev/urandom /r/dev/
  cp /etc/resolv.conf /r/etc/resolv.conf
  mkdir -p /r/boot/config/plugins /r/var/log/plugins /r/tmp/plugins /r/var/local/emhttp

  # emhttpd writes these at runtime; they are not in the image.
  echo "mdState=\"STARTED\"" > /r/var/local/emhttp/var.ini
  cat > /r/var/local/emhttp/disks.ini <<EOF
["parity"]
name="parity"
device=""
status="DISK_NP_DSBL"
type="Parity"
["disk1"]
name="disk1"
device="sdb"
status="DISK_OK"
temp="31"
numErrors="0"
type="Data"
["flash"]
name="flash"
device="sda"
status="DISK_OK"
temp="*"
type="Flash"
EOF

  # 1. Install with the plugin manager: download, SHA256, scripts, agent start.
  cp /w/zabbix-agent.plg /r/tmp/zabbix-agent.plg
  out=$(run /usr/local/sbin/plugin install /tmp/zabbix-agent.plg 2>&1 | tr "\r" "\n" | grep -v "downloading:.*%") || true
  echo "$out"
  grep -q "zabbix-agent.plg installed" <<< "$out" || fail "plugin install"
  ok "plugin install"

  get() { run /usr/local/bin/zabbix_get -s 127.0.0.1 -k "$1"; }
  for i in $(seq 20); do [ "$(get agent.ping 2>/dev/null)" = 1 ] && break; sleep 0.5; done
  [ "$(get agent.ping)" = 1 ] || fail "agent does not answer"
  ok "agent.ping"

  # 2. Unraid keys: sed, PHP and smartctl of this release.
  [ "$(get unraid.array.state)" = STARTED ] || fail "unraid.array.state"
  ok "unraid.array.state"
  [ "$(get unraid.disks | jq -r .disk1.device)" = sdb ] || fail "unraid.disks: $(get unraid.disks)"
  ok "unraid.disks"
  run smartctl -h | grep -q -- "--nocheck=MODE" || fail "smartctl has no -n (standby)"
  get "unraid.smart.health[sda]" >/dev/null || fail "unraid.smart.health"
  ok "smartctl $(run smartctl -V | head -1 | cut -d" " -f2)"

  # 3. Settings page: PHP syntax under this release, then save.php for real.
  P=/r/usr/local/emhttp/plugins/zabbix-agent
  sed "1,/^---\$/d" $P/ZabbixAgent.page > /r/tmp/page.php
  run php -l /tmp/page.php >/dev/null || fail "ZabbixAgent.page: $(run php -l /tmp/page.php)"
  run php -l /usr/local/emhttp/plugins/zabbix-agent/include/save.php >/dev/null || fail "save.php syntax"
  ok "php -l ($(run php -r "echo PHP_VERSION;"))"
  CONF=/r/boot/config/plugins/zabbix-agent/zabbix_agentd.conf
  save() { run php -r "\$_POST = json_decode(\$argv[1], true); include \"/usr/local/emhttp/plugins/zabbix-agent/include/save.php\";" "$1"; }
  before=$(cat $CONF)
  [ -n "$(save "{\"Server\":\"127.0.0.1\",\"extra\":\"NoSuchOption=1\"}")" ] || fail "save.php accepted a bad option"
  [ -n "$(save "{\"Server\":\"127.0.0.1\",\"extra\":\"Hostname=x\"}")" ] || fail "save.php accepted a form key in Advanced"
  [ "$(cat $CONF)" = "$before" ] || fail "save.php wrote a rejected config"
  ok "save.php rejects bad settings"
  pid=$(run pgrep -x zabbix_agentd | head -1)
  msg=$(save "{\"Server\":\"127.0.0.1\",\"Hostname\":\"ci-test\",\"extra\":\"Timeout=5\"}")
  [ -z "$msg" ] || fail "save.php: $msg"
  grep -qx "Hostname=ci-test" $CONF && grep -qx "Timeout=5" $CONF || fail "save.php did not write: $(cat $CONF)"
  for i in $(seq 20); do [ "$(get agent.hostname 2>/dev/null)" = ci-test ] && break; sleep 0.5; done
  [ "$(get agent.hostname)" = ci-test ] || fail "agent not restarted with the new settings"
  [ "$(run pgrep -x zabbix_agentd | head -1)" != "$pid" ] || fail "agent not restarted"
  ok "save.php writes and restarts"

  # 4. Remove: binaries gone, settings kept.
  run /usr/local/sbin/plugin remove zabbix-agent.plg >/dev/null 2>&1 || true
  [ ! -e /r/usr/local/sbin/zabbix_agentd ] || fail "binary left after remove"
  ! run pgrep -x zabbix_agentd >/dev/null || fail "agent still running after remove"
  [ -f $CONF ] || fail "settings removed"
  ok "plugin remove"
  echo "PASS"
'
