# Personal AI Infrastructure (PAI)

TL;DR;

```bash
docker compose up -d
```

## Configure Routes

```bash
admin_key=$(yq '.deployment.admin.admin_key[0].key' apisix_conf/config.yaml | sed 's/"//g')
```

```bash
curl -i http://127.0.0.1:9180/apisix/admin/routes/1 \
-H "X-API-KEY: $admin_key" -X PUT -d '
{
    "name": "demo",
    "desc": "nacos",
    "uri": "/demo/*",
    "plugins": {
        "proxy-rewrite": {
            "regex_uri": ["^/demo/(.*)", "/$1"]
        }
    },
    "upstream": {
        "service_name": "demo-service",
        "type": "roundrobin",
        "discovery_type": "nacos"
    }
}'
```
