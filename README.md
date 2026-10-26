# ilo-cert-renew

Automated Let's Encrypt TLS certificate renewal for HPE iLO 4 management
interfaces. The iLO generates its own keypair internally; the private key
never leaves the hardware.

Tested on iLO 4 firmware 2.82.

***

## How it works

1. Checks the days remaining on the current iLO certificate.
2. Opens a Redfish session on iLO and requests a new CSR (the iLO generates
   the keypair; only the CSR leaves the device).
3. Submits the CSR to Let's Encrypt via `certbot` using a DNS-01 challenge
   fulfilled by RFC 2136 dynamic update against a local DNS server.
4. Imports the signed certificate back into iLO via Redfish.

iLO restarts its HTTPS service \~30 seconds after import.

> **CSR generation time**: iLO documentation states keypair generation can
> take up to 10 minutes. In testing it completed in under 30 seconds. The
> script polls for up to 5 minutes. Your experience may vary.

***

## Requirements

| Tool                          | Purpose                                           |
| ----------------------------- | ------------------------------------------------- |
| `bash` 4.0+                   | Script runtime (arrays, `[[ ]]`)                  |
| `curl`                        | Redfish API calls to iLO                          |
| `openssl`                     | Read certificate expiry from iLO port 443         |
| `awk`                         | Parse `.netrc` credentials; extract CSR from JSON |
| `certbot`                     | Let's Encrypt ACME client                         |
| `python3-certbot-dns-rfc2136` | certbot DNS-01 plugin (RFC 2136)                  |
| `date` (GNU coreutils)        | Date arithmetic for expiry calculation            |
| `logger` (util-linux)         | Route cron output to the system log               |

> **macOS note**: the script uses `date -d` (GNU syntax). macOS ships BSD `date`.
> Run on Linux, or install `coreutils` via Homebrew (`brew install coreutils`)
> and alias `gdate` to `date`.

***

## Prerequisites

### DNS server: RFC 2136 dynamic updates

Your authoritative DNS server must accept dynamic updates authenticated with a
TSIG key scoped to the `_acme-challenge` record for your iLO host.

The BIND configuration below is tested. See the appendix for Knot DNS and
PowerDNS.

#### BIND

Generate a key:

```bash
tsig-keygen -a hmac-sha256 ilo-cert-renew
```

**`/etc/bind/named.conf.local`** **(or equivalent)**

```
key "ilo-cert-renew" {
    algorithm hmac-sha256;
    secret "<base64-key>";
};

zone "example.com" {
    type master;
    file "/var/lib/bind/example.com.zone";
    update-policy {
        grant ilo-cert-renew name _acme-challenge.<ilo-hostname.example.com>. TXT;
    };
};
```

### iLO account

Create a dedicated iLO account with the **Configure iLO Settings** privilege.
No other privilege is required. Store credentials in `.netrc` (see below),
never in the config file.

***

## Installation

Suggested target directory is `/opt/ilo-cert-renew/`

```bash
mkdir -p /opt/ilo-cert-renew
wget -qO- https://github.com/mjuliaq/ilo-cert-renew/archive/refs/heads/main.tar.gz \
    | tar -xz --strip-components=1 -C /opt/ilo-cert-renew
chmod 755 /opt/ilo-cert-renew/ilo-cert-renew /opt/ilo-cert-renew/preflight.sh
```

### Configuration

```bash
cp /opt/ilo-cert-renew/ilo-cert-renew.conf.example /opt/ilo-cert-renew/ilo-cert-renew.conf
chmod 600 /opt/ilo-cert-renew/ilo-cert-renew.conf
```

Edit `ilo-cert-renew.conf`:

```bash
ILO_HOST="<ilo-hostname.example.com>"
RENEW_DAYS=30
CERTBOT_CREDENTIALS="/opt/ilo-cert-renew/certbot.ini"
CSR_COUNTRY="US"
CSR_STATE="State"
CSR_CITY="City"
CSR_ORG="Your Organization"
CSR_ORG_UNIT="Your Unit"
```

### Credentials

Create a `.netrc` file and edit it to add the iLO username/password create before. 

```bash
cat > /opt/ilo-cert-renew/.netrc <<'EOF'
machine <ilo-hostname.example.com> login <ilo-user> password <ilo-password>
EOF
chmod 600 /opt/ilo-cert-renew/.netrc
```

