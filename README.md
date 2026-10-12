# Claude-Code-Sandbox für Go-Repos

## Bauen
    docker build -t claude-agent .

## Starten
    export GH_TOKEN=github_pat_...     # Fine-grained Token, nur für das eine Repo
    ./run-agent.sh ~/src/hostus
    ./run-agent.sh ~/src/hostus claude --dangerously-skip-permissions

Beim ersten Start in Claude Code anmelden; die Anmeldung bleibt im Volume
`claude-agent-home` erhalten. Alternativ ANTHROPIC_API_KEY setzen.

## Was isoliert ist
- Nur das Repo ist eingehängt, nichts aus deinem Home-Verzeichnis.
- Ausgehend nur HTTPS zu Anthropic, GitHub und dem Go-Modul-Proxy, plus DNS.
- Der Agent läuft als "dev" ohne Capabilities und kann die Firewall nicht ändern.
- Git nur per HTTPS mit Token, keine SSH-Schlüssel im Container.

## Grenzen
- DNS ist offen; Datenabfluss über DNS-Anfragen ist theoretisch möglich.
- Ändern CDN-Adressen während einer langen Sitzung, Container neu starten.
- Volumes zurücksetzen: docker volume rm claude-agent-home claude-agent-gopath claude-agent-cache
