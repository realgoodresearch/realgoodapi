# Real Good API reverse proxy

This deploys an Ubuntu Lightsail instance as the public HTTPS endpoint for APIs
running on Serenity. Nginx terminates TLS and sends requests through the existing
WireGuard VPN to Serenity at `192.168.50.5`.

```text
Public client
    -> HTTPS :443
Lightsail (Nginx and WireGuard client)
    -> existing WireGuard VPN server
Serenity (192.168.50.5)
    -> SocialWatcher container :8000
```

The SocialWatcher route preserves the complete API path:

```text
https://api.realgoodresearch.com/socialwatcher/v1/query
    -> http://192.168.50.5:8000/socialwatcher/v1/query
```

## Files

- `deploy.sh` installs the required Ubuntu packages.
- `www/` contains the Quarto source for the API landing page.
- `nginx/api.realgoodresearch.com.initial.conf` bootstraps HTTP for certificate issuance.
- `nginx/api.realgoodresearch.com.conf` is the production HTTPS reverse proxy.
- `wireguard/lightsail-wg0.conf` is the restricted Lightsail VPN client template.
- `www/_site/` contains the rendered site deployed by Nginx.
- `env.example` records the deployment values but is not read automatically.

## 1. Collect the VPN details

Before creating the instance, obtain these values from the existing WireGuard
server:

- Its public hostname or IP address and UDP port.
- Its WireGuard public key.
- An unused WireGuard client address for Lightsail, including its prefix length.

The Lightsail peer will route only `192.168.50.5/32` through the VPN. The VPN
server must already route VPN clients to Serenity's LAN, as it does for the
existing laptop client.

## 2. Create the Lightsail instance

1. Create an Ubuntu instance using the `$5/month`, 512 MB Linux plan.
2. Attach a Lightsail static IPv4 address to it.
3. In the Lightsail IPv4 firewall, allow:
   - TCP 22 from your own public IP where practical.
   - TCP 80 from anywhere.
   - TCP 443 from anywhere.
4. Do not open UDP 51820 on Lightsail. It is a WireGuard client and initiates the
   connection to the existing VPN server.

Record the static public IP as `LIGHTSAIL_PUBLIC_IP`.

## 3. Point DNS at Lightsail

In the existing Lightsail DNS zone, create or update:

```text
Type: A
Name: api
Value: LIGHTSAIL_PUBLIC_IP
```

Confirm that public DNS has updated before requesting a certificate:

```bash
dig +short api.realgoodresearch.com
```

The result must be the Lightsail static IP.

## 4. Copy the repository to Lightsail

Connect to the instance:

```bash
ssh ubuntu@LIGHTSAIL_PUBLIC_IP
```

Clone this repository, or copy it to the instance, then enter its directory:

```bash
sudo apt-get update
sudo apt-get install --yes git
git clone REPOSITORY_URL realgoodapi
cd realgoodapi
```

Install the system packages. The script also creates a persistent 1 GB swapfile
and enables daily unattended security updates without automatic reboots:

```bash
sudo ./deploy.sh
```

Verify both after installation:

```bash
swapon --show
systemctl status unattended-upgrades --no-pager
sudo unattended-upgrade --dry-run --debug
```

## 5. Create the Lightsail WireGuard identity

Generate the key pair and a unique preshared key on Lightsail. Never copy either
secret into this repository:

```bash
sudo install -d -m 700 /etc/wireguard
sudo sh -c 'umask 077; wg genkey > /etc/wireguard/lightsail-private.key; wg pubkey < /etc/wireguard/lightsail-private.key > /etc/wireguard/lightsail-public.key; wg genpsk > /etc/wireguard/lightsail-preshared.key'
sudo cat /etc/wireguard/lightsail-public.key
```

Keep the displayed public key for the next step.

## 6. Register Lightsail on the existing VPN server

Add a peer to the existing WireGuard server using:

```ini
[Peer]
# Lightsail reverse proxy
PublicKey = LIGHTSAIL_PUBLIC_KEY
PresharedKey = LIGHTSAIL_PRESHARED_KEY
AllowedIPs = LIGHTSAIL_VPN_ADDRESS_WITHOUT_PREFIX/32
```

Transfer the value from `/etc/wireguard/lightsail-preshared.key` to the VPN
server through the same secure administrative channel used for other client
preshared keys.

