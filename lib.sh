temp_podman_machine() {
  (
    set -eu
    [ "${DEBUG:-}" ] && set -x

    if [ "$#" -lt 2 ]; then
        echo "usage: temp-podman-machine pid [podman-machine-init-args...] machine-name" >&2
        exit 2
    fi

    ensure_podman() {
        if command -v podman >/dev/null 2>&1; then
            return 0
        fi

        if command -v brew >/dev/null 2>&1; then
            brew install podman || {
                echo "failed to install podman via homebrew" >&2
                exit 1
            }
        else
            echo "podman not found and homebrew is unavailable" >&2
            exit 127
        fi

        command -v podman >/dev/null 2>&1 || {
            echo "podman is still unavailable after installation" >&2
            exit 1
        }
    }

    ensure_podman

    command -v nc >/dev/null 2>&1 || { echo "nc not found" >&2; exit 127; }

    target_pid=$1
    shift
    case "$target_pid" in
        ''|*[!0-9]*) echo "invalid pid: $target_pid" >&2; exit 2 ;;
    esac

    # Remaining arguments are: [podman machine init options...] machine-name
    if [ "$#" -lt 1 ]; then
        echo "machine name (last argument) is required" >&2
        exit 2
    fi

    # Get last argument as machine name (Podman style: init [options] [name])
    last_arg=$1
    for a; do last_arg=$a; done

    case "$last_arg" in
        '' )
            echo "machine name (last argument) is required" >&2
            exit 2
            ;;
        -* )
            echo "machine name (last argument) must not start with '-'; it should be a positional name like 'myvm'" >&2
            exit 2
            ;;
        * )
            machine_name=$last_arg
            ;;
    esac

    ensure_machine_absent() {
        if podman machine inspect "$1" >/dev/null 2>&1; then
            echo "machine '$1' already exists; remove it or choose a different name" >&2
            exit 1
        fi
    }

    ensure_machine_absent "$machine_name"

    uid=$(id -u)
    safe_machine_name=$(printf '%s' "$machine_name" | tr -c 'A-Za-z0-9.-' '-')
    agent_label="temp-podman-machine.${safe_machine_name}"

    state_root="$HOME/Library/Application Support/temp-podman-machine/state"
    state_dir="${STATE_DIR:-${state_root}/${safe_machine_name}}"
    create_args_file="$state_dir/create-args"
    agent_script="$state_dir/temp-podman-machine-agent.sh"
    launch_agents_dir="$HOME/Library/LaunchAgents"
    plist_path="$launch_agents_dir/${agent_label}.plist"
    socket_path="/tmp/${agent_label}.${uid}.sock"

    mkdir -p "$state_dir" "$launch_agents_dir"

    : >"$create_args_file"
    # Store all init options EXCEPT the machine name into CREATE_ARGS_FILE
    for arg; do
        [ "$arg" = "$machine_name" ] && continue
        printf '%s\0' "$arg" >>"$create_args_file"
    done

    cat >"$agent_script" << 'AGENT'
#!/bin/sh

set -eu
[ "${DEBUG:-}" ] && set -x

PATH="$HOME/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export PATH

command -v podman >/dev/null 2>&1 || { printf '%s\n' 'podman not found' >&2; exit 127; }

MACHINE=${MACHINE:-}
[ -n "$MACHINE" ] || { printf '%s\n' 'machine name is required' >&2; exit 2; }

STATE_DIR=${STATE_DIR:-}
[ -n "$STATE_DIR" ] || { printf '%s\n' 'STATE_DIR is required' >&2; exit 2; }

CREATE_ARGS_FILE=${CREATE_ARGS_FILE:-${STATE_DIR}/create-args}
AGENT_PLIST=${AGENT_PLIST:-}
AGENT_LABEL=${AGENT_LABEL:-}
UID_NUM=${UID_NUM:-$(id -u)}
SOCKET_PATH=${SOCKET_PATH:-}
AGENT_SCRIPT=${AGENT_SCRIPT:-}

STOP_GRACE_SECS=${STOP_GRACE_SECS:-1}
WAIT_TIMEOUT_SECS=${WAIT_TIMEOUT_SECS:-90}

mkdir -p "$STATE_DIR"
exec 3>>"$STATE_DIR/temp-podman-machine-agent.log"

log() {
  printf '%s temp-podman-machine-agent[%s]: %s\n' "$(date '+%F %T')" "$$" "$*" >&3
}

wait_podman_ready() {
  start=$(date +%s)
  while :; do
    if podman --connection "$MACHINE" info >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.5
    now=$(date +%s)
    if [ $((now - start)) -ge "$WAIT_TIMEOUT_SECS" ]; then
      log "timeout waiting for podman '$MACHINE'"
      return 1
    fi
  done
}

ensure_machine() {
  if podman machine inspect "$MACHINE" >/dev/null 2>&1; then
    return 0
  fi

  log "creating podman machine '$MACHINE'"
  set --
  if [ -r "$CREATE_ARGS_FILE" ]; then
    while IFS= read -r -d '' arg; do
      set -- "$@" "$arg"
    done <"$CREATE_ARGS_FILE"
  fi
  podman machine init "$MACHINE" "$@" || { log "machine init failed for '$MACHINE'"; exit 1; }
}

