# Architecture — Envoy Solo

> Schémas de référence du POC au déploiement production.

---

## 1. Vue d'ensemble du POC

```
                         ┌──────────────────────────────┐
                         │        VM CentOS 9           │
                         │                              │
   Client                │   ┌──────────────────────┐   │
   ──────►  :8080 ───────┼──►│      Envoy           │   │
   (curl,                │   │   (reverse proxy)    │   │
    navigateur)          │   │                      │   │
                         │   │  Listener :8080      │   │
                         │   │  Admin    :9901      │   │
                         │   └────────┬──────┬──────┘   │
                         │            │      │          │
                         │      /app1 │      │ /app2    │
                         │            ▼      ▼          │
                         │   ┌──────────┐ ┌──────────┐  │
                         │   │ Flask 1  │ │ Flask 2  │  │
                         │   │ :5001    │ │ :5002    │  │
                         │   └──────────┘ └──────────┘  │
                         │                              │
                         └──────────────────────────────┘
```

**Points clés** :

- Un seul point d'entrée (`:8080`), deux backends.
- Envoy est le **seul à connaître** l'existence des deux applications.
- L'admin (`:9901`) est **local uniquement** — jamais exposé.

---

## 2. Flux d'une requête

```
   curl /app1
       │
       ▼
┌──────────────────────────────────────────────────────────┐
│ LISTENER :8080                                           │
│   reçoit la requête TCP/HTTP                             │
└────────────────────────┬─────────────────────────────────┘
                         │
                         ▼
┌──────────────────────────────────────────────────────────┐
│ HTTP CONNECTION MANAGER                                  │
│   filtre réseau principal d'Envoy                        │
└────────────────────────┬─────────────────────────────────┘
                         │
                         ▼
┌──────────────────────────────────────────────────────────┐
│ ROUTE MATCHING                                           │
│   prefix: "/app1"  ──►  cluster: app1_cluster            │
└────────────────────────┬─────────────────────────────────┘
                         │
                         ▼
┌──────────────────────────────────────────────────────────┐
│ CLUSTER : app1_cluster                                   │
│   load_balancing: ROUND_ROBIN                            │
│   endpoints:                                             │
│     - 127.0.0.1:5001                                     │
│     - 127.0.0.1:5003  (si LB activé)                     │
└────────────────────────┬─────────────────────────────────┘
                         │
                         ▼
                 ┌───────────────┐
                 │  Flask 1      │
                 │  Hello...     │
                 └───────────────┘
```

---

## 3. Load Balancing (round-robin)

```
                     Requête 1        Requête 2        Requête 3
                         │                │                │
                         ▼                ▼                ▼
                  ┌─────────────────────────────────────────┐
                  │            Envoy :8080                  │
                  │         (round-robin balancer)          │
                  └──────┬─────────────────────────┬────────┘
                         │                         │
                  Requête 1                 Requête 2
                         │                         │
                         ▼                         ▼
                  ┌────────────┐            ┌────────────┐
                  │  Flask 1   │            │ Flask 1bis │
                  │  :5001     │            │  :5003     │
                  └────────────┘            └────────────┘

                  Requête 3 ──► revient sur Flask 1 (:5001)
```

**Algorithmes disponibles** :
`ROUND_ROBIN` (défaut), `LEAST_REQUEST`, `RANDOM`, `RING_HASH`, `MAGLEV`.

---

## 4. Traffic Splitting (canary 90/10)

```
                   100 requêtes entrantes
                           │
                           ▼
                  ┌─────────────────┐
                  │  Envoy :8080    │
                  │ weighted_clusters│
                  └────┬────────┬───┘
                90 %   │        │  10 %
                       ▼        ▼
              ┌────────────┐  ┌────────────┐
              │ app1       │  │ app1_bis   │
              │ v1 stable  │  │ v2 canary  │
              │ :5001      │  │ :5003      │
              └────────────┘  └────────────┘

              → 90 réponses  → 10 réponses
              → Rollback instantané en cas d'incident
```

**Cas d'usage** : déploiement progressif, A/B testing, migration de version.

---

## 5. Architecture production (standalone)

