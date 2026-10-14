# Sandbox für Claude Code mit Go-Toolchain.
# GO_VERSION an die Version in deinen go.mod-Dateien anpassen.
ARG GO_VERSION=1.25
FROM golang:${GO_VERSION}-bookworm

RUN apt-get update && apt-get install -y --no-install-recommends \
      iptables ipset dnsutils jq curl ca-certificates git util-linux less ripgrep \
    && rm -rf /var/lib/apt/lists/*

# Unprivilegierter Nutzer mit UID/GID des Host-Nutzers. Auf Linux-Hosts
# behalten eingehängte Dateien ihre numerischen Besitzer; nur bei gleicher UID
# kann der Agent sie schreiben. sandbox.sh prüft das und nennt den Build-Befehl:
#   docker build --build-arg UID=$(id -u) --build-arg GID=$(id -g) -t claude-agent .
# Unter Docker Desktop (macOS, Windows) ist die UID egal, Standard 1000 genügt.
ARG UID=1000
ARG GID=1000
LABEL sandbox.uid="${UID}" sandbox.gid="${GID}"

# Verzeichnisse vorab anlegen, damit benannte Volumes beim ersten Einhängen
# die richtigen Besitzrechte übernehmen. Gibt es die GID schon (z. B. 100
# "users"), wird diese Gruppe verwendet.
RUN getent group "${GID}" >/dev/null || groupadd -g "${GID}" dev \
    && useradd -m -s /bin/bash -o -u "${UID}" -g "${GID}" dev \
    && mkdir -p /home/dev/.claude /home/dev/go /home/dev/.cache /workspace \
    && chown -R "${UID}:${GID}" /home/dev /workspace

ENV HOME=/home/dev \
    GOPATH=/home/dev/go \
    PATH=/home/dev/.local/bin:/home/dev/go/bin:/usr/local/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    CLAUDE_CONFIG_DIR=/home/dev/.claude \
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
    DISABLE_AUTOUPDATER=1

USER dev
RUN curl -fsSL https://claude.ai/install.sh | bash \
    && git config --global credential.helper ghtoken \
    # Worktrees liegen unter ihren Host-Pfaden, nicht nur unter /workspace.
    && git config --global --add safe.directory '*' \
    # .git/config ist schreibgeschützt eingehängt: kein Upstream-Eintrag nötig.
    && git config --global push.default current \
    && git config --global branch.autoSetupMerge false \
    # Remotes per SSH über HTTPS mit Token bedienen (Port 22 ist gesperrt).
    && git config --global url."https://github.com/".insteadOf git@github.com: \
    && git config --global --add url."https://github.com/".insteadOf ssh://git@github.com/

COPY --chmod=755 init-firewall.sh entrypoint.sh git-credential-ghtoken /usr/local/bin/

# Der Einstiegspunkt startet als root (nur für die Firewall)
# und wechselt danach dauerhaft zu "dev" ohne jegliche Capabilities.
USER root
WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["claude"]