Rename the sample `certbot.ini` credentials file:

```bash
cp /opt/ilo-cert-renew/certbot.ini.example /opt/ilo-cert-renew/certbot.ini
chmod 600 /opt/ilo-cert-renew/certbot.ini
```

Edit `certbot.ini` with your local values:

```ini
dns_rfc2136_server = 127.0.0.1
dns_rfc2136_port = 53
dns_rfc2136_name = ilo-cert-renew
dns_rfc2136_secret = <base64-key>
dns_rfc2136_algorithm = HMAC-SHA256
```

***

## Verify the installation

```bash
/opt/ilo-cert-renew/preflight.sh
```

This checks all dependencies and configuration before you run a live renewal.

***

## Usage

```
/opt/ilo-cert-renew/ilo-cert-renew [OPTIONS]

Options:
  -c FILE            Config file (default: <script_dir>/ilo-cert-renew.conf)
  -h HOST            iLO hostname (overrides config)
  -d DAYS            Renew threshold in days (overrides config)
  -f                 Force renewal regardless of expiry
  --dry-run          Check configuration and expiry, make no changes
  --certbot-dry-run  Full iLO CSR request + DNS challenge test, no cert issued
  --help             Show this help
```

### Check configuration

```bash
/opt/ilo-cert-renew/ilo-cert-renew --dry-run
```

### Test DNS challenge without issuing a certificate

```bash
/opt/ilo-cert-renew/ilo-cert-renew --certbot-dry-run
```

This runs the full iLO keypair generation and submits the CSR to Let's
Encrypt staging, exercising the DNS-01 challenge end-to-end without issuing
a real certificate.

### First time run and force renewal

To replace a HPE self-signed certificate that hasn't expired or force renewal of a current certificate use the `-f` switch

```bash
/opt/ilo-cert-renew/ilo-cert-renew -f
```

### Task Scheduling

Schedule the script to run in cron or your favorite system scheduler. The task in the example below runs daily at 03:17.

```cron
17 3 * * * root /opt/ilo-cert-renew/ilo-cert-renew 2>&1 | logger -t ilo-cert-renew
```

***

## Known constraints

* iLO 4 firmware 2.82. Redfish endpoints confirmed working at this version.

* iLO 5 uses different Redfish paths and is not supported without modification.

* iLO restarts its web service during keypair generation (\~30–60 s), which
  invalidates the session token. The script re-authenticates before importing
  the certificate.

* iLO restarts its web service again after certificate import (\~30 s downtime).

***

## Appendix: Knot DNS

These sections were generated with AI assistance for completeness. Treat them
as a starting point and verify against your DNS server's documentation.

Generate a key:

```bash
keymgr -t ilo-cert-renew hmac-sha256
```

**`/etc/knot/knot.conf`**

```yaml
key:
  - id: ilo-cert-renew
    algorithm: hmac-sha256
    secret: <base64-key>

acl:
  - id: ilo_acme_acl
    key: ilo-cert-renew
    action: update
    update-owner: name
    update-owner-name: [_acme-challenge.<ilo-hostname.example.com>.]
    update-type: TXT

zone:
  - domain: example.com
    acl: ilo_acme_acl
```

***

## Appendix: PowerDNS

These sections were generated with AI assistance for completeness. Treat them
as a starting point and verify against your DNS server's documentation.

Generate a key (PowerDNS stores it internally; the secret is printed once —
copy it to `certbot.ini`):

```bash
pdnsutil generate-tsig-key ilo-cert-renew hmac-sha256
```

To retrieve the secret later:

```bash
pdnsutil list-tsig-keys
```

Enable updates for the zone:

```bash
pdnsutil set-meta example.com TSIG-ALLOW-DNSUPDATE ilo-cert-renew
pdnsutil set-meta example.com ALLOW-DNSUPDATE-FROM <ilo-cert-renew host>/32
```

Enable RFC 2136 in `pdns.conf`:

```
dnsupdate=yes
```

> **Note**: PowerDNS grants the key access to the whole zone. Per-name or
> per-type restriction requires a Lua update-policy hook, which is out of
> scope here. Ensure the key is distributed only to the host running this
> script.