After saving `/etc/wireguard/wg0.conf` on the VPN server, apply it without
interrupting existing clients:

```bash
sudo bash -c 'wg syncconf wg0 <(wg-quick strip wg0)'
sudo wg show wg0
```

### Restrict the Lightsail peer on the VPN server

The `AllowedIPs` setting on Lightsail is only a routing preference; an attacker
with root access could change it. The VPN server must enforce the boundary.

Use UFW on the VPN server. Replace `LIGHTSAIL_VPN_IP` with the peer address
without its prefix and `wg0` if the server uses a different WireGuard interface.
Add the broad deny first, then prepend the specific allow above it:

```bash
sudo ufw route prepend deny in on wg0 from LIGHTSAIL_VPN_IP to any comment 'Block Lightsail from LAN'
sudo ufw route prepend allow in on wg0 proto tcp from LIGHTSAIL_VPN_IP to 192.168.50.5 port 8000 comment 'Lightsail to SocialWatcher'
sudo ufw prepend deny in on wg0 from LIGHTSAIL_VPN_IP to any comment 'Block Lightsail from VPN server'
sudo ufw reload
sudo ufw status numbered
```

UFW persists these rules automatically. In its routed rules, the SocialWatcher
allow must appear before the broader Lightsail deny. The resulting policy is:

```text
allow Lightsail VPN IP -> 192.168.50.5 TCP 8000
drop  Lightsail VPN IP -> every other forwarded destination and port
drop  Lightsail VPN IP -> services on the VPN server itself
```

These rules must also appear before any existing general rule that allows VPN
clients onto the LAN. Inspect `sudo ufw status numbered` and use `ufw delete
RULE_NUMBER` followed by the `prepend` commands again if ordering is wrong.

## 7. Configure WireGuard on Lightsail

Create the deployed configuration without storing the private key in Git:

```bash
sudoedit /etc/wireguard/wg0.conf
```

Enter the following, substituting all uppercase placeholders:

```ini
[Interface]
Address = LIGHTSAIL_VPN_ADDRESS_WITH_PREFIX
PrivateKey = LIGHTSAIL_PRIVATE_KEY
SaveConfig = false

[Peer]
PublicKey = VPN_SERVER_PUBLIC_KEY
PresharedKey = LIGHTSAIL_PRESHARED_KEY
Endpoint = VPN_SERVER_PUBLIC_HOST_OR_IP:VPN_SERVER_PORT
AllowedIPs = 192.168.50.5/32
PersistentKeepalive = 25
```

Read the private key for pasting into that file, then clear it from the terminal:

```bash
sudo cat /etc/wireguard/lightsail-private.key
sudo cat /etc/wireguard/lightsail-preshared.key
clear
```

Protect and start the configuration:

```bash
sudo chmod 600 /etc/wireguard/wg0.conf
sudo systemctl enable --now wg-quick@wg0
```

Verify the handshake, route, and API connectivity:

```bash
sudo wg show
ip route get 192.168.50.5
curl --fail --show-error --verbose http://192.168.50.5:8000/socialwatcher/v1/query
```

Do not continue until the route uses `wg0`, `wg show` reports a recent handshake,
and the API responds. An application-level `4xx` response can still prove the
network path works if the endpoint requires a request body or authentication.

Also verify from Lightsail that another Serenity port and another LAN host are
blocked. Choose a LAN address that is online and a Serenity port known to be
open locally:

```bash
nc -zvw3 192.168.50.5 BLOCKED_PORT
nc -zvw3 ANOTHER_LAN_IP OPEN_PORT
```

Both commands must fail. If either connects, stop and correct the VPN server's
forwarding policy before exposing the public API.

## 8. Enable the Lightsail instance firewall

Inbound access is usually managed in the instance's **Networking** settings in
the Lightsail console, as configured in step 2. UFW is optional instance-level
defence in depth. If you use it, allow SSH before enabling it:

```bash
sudo ufw allow OpenSSH
sudo ufw allow 'Nginx Full'
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw enable
sudo ufw status verbose
```

WireGuard requires no inbound UFW rule on Lightsail for this client setup.

## 9. Bootstrap Nginx over HTTP

