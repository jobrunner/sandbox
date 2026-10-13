# Claude-Code-Sandbox für das gemeine Go-Repo v1.0_final_final_geändert_ueberarbeitet_final_ausprobieren_;-)

## Bauen

    docker build -t claude-agent .

## Starten

Mit GitHub App (empfohlen, siehe unten):

    ./sandbox.sh ~/src/working-dir
    ./sandbox.sh ~/src/working-dir claude --dangerously-skip-permissions

Ohne GitHub App mit Fine-grained Token, nur für das eine Repo (läuft nicht ab,
muss aber von Hand erstellt und widerrufen werden):

    export GH_TOKEN=github_pat_...
    ./sandbox.sh ~/src/working-dir

`sandbox.sh` braucht bash ≥ 4 (macOS: `brew install bash`).

## Worktrees: eine Aufgabe, ein Verzeichnis

    ./sandbox.sh -b fix/login ~/src/working-dir      # oder --branch fix/login
    ./sandbox.sh ~/src/working-dir-wt/fix-login      # bestehenden Worktree weiterverwenden
    ./sandbox.sh --rm-wt ~/src/working-dir           # Worktrees auswählen und entfernen
    ./sandbox.sh --rm-wt=fix-login ~/src/working-dir

- Mit `-b` legt die Sandbox ohne Rückfrage den Worktree `~/src/working-dir-wt/fix-login`
  auf dem Branch `fix/login` an (neu von `origin/main`, oder der vorhandene lokale bzw.
  entfernte Branch). Gibt es ihn schon, wird er wiederverwendet.
- Ohne `-b` fragt die Sandbox beim Hauptrepo nach einem Branch; leere Eingabe heißt:
  direkt im Hauptrepo arbeiten.
- Mehrere Sandboxen auf verschiedenen Worktrees laufen parallel; jede hat ihr eigenes
  Netz, Portkonflikte gibt es also nicht.
- Nach dem Beenden bleibt der Worktree zum Review stehen. `--rm-wt` zeigt ohne Namen eine
  Auswahlliste (fzf, TAB markiert; ohne fzf eine nummerierte Liste), zeigt nicht
  committete und nicht gepushte Änderungen und fragt vor dem Löschen nach. Der Branch
  wird nur gelöscht, wenn er gemergt ist.

## Neues Projekt ohne Repo oder Remote

- Ist das Verzeichnis noch kein Repo, legt die Sandbox es mit `git init` an.
- Ohne GitHub-Remote läuft die Sandbox ohne Token: Committen geht, Pushen nicht.
  Remote auf dem Host setzen (`git remote add origin https://github.com/<owner>/<repo>`),
  die Sandbox neu starten und mit `claude --continue` weitermachen.
- Worktrees gehen erst ab dem ersten Commit; bis dahin wird `-b` ignoriert.

Beim ersten Start in Claude Code anmelden (die Anmeldung bleibt im Volume
`claude-agent-home` drinne). Alternativ ANTHROPIC_API_KEY setzen.

Optionale Variablen:

- `GH_REPO`: Repo-Name auf GitHub; Standard ist der Name aus der URL von `origin`.
- `GH_PERMS`: Rechte des Tokens, Standard `contents=write`, z. B.
  `contents=write,pull_requests=write`. Darf nicht mehr verlangen, als die App hat.
- `FW_EXTRA_ALLOWED_DOMAINS`: weitere Domains für die Firewall, durch Leerzeichen getrennt.

## Was aktuell isoliert ist (wip)

- Nur das Repo bzw. der Worktree samt dessen `.git` ist eingehängt, nichts sonst.
- `.git/hooks` und `.git/config` sind im Container schreibgeschützt, damit der Agent
  keinen Code hinterlegen kann, der beim nächsten `git`-Aufruf auf dem Host läuft.
  Remote und Repo-Config deshalb auf dem Host ändern. Ein einfaches `git push` reicht
  im Container (`push.default=current`), ein Upstream mit `-u` lässt sich nicht setzen.
