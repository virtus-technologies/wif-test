# wif-test

A minimal **Node.js + Express** app deployed to **Azure App Service** using
**OpenID Connect (OIDC) / Workload Identity Federation** — no passwords, no
publish profiles, no secrets that expire.

---

## Deployment options

| Strategy | When to use |
|---|---|
| [Local deploy](#local-deploy-no-cicd) | Quick pushes from your machine — just `az login` and run a script |
| [GitHub Actions (OIDC)](#oidc-setup-one-time--5-minutes) | Automated deploys on every push to `main` |

---

## API Routes

| Method | Path | Description |
|--------|------|-------------|
| GET | `/` | Route index |
| GET | `/health` | Health check |
| GET | `/currency?from=USD&to=EUR&amount=100` | Currency conversion (free, no key) |
| GET | `/weather` | Weather for a random city (free, no key) |
| GET | `/weather/:city` | Weather for a specific city |

**Data sources (both free, no API key needed):**
- Currency — [open.er-api.com](https://open.er-api.com)
- Weather  — [wttr.in](https://wttr.in/:city?format=j1)

---

## OIDC Setup (one-time, ~5 minutes)

Instead of downloading a publish profile, the GitHub Actions workflow logs in
to Azure by exchanging a **short-lived GitHub OIDC token** for an Azure access
token. Nothing is stored; there is nothing to rotate.

### Prerequisites

- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli-windows) installed
- Logged in: `az login`
- PowerShell 5.1 or later (built into Windows)

### Run the setup script

A single script handles everything — App Registration, Service Principal,
Federated Credential, and role assignment.

Open PowerShell in the repository root and run:

```powershell
.\setup-oidc.ps1 -GitHubOrg "<your-github-username-or-org>"
```

**Example — personal account:**

```powershell
.\setup-oidc.ps1 -GitHubOrg "marceloafanaci"
```

**Example — organisation account:**

```powershell
.\setup-oidc.ps1 -GitHubOrg "virtus-dev"
```

> The `-GitHubOrg` value is whatever appears in your GitHub repository URL:
> `https://github.com/`**`<this-part>`**`/wif-test`

The script is **idempotent** — safe to run more than once. It skips any
resource that already exists.

At the end it prints the three values you need for the next step:

```
  AZURE_CLIENT_ID        = xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
  AZURE_TENANT_ID        = xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
  AZURE_SUBSCRIPTION_ID  = 23e38ba1-3638-4e70-a7a5-3244936cbada
```

### Add the GitHub repository secrets

Go to your GitHub repo → **Settings → Secrets and variables → Actions → New repository secret** and add the three values printed above:

| Secret name | Value |
|---|---|
| `AZURE_CLIENT_ID` | printed by the script |
| `AZURE_TENANT_ID` | printed by the script |
| `AZURE_SUBSCRIPTION_ID` | printed by the script |

These are **not credentials** — they are public IDs. The actual authentication
happens via the signed OIDC token that GitHub mints at runtime.

### Configure the App Service startup command

In the Azure Portal, go to **App Service → Settings → Configuration → General settings**
and set:

```
Startup Command: node index.js
```

Or set the Node.js version to 20 and leave the startup command blank — Azure
will automatically run `npm start`.

### Push to main and watch it deploy

```powershell
git init
git remote add origin https://github.com/<your-org>/wif-test.git
git add .
git commit -m "initial commit"
git push -u origin main
```

The workflow at `.github/workflows/deploy.yml` will trigger automatically.

---

## Local development

```bash
npm install
npm run dev       # uses node --watch (Node 18+), no nodemon needed
```

Then open:
- http://localhost:3000/currency?from=BRL&to=USD&amount=500
- http://localhost:3000/weather
- http://localhost:3000/weather/London

---

## Local deploy (no CI/CD)

Deploy directly from your machine to Azure App Service using only the Azure CLI.
No GitHub Actions, no publish profile, no secrets to manage.

### Prerequisites

- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli-windows) installed
- Logged in: `az login`

### Run the deploy script

```powershell
.\deploy-local.ps1
```

That's it. The script will:

1. Verify your `az login` session
2. Run `npm ci --omit=dev` to install production dependencies
3. Zip the project (excluding `.git`, scripts, and other non-runtime files)
4. Push the zip to your App Service via `az webapp deploy`
5. Delete the temporary zip file
6. Print the live URL when done

### What it deploys to

| Setting | Value |
|---|---|
| App Service | `wif-test` |
| Resource group | `virtus-dev` |
| URL | https://wif-test.azurewebsites.net |

> To deploy to a different environment, edit the `$APP_NAME` and `$RESOURCE_GROUP`
> variables at the top of `deploy-local.ps1`.

---

## How OIDC login works (the short version)

```
GitHub Actions runner
       │
       │  1. requests OIDC token from GitHub's token endpoint
       ▼
GitHub Token Service  ──►  signed JWT  (subject = repo:org/repo:ref:refs/heads/main)
                                │
       ┌────────────────────────┘
       │  2. sends JWT to Azure AD
       ▼
Azure AD  ──► checks issuer + subject against the Federated Credential
           ──► if it matches, issues a short-lived Azure access token
                                │
       ┌────────────────────────┘
       │  3. azure/login stores the token; subsequent steps use it
       ▼
azure/webapps-deploy  ──►  deploys to App Service  ✓
```

No passwords. No certificates. Nothing to rotate.