“Bootstrap” means starting Nginx with a temporary HTTP-only configuration. The
production configuration cannot start yet because it refers to TLS certificate
files that do not exist until Certbot creates them. This temporary site lets
Let's Encrypt reach its validation challenge over port 80. Step 11 replaces it
with the production HTTPS proxy after the certificate has been issued.

Install the temporary configuration and disable the default site:

```bash
sudo install -m 644 nginx/api.realgoodresearch.com.initial.conf /etc/nginx/sites-available/api.realgoodresearch.com
sudo ln -sfn /etc/nginx/sites-available/api.realgoodresearch.com /etc/nginx/sites-enabled/api.realgoodresearch.com
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t
sudo systemctl enable --now nginx
sudo systemctl reload nginx
```

From another machine, confirm:

```bash
curl --fail http://api.realgoodresearch.com/
```

It should return the bootstrap message.

## 10. Obtain the TLS certificate

Replace `CERTBOT_EMAIL` with the operational email address:

```bash
sudo certbot certonly --webroot --webroot-path /var/www/html --domain api.realgoodresearch.com --email CERTBOT_EMAIL --agree-tos --no-eff-email
```

Confirm that Certbot installed its renewal timer:

```bash
systemctl list-timers certbot.timer
sudo certbot renew --dry-run
```

## 11. Activate the production proxy

The production configuration defines Serenity's IP once:

```nginx
set $serenity_ip 192.168.50.5;
```

If Serenity's reserved LAN address changes, update this one line before copying
the file.

Render the landing page on a development machine with Quarto installed whenever
the files under `www/` change:

```bash
quarto render www
```

This writes the deployable site to `www/_site/`. Commit the source and rendered output
so Quarto is not required on the small Lightsail instance. Install the landing
page and production configuration, then validate them:

```bash
sudo install -d -m 755 /var/www/html
sudo cp -a www/_site/. /var/www/html/
sudo install -m 644 nginx/api.realgoodresearch.com.conf /etc/nginx/sites-available/api.realgoodresearch.com
sudo nginx -t
sudo systemctl reload nginx
```

## 12. Verify the complete request path

Test Nginx itself:

```bash
curl --fail https://api.realgoodresearch.com/
curl --fail https://api.realgoodresearch.com/livez
```

Test SocialWatcher using a valid request for the API:

```bash
curl --verbose https://api.realgoodresearch.com/socialwatcher/v1/query
```

Every `/socialwatcher/` request path is preserved exactly when Nginx sends it
to port 8000 on Serenity. Other unconfigured paths return `404`. The exact
`/livez` and `/healthz` locations remain reserved.

`/healthz` is forwarded to `http://192.168.50.5:8000/healthz`. It will succeed
only after SocialWatcher implements that endpoint:

```bash
curl --fail https://api.realgoodresearch.com/healthz
```

## 13. Check logs and service status

On Lightsail:

```bash
sudo systemctl status wg-quick@wg0 nginx
sudo wg show
sudo journalctl -u wg-quick@wg0 --since today
sudo tail -n 100 /var/log/nginx/error.log
sudo tail -n 100 /var/log/nginx/access.log
```

If Nginx returns `502 Bad Gateway`, first test the internal URL directly from
Lightsail. A direct failure indicates VPN routing, Serenity's firewall, Docker
port publishing, or the API service rather than the public Nginx configuration.

## Adding another API

Publish the new API on another port on Serenity, add a dedicated Nginx `location`
for its public path prefix, and reuse `$serenity_ip`. Always run `sudo nginx -t`
before reloading Nginx.

## Updating the API landing page

Edit the Quarto source under `www/`, then render and publish it from the
development machine:

```bash
quarto render www
git add .
git commit -m "Update API landing page"
git push
```

On Lightsail, pull and install the rendered site:

```bash
cd ~/realgoodapi
git pull
sudo cp -a www/_site/. /var/www/html/
```

Content and style changes do not require an Nginx reload. If the Nginx
configuration also changed, install and validate it before reloading:

```bash
sudo install -m 644 nginx/api.realgoodresearch.com.conf /etc/nginx/sites-available/api.realgoodresearch.com
sudo nginx -t
sudo systemctl reload nginx
```

Verify the deployed landing page:

```bash
curl --fail https://api.realgoodresearch.com/
```
