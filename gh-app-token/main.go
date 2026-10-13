// gh-app-token erzeugt ein kurzlebiges Installations-Token einer GitHub App,
// beschränkt auf ein Repo und ausgewählte Rechte. Läuft nur auf dem Host;
// der private Schlüssel gelangt nie in den Container.
package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

func main() {
	appID := flag.String("app", os.Getenv("GH_APP_ID"), "Client-ID oder App-ID der GitHub App")
	keyPath := flag.String("key", os.Getenv("GH_APP_KEY"), "Pfad zum privaten Schlüssel (.pem)")
	instID := flag.String("installation", os.Getenv("GH_APP_INSTALLATION_ID"), "Installations-ID")
	repo := flag.String("repo", "", "Repo-Name ohne Besitzer, z. B. hostus")
	perms := flag.String("perms", "contents=write", "Rechte, z. B. contents=write,pull_requests=write")
	flag.Parse()

	if *appID == "" || *keyPath == "" || *instID == "" {
		fail("GH_APP_ID, GH_APP_KEY und GH_APP_INSTALLATION_ID müssen gesetzt sein")
	}
	// Ohne Repo gälte das Token für alle Repos der Installation.
	if *repo == "" {
		fail("-repo muss gesetzt sein")
	}

	jwtToken, err := appJWT(*appID, *keyPath)
	if err != nil {
		fail("JWT erzeugen: %v", err)
	}

	body := map[string]any{
		"permissions":  parsePerms(*perms),
		"repositories": []string{*repo},
	}
	token, expires, err := installationToken(jwtToken, *instID, body)
	if err != nil {
		fail("Token anfordern: %v", err)
	}

	fmt.Fprintf(os.Stderr, "GitHub-Token gültig bis %s\n", expires.Local().Format("15:04"))
	fmt.Println(token)
}

// appJWT signiert ein JSON Web Token mit dem privaten Schlüssel der App (maximal 10 Minuten gültig).
func appJWT(appID, keyPath string) (string, error) {
	pem, err := os.ReadFile(keyPath)
	if err != nil {
		return "", err
	}
	key, err := jwt.ParseRSAPrivateKeyFromPEM(pem)
	if err != nil {
		return "", err
	}
	now := time.Now()
	claims := jwt.RegisteredClaims{
		Issuer:    appID,
		IssuedAt:  jwt.NewNumericDate(now.Add(-60 * time.Second)), // Uhrabweichung abfangen
		ExpiresAt: jwt.NewNumericDate(now.Add(9 * time.Minute)),
	}
	return jwt.NewWithClaims(jwt.SigningMethodRS256, claims).SignedString(key)
}

// installationToken tauscht das JWT gegen ein Installations-Token (1 Stunde gültig).
func installationToken(jwtToken, instID string, body map[string]any) (string, time.Time, error) {
	buf, err := json.Marshal(body)
	if err != nil {
		return "", time.Time{}, err
	}
	url := "https://api.github.com/app/installations/" + instID + "/access_tokens"
	req, err := http.NewRequest(http.MethodPost, url, bytes.NewReader(buf))
	if err != nil {
		return "", time.Time{}, err
	}
	req.Header.Set("Authorization", "Bearer "+jwtToken)
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("X-GitHub-Api-Version", "2022-11-28")

	// Ohne Timeout könnte ein hängender Request Start und Erneuerung blockieren.
	client := &http.Client{Timeout: 30 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return "", time.Time{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusCreated {
		msg, _ := io.ReadAll(resp.Body)
		return "", time.Time{}, fmt.Errorf("HTTP %d: %s", resp.StatusCode, msg)
	}

	var out struct {
		Token     string    `json:"token"`
		ExpiresAt time.Time `json:"expires_at"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return "", time.Time{}, err
	}
	return out.Token, out.ExpiresAt, nil
}

// parsePerms macht aus "contents=write,issues=read" eine Map für die GitHub-API.
func parsePerms(s string) map[string]string {
	m := map[string]string{}
	for _, p := range strings.Split(s, ",") {
		if k, v, ok := strings.Cut(strings.TrimSpace(p), "="); ok {
			m[k] = v
		}
	}
	return m
}

func fail(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "gh-app-token: "+format+"\n", args...)
	os.Exit(1)
}
