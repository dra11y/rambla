# List recipes.
@list:
    just --list

# Incremental build.
[script]
build:
    set -euo pipefail
    if ! command -v mise >/dev/null 2>&1; then
        echo "error: 'mise' is required (it pins the Node version this repo builds with)."
        echo "  install: https://mise.jdx.dev/installing-mise.html  (then: mise install)"
        exit 1
    fi
    eval "$(mise env -s bash)"
    ./tsconfig/build.sh

# Clean build outputs.
[script]
clean:
    set -euo pipefail
    rm -rf packages/*/dist tsconfig/*.tsbuildinfo
    echo "cleaned: all dist outputs and build state removed"

# Install dependencies, build, and install the rambla user service.
[script]
install:
    set -euo pipefail
    if ! command -v mise >/dev/null 2>&1; then
        echo "error: 'mise' is required (it pins the Node version this repo builds with)."
        echo "  install: https://mise.jdx.dev/installing-mise.html  (then: mise install)"
        exit 1
    fi
    eval "$(mise env -s bash)"

    if ! command -v systemctl >/dev/null 2>&1; then
        if [ "$(uname)" = "Darwin" ]; then
            echo ""
            echo "macOS: dependencies install and the build runs, but the launchd"
            echo "user service is not wired up yet (TODO). For now, start the"
            echo "daemon manually:"
            echo ""
            echo "    ./packages/cli/bin/paseo daemon start"
            echo ""
        else
            echo "error: systemd not found — this install path currently supports Linux only." >&2
        fi
        exit 0
    fi

    have_systemd=$(command -v systemctl >/dev/null 2>&1 && echo yes || echo no)

    # npm ci only when node_modules is missing or the lockfile changed.
    lock_hash=$(sha256sum package-lock.json | cut -d' ' -f1)
    if [ ! -d node_modules ] || ! [ -f .dev/lock-hash ] || [ "$(cat .dev/lock-hash)" != "$lock_hash" ]; then
        echo "[install] installing dependencies (missing or lockfile changed)"
        npm ci
        mkdir -p .dev && printf '%s' "$lock_hash" > .dev/lock-hash
    else
        echo "[install] dependencies up to date, skipping npm ci"
    fi

    ./tsconfig/build.sh

    if [ "$have_systemd" != "yes" ]; then
        echo "[install] done (build only — no service installed on this platform)"
        exit 0
    fi

    unit="$HOME/.config/systemd/user/rambla.service"
    mkdir -p "$(dirname "$unit")"
    {
        echo "[Unit]"
        echo "Description=Rambla daemon"
        echo ""
        echo "[Service]"
        echo "Type=simple"
        echo "WorkingDirectory={{justfile_dir()}}"
        echo "Environment=\"PASEO_LOG_LEVEL=info\""
        echo "ExecStart={{justfile_dir()}}/packages/cli/bin/paseo start --foreground"
        echo "Restart=always"
        echo "RestartSec=5"
        echo ""
        echo "[Install]"
        echo "WantedBy=default.target"
    } > "$unit"

    systemctl --user daemon-reload
    systemctl --user enable rambla
    if systemctl --user list-unit-files 2>/dev/null | grep -q "^paseo\.service"; then
        echo "[install] legacy 'paseo' service found — disabling it so it cannot fight rambla for the port"
        systemctl --user disable --now paseo 2>/dev/null || true
    fi
    systemctl --user restart rambla
    sleep 2
    if systemctl --user is-active --quiet rambla; then
        echo "[install] rambla.service installed and running."
        echo "  logs:      just log"
        echo "  rebuild:   just restart"
    else
        echo "error: rambla.service did not come up. Check:" >&2
        echo "  journalctl --user -u rambla -n 50 --no-pager" >&2
        exit 1
    fi

# Rebuild and restart the daemon.
[script]
restart: build
    set -euo pipefail
    if [ "$(uname)" = "Darwin" ]; then
        echo "TODO: macOS launchd service not set up yet. Rebuild done; start manually:"
        echo "  ./packages/cli/bin/paseo daemon start"
        exit 0
    fi
    systemctl --user restart rambla
    sleep 2
    systemctl --user --no-pager status rambla | head -5 || true

# Show the daemon log tail.
log lines="40":
    tail -n {{lines}} ~/.paseo/daemon.log
