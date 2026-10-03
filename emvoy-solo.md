Voici le document complet, prêt à être partagé et à servir de support pour votre meetup.

---

```markdown
# Envoy Solo — Déployer un proxy de production sans Kubernetes

> **Un TP progressif pour comprendre Envoy Proxy, du POC au reverse proxy
> prêt pour la production, sans Istio ni Kubernetes.**

---

## 📖 À propos de ce document

Ce document est né d'une expérience concrète : **comprendre Envoy Proxy en dehors
de Kubernetes**, et vérifier par la pratique qu'un proxy de production peut être
déployé sans orchestrateur, avec de la configuration maîtrisée.

Il est structuré comme un **TP pas-à-pas**, mais peut aussi servir de
**support de présentation** pour un meetup technique (voir la section
[« Plan de présentation »](#-plan-de-présentation-meetup)).

**Public visé** : développeurs, SRE, DevOps curieux de comprendre ce qui se passe
"sous le capot" d'Istio, Traefik, ou de tout autre proxy moderne.

**Prérequis** : un minimum de Linux, une VM CentOS 9 (ou Rocky/Alma), Python 3.

**Durée estimée** : 3 à 5 heures pour le TP complet.

---

## 🎯 Objectifs pédagogiques

À la fin de ce TP, vous saurez :

1. Expliquer les concepts fondamentaux d'Envoy : **Listener → Route → Cluster**.
2. Installer et lancer Envoy comme un simple processus Linux.
3. Configurer Envoy comme **reverse proxy** devant deux applications Flask.
4. Comprendre le **routage par préfixe d'URL** et la **réécriture de chemin**.
5. Mettre en place du **load balancing** et du **traffic splitting**.
6. Passer d'un POC à un **déploiement production** sans Kubernetes.
7. Identifier ce qu'Istio automatise, et pourquoi c'est utile (ou pas) selon le contexte.

---

## 🧠 Partie 1 — Comprendre Envoy en 5 minutes

Envoy est un **proxy L7 (HTTP/gRPC)** hautement performant, extensible et
observable. Il est utilisé comme :

- **Edge proxy** : point d'entrée du trafic externe.
- **Service proxy** : side-car dans un maillage (Istio, Consul Connect...).
- **API Gateway** : routage, auth, rate limiting, transformation.

### Les 3 concepts fondamentaux

| Concept | Rôle | Exemple |
|---|---|---|
| **Listener** | Port d'écoute | `0.0.0.0:8080` |
| **Route** | Règle de routage | `/app1` → `app1_cluster` |
| **Cluster** | Groupe de backends | `127.0.0.1:5001`, `127.0.0.1:5002` |

Le flux est toujours :

```
Requête → Listener → Route → Cluster → Backend
```

### Envoy ≠ Istio

- **Envoy** est le **data plane** : il fait transiter le trafic.
- **Istio** est un **control plane** : il **génère** la config Envoy
  automatiquement (via l'API xDS) et la pousse aux proxies.

Sans Istio, vous écrivez la config Envoy à la main.
Avec Istio, vous écrivez des `VirtualService` et Istio fait la traduction.

**Ce TP vous montre le "à la main".** C'est ce qui permet de comprendre
ensuite ce qu'Istio fait pour vous.

---

## 🧰 Partie 2 — Installation sur CentOS 9

### 2.1. Récupérer le binaire

```bash
ENVOY_VERSION=1.38.0
sudo curl -L "https://github.com/envoyproxy/envoy/releases/download/v${ENVOY_VERSION}/envoy-${ENVOY_VERSION}-linux-x86_64" \
  -o /usr/local/bin/envoy
sudo chmod +x /usr/local/bin/envoy
envoy --version
```

### 2.2. Créer l'utilisateur dédié

```bash
sudo useradd --system --no-create-home --shell /sbin/nologin envoy
```

### 2.3. Préparer les répertoires

```bash
sudo mkdir -p /etc/envoy /var/log/envoy
sudo chown -R envoy:envoy /etc/envoy /var/log/envoy
```

---

## 🐍 Partie 3 — Deux applications Flask

Créez deux applications identiques sur des ports différents.

**`app1.py`**

```python
from flask import Flask
app = Flask(__name__)

@app.route('/')
@app.route('/app1')
def hello():
    return "Hello from Application 1!"

@app.route('/healthz')
def health():
    return "ok", 200

if __name__ == '__main__':
    app.run(host='127.0.0.1', port=5001)
```

**`app2.py`**

```python
from flask import Flask
app = Flask(__name__)

@app.route('/')
@app.route('/app2')
def hello():
    return "Hello from Application 2!"

@app.route('/healthz')
def health():
    return "ok", 200

if __name__ == '__main__':
    app.run(host='127.0.0.1', port=5002)
```

Installez Flask et lancez les deux :

```bash
pip install flask
python3 app1.py &
python3 app2.py &
```

Testez localement :

```bash
curl http://localhost:5001/app1   # Hello from Application 1!
curl http://localhost:5002/app2   # Hello from Application 2!
```

---

## ⚙️ Partie 4 — Configuration Envoy (reverse proxy)

Créez `/etc/envoy/envoy.yaml` :

```yaml
admin:
  address:
    socket_address:
      address: 127.0.0.1
      port_value: 9901

static_resources:
  listeners:
  - name: listener_0
    address:
      socket_address:
        address: 0.0.0.0
        port_value: 8080
    filter_chains:
    - filters:
      - name: envoy.filters.network.http_connection_manager
        typed_config:
          "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
          stat_prefix: ingress_http
          route_config:
            name: local_route
            virtual_hosts:
            - name: local_service
              domains: ["*"]
              routes:
              - match:
                  prefix: "/app1"
                route:
                  cluster: app1_cluster
              - match:
                  prefix: "/app2"
                route:
                  cluster: app2_cluster
          http_filters:
          - name: envoy.filters.http.router
            typed_config:
              "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router

  clusters:
  - name: app1_cluster
    connect_timeout: 5s
    type: STRICT_DNS
    load_assignment:
      cluster_name: app1_cluster
      endpoints:
      - lb_endpoints:
        - endpoint:
            address:
              socket_address: { address: 127.0.0.1, port_value: 5001 }

  - name: app2_cluster
    connect_timeout: 5s
    type: STRICT_DNS
    load_assignment:
      cluster_name: app2_cluster
      endpoints:
      - lb_endpoints:
        - endpoint:
            address:
              socket_address: { address: 127.0.0.1, port_value: 5002 }
```

Lancez Envoy :

```bash
sudo -u envoy /usr/local/bin/envoy -c /etc/envoy/envoy.yaml
```

Testez :

```bash
curl http://localhost:8080/app1   # Hello from Application 1!
curl http://localhost:8080/app2   # Hello from Application 2!
```

---

## 🔍 Partie 5 — Observer Envoy en action

Envoy expose une **interface d'administration** sur `127.0.0.1:9901`.
C'est votre meilleur outil de débogage.

```bash
# Clusters détectés et leur santé
curl -s http://localhost:9901/clusters | head -40

# Statistiques HTTP
curl -s http://localhost:9901/stats | grep -E "http.*downstream_rq_total"

# Config complète telle qu'Envoy la comprend
curl -s http://localhost:9901/config_dump | jq .
```

**Astuce** : refaites un `curl` vers `/app1` et regardez les compteurs augmenter.

---

## ✂️ Partie 6 — Réécriture de chemin

Par défaut, Envoy **transmet le chemin tel quel**. Si Flask ne connaît
que `/`, il renvoie un 404. Deux solutions :

**a) Ajouter la route côté Flask** (ce qu'on a fait ci-dessus).
**b) Réécrire le préfixe côté Envoy** :

```yaml
routes:
- match:
    prefix: "/app1"
  route:
    cluster: app1_cluster
    prefix_rewrite: "/"
```

L'application reste inchangée : Envoy fait le travail.

---

## ⚖️ Partie 7 — Load balancing et traffic splitting

### 7.1. Load balancing

Dupliquez `app1.py` sur le port 5003, puis ajoutez un endpoint :

```yaml
    load_assignment:
      cluster_name: app1_cluster
      endpoints:
      - lb_endpoints:
        - endpoint:
            address:
              socket_address: { address: 127.0.0.1, port_value: 5001 }
        - endpoint:
            address:
              socket_address: { address: 127.0.0.1, port_value: 5003 }
```

Testez :

```bash
for i in {1..10}; do curl -s http://localhost:8080/app1; echo; done
```

Envoy alterne (round-robin par défaut).

### 7.2. Traffic splitting (canary)

```yaml
route:
  weighted_clusters:
    clusters:
    - name: app1_cluster
      weight: 90
    - name: app1_bis_cluster
      weight: 10
```

90 % du trafic vers la v1, 10 % vers la v2.
Idéal pour un déploiement progressif.

---

## 🔧 Partie 8 — Service systemd

**`/etc/systemd/system/envoy.service`**

```ini
[Unit]
Description=Envoy Proxy
After=network.target

[Service]
Type=simple
User=envoy
Group=envoy
ExecStartPre=/bin/rm -f /dev/shm/envoy_shared_memory_*
ExecStart=/usr/local/bin/envoy -c /etc/envoy/envoy.yaml --base-id 1
ExecReload=/bin/kill -USR1 $MAINPID
Restart=on-failure
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
```

Activez et démarrez :

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now envoy
sudo systemctl status envoy
```

> **Note** : si vous avez vu l'erreur `cannot open shared memory`,
> c'est parce que le hot restart utilise des segments de mémoire partagée.
> Le `ExecStartPre` nettoie les orphelins, et `--base-id 1` évite les collisions.

---

## 🚀 Partie 9 — Perspectives production (sans Kubernetes)

Ce que nous avons fait est un **POC**. Pour passer en production sur une VM
standalone, voici les 6 chantiers à mener, par ordre de priorité.

### 9.1. Gunicorn à la place de Flask dev

`app.run()` est **mono-thread, non sécurisé, non performant**.

```bash
pip install gunicorn
gunicorn -w 4 -b 127.0.0.1:5001 --access-logfile - app1:app
```

Créez un service systemd pour chaque application (même modèle que pour Envoy).

### 9.2. Hot restart propre

On a désactivé le hot restart pour le POC. En production, il faut le
**réactiver** pour recharger la config sans coupure :

- `--base-id` unique par instance.
- Nettoyage des segments `/dev/shm/envoy_shared_memory_*` au démarrage.
- `ExecReload=/bin/kill -USR1 $MAINPID` dans le service.
- **Toujours valider la config avant** :

```bash
envoy --mode validate -c /etc/envoy/envoy.yaml
```

### 9.3. TLS obligatoire

Envoy termine le TLS lui-même. Ajoutez un listener `:443` :

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

Renouvellement via `certbot` + `systemctl reload envoy` (grâce au hot restart,
aucune coupure).

### 9.4. Health checks, retries, timeouts

Sans ces trois éléments, Envoy n'apporte pas grand-chose en production.

```yaml
clusters:
- name: app1_cluster
  connect_timeout: 2s
  health_checks:
  - timeout: 1s
    interval: 5s
    unhealthy_threshold: 2
    healthy_threshold: 2
    http_health_check:
      path: "/healthz"

routes:
- match: { prefix: "/app1" }
  route:
    cluster: app1_cluster
    timeout: 10s
    retry_policy:
      retry_on: "5xx,reset,connect-failure"
      num_retries: 3
      per_try_timeout: 3s
```

### 9.5. Observabilité

**a) Logs d'accès JSON** vers un fichier :

```yaml
access_log:
- name: envoy.access_loggers.file
  typed_config:
    "@type": type.googleapis.com/envoy.extensions.access_loggers.file.v3.FileAccessLog
    path: /var/log/envoy/access.log
    log_format:
      json_format:
        timestamp: "%START_TIME%"
        method: "%REQ(:METHOD)%"
        path: "%REQ(X-ENVOY-ORIGINAL-PATH?:PATH)%"
        status: "%RESPONSE_CODE%"
        duration_ms: "%DURATION%"
        upstream: "%UPSTREAM_HOST%"
```

**b) Métriques Prometheus** : Envoy les expose déjà sur
`http://127.0.0.1:9901/stats/prometheus`. Branchez Prometheus + Grafana.

