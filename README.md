# rawhidebuild

Builds a Fedora Rawhide installer ISO with full dev environment and CloudID SSH integration, then pushes it to mkube as an iSCSI CDROM.

## What it does

1. Downloads the Rawhide netinstall `boot.iso`
2. Embeds a kickstart via `mkksiso` that includes:
   - Full Go, Rust (rustup + musl targets), C/C++, and kernel dev toolchains
   - CloudID SSH key fetch at install time
   - Periodic SSH key refresh timer (every 5 min from CloudID)
3. Uploads the ISO to mkube as an iSCSI CDROM (`rawhide-dev`)

## Build via mkube job

```bash
curl -s -X POST 'http://192.168.200.2:8082/api/v1/namespaces/default/jobs' \
  -H 'Content-Type: application/json' --data-binary @- <<'EOF'
{"apiVersion":"v1","kind":"Job","metadata":{"name":"build-rawhide-iso","namespace":"default"},"spec":{"pool":"build","priority":10,"repo":"https://github.com/glennswest/rawhidebuild","buildScript":"build.sh","buildImage":"registry.fedoraproject.org/fedora:latest","timeout":7200}}
EOF
```

## Boot a server from the ISO

```bash
mk patch bmh/server2 --type=merge -p '{"spec":{"image":"rawhide-dev"}}'
mk annotate bmh/server2 bmh.mkube.io/reboot="$(date -u +%Y-%m-%dT%H:%M:%SZ)" --overwrite
```

## Monitor

```bash
mk get jobs -n default
curl -s 'http://192.168.200.2:8082/api/v1/namespaces/default/jobs/build-rawhide-iso/logs'
```
