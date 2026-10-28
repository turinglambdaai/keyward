#!/usr/bin/env bash
# Release-acceptance smoke: run the packaged host against a synthetic
# disposable vault and assert — through the accessibility tree — that
# the sidebar lists the vault's product. Two launches: the first selects
# the vault via KEYWARD_STORE, the second restores it from the persisted
# config (the v0.2.0 restart-wedge scenario). No real key material is
# ever touched; the vault and config live in mktemp directories.
#
# Usage: dbus-run-session -- bash release-acceptance.sh /path/to/RivetHost
# dbus-run-session provides the session bus the GTK a11y bridge needs;
# xvfb-run (inside) provides the headless display. Job control (-m) puts
# each xvfb-run into its own process group so stop_host can take the
# wrapper, Xvfb and the app down together — by group, never by name
# matching (a pkill -f pattern can match this script's own argv).
# Do not wrap this script in a second xvfb-run: nested Xvfb teardown
# kills the app mid-run.
set -euom pipefail

HOST="${1:?usage: release-acceptance.sh <path-to-RivetHost>}"
CONFIG_DIR="$(mktemp -d)"
VAULT="$(mktemp -d)/acceptance-vault.ini"
printf '[acceptance-app]\nACCEPTANCE_NOTE = synthetic\n' > "$VAULT"
export KEYWARD_CONFIG_DIR="$CONFIG_DIR"
export GSK_RENDERER=cairo

assert_product_visible() {
  python3 <<'PY'
import sys, time
import pyatspi

needle = "acceptance-app"

def walk(obj, depth=0):
    if depth > 14:
        return False
    try:
        text = (obj.name or "") + (obj.description or "")
    except Exception:
        return False
    if needle in text:
        return True
    try:
        for i in range(obj.childCount):
            if walk(obj.getChildAtIndex(i), depth + 1):
                return True
    except Exception:
        pass
    return False

for _ in range(10):
    desktop = pyatspi.Registry.getDesktop(0)
    for i in range(desktop.childCount):
        if walk(desktop.getChildAtIndex(i)):
            print("acceptance: sidebar lists %s" % needle)
            sys.exit(0)
    time.sleep(2)
sys.exit("acceptance failed: the sidebar never listed %r" % needle)
PY
}

launch_and_assert() {
  xvfb-run -a "$HOST" > /tmp/keyward-acceptance.log 2>&1 &
  APP=$!
  sleep 8
  kill -0 "$APP"
  assert_product_visible
}

stop_host() {
  kill -TERM -- "-$APP" 2>/dev/null || true
  for _ in $(seq 1 15); do
    kill -0 -- "-$APP" 2>/dev/null || break
    sleep 1
  done
  kill -KILL -- "-$APP" 2>/dev/null || true
  sleep 1
}

# launch 1: the vault comes from KEYWARD_STORE
KEYWARD_STORE="$VAULT" launch_and_assert
stop_host

# the choice persists the way store-open persists it; launch 2 restores
# from config.json alone (no env var) — the v0.2.0 wedge scenario. The
# wait in stop_host guarantees the previous primary instance has left
# the bus, or this launch would exit instantly via GApplication
# uniqueness.
mkdir -p "$CONFIG_DIR"
printf '{"store": "%s"}\n' "$VAULT" > "$CONFIG_DIR/config.json"
launch_and_assert
stop_host

echo "acceptance smoke: OK"
