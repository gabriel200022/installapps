# 📋 Documentație Tehnică Script Centralizat Enterprise MDM (install.sh)

Acest document descrie arhitectura, logica de execuție și parametrii implementați în scriptul unificat pentru managementul aplicațiilor pe macOS, configurat pentru distribuție prin **Hexnode MDM** și stocat pe GitHub.

---

## 🏗️ 1. Arhitectură și Concepte Core

Scriptul este proiectat să funcționeze într-un mediu **Enterprise Management (MDM)**, rulând cu privilegii de `root` (prin intermediul agentului Hexnode), dar fiind capabil să detecteze utilizatorul curent logat pe mașină pentru a configura corect directoarele specifice (`HOME`).

### Mecanisme de Siguranță Implementate:
* **`set -euo pipefail`**: Oprește execuția imediat la prima eroare întâlnită, previne utilizarea variabilelor nedeclarate și propagă erorile din interiorul pipe-urilor.
* **Detecție Dinamică de Arhitectură (`ARCH`)**: Identifică nativ dacă sistemul rulează pe Apple Silicon (`arm64`) sau Intel (`x86_64`), adaptând automat căile de instalare (ex: Homebrew în `/opt/homebrew` vs `/usr/local/Homebrew`).
* **Izolare Sesiune Utilizator (`get_home_dir`)**: Interoghează `dscl` pentru a afla calea reală a folderului utilizatorului curent (ex: `/Users/nume_utilizator`), evitând capcana în care folderul `$HOME` este mapat greșit către `/var/root`.

---

## 🛠️ 2. Matricea de Comenzi și Parametri

Sistemul acceptă un argument principal (transmis prin consola MDM în câmpul *Arguments* sau prin variabila `HEXNODE_APP_ARGUMENT`). Acesta a fost structurat în 4 straturi logice:

| Tip Acțiune | Parametru Global | Parametru Individual | Logică de Execuție |
| :--- | :--- | :--- | :--- |
| **Instalare** | *Rulare fără argumente* | `chrome`, `vscode`, `pritunl`, `nvm` etc. | Descarcă, montează și instalează aplicația de la zero. |
| **Dezinstalare** | `uninstall` | `uninstall-chrome`, `uninstall-pritunl` etc. | Oprește procesele și șterge **complet** binarul + profilele + cache-ul. |
| **Reinstalare** | `reinstall` | `reinstall-chrome`, `reinstall-pritunl` etc. | Rulează consecutiv secvența de Dezinstalare Curată ➔ Instalare Fresh. |
| **Actualizare** | `update` | `update-chrome`, `update-pritunl` etc. | Oprește procesul ➔ Șterge **doar** binarul vechi ➔ Pune binarul nou (**Păstrează datele**). |

---

## 🔄 3. Logica Detaliată a Parametrului `update`

Spre deosebire de o reinstalare clasică care șterge tot, parametrul `update` (și variantele de tip `update-[nume-app]`) acționează chirurgical pentru a nu perturba activitatea utilizatorului:

```
[Hexnode Trigger] ➔ [Oprește Aplicația (pkill)] ➔ [Șterge doar /Applications/App.app] ➔ [Instalează Noua Versiune]
                                                                                           |
                                                                                    (PĂSTREAZĂ DATELE)
                                                                                           |
                                                                                           ▼
                                                                            📂 ~/Library/Application Support/...
```

### Ce se întâmplă în spate:
1. **Oprirea Instanței Active (`kill_app`)**: Folosește `pkill -x` și `pkill -f` pentru a închide în siguranță orice instanță pornită din `/Applications`, prevenind blocajele de suprascriere la nivel de sistem (eroarea de fișier ocupat).
2. **Ștergerea Binarului (Nu și a Datelor)**: Se elimină folderul `.app` din `/Applications`. **Nu se ating** directoarele din `~/Library/Application Support/`, `~/Library/Preferences/` sau folderele de profil (cum sunt cheile/profilele VPN în cazul Pritunl sau tab-urile/sesiunile în cazul Google Chrome).
3. **Instalarea Peste Versiunea Veche**: Scriptul descarcă ultima versiune și o mută în `/Applications`. Când utilizatorul redeschide aplicația, aceasta își va prelua automat toate datele, conturile și configurările anterioare, realizând un update nativ invizibil (Silent Enterprise Update).
4. **Excluderea Brew și NVM**: Comanda globală `update` rulează actualizări doar pentru aplicațiile vizuale (`.app`/`.pkg`), ocolind în mod intenționat `brew` și `nvm` pentru a preveni alterarea mediilor de dezvoltare ale programatorilor.

---

## 📦 4. Detalii Implementare per Aplicație

* **Google Chrome**: Utilizează descărcarea pachetului universal de la Google, montarea silențioasă a DMG-ului și aplicarea instrumentului `ditto` pentru copiere securizată, urmată de eliminarea atributului de carantină Apple (`com.apple.quarantine`).
* **Pritunl**: Descarcă pachetul oficial de tip ZIP, extrage installer-ul `.pkg` și rulează comanda nativă macOS `installer -target /`. În cazul `update-pritunl`, profilele VPN salvate în `/var/lib/pritunl-client` rămân neatinse.
* **VS Code & Postman & iTerm2**: Descarcă arhivele electron/zip oficiale direct în directorul `/Applications`, folosind `unzip -o` pentru a forța suprascrierea curată a binarului existent.
* **Docker Desktop & Telegram & MongoDB Compass**: Automatizează parsing-ul API-ului GitHub sau al endpoint-urilor de producție, montează DMG-urile via `hdiutil attach -nobrowse` și extrag binarele direct în directoarele de sistem.
* **Homebrew & NVM**: Folosesc metode Enterprise izolate (instalare prin tarball direct în `/opt/homebrew` sau `/usr/local/Homebrew` și maparea automată a mediului în fișierul `.zshrc` al utilizatorului fără a necesita interacțiune umană).

---

## 🛠️ 5. Ghid de Troubleshooting în Hexnode

Dacă în consola Hexnode întâmpini o eroare de tipul `curl: (56) The requested URL returned error: 404`:
1. **Numele Fișierului**: Asigură-te că fișierul din repository-ul GitHub se numește exact `install.sh` (cu litere mici).
2. **Branch-ul Corect**: Verifică dacă ai dat commit direct pe branch-ul principal (de regulă `main` sau `master`). Link-ul de tip `raw.githubusercontent.com` trebuie să reflecte exact această structură:
   `https://raw.githubusercontent.com/[Utilizator]/[Repository]/main/install.sh`
3. **Validare**: Copiază link-ul raw direct în browser. Dacă textul scriptului apare pe ecran, Hexnode va putea rula comanda cu succes.