```
                         Internet
                            │
                            ▼
                  ┌────────────────────┐
                  │   Firewall / WAF   │
                  │   (facultatif)     │
                  └─────────┬──────────┘
                            │
                            ▼
              ┌─────────────────────────────┐
              │   LB externe (optionnel)    │
              │   HAProxy / LVS / Cloud LB  │
              └──────────┬──────────────────┘
                         │
              ┌──────────┴──────────┐
              ▼                     ▼
     ┌─────────────────┐   ┌─────────────────┐
     │  Envoy VM 1     │   │  Envoy VM 2     │
     │  :443 (TLS)     │   │  :443 (TLS)     │
     │  :9901 (admin)  │   │  :9901 (admin)  │
     └────────┬────────┘   └────────┬────────┘
              │                     │
              └──────────┬──────────┘
                         ▼
              ┌─────────────────────┐
              │  Backends (Flask)   │
              │  Gunicorn + systemd │
              │  :5001 / :5002      │
              └─────────────────────┘

     ┌──────────────────────────────────────┐
     │  Observabilité                       │
     │  ┌──────────┐  ┌─────────┐  ┌──────┐ │
     │  │Prometheus│─►│ Grafana │  │Loki  │ │
     │  └──────────┘  └─────────┘  └──────┘ │
     └──────────────────────────────────────┘
```

**Caractéristiques** :

- **Au moins 2 instances Envoy** (HA).
- TLS terminé par Envoy (certbot ou CA interne).
- Backends **Gunicorn** (jamais Flask dev).
- Observabilité **découplée** (Prometheus scrape l'admin).
- Config versionnée dans **Git**, déployée par Ansible/CI.

---

## 6. Cycle de vie d'un rechargement

```
   Modif config            Validation            Rechargement
   (Git commit)            (dry-run)             (hot restart)
       │                       │                      │
       ▼                       ▼                      ▼
   ┌────────┐          ┌──────────────┐       ┌──────────────┐
   │ .yaml  │ ───────► │ envoy --mode │ ────► │ kill -USR1   │
   │ édité  │          │ validate     │       │ (hot restart)│
   └────────┘          └──────┬───────┘       └──────┬───────┘
                              │                      │
                         ┌────┴────┐            ┌────┴────┐
                         │  OK ?   │            │ Nouveau │
                         └────┬────┘            │ process │
                              │                 │ prend   │
                         ┌────┴────┐            │ le trafic│
                         │ Abort   │            └────┬────┘
                         │ si KO   │                 │
                         └─────────┘            ┌────┴────┐
                                                │ Ancien  │
                                                │ termine │
                                                └─────────┘

   ⏱️  Durée totale : quelques secondes, ZÉRO coupure
```

---

## 7. Comparaison Envoy standalone vs Istio

```
        ENVOY STANDALONE                    ISTIO SUR K8S
        ─────────────────                   ─────────────────

        ┌─────────────┐                    ┌─────────────────┐
        │   Vous      │                    │  Control Plane  │
        │  (humain)   │                    │    (Istiod)     │
        │  écrit la   │                    │  génère la      │
        │  config     │                    │  config         │
        └──────┬──────┘                    └────────┬────────┘
               │                                    │ xDS
               ▼                                    ▼
        ┌─────────────┐                    ┌─────────────────┐
        │   Envoy     │                    │  Envoy sidecar  │
        │  (manuel)   │                    │  (auto-injecté) │
        └─────────────┘                    └─────────────────┘

        ✅ Simple                          ✅ Scalable
        ✅ Contrôle total                  ✅ mTLS auto
        ✅ Pas de K8s                      ✅ Découverte auto
        ❌ Gestion manuelle                ❌ Complexe
        ❌ Pas de mTLS auto                ❌ Nécessite K8s
```

---

## 8. Arbre de décision

```
                    Besoin d'un proxy L7 ?
                            │
                            ▼
              ┌──────────────────────────┐
              │  Combien de services ?   │
              └────────────┬─────────────┘
                           │
              ┌────────────┴────────────┐
              │                         │
          1 à 10                     > 10
              │                         │
              ▼                         ▼
    ┌──────────────────┐      ┌──────────────────┐
    │ Config stable ?  │      │ Changements      │
    │                  │      │ fréquents ?      │
    └────────┬─────────┘      └────────┬─────────┘
             │                         │
        Oui  │  Non               Oui  │  Non
             ▼    ▼                    ▼    ▼
       ┌────────┐ ┌──────────┐   ┌────────┐ ┌──────────┐
       │ Envoy  │ │ Envoy +  │   │ Istio  │ │  Consul  │
       │ stand- │ │ Git +    │   │ sur K8s│ │ Connect  │
       │ alone  │ │ CI/CD    │   │        │ │          │
       └────────┘ └──────────┘   └────────┘ └──────────┘
```

---

## Légende des symboles

```
  ──────►   Flux de requête
  ┌───┐     Composant
  ✅ ❌     Avantages / Inconvénients
  │         Frontière réseau
  ⏱️        Durée / timing
```