---
marp: true
theme: default
paginate: true
backgroundColor: #0d1117
color: #e6edf3
style: |
  section {
    font-family: 'Inter', 'Segoe UI', sans-serif;
    font-size: 26px;
  }
  h1 { color: #58a6ff; font-size: 48px; }
  h2 { color: #58a6ff; border-bottom: 2px solid #30363d; padding-bottom: 8px; }
  code { background: #161b22; color: #79c0ff; padding: 2px 6px; border-radius: 4px; }
  pre { background: #161b22; border: 1px solid #30363d; border-radius: 8px; }
  table { font-size: 22px; }
  th { background: #161b22; color: #58a6ff; }
  .accent { color: #7ee787; }
  .warn { color: #f0883e; }
  .small { font-size: 20px; }
  .center { text-align: center; }
---

<!-- _class: center -->

# 🛡️ Envoy Solo

## Déployer un proxy de production sans Kubernetes

**Du POC au reverse proxy prêt pour la prod**

*Un TP concret, sans Istio, sans orchestrateur*

---

## 🎯 Pourquoi ce talk ?

- Tout le monde parle d'**Istio**, **Envoy**, **service mesh**...
- Mais **qui a déjà écrit une config Envoy à la main ?**
- Objectif : **comprendre ce qui se passe sous le capot**
- Et vérifier par la pratique qu'on peut faire de la **prod sans K8s**

> Istio automatise Envoy. Il ne le remplace pas.
> Pour comprendre Istio, il faut d'abord comprendre Envoy.

---

## 🧠 Envoy en 3 concepts

| Concept | Rôle | Exemple |
|---|---|---|
| **Listener** | Port d'écoute | `0.0.0.0:8080` |
| **Route** | Règle de routage | `/app1` → `app1_cluster` |
| **Cluster** | Groupe de backends | `127.0.0.1:5001` |

```
Requête → Listener → Route → Cluster → Backend
```

**C'est tout.** Le reste, c'est du raffinement.

---

## 🌐 Envoy vs Istio

```
        ┌─────────────────────┐
        │   Control Plane     │  ← Istio
        │  (génère la config) │
        └──────────┬──────────┘
                   │ xDS
        ┌──────────┼──────────┐
        ▼          ▼          ▼
    ┌───────┐  ┌───────┐  ┌───────┐
    │Envoy 1│  │Envoy 2│  │Envoy 3│  ← Data plane
    └───────┘  └───────┘  └───────┘
```

- **Envoy** = data plane (fait transiter le trafic)
- **Istio** = control plane (génère la config Envoy)
- **Sans Istio** = vous écrivez la config à la main

---

<!-- _class: center -->

# 🛠️ Démo Live

## Setup en 5 minutes

*(script fourni — `demo.sh`)*

---

## 🏗️ Architecture du TP

```
                  Client
                    │
                    ▼
           ┌─────────────────┐
           │  Envoy :8080    │
           │  (reverse proxy)│
           └────┬───────┬────┘
                │       │
       /app1 ───┘       └─── /app2
                │       │
                ▼       ▼
          ┌─────────┐ ┌─────────┐
          │ Flask 1 │ │ Flask 2 │
          │ :5001   │ │ :5002   │
          └─────────┘ └─────────┘

          Admin Envoy : 127.0.0.1:9901
```

---

## 🎬 Étape 1 — Les deux applications Flask

```python
# app1.py
from flask import Flask
app = Flask(__name__)

@app.route('/')
@app.route('/app1')
def hello():
    return "Hello from Application 1!"
```

*On lance deux instances sur `:5001` et `:5002`.*

---

## 🎬 Étape 2 — La config Envoy

```yaml
listeners:
- name: listener_0
  address:
    socket_address: { address: 0.0.0.0, port_value: 8080 }
  filter_chains:
  - filters:
    - name: envoy.filters.network.http_connection_manager
      typed_config:
        # ...
        route_config:
          virtual_hosts:
          - name: local_service
            domains: ["*"]
            routes:
            - match: { prefix: "/app1" }
              route: { cluster: app1_cluster }
            - match: { prefix: "/app2" }
              route: { cluster: app2_cluster }
```

---

## 🎬 Étape 3 — Test du routage

```bash
$ curl http://localhost:8080/app1
Hello from Application 1!

$ curl http://localhost:8080/app2
Hello from Application 2!
```

✅ **Envoy route correctement.**

*Même application, un seul port d'entrée, deux backends.*

---

<!-- _class: center -->

# 🔍 L'admin Envoy

## Votre meilleur outil de débogage

---

## 🔍 Observer Envoy en action

**Port 9901 — jamais exposé sur Internet.**

```bash
# Clusters détectés et leur santé
curl -s http://localhost:9901/clusters

# Statistiques HTTP en temps réel
curl -s http://localhost:9901/stats | grep downstream_rq

# Config complète telle qu'Envoy la comprend
curl -s http://localhost:9901/config_dump | jq .
```

**Démo** : faites un `curl` et regardez les compteurs bouger.

---

## ✂️ Path Rewrite

Envoy **transmet le chemin tel quel** par défaut.

```yaml
routes:
- match: { prefix: "/app1" }
  route:
    cluster: app1_cluster
    prefix_rewrite: "/"    # ← retire /app1
```

**Sans** : Flask reçoit `/app1` → 404 si non déclaré.
**Avec** : Flask reçoit `/` → OK, application inchangée.

*Principe clé : le proxy peut transformer la requête.*

---

## ⚖️ Load Balancing

Ajoutez un endpoint au cluster :

```yaml
load_assignment:
  endpoints:
  - lb_endpoints:
    - endpoint: { address: { socket_address: { address: 127.0.0.1, port_value: 5001 } } }
    - endpoint: { address: { socket_address: { address: 127.0.0.1, port_value: 5003 } } }
```

```bash
$ for i in {1..6}; do curl -s localhost:8080/app1; echo; done
Hello from Application 1!
Hello from Application 1 bis!
Hello from Application 1!
Hello from Application 1 bis!
```

*Round-robin par défaut. Configurable (least_request, random, ring_hash...).*

---

## 🐤 Traffic Splitting (Canary)

```yaml
route:
  weighted_clusters:
    clusters:
    - name: app1_cluster
      weight: 90
    - name: app1_bis_cluster
      weight: 10
```

**90 % v1 · 10 % v2**

Cas d'usage : **déploiement progressif**, A/B testing, migration.

*Sans toucher au code des applications.*

---

<!-- _class: center -->

# 🚀 Vers la Production

## Ce qui change vraiment

---

## 📊 POC vs Production

| Aspect | POC | Production |
|---|---|---|
| Hot restart | Désactivé | **Activé** |
| Utilisateur | root | **`envoy` dédié** |
| TLS | Non | **Obligatoire** |
| Backends | Flask dev | **Gunicorn** |
| Health checks | Non | **Oui** |
| Retries | Non | **Oui** |
| Logs | Manuels | **JSON structuré** |
| Métriques | curl admin | **Prometheus** |
| Config | Local | **Git + CI/CD** |

---

## 🔐 TLS — Non négociable

Envoy termine le TLS lui-même :

```yaml
transport_socket:
  name: envoy.transport_sockets.tls
  typed_config:
    "@type": type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.DownstreamTlsContext
    common_tls_context:
      tls_certificates:
      - certificate_chain: { filename: "/etc/envoy/certs/fullchain.pem" }
        private_key: { filename: "/etc/envoy/certs/privkey.pem" }
```

Renouvellement : `certbot` + `systemctl reload envoy` (**sans coupure**).

---

## ❤️ Health Checks + Retries

```yaml
clusters:
- name: app1_cluster
  health_checks:
  - timeout: 1s
    interval: 5s
    http_health_check: { path: "/healthz" }

routes:
- match: { prefix: "/app1" }
  route:
    timeout: 10s
    retry_policy:
      retry_on: "5xx,reset,connect-failure"
      num_retries: 3
```

**Sans ça, Envoy ne sert à rien en prod.** C'est ce qui absorbe les pannes.

---

## 📈 Observabilité — Les 3 piliers

**1. Logs JSON** → Filebeat → Elasticsearch/Loki
**2. Métriques** → Prometheus scrape `/stats/prometheus`
**3. Traces** → OpenTelemetry → Jaeger

```
┌──────────┐    scrape    ┌────────────┐    ┌─────────┐
│  Envoy   │ ───────────► │ Prometheus │ ─► │ Grafana │
│  :9901   │              └────────────┘    └─────────┘
└──────────┘
```

Dashboard Grafana officiel : **ID 6693**.

---

## 🔄 Rechargement sans coupure

**Le point le plus important en prod.**

```ini
# systemd
ExecStartPre=/bin/rm -f /dev/shm/envoy_shared_memory_*
ExecStart=/usr/local/bin/envoy -c /etc/envoy/envoy.yaml --base-id 1
ExecReload=/bin/kill -USR1 $MAINPID
```

Workflow de déploiement :

```bash
envoy --mode validate -c /etc/envoy/envoy.yaml \
  && systemctl reload envoy
```

**Zero downtime.** C'est le hot restart.

---

<!-- _class: center -->

# 🧭 Et Istio ?

## Positionnement

---

## 🎯 Quand utiliser quoi ?

| Situation | Choix |
|---|---|
| 1–10 services, config stable | **Envoy standalone** ✅ |
| Dizaines de services, changements fréquents | **Istio sur K8s** |
| Besoin de mTLS automatique | **Istio / Consul Connect** |
| Équipe SRE restreinte | **Envoy standalone + Git** |
| Labo / POC | **Istio VM (workloads externes)** |

**Sans K8s**, faire tourner Istio est possible mais **complexe et non supporté officiellement**.

---

## 💡 La vraie leçon

- Envoy **n'a pas besoin de Kubernetes** pour être utile.
- Istio **génère** de la config Envoy — il ne fait rien de magique.
- Comprendre Envoy à la main rend **Istio limpide**.
- Les **6 chantiers de prod** (TLS, HC, observabilité, hot restart, Gunicorn, Git)
  sont **les mêmes** avec ou sans orchestrateur.

> **Maîtrisez le proxy. L'orchestrateur n'est qu'un confort.**

---

<!-- _class: center -->

# ✅ Ce qu'il faut retenir

1. **Listener → Route → Cluster** = la clé de voûte
2. **L'admin (9901)** = votre meilleur ami
3. **POC ≠ Prod** — 6 chantiers à mener
4. **Istio automatise**, il ne remplace pas
5. **Git + validation + hot restart** = déploiement serein

---

<!-- _class: center -->

# 🙏 Merci !

## Questions ?

**Slides** : `slides.md`
**Démo** : `demo.sh`
**Architecture** : `ARCHITECTURE.md`

*Repo : envoy-solo*