unit := home_dir() / ".config/systemd/user/rambla.service"
desktop := home_dir() / ".local/share/applications/rambla.desktop"

# List recipes.
@list:
    just --list

# Build rambla
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

# Uninstall systemd unit.
uninstall: stop systemctl-reload
    systemctl --user disable rambla.service
    rm -f "{{unit}}"

# Clean build outputs.
[script]
clean: stop
    set -euo pipefail
    rm -rf **/node_modules
    rm -rf packages/desktop/release packages/*/dist
    find . -name '*.tsbuildinfo' -not -path './node_modules/*' -delete
    rm -rf packages/app/.expo/types
    echo "cleaned: all dist outputs and build state removed"

# Check whether CI is green.
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

# Headless e2e suites (no device). Stops at the first failure.
e2e: e2e-server e2e-cli e2e-app e2e-desktop

e2e-server:
    PORT=26767 npm run test:integration -w @getpaseo/server

e2e-cli:
    PORT=26768 npm run test:local -w @getpaseo/cli

e2e-app:
    npm run test:e2e -w @getpaseo/app

e2e-desktop:
    npm run test:e2e:renderer -w @getpaseo/desktop

start:
    systemctl --user start rambla

stop:
    systemctl --user stop rambla || true

systemctl-reload:
    systemctl --user daemon-reload

restart:
    systemctl --user enable rambla
    systemctl --user restart rambla

status:
    systemctl --user status rambla

[script]
install-daemon: && install-service
    eval "$(mise env -s bash)"
    npm run build:server

[script]
install-service: systemctl-reload restart
    mkdir -p "$(dirname "{{unit}}")"
    cat > {{unit}} <<EOF
    [Unit]
    Description=Rambla daemon

    [Service]
    Type=simple
    WorkingDirectory={{justfile_dir()}}
    ExecStart={{justfile_dir()}}/packages/cli/bin/rambla start --foreground
    Restart=always
    RestartSec=5

    [Install]
    WantedBy=graphical-session.target
    EOF


# # Incremental - Broken - Install dependencies, build, install rambla service unit.
# [script]
# install:
#     set -euo pipefail
#     if ! command -v mise >/dev/null 2>&1; then
#         echo "error: 'mise' is required (it pins the Node version this repo builds with)."
#         echo "  install: https://mise.jdx.dev/installing-mise.html  (then: mise install)"
#         exit 1
#     fi
#     eval "$(mise env -s bash)"

#     npm install
#     ./tsconfig/build.sh

#     if [ "$have_systemd" != "yes" ]; then
#         echo "[install] done (build only — no service installed on this platform)"
#         exit 0
#     fi

#     systemctl --user restart rambla
#     sleep 2
#     if systemctl --user is-active --quiet rambla; then
#         echo "[install] rambla.service installed and running."
#         echo "  logs:      just log"
#         echo "  rebuild:   just restart"
#     else
#         echo "error: rambla.service did not come up. Check:" >&2
#         echo "  journalctl --user -u rambla -n 50 --no-pager" >&2
#         exit 1
#     fi

# Build the desktop app.
[script]
install-app: && install-desktop
    set -euo pipefail
    eval "$(mise env -s bash)"
    # SKIP linux packages with -- --dir
    npm run build:desktop -- --dir

# Write the desktop launcher (XDG .desktop entry).
[script]
install-desktop:
    set -euo pipefail
    mkdir -p "$(dirname "{{desktop}}")"
    cat > {{desktop}} <<EOF
    [Desktop Entry]
    Type=Application
    Name=Rambla
    Exec={{justfile_dir()}}/packages/desktop/release/linux-unpacked/Paseo
    Icon={{justfile_dir()}}/packages/desktop/assets/icon.png
    Categories=Development;
    Terminal=false
    EOF

# Show the daemon log tail.
daemon-log lines="40":
    tail -n {{lines}} ~/.rambla/daemon.log

logs lines="40":
    journalctl --user -n {{lines}} -u rambla
