#!/usr/bin/env bash
# Aufruf:
#   ./sandbox.sh [-b <branch>] <pfad> [befehl ...]   Sandbox starten, ohne Befehl "claude"
#   ./sandbox.sh --rm-wt[=<name>] [<repo-pfad>]       Worktrees entfernen (mit Rückfrage)
#
# <pfad> kann sein:
#   - ein Verzeichnis ohne Repo: wird mit "git init" angelegt
#   - ein Worktree: wird direkt verwendet
#   - das Hauptrepo: mit -b/--branch wird ohne Rückfrage ein Worktree unter
#     <repo>-wt/<branch> angelegt oder wiederverwendet (fix/login wird zu
#     <repo>-wt/fix/login), ohne -b wird gefragt
#     (leere Eingabe = direkt im Hauptrepo arbeiten)
#
# Autonomer Modus: ./sandbox.sh -b fix/login ~/src/hostus claude --dangerously-skip-permissions
set -euo pipefail
(( BASH_VERSINFO[0] >= 4 )) || { echo "sandbox.sh braucht bash >= 4 (macOS: brew install bash)" >&2; exit 1; }

SELF="$(basename "$0")"
usage() {
  sed -n '2,4p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit "${1:-2}"
}
say() { echo "$SELF: $*" >&2; }
die() { say "$*"; exit 1; }

# Fragt auf dem Terminal nach, auch wenn stdin umgeleitet ist. Standard: nein.
confirm() {
  local answer
  read -r -p "$1 [j/N] " answer </dev/tty || return 1
  [[ "$answer" =~ ^[jJyY]$ ]]
}

# Name eines Worktrees: der Pfad unterhalb von <repo>-wt/, sonst der Ordnername.
# Weil Git keine Branches "a" und "a/b" nebeneinander erlaubt, ist
# <repo>-wt/<branch> eindeutig, anders als ein Ersetzen von "/" durch "-".
wt_name() {
  local wt="$1" main="$2"
  if [[ "$wt" == "$main-wt/"* ]]; then echo "${wt#"$main-wt/"}"; else basename "$wt"; fi
}

# Wurzel des Hauptrepos, abgeleitet vom gemeinsamen Git-Verzeichnis.
main_root() {
  local common
  common="$(git -C "$1" rev-parse --path-format=absolute --git-common-dir)"
  dirname "$common"
}

