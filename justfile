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

# Check whether CI on getrambla/rambla is green. On failure: the error lines in red,
# plus (yellow) any upstream workflow changes GitHub refused to let the
# auto-merge push. Intentionally no fix, no retry — upstream CI changes should
# break the merge loudly until reviewed by hand.
[script]
ci-status:
    set -euo pipefail
    RED=$(tput -T xterm-256color setaf 1) YEL=$(tput -T xterm-256color setaf 3) GRN=$(tput -T xterm-256color setaf 2) OFF=$(tput -T xterm-256color sgr0)

    echo "Latest workflow runs on getrambla/rambla:"
    gh run list -R getrambla/rambla --limit 5 \
        --json workflowName,conclusion,status,createdAt,displayTitle,databaseId \
        --jq '.[] | "  \(.createdAt[0:10])  \(.conclusion // .status)  \(.workflowName)  \(.displayTitle)  (\(.databaseId))"'

    failed="$(gh run list -R getrambla/rambla --limit 15 \
        --json databaseId,conclusion \
        --jq '[.[] | select(.conclusion == "failure")][0].databaseId // ""')"

    if [ -z "$failed" ]; then
        echo "${GRN}All recent runs passed.${OFF}"
    else
        echo
        echo "${RED}FAILED run $failed — https://github.com/getrambla/rambla/actions/runs/$failed${OFF}"
        echo "Error lines from the failing step:"
        errs="$(gh run view "$failed" -R getrambla/rambla --log-failed 2>/dev/null \
            | grep -E '##\[error\]|refusing to allow|CONFLICT|error TS|npm error|fatal:' \
            | sed 's/^[^ ]* [^ ]* [0-9T:.Z-]*Z //' \
            | sort -u | head -15 || true)"
        if [ -n "$errs" ]; then
            printf '%s\n' "$errs"
        else
            # No step log exists (run died before any step started, or GitHub
            # pruned it). Facts only: what jobs exist and how they ended.
            jobs="$(gh api "repos/getrambla/rambla/actions/runs/$failed/jobs" \
                --jq '.jobs[] | "  \(.name): \(.conclusion)"' || true)"
            if [ -n "$jobs" ]; then
                printf 'Jobs:\n%s\n' "$jobs"
            else
                echo "no jobs were created — the run failed before any step ran"
            fi
        fi
    fi

    echo
    echo "Upstream workflow changes not yet on origin/main (what the auto-merge would try to push):"
    git fetch upstream main -q
    if git diff --quiet origin/main...upstream/main -- .github/workflows/; then
        echo "${GRN}none — .github/workflows/ matches upstream${OFF}"
    else
        echo "${YEL}"
        git --no-pager diff origin/main...upstream/main -- .github/workflows/
        echo "${OFF}"
    fi

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
        echo "WantedBy=graphical-session.target"
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