**c) Sécurisez l'admin** : port 9901 **uniquement sur localhost**,
jamais exposé sur Internet.

### 9.6. Gestion de la configuration

- **Versionnez `/etc/envoy/`** dans Git.
- Déployez via **Ansible** ou un script + CI/CD.
- **Validez avant rechargement** :
  ```bash
  envoy --mode validate -c /etc/envoy/envoy.yaml && systemctl reload envoy
  ```

---

## 📊 Tableau récapitulatif : POC vs Production

| Aspect | POC | Production standalone |
|---|---|---|
| Hot restart | Désactivé | **Activé** via `--base-id` |
| Utilisateur | root | **`envoy` dédié**, non-root |
| Limites | Aucune | `LimitNOFILE=65536` |
| TLS | Non | **Obligatoire** |
| Backends | Flask dev | **Gunicorn** + systemd |
| Health checks | Non | **Oui** |
| Retries / timeouts | Non | **Oui** |
| Logs | Manuels | **JSON structuré** |
| Métriques | curl admin | **Prometheus + Grafana** |
| Admin (9901) | localhost | localhost + firewall |
| Rechargement | Redémarrage | **SIGUSR1** + validation |
| Versioning config | Aucun | **Git + Ansible/CI** |

---

## 🧭 Et Istio dans tout ça ?

Istio **n'est pas nécessaire** pour faire de la production avec Envoy.
Il apporte :

- La **découverte automatique** des services (via l'API Kubernetes).
- La **génération automatique** de la config xDS.
- Le **mTLS** automatique entre services.
- La **gestion multi-cluster**.

**Sans Kubernetes**, faire tourner Istio est possible mais :
- Complexe (il faut fournir un plan de contrôle Kubernetes "nu").
- Non supporté officiellement.
- Réservé à du POC avancé.

**Le bon critère de décision** :

| Situation | Choix recommandé |
|---|---|
| 1 à 10 services, config stable | **Envoy standalone** |
| Dizaines de services, changements fréquents | **Istio sur K8s** |
| Besoin de mTLS automatique | **Istio ou Consul Connect** |
| Équipe SRE restreinte | **Envoy standalone + Git** |

---

## 🎤 Plan de présentation (meetup)

Structure suggérée pour un talk de **30 minutes** :

| Min | Section | Contenu |
|---|---|---|
| 0–3 | **Intro** | Pourquoi Envoy ? Pourquoi sans K8s ? |
| 3–8 | **Concepts** | Listener / Route / Cluster (schéma) |
| 8–15 | **Démo live** | Deux Flask + Envoy (routage, path rewrite) |
| 15–20 | **Admin & observabilité** | `/clusters`, `/stats`, `/config_dump` |
| 20–25 | **Load balancing & canary** | Démo `for i in ...` + weighted_clusters |
| 25–30 | **Vers la prod** | TLS, health checks, hot restart, Git |
| 30+ | **Q&A / Istio** | Positionnement, quand passer à Istio |

**Conseil** : préparez un `tmux` avec 3 panneaux :
1. Envoy qui tourne (logs).
2. Flask 1 et Flask 2.
3. Terminal pour les `curl` et l'admin.

---

## 📚 Ressources

- [Documentation officielle Envoy](https://www.envoyproxy.io/docs/envoy/latest/)
- [Envoy Proxy GitHub Releases](https://github.com/envoyproxy/envoy/releases)
- [Istio — Workloads externes (VMs)](https://istio.io/latest/docs/setup/install/virtual-machine/)
- [Dashboards Grafana officiels Envoy](https://grafana.com/grafana/dashboards/6693)

---

## ✅ Ce qu'il faut retenir

1. **Envoy n'a pas besoin de Kubernetes** pour être utile en production.
2. **Listener → Route → Cluster** est la clé de voûte de toute config.
3. **L'admin (9901) est votre meilleur ami** pour déboguer.
4. Le passage POC → prod tient en **6 chantiers** : TLS, health checks,
   observabilité, hot restart, Gunicorn, gestion de config.
5. **Istio n'est qu'un automatiseur** de config Envoy. Comprendre Envoy
   à la main rend Istio beaucoup plus clair.
