# Real Good API landing page

Public API directory for [api.realgoodresearch.com](https://api.realgoodresearch.com/).
This repository contains the Quarto source and rendered static site.

Host provisioning, Nginx, WireGuard, firewall rules, and TLS operations are now
maintained in the private `realgoodresearch/sysadmin` repository under
`reverse-proxy/`. Operators need access to that repository for infrastructure
changes. Removing those files here does not change the running proxy.

## Edit and render

With Quarto installed on a development machine:

```bash
quarto render www
git add www
git commit -m "Update API landing page"
git push
```

Commit both source and rendered output so Quarto is not required on the web host.

## Publish

On the existing web host, update the public checkout and copy the rendered site:

```bash
cd ~/realgoodapi
git pull --ff-only
sudo install -d -m 755 /var/www/html
sudo cp -a www/_site/. /var/www/html/
```

These commands preserve other files in the webroot, including certificate
validation files. Static content changes do not require an Nginx reload.

Verify the deployed page:

```bash
curl --fail https://api.realgoodresearch.com/
```

The Quarto source is in `www/index.qmd`, configuration in `www/_quarto.yml`,
and styling in `www/custom-theme.scss`. Rendered output lives in `www/_site/`.
