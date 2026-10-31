# Cheap storage hosting with DeluxeHost and FileBrowser Quantum

### Deluxe Host
https://deluxhost.net/

Storage VPS options:
https://deluxhost.net/en/storage

Selected:
Intel Storage-2
Cores: 2vCore
RAM: 3gb
Storage: 10gb
Primary Disk: 1TB
Bandwidth: 1Gbit/s

Price: 1.99 Euro/mo (~$2.25/mo USD)

### FileBrowser Quantum
For putting files inside the computer without all of the extra plugin app let's do everything type bullshit that adds so much overhead.
https://filebrowserquantum.com/en/

---

# Actions to take in order to be done in order to contain the files to be delivered upon future requests.

## Run this script:

***OR***

## Copy Pasta

### 1. User, folders, and the program
```bash
apt update && apt install -y nginx curl
useradd -r -s /usr/sbin/nologin -d /opt/filebrowser filebrowser
mkdir -p /opt/filebrowser/cache /mnt/data/files
chown -R filebrowser:filebrowser /opt/filebrowser /mnt/data/files

curl -fL -o /usr/local/bin/filebrowser \
  https://github.com/gtsteffaniak/filebrowser/releases/download/v2.0.2-stable/linux-amd64-filebrowser
chmod +x /usr/local/bin/filebrowser
filebrowser version
```

### 2. Config
```bash
cat > /opt/filebrowser/config.yaml <<EOF
server:
  sources:
    - path: "/mnt/data/files"
      name: "Files"
      config:
        defaultEnabled: true
  cacheDir: "/opt/filebrowser/cache"
  database:
    path: "/opt/filebrowser/filebrowser.sqlite"
  logging:
    - levels: "info|warning|error"
      noColors: true
http:
  port: 8080
  listen: "127.0.0.1"
  externalUrl: "http://$(hostname -I | awk '{print $1}')"
  trustProxyHeaders: true
auth:
  adminUsername: "admin"
EOF
chown filebrowser:filebrowser /opt/filebrowser/config.yaml
chmod 600 /opt/filebrowser/config.yaml
```
- `listen: 127.0.0.1` means only nginx can reach Quantum directly, not the internet.
- `externalUrl` is the address share links will use.

### 3. Run it as a service
```bash
cat > /etc/systemd/system/filebrowser.service <<'EOF'
[Unit]
Description=FileBrowser Quantum
After=network.target local-fs.target

[Service]
User=filebrowser
Group=filebrowser
WorkingDirectory=/opt/filebrowser
ExecStart=/usr/local/bin/filebrowser -c /opt/filebrowser/config.yaml
Restart=on-failure
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now filebrowser
```

### 4. nginx in front
```bash
cat > /etc/nginx/sites-available/files <<'EOF'
server {
    listen 80;
    listen [::]:80;
    server_name _;

    client_max_body_size 0;
    proxy_request_buffering off;
    proxy_buffering off;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $http_connection;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
EOF
rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/files /etc/nginx/sites-enabled/files
nginx -t && systemctl reload nginx
```
`client_max_body_size 0` removes nginx's upload size limit, so big files work.

### 5. Get the admin password and log in
```bash
journalctl -u filebrowser | grep "Generated initial admin password"
```
The password is the bit at the end of that line, something like `bed-frg7t-vb`. Go to `http://your-server-ip/`, log in as `admin`, and it will make you set a new password.

### 6. fail2ban
- Note: if you want to whitelist your own ip add it to the 'ignoreip' value under [DEFALT]
```bash
apt install -y fail2ban nftables python3-systemd

cat > /etc/fail2ban/filter.d/filebrowser.conf <<'EOF'
[Definition]
failregex = ^<HOST> \S+ \S+ .*"POST /api/auth/(?:login|otp/verify)[^"]*" (?:401|429) 
ignoreregex =
EOF

cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1
banaction = nftables-multiport
banaction_allports = nftables-allports
bantime = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
backend = systemd

[filebrowser]
enabled = true
port = 80,443
filter = filebrowser
logpath = /var/log/nginx/access.log
maxretry = 5
findtime = 1h
bantime = 24h
EOF
systemctl restart fail2ban; sleep 3; fail2ban-client status
```
fail2ban reads nginx's log, which records the real visitor IP, rather than Quantum's own log. Quantum also has its own built-in lockout (8 wrong tries locks that username for 15 minutes from that IP), so this is a second layer.

### 7. Swap if you would like swaps
```bash
fallocate -l 1G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab
echo 'vm.swappiness=10' > /etc/sysctl.d/99-swappiness.conf && sysctl -p /etc/sysctl.d/99-swappiness.conf
```
