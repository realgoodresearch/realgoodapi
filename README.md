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

The initial route is:

```text
https://api.realgoodresearch.com/socialwatcher/v1/query
    -> http://192.168.50.5:8000/socialwatcher/v1/query
```

## Files

- `deploy.sh` installs the required Ubuntu packages.
- `nginx/api.realgoodresearch.com.initial.conf` bootstraps HTTP for certificate issuance.
- `nginx/api.realgoodresearch.com.conf` is the production HTTPS reverse proxy.
- `wireguard/lightsail-wg0.conf` is the restricted Lightsail VPN client template.
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

Install the system packages:

```bash
sudo ./deploy.sh
```

## 5. Create the Lightsail WireGuard identity

Generate the key pair on Lightsail. Never copy the private key into this
repository:

```bash
sudo install -d -m 700 /etc/wireguard
sudo sh -c 'umask 077; wg genkey > /etc/wireguard/lightsail-private.key; wg pubkey < /etc/wireguard/lightsail-private.key > /etc/wireguard/lightsail-public.key'
sudo cat /etc/wireguard/lightsail-public.key
```

Keep the displayed public key for the next step.

## 6. Register Lightsail on the existing VPN server

Add a peer to the existing WireGuard server using:

```ini
[Peer]
# Lightsail reverse proxy
PublicKey = LIGHTSAIL_PUBLIC_KEY
AllowedIPs = LIGHTSAIL_VPN_ADDRESS_WITHOUT_PREFIX/32
```

Use the VPN server's normal configuration process to apply the peer. Do not
replace or restart unrelated VPN configuration if the server supports a live
reload.

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
Endpoint = VPN_SERVER_PUBLIC_HOST_OR_IP:VPN_SERVER_PORT
AllowedIPs = 192.168.50.5/32
PersistentKeepalive = 25
```

Read the private key for pasting into that file, then clear it from the terminal:

```bash
sudo cat /etc/wireguard/lightsail-private.key
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

## 8. Enable the host firewall

Allow SSH before enabling UFW:

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
the file. Install and validate the production configuration:

```bash
sudo install -m 644 nginx/api.realgoodresearch.com.conf /etc/nginx/sites-available/api.realgoodresearch.com
sudo nginx -t
sudo systemctl reload nginx
```

## 12. Verify the complete request path

Test Nginx itself:

```bash
curl --fail https://api.realgoodresearch.com/livez
```

Test SocialWatcher using a valid request for the API:

```bash
curl --verbose https://api.realgoodresearch.com/socialwatcher/v1/query
```

The public request path is preserved exactly when Nginx sends it to port 8000
on Serenity.

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
