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

    # helper: show podman command + send its output to the caller's terminal
    # (or stderr as a fallback), not to our stdout (which is captured by $()).
    podman_cmd() {
      if [ -w /dev/tty ] 2>/dev/null; then
        printf '+ podman %s\n' "$*" >/dev/tty
        podman "$@" >/dev/tty 2>&1
      else
        printf '+ podman %s\n' "$*" >&2
        podman "$@" >&2
      fi
    }

    target_pid=$1
    shift
    case "$target_pid" in
      ''|*[!0-9]*) echo "invalid pid: $target_pid" >&2; exit 2 ;;
    esac

    if [ "$#" -lt 1 ]; then
      echo "machine name (last argument) is required" >&2
      exit 2
    fi

    last_arg=$1
    for a; do last_arg=$a; done

    case "$last_arg" in
      '' )
        echo "machine name (last argument) is required" >&2
        exit 2
        ;;
      -* )
        echo "machine name (last argument) must not start with '-'" >&2
        exit 2
        ;;
      * )
        machine_name=$last_arg
        ;;
    esac

    uid=$(id -u)
    base_dir="$HOME/Library/Application Support/temp-podman-machine"
    launch_agents_dir="$HOME/Library/LaunchAgents"
    state_dir="$base_dir/state"
    cleanup_script="$base_dir/cleanup-agent.sh"
    agent_label="temp-podman-machine.cleanup"
    plist_path="$launch_agents_dir/${agent_label}.plist"

    mkdir -p "$base_dir" "$state_dir" "$launch_agents_dir"

    need_reload=0

    tmp_cleanup=$(mktemp "${TMPDIR:-/tmp}/temp-podman-cleanup.XXXXXX")
    cat >"$tmp_cleanup" <<'CLEANUP'
#!/bin/sh
set -eu
command -v podman >/dev/null 2>&1 || exit 0
base_dir="$HOME/Library/Application Support/temp-podman-machine"
state_dir="$base_dir/state"
[ -d "$state_dir" ] || exit 0
for f in "$state_dir"/*; do
  [ -f "$f" ] || continue
  machine=$(basename "$f")
  pid=$(sed -n '1p' "$f" 2>/dev/null || printf '')
  case "$pid" in
    ''|*[!0-9]*) rm -f "$f" 2>/dev/null || true; continue ;;
  esac
  if kill -0 "$pid" 2>/dev/null; then
    continue
  fi
  podman machine stop "$machine" || true
  podman machine rm -f "$machine" || true
  rm -f "$f" 2>/dev/null || true
done
exit 0
CLEANUP

    if [ ! -f "$cleanup_script" ] || ! cmp -s "$tmp_cleanup" "$cleanup_script"; then
      mv "$tmp_cleanup" "$cleanup_script"
      chmod 0755 "$cleanup_script"
      need_reload=1
    else
      rm -f "$tmp_cleanup"
    fi

    tmp_plist=$(mktemp "${TMPDIR:-/tmp}/temp-podman-plist.XXXXXX")
    cat >"$tmp_plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${agent_label}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${cleanup_script}</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>3600</integer>
  <key>KeepAlive</key><false/>
  <key>ProcessType</key><string>Background</string>
</dict>
</plist>
PLIST

    if [ ! -f "$plist_path" ] || ! cmp -s "$tmp_plist" "$plist_path"; then
      mv "$tmp_plist" "$plist_path"
      chmod 0644 "$plist_path"
      need_reload=1
    else
      rm -f "$tmp_plist"
    fi

    if [ "$need_reload" -eq 1 ]; then
      launchctl bootout "gui/${uid}/${agent_label}" >/dev/null 2>&1 || true
      launchctl bootstrap "gui/${uid}" "$plist_path" >/dev/null 2>&1 || true
    else
      # Only bootstrap if not already loaded
      if ! launchctl print "gui/${uid}/${agent_label}" >/dev/null 2>&1; then
        launchctl bootstrap "gui/${uid}" "$plist_path" >/dev/null 2>&1 || true
      fi
    fi

    state_file="$state_dir/$machine_name"
    if [ -f "$state_file" ]; then
      old_pid=$(sed -n '1p' "$state_file" 2>/dev/null || printf '')
      case "$old_pid" in
        ''|*[!0-9]*) rm -f "$state_file" 2>/dev/null || true ;;
        *)
          if kill -0 "$old_pid" 2>/dev/null; then
            echo "machine '$machine_name' already in use by pid $old_pid" >&2
            exit 1
          else
            if podman machine inspect "$machine_name" >/dev/null 2>&1; then
              podman_cmd machine stop "$machine_name" || true
              podman_cmd machine rm -f "$machine_name" || true
            fi
            rm -f "$state_file" 2>/dev/null || true
          fi
          ;;
      esac
    fi

    # Build init args without the machine name, safely (no eval)
    set -- "$@"
    init_args=
    for arg; do
      [ "$arg" = "$machine_name" ] && continue
      if [ -z "$init_args" ]; then
        init_args=$arg
      else
        init_args="$init_args $arg"
      fi
    done

    if podman machine inspect "$machine_name" >/dev/null 2>&1; then
      podman_cmd machine stop "$machine_name" || true
      podman_cmd machine rm -f "$machine_name" || true
    fi

    if [ -n "$init_args" ]; then
      # shellcheck disable=SC2086
      set -- $init_args
      podman_cmd machine init "$@" "$machine_name"
    else
      podman_cmd machine init "$machine_name"
    fi

    podman_cmd machine start "$machine_name"

    # Record the owner PID
    printf '%s\n' "$target_pid" >"$state_file"

    # Discover the VM-side Podman socket path (usable as a host path in podman run -v).
    socket_path=''

    # Get the default connection URI, e.g. ssh://core@localhost:53685/run/user/501/podman/podman.sock
    default_uri=$(podman system connection ls \
      --format '{{.Default}} {{.URI}}' 2>/dev/null | awk '$1=="true"{print $2; exit}' || printf '')

    if [ -n "$default_uri" ]; then
      # Strip scheme + host part; keep the path starting with /
      socket_path=$(printf '%s\n' "$default_uri" | sed -E 's#^[^/]*//[^/]+(/.*)#\1#')
    fi

    # Fallback: ask Podman for the remote socket path if parsing failed
    if [ -z "$socket_path" ]; then
      socket_path=$(podman info --format '{{.Host.RemoteSocket.Path}}' 2>/dev/null || printf '')
    fi

    if [ -z "$socket_path" ]; then
      echo "failed to determine podman VM socket path" >&2
      exit 1
    fi

    if [ -z "$socket_path" ]; then
      echo "failed to determine podman socket path for machine '$machine_name'" >&2
      exit 1
    fi

    # Background watcher: does NOT keep the $() pipe open.
    (
      set -eu

      # Detach from command-substitution stdout:
      if [ -w /dev/tty ] 2>/dev/null; then
        exec >>/dev/tty 2>&1
      else
        exec >/dev/null 2>&1
      fi

      while kill -0 "$target_pid" 2>/dev/null; do
        sleep 2
      done

      podman_cmd machine stop "$machine_name" || true
      podman_cmd machine rm -f "$machine_name" || true
      rm -f "$state_file" 2>/dev/null || true
    ) &

    # The ONLY thing that goes to stdout: the socket path (for $()).
    printf '%s\n' "$socket_path"
  )
}