- Ausgehend nur HTTPS zu Anthropic, GitHub und dem Go-Modul-Proxy, plus DNS.
- Ausgehende Requests lässt die Firewall zusätzlich via Port 443 durch, wenn sie beim Container-Start in `FW_EXTRA_ALLOWED_DOMAINS` im Env stehen.
- Der Agent läuft als "dev" ohne Capabilities und kann die Firewall nicht ändern.
- Git nur per HTTPS mit Token, keine SSH-Schlüssel im Container.
- Der private Schlüssel der Github-App bleibt auf dem Host, wo auch der Token erzeugt wird, der nach einer Stunde für dieses Repo verfällt. `sandbox.sh` erneuert das Token alle 30m im Hintergrund.

## Foo

- DNS ist weiterhin offen wie ein Scheunentor, ergo sind Datenausflüsse über DNS-Anfragen möglich.
- Ändern CDN-Adressen während einer langen Sitzung, knallts, weil die Firewall gerade nicht beweglich sein soll. Abhilfe: Container neu starten.
- Volumes zurücksetzen: `docker volume rm claude-agent-home claude-agent-gopath claude-agent-cache`

## GitHub App einrichten

Einmalig pro Konto. Die App gibt dem Agenten Tokens, die nur für ein Repo gelten und
nach einer Stunde ablaufen. Commits erscheinen unter dem Namen der App (`<name>[bot]`).

1. **App anlegen:** [https://github.com/settings/apps/new](https://github.com/settings/apps/new) (für eine Organisation:
   `https://github.com/organizations/<org>/settings/apps/new`).

   - Name frei wählen, Homepage-URL beliebig (z. B. die Repo-URL).
   - Webhook: Haken bei „Active“ entfernen.
   - Repository permissions: **Contents: Read and write**, bei Bedarf
     **Pull requests: Read and write**. Mehr eher nicht.
   - "Only on this account" auswählen und die App anlegen.
2. **Kennungen notieren:** Auf der Seite der App stehen App-ID und Client-ID;
   `gh-app-token` nimmt beide.
3. **Private Key erzeugen:** Unten auf der Seite „Generate a private key“.
   Die `.pem`-Datei außerhalb des Repos ablegen, z. B.:

   ```sh
   mkdir -p ~/.config/gh-app && mv ~/Downloads/<name>.*.pem ~/.config/gh-app/key.pem
   chmod 600 ~/.config/gh-app/key.pem
   ```

4. **App installieren:** Links "Install App" -> "Only select repositories" und
   die Repos auswählen, in denen der Agent arbeiten darf. Die Installations-ID steht
   danach in der URL: `https://github.com/settings/installations/<ID>`.
5. **Bot-Kennung für die Commit-Adresse ermitteln** (`<slug>` ist der Name der App in der URL und weder die eckigen Klammern noch das bot bekommt man weg: Heißt, bitte in Github-Workflows ggf. drauf achten):

   ```sh
   curl -s 'https://api.github.com/users/<slug>%5Bbot%5D' | jq .id
   ```

6. **`gh-app-token` auf dem Host installieren** (braucht aktuell noch Go lokal):

   ```sh
   cd gh-app-token && go install .
   ```

   Das Programm landet in `$GOBIN` bzw. `~/go/bin`; das Verzeichnis muss im `PATH` stehen.
7. **Variablen setzen**, z. B. in `.envrc` für direnv (ist per `.gitignore` ausgeschlossen):

   ```sh
   export GH_APP_ID=Iv23li...                 # Client-ID oder App-ID
   export GH_APP_KEY=~/.config/gh-app/key.pem
   export GH_APP_INSTALLATION_ID=12345678
   export GH_APP_BOT_ID=87654321
   export GH_APP_BOT_NAME="<slug>[bot]"
   export GH_APP_BOT_EMAIL="$GH_APP_BOT_ID+$GH_APP_BOT_NAME@users.noreply.github.com"
   ```

   Test: `gh-app-token -repo <repo-name>` gibt ein Token aus.

Ein weiteres Repo freigeben: in den Einstellungen der Installation hinzufügen, fertig.
Schlüssel kompromittiert: auf der Seite der App löschen und einen neuen erzeugen.