remove_agent_files() {
  [ -n "$AGENT_PLIST" ] && rm -f "$AGENT_PLIST" 2>/dev/null || true
  [ -n "$SOCKET_PATH" ] && rm -f "$SOCKET_PATH" 2>/dev/null || true
  [ -n "$AGENT_SCRIPT" ] && rm -f "$AGENT_SCRIPT" 2>/dev/null || true
  rm -rf "$STATE_DIR" 2>/dev/null || true
}

remove_launch_agent() {
  [ -n "$AGENT_LABEL" ] || return 0
  launchctl bootout "gui/${UID_NUM}/${AGENT_LABEL}" >/dev/null 2>&1 || true
}

ensure_machine

log "connection accepted; ensuring machine '$MACHINE' is running"
podman machine start "$MACHINE" >/dev/null 2>&1 || true
wait_podman_ready || true

# Signal ready to the caller and then wait for the connection to close.
printf 'ready\n'
cat >/dev/null || true

# The client (temp_podman_machine caller) has gone away; give Podman a
# short grace period, then tear everything down.
[ "$STOP_GRACE_SECS" -gt 0 ] && sleep "$STOP_GRACE_SECS"

log "no more connections; stopping machine '$MACHINE'"
podman machine stop "$MACHINE" >/dev/null 2>&1 || true
podman machine rm -f "$MACHINE" >/dev/null 2>&1 || true

remove_agent_files
remove_launch_agent
exit 0
AGENT

    chmod 0755 "$agent_script"

    cat >"$plist_path" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>${agent_label}</string>

  <key>ProgramArguments</key>
  <array>
    <string>${agent_script}</string>
  </array>

  <key>Sockets</key>
  <dict>
    <key>Control</key>
    <dict>
      <key>SockPathName</key><string>${socket_path}</string>
      <key>SockFamily</key><string>Unix</string>
      <key>SockType</key><string>stream</string>
      <key>SockPathMode</key><integer>384</integer>
    </dict>
  </dict>

  <key>inetdCompatibility</key>
  <dict>
    <key>Wait</key><false/>
  </dict>

  <key>EnvironmentVariables</key>
  <dict>
    <key>MACHINE</key><string>${machine_name}</string>
    <key>STATE_DIR</key><string>${state_dir}</string>
    <key>CREATE_ARGS_FILE</key><string>${create_args_file}</string>
    <key>AGENT_PLIST</key><string>${plist_path}</string>
    <key>AGENT_LABEL</key><string>${agent_label}</string>
    <key>UID_NUM</key><string>${uid}</string>
    <key>SOCKET_PATH</key><string>${socket_path}</string>
    <key>AGENT_SCRIPT</key><string>${agent_script}</string>
  </dict>

  <key>KeepAlive</key><false/>
  <key>ProcessType</key><string>Background</string>
</dict></plist>
PLIST
    chmod 0644 "$plist_path"

    launchctl bootout "gui/${uid}/${agent_label}" >/dev/null 2>&1 || true
    launchctl bootstrap "gui/${uid}" "$plist_path"
    launchctl kickstart -k "gui/${uid}/${agent_label}" >/dev/null 2>&1 || true

    ready_fifo_path=$(mktemp "${TMPDIR:-/tmp}/temp-podman-machine.ready.XXXXXX")
    rm -f "$ready_fifo_path"
    mkfifo "$ready_fifo_path"

    hold_fifo_path=$(mktemp "${TMPDIR:-/tmp}/temp-podman-machine.hold.XXXXXX")
    rm -f "$hold_fifo_path"
    mkfifo "$hold_fifo_path"

    (
        exec </dev/null >/dev/null 2>&1
        exec 8>"$hold_fifo_path"
        while kill -0 "$target_pid" 2>/dev/null; do
            sleep 15 || break
        done
        :
    ) &
    watcher_pid=$!

    nc -U "$socket_path" >"$ready_fifo_path" <"$hold_fifo_path" 2>/dev/null &
    nc_pid=$!

    trap 'kill "$nc_pid" "$watcher_pid" 2>/dev/null || true; rm -f "$ready_fifo_path" "$hold_fifo_path" 2>/dev/null || true' 0 2 15

    if ! IFS= read -r _ <"$ready_fifo_path"; then
        rm -f "$ready_fifo_path" "$hold_fifo_path"
        wait "$nc_pid" 2>/dev/null || true
        kill "$watcher_pid" 2>/dev/null || true
        exit 1
    fi
    rm -f "$ready_fifo_path"

    if ! kill -0 "$nc_pid" 2>/dev/null; then
        wait "$nc_pid" 2>/dev/null || true
        kill "$watcher_pid" 2>/dev/null || true
        rm -f "$hold_fifo_path"
        exit 1
    fi

    trap 'rm -f "$hold_fifo_path" 2>/dev/null || true' 0 2 15

    printf '%s\n' "$machine_name"
    exit 0
  )
}