# ---------------------------------------------------------------------------
# Worktrees entfernen
# ---------------------------------------------------------------------------
remove_worktrees() {
  local name="$1" repo="$2"
  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || die "$repo ist kein Git-Repo"
  local main; main="$(main_root "$repo")"

  # Alle Worktrees außer dem Hauptrepo: Pfad und Branch, durch Tab getrennt.
  local -a entries=()
  local path="" line
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) path="${line#worktree }" ;;
      "branch "*)   [[ "$path" != "$main" ]] && entries+=("$path"$'\t'"${line#branch refs/heads/}") ;;
      detached)     [[ "$path" != "$main" ]] && entries+=("$path"$'\t'"(detached)") ;;
    esac
  done < <(git -C "$main" worktree list --porcelain)
  (( ${#entries[@]} )) || { say "keine Worktrees in $main"; return 0; }

  local -a selected=()
  local e
  if [[ -n "$name" ]]; then
    for e in "${entries[@]}"; do
      if [[ "$(wt_name "${e%%$'\t'*}" "$main")" == "$name" || "${e#*$'\t'}" == "$name" ]]; then
        selected+=("$e")
      fi
    done
    (( ${#selected[@]} )) || die "kein Worktree namens $name in $main"
  elif command -v fzf >/dev/null; then
    mapfile -t selected < <(printf '%s\n' "${entries[@]}" | fzf --multi \
      --delimiter=$'\t' --with-nth=1,2 \
      --header="TAB markiert, Enter bestätigt, Esc bricht ab" \
      --prompt="Worktrees entfernen> ") || true
  else
    local i=1
    for e in "${entries[@]}"; do printf '%3d) %s  [%s]\n' "$i" "${e%%$'\t'*}" "${e#*$'\t'}"; i=$((i + 1)); done
    local nums n
    read -r -p "Nummern, durch Leerzeichen getrennt (leer = abbrechen): " nums </dev/tty
    for n in $nums; do
      if ! [[ "$n" =~ ^[0-9]+$ ]] || (( n < 1 || n > ${#entries[@]} )); then die "ungültige Nummer: $n"; fi
      selected+=("${entries[n - 1]}")
    done
  fi
  (( ${#selected[@]} )) || { say "nichts ausgewählt"; return 0; }

  local wt branch dirty unpushed force
  for e in "${selected[@]}"; do
    wt="${e%%$'\t'*}"; branch="${e#*$'\t'}"
    echo
    echo "== $wt  [$branch]"
    dirty="$(git -C "$wt" status --porcelain)"
    [[ -n "$dirty" ]] && { echo "Nicht committete Änderungen:"; git -C "$wt" status --short; }
    if [[ -n "$(git -C "$wt" remote)" ]]; then
      unpushed="$(git -C "$wt" log --oneline HEAD --not --remotes)"
      [[ -n "$unpushed" ]] && { echo "Nicht gepushte Commits:"; echo "$unpushed"; }
    else
      echo "Kein Remote: Commits auf $branch existieren nur lokal."
    fi

    confirm "Worktree $wt entfernen?" || { echo "übersprungen"; continue; }
    force=()
    if [[ -n "$dirty" ]]; then
      confirm "Die Änderungen gehen verloren. Wirklich entfernen?" || { echo "übersprungen"; continue; }
      force=(--force)
    fi
    git -C "$main" worktree remove "${force[@]}" "$wt"
    echo "entfernt: $wt"
    # Leere Zwischenordner von Branches wie fix/login aufräumen.
    local parent; parent="$(dirname "$wt")"
    while [[ "$parent" == "$main-wt/"* ]] && rmdir "$parent" 2>/dev/null; do parent="$(dirname "$parent")"; done
    if [[ "$branch" != "(detached)" ]]; then
      if git -C "$main" branch -d "$branch" >/dev/null 2>&1; then
        echo "Branch $branch gelöscht"
      else
        echo "Branch $branch bleibt (nicht gemergt; löschen mit: git branch -D $branch)"
      fi
    fi
  done
  git -C "$main" worktree prune
}

# ---------------------------------------------------------------------------
# Argumente
# ---------------------------------------------------------------------------
BRANCH="" RM_WT="" RM_NAME=""
while (( $# )); do
  case "$1" in
    -b|--branch) BRANCH="${2:?$1 braucht einen Branch-Namen}"; shift 2 ;;
    --branch=*)  BRANCH="${1#*=}"; shift ;;
    --rm-wt)     RM_WT=1; shift ;;
    --rm-wt=*)   RM_WT=1; RM_NAME="${1#*=}"; shift ;;
    -h|--help)   usage 0 ;;
    --)          shift; break ;;
    -*)          say "unbekannte Option: $1"; usage ;;
    *)           break ;;
  esac
done

if [[ -n "$RM_WT" ]]; then
  remove_worktrees "$RM_NAME" "${1:-.}"
  exit 0
fi

(( $# )) || usage

# ---------------------------------------------------------------------------
# Image und UID
# ---------------------------------------------------------------------------
IMAGE="${SANDBOX_IMAGE:-claude-agent}"
BUILD_HINT="docker build --build-arg UID=$(id -u) --build-arg GID=$(id -g) -t $IMAGE ."
docker image inspect "$IMAGE" >/dev/null 2>&1 || die "Image $IMAGE fehlt. Bauen mit: $BUILD_HINT"

# Auf Linux-Hosts behalten eingehängte Dateien ihre numerischen Besitzer.
# Der Agent kann sie nur schreiben (und das Token nur lesen), wenn "dev" im
# Image dieselbe UID hat wie der Host-Nutzer. Docker Desktop gleicht das selbst aus.
if [[ "$(uname -s)" == Linux ]]; then
  (( $(id -u) != 0 )) || die "nicht als root starten; Docker ohne sudo nutzen (Nutzer in der Gruppe docker)"
  img_uid="$(docker image inspect -f '{{index .Config.Labels "sandbox.uid"}}' "$IMAGE")"
  img_gid="$(docker image inspect -f '{{index .Config.Labels "sandbox.gid"}}' "$IMAGE")"
  if [[ "$img_uid" != "$(id -u)" || "$img_gid" != "$(id -g)" ]]; then
    die "Image $IMAGE ist für UID:GID ${img_uid:-?}:${img_gid:-?} gebaut, du bist $(id -u):$(id -g).
Neu bauen mit: $BUILD_HINT
Danach die Volumes zurücksetzen, falls sie mit der alten UID angelegt wurden:
docker volume rm claude-agent-home claude-agent-gopath claude-agent-cache"
  fi
fi

DIR="$(cd "$1" 2>/dev/null && pwd -P)" || die "Verzeichnis nicht gefunden: $1"
shift

# ---------------------------------------------------------------------------
# Repo, Worktree
# ---------------------------------------------------------------------------
if ! git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1; then
  say "$DIR ist kein Git-Repo, lege es an"
  git -C "$DIR" init -q
fi

TOP="$(git -C "$DIR" rev-parse --show-toplevel)"
[[ "$TOP" == "$DIR" ]] || die "$DIR liegt innerhalb des Repos $TOP; bitte dessen Wurzel oder einen Worktree angeben"

GIT_DIR_ABS="$(git -C "$DIR" rev-parse --path-format=absolute --git-dir)"
COMMON="$(git -C "$DIR" rev-parse --path-format=absolute --git-common-dir)"
HAS_COMMIT=""; git -C "$DIR" rev-parse --verify -q HEAD >/dev/null && HAS_COMMIT=1

if [[ "$GIT_DIR_ABS" != "$COMMON" ]]; then
  [[ -n "$BRANCH" ]] && say "$DIR ist bereits ein Worktree, -b $BRANCH wird ignoriert"
elif [[ -z "$HAS_COMMIT" ]]; then
  [[ -n "$BRANCH" ]] && say "noch kein Commit, ein Worktree ist erst danach möglich; -b $BRANCH wird ignoriert"
else
  if [[ -z "$BRANCH" && -t 0 ]]; then
    read -r -p "Branch für einen Worktree (leer = direkt in $DIR arbeiten): " BRANCH
  fi
  if [[ -n "$BRANCH" ]]; then
    git check-ref-format --branch "$BRANCH" >/dev/null 2>&1 || die "ungültiger Branch-Name: $BRANCH"

    # Ist der Branch schon irgendwo ausgecheckt, dort weiterarbeiten.
    existing="$(git -C "$DIR" worktree list --porcelain | awk -v b="branch refs/heads/$BRANCH" '
      /^worktree / { p = substr($0, 10) }  $0 == b { print p; exit }')"
    if [[ -n "$existing" ]]; then
      say "Branch $BRANCH ist bereits ausgecheckt in $existing"
      DIR="$existing"
    else
      WT="$DIR-wt/$BRANCH"
      [[ -e "$WT" ]] && die "$WT existiert bereits, ist aber kein Worktree für $BRANCH"
      if git -C "$DIR" show-ref --verify -q "refs/heads/$BRANCH"; then
        git -C "$DIR" worktree add "$WT" "$BRANCH"
      elif git -C "$DIR" remote get-url origin >/dev/null 2>&1; then
        git -C "$DIR" fetch -q origin || say "git fetch origin fehlgeschlagen, verwende den lokalen Stand"
        if git -C "$DIR" show-ref --verify -q "refs/remotes/origin/$BRANCH"; then
          git -C "$DIR" worktree add --track -b "$BRANCH" "$WT" "origin/$BRANCH"
        else
          base="$(git -C "$DIR" symbolic-ref -q --short refs/remotes/origin/HEAD || true)"
          [[ -z "$base" ]] && git -C "$DIR" show-ref --verify -q refs/remotes/origin/main && base=origin/main
          git -C "$DIR" worktree add --no-track -b "$BRANCH" "$WT" "${base:-HEAD}"
        fi
      else
        git -C "$DIR" worktree add -b "$BRANCH" "$WT" HEAD
      fi
      DIR="$WT"
    fi
    GIT_DIR_ABS="$(git -C "$DIR" rev-parse --path-format=absolute --git-dir)"
  fi
fi

MAIN="$(dirname "$COMMON")"
REPO_NAME="$(basename "$MAIN")"
IS_WORKTREE=""; [[ "$GIT_DIR_ABS" != "$COMMON" ]] && IS_WORKTREE=1
# Liegt das Git-Verzeichnis nicht als .git im Arbeitsverzeichnis (Worktree,
# Submodul), müssen beide unter ihren Host-Pfaden eingehängt werden.
SAME_PATH=""; [[ "$COMMON" != "$DIR/.git" ]] && SAME_PATH=1

# ---------------------------------------------------------------------------
# Einhängen
# ---------------------------------------------------------------------------
# Ein Worktree verweist mit absoluten Host-Pfaden auf das gemeinsame .git.
# Deshalb werden Worktree und .git dann unter denselben Pfaden eingehängt.
# hooks/ und config sind schreibgeschützt: Sonst könnte der Agent dort Code
# hinterlegen (Hook, core.fsmonitor), der beim nächsten git-Aufruf auf dem Host läuft.
mkdir -p "$COMMON/hooks"
if [[ -n "$SAME_PATH" ]]; then
  WORKDIR="$DIR"
  CONTAINER_GIT="$COMMON"
  MOUNTS=(-v "$DIR":"$DIR" -v "$COMMON":"$COMMON")
  CONTAINER_NAME="agent-$REPO_NAME-$(wt_name "$DIR" "$MAIN" | tr '/' '_')"
else
  WORKDIR=/workspace
  CONTAINER_GIT=/workspace/.git
  MOUNTS=(-v "$DIR":/workspace)
  CONTAINER_NAME="agent-$REPO_NAME"
fi
MOUNTS+=(-v "$COMMON/hooks":"$CONTAINER_GIT/hooks":ro -v "$COMMON/config":"$CONTAINER_GIT/config":ro)
CONTAINER_NAME="$(printf '%s' "$CONTAINER_NAME" | tr -c 'A-Za-z0-9_.-' '-')"

# ---------------------------------------------------------------------------
# GitHub-Token
# ---------------------------------------------------------------------------
# Repo-Name aus origin, falls das auf GitHub zeigt. GH_REPO überschreibt ihn.
ORIGIN_URL="$(git -C "$DIR" remote get-url origin 2>/dev/null || true)"
GITHUB_URL_RE='^(https://([^@/]+@)?github\.com/|git@github\.com:|ssh://git@github\.com/)[^/]+/([^/]+)$'
if [[ -z "${GH_REPO:-}" && "$ORIGIN_URL" =~ $GITHUB_URL_RE ]]; then
  GH_REPO="${BASH_REMATCH[3]%.git}"
fi

# Mit GitHub App: kurzlebiges Token nur für dieses Repo erzeugen.
# GH_PERMS legt die Rechte fest (Standard: nur Inhalte schreiben).
# Das Token gilt nur eine Stunde. Deshalb erneuert der Host es im Hintergrund
# und legt es in ein schreibgeschützt eingehängtes Verzeichnis; der
# Credential-Helper im Container liest es bei jedem Git-Zugriff neu.
TOKEN_MOUNT=()
if [[ -z "${GH_REPO:-}" ]]; then
  say "Kein GitHub-Remote: lokale Arbeit möglich, Push erst nach"
  say "\"git remote add origin …\" auf dem Host und Neustart der Sandbox."
elif [[ -n "${GH_APP_ID:-}" ]]; then
  TOKEN_DIR="$(mktemp -d)"
  REFRESH_PID=""
  trap '[[ -n "$REFRESH_PID" ]] && kill "$REFRESH_PID" 2>/dev/null; rm -rf "$TOKEN_DIR"' EXIT

  # Atomar schreiben (mv innerhalb des Verzeichnisses), damit Git nie eine
  # halbe Datei liest. Ausgaben von gh-app-token landen im Log, nicht im Terminal.
  refresh_token() {
    local tmp="$TOKEN_DIR/.token.$$"
    if gh-app-token -repo "$GH_REPO" \
         -perms "${GH_PERMS:-contents=write}" >"$tmp" 2>>"$TOKEN_DIR/refresh.log"; then
      chmod 644 "$tmp"
      mv -f "$tmp" "$TOKEN_DIR/token"
    else
      rm -f "$tmp"
      return 1
    fi
  }

  refresh_token || { cat "$TOKEN_DIR/refresh.log" >&2; exit 1; }

  # Alle 30 Minuten erneuern. Geprüft wird jede Minute gegen die Uhrzeit,
  # damit nach dem Ruhezustand des Rechners sofort erneuert wird.
  (
    trap - EXIT
    last=$(date +%s)
    while sleep 60; do
      if (( $(date +%s) - last >= 1800 )) && refresh_token; then
        last=$(date +%s)
      fi
    done
  ) &
  REFRESH_PID=$!

  TOKEN_MOUNT=(-v "$TOKEN_DIR":/run/gh-token:ro -e GH_TOKEN_FILE=/run/gh-token/token)
  unset GH_TOKEN   # ein statisches Token würde nach einer Stunde ungültig
fi

GIT_NAME="${GH_APP_BOT_NAME:-$(git config --global user.name || true)}"
GIT_MAIL="${GH_APP_BOT_EMAIL:-$(git config --global user.email || true)}"

status=0
docker run --rm -it \
  --name "$CONTAINER_NAME" \
  --cap-drop ALL \
  --cap-add NET_ADMIN --cap-add NET_RAW \
  --cap-add SETUID --cap-add SETGID \
  --security-opt no-new-privileges \
  --pids-limit 512 --memory 6g --cpus 4 \
  "${MOUNTS[@]}" \
  -w "$WORKDIR" \
  -v claude-agent-home:/home/dev/.claude \
  -v claude-agent-gopath:/home/dev/go \
  -v claude-agent-cache:/home/dev/.cache \
  "${TOKEN_MOUNT[@]}" \
  -e GH_TOKEN \
  -e ANTHROPIC_API_KEY \
  -e GIT_AUTHOR_NAME="$GIT_NAME" \
  -e GIT_AUTHOR_EMAIL="$GIT_MAIL" \
  -e GIT_COMMITTER_NAME="$GIT_NAME" \
  -e GIT_COMMITTER_EMAIL="$GIT_MAIL" \
  -e FW_EXTRA_ALLOWED_DOMAINS \
  "$IMAGE" "$@" || status=$?

if [[ -n "$IS_WORKTREE" ]]; then
  say "Worktree bleibt stehen: $DIR"
  say "Entfernen mit: $0 --rm-wt=$(wt_name "$DIR" "$MAIN") $MAIN"
fi
exit "$status"
