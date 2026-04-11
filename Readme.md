# 🏰 Serverstack

A self-hosted server stack built around Traefik as the reverse proxy, with CrowdSec for threat detection and automated IP banning.

> **Status:** Work in progress. More stacks will be added over time.

---

## Stack Overview

| Service   | Purpose                          |
|-----------|----------------------------------|
| Traefik   | Reverse proxy, SSL termination   |
| CrowdSec  | Threat detection + IP banning    |

---

## Prerequisites

- Docker + Docker Compose installed
- A domain pointing to your server's public IP
- Ports `80` and `443` open on your firewall
- (Optional) Tailscale for secure remote access

---

## 1. Traefik Setup

Traefik handles all incoming traffic, terminates SSL via Let's Encrypt, and routes requests to your services.

### Folder structure

```
traefik/
├── docker-compose.yml
├── traefik.yml               # Static config
├── secrets/                  # File-mounted secrets for Traefik plugin config
└── data/
    ├── acme.json             # SSL certs (auto-generated, chmod 600)
    └── config/
        └── dynamic.yml       # Dynamic config (routers, middlewares, services)
```

### Steps

**1. Create the shared Docker network:**
```bash
docker network create proxy
```

**2. Create the log volume (needed for CrowdSec):**
```bash
docker volume create --name traefik_logs
```

**3. Set permissions on acme.json:**
```bash
chmod 600 traefik/data/acme.json
```

**4. Update `traefik.yml`:**
- Set your email for Let's Encrypt under `certificatesResolvers.letsencrypt.acme.email`

**5. Update `dynamic.yml`:**
- Replace all domain references (e.g. `yourdomain.dev`) with your own domain
- Update service URLs to point to your containers

**6. Start Traefik:**
```bash
cd traefik
docker compose up -d
```

**7. Verify:**
```bash
docker logs traefik | tail -20
```

---

## 2. CrowdSec Setup

CrowdSec watches Traefik access logs and SSH auth logs, detects threats, and tells Traefik to ban malicious IPs via the bouncer plugin.

### Folder structure

```
crowdsec/
├── docker-compose.yml
├── .env                      # Secrets (not committed)
├── .env.example              # Template for .env
└── data/
    ├── acquis.yml            # Log sources config
    ├── config/
    │   ├── profiles.yaml     # Alert → decision rules
    │   └── notifications/
    │       └── email.yaml    # Email alert config
    └── parsers/
        └── s02-enrich/
            └── tailscale-whitelist.yaml
```

### Steps

**1. Create your `.env` file from the example:**
```bash
cp crowdsec/.env.example crowdsec/.env
```

Fill in the values:
```env
CROWDSEC_BOUNCER_KEY=        # Generated in step 4
SMTP_USERNAME=               # Gmail address to send from
SMTP_PASSWORD=               # Gmail App Password (16 chars)
ALERT_EMAIL=                 # Email to receive alerts
```

**2. Start CrowdSec with a placeholder bouncer key first:**
```bash
echo "CROWDSEC_BOUNCER_KEY=placeholder" >> crowdsec/.env
cd crowdsec
docker compose up -d
```

**3. Generate the real bouncer key:**
```bash
docker exec crowdsec cscli bouncers add traefik-bouncer
```

Copy the printed key into `.env` as `CROWDSEC_BOUNCER_KEY`, then:
```bash
docker compose restart
```

**4. Store the bouncer key for Traefik:**

Traefik does not reliably interpolate the CrowdSec key from the CrowdSec `.env` file in dynamic plugin config, so we use a file-mounted secret instead.

Create the file `traefik/secrets/crowdsec_api_key` and paste only the key value into it.

Then in `traefik/data/config/dynamic.yml`, the plugin should use:
```yaml
crowdsecLapiKey: /secrets/crowdsec_api_key
```

Restart Traefik again after creating the secret file:
```bash
cd traefik && docker compose restart
```

**5. Verify the bouncer is connected:**
```bash
docker exec crowdsec cscli bouncers list
```

You should see `traefik-bouncer` with a recent `Last API pull` timestamp.

---

## 3. Email Alerts Setup

CrowdSec sends an email whenever an IP is banned.

### Gmail App Password

1. Go to [myaccount.google.com](https://myaccount.google.com)
2. Security → 2-Step Verification → App passwords
3. Create one named `crowdsec`
4. Copy the 16-character password into `.env` as `SMTP_PASSWORD`

### Test the notification

```bash
docker exec crowdsec cscli notifications test email_default
```

Check your inbox — you should receive a test alert.

---

## 4. Tailscale Whitelist

If you use Tailscale, whitelist the CGNAT range so your own traffic is never banned.

The whitelist is already configured at:
```
crowdsec/data/parsers/s02-enrich/tailscale-whitelist.yaml
crowdsec/data/config/parsers/s02-enrich/tailscale-whitelist.yaml
```

No action needed — it loads automatically.

---

## Useful Commands

```bash
# Watch live traffic
docker exec traefik tail -f /var/log/traefik/access.log

# Check active bans
docker exec crowdsec cscli decisions list

# Check recent alerts
docker exec crowdsec cscli alerts list --since 24h

# Manually ban an IP
docker exec crowdsec cscli decisions add --ip 1.2.3.4 --duration 24h --reason "reason"

# Remove a ban
docker exec crowdsec cscli decisions delete --ip 1.2.3.4

# CrowdSec metrics
docker exec crowdsec cscli metrics

# Test email notification
docker exec crowdsec cscli notifications test email_default
```

---

## Troubleshooting

### Traefik

| Problem | Fix |
|---|---|
| SSL cert not generating | Check port 80 is open. Check acme.json has `chmod 600` |
| Dashboard not accessible | Traefik dashboard runs on port 8080, restrict to Tailscale only |
| Routes not loading | Check `dynamic.yml` syntax. Traefik hot-reloads — check logs for parse errors |

### CrowdSec

| Problem | Fix |
|---|---|
| Bouncer not connecting | Check both containers are on the `proxy` network: `docker network inspect proxy` |
| `server misbehaving` DNS error | Upgrade bouncer plugin to `v1.4.2` in `traefik.yml`. Known bug in older versions |
| Decisions not enforced | Wait up to 60s — bouncer polls in `stream` mode every 60s |
| Email not sending | Confirm env vars are passed via `env_file: .env` in compose. Test with `cscli notifications test email_default` |
| `receiver emails are not set` | Field must be `receiver_emails`, not `smtp_to` |
| `cookie token is empty` on `/v1/alerts` | That endpoint requires machine credentials, not bouncer API key. Use `/v1/decisions` instead |
| Config not loading after edit | If using bind mount over a named volume, use `docker cp` or ensure `crowdsec_config` volume is removed |

### General

| Problem | Fix |
|---|---|
| Container can't resolve another by name | Both must be on the same Docker network |
| Changes to `dynamic.yml` not taking effect | Traefik hot-reloads file changes — check logs. If plugin config changed, full restart needed |
| `Permission denied` writing to `data/config/` | Run `sudo chown -R $USER:$USER ~/serverstack/crowdsec/data/config` |

---

## Notes

- `acme.json` is auto-generated and gitignored — do not commit it
- `.env` is gitignored — use `.env.example` as the template
- CrowdSec hub files (`collections/`, `scenarios/`, `parsers/` inside `data/config/`) are downloaded automatically on startup — do not commit them
- The `traefik_logs` Docker volume is shared between Traefik and CrowdSec — it must be created before either container starts

---

*More stacks coming soon.*