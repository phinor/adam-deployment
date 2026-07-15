# Specification: Central On-Demand TLS Authorisation Endpoint (`ask`)

**Status:** Draft specification
**Owner:** Central management server (hosted there — **not** in ADAM, **not** on
the school servers)
**Consumed by:** Caddy / FrankenPHP on each ADAM school server, via its
`on_demand_tls { ask <url> }` directive.
**Companion:** `docs/frankenphp-migration-runbook.md` §12 (dynamic multi-tenant
hosting) describes the school-server side that calls this endpoint.

---

## 1. Purpose

When ADAM school servers run FrankenPHP/Caddy with **On-Demand TLS**, a single
catch-all site obtains each tenant domain's certificate **lazily, on the first
HTTPS request**. Before Caddy asks a CA (Let's Encrypt) to issue a certificate
for a hostname it has never seen, it makes an HTTP call to this **authorisation
endpoint**. The endpoint returns success **only** for hostnames that are real,
active ADAM tenants.

This is the mandatory abuse-control for on-demand TLS: without it, anyone who
points DNS at a school server could force certificate-issuance attempts for
arbitrary names and exhaust the ACME rate limit (and fill disk/logs).

It is hosted **centrally** because the management server already holds the
authoritative tenant registry and runs onboarding/offboarding — so it is the
natural single source of truth, and it keeps this concern out of both the ADAM
application and the individual school servers.

---

## 2. How Caddy calls it

Each school server's Caddyfile (see runbook §12.1):

```caddyfile
{
    on_demand_tls {
        ask https://mgmt.adam.co.za/v1/tls-authorize?token={$TLS_ASK_TOKEN}
    }
}

https:// {
    tls { on_demand }
    root * /var/www/adam/live/public
    php_server
}
```

Behaviour of the `ask` call:

- **Method:** `GET`.
- **URL:** exactly the configured `ask` URL, with the queried hostname appended
  as a `domain` query parameter. Because the configured URL already carries
  `?token=…`, Caddy appends `&domain=<hostname>`. The endpoint therefore receives:

  ```
  GET /v1/tls-authorize?token=<shared-secret>&domain=<sni-hostname>
  ```

  > Implementer action: confirm on the target Caddy/FrankenPHP version that the
  > `domain` parameter is appended with `&` when the ask URL already has a query
  > string (it is, in current Caddy v2, but pin it in a test).
- **When:** only when Caddy has **no cached certificate** for the hostname (i.e.
  first issuance) and during renewal maintenance for on-demand certs — **not** on
  every request. Once issued, the cert is cached and served directly.
- **No custom headers / body.** Caddy does not send an auth header or body with
  the ask request. This constrains how the endpoint authenticates its caller —
  see §5.
- **Response interpretation:** HTTP **`2xx` → authorise** issuance; **any other
  status (or timeout / connection error) → deny.** The response **body is
  ignored**. Keep responses fast (see §6).

---

## 3. Request → response contract

| | |
|---|---|
| **Path** | `/v1/tls-authorize` (versioned; choose your own, keep it stable) |
| **Method** | `GET` |
| **Query** | `token` (shared secret, §5.2), `domain` (hostname, appended by Caddy) |
| **`200 OK`** | `domain` is a registered, active tenant → Caddy may issue |
| **`403 Forbidden`** | valid request, but not an authorised tenant (or bad token) → deny |
| **`400 Bad Request`** | `domain` missing/malformed → deny |
| **`429` / `5xx`** | transient error → Caddy treats as deny; it will retry later |
| **Latency budget** | respond well under Caddy's ask timeout; target p99 < 1 s |

Caddy only distinguishes **2xx vs non-2xx**; the specific 4xx codes are for your
own logs/observability.

---

## 4. Authorisation logic

Return `200` **iff**, after normalisation, `domain` is a **currently provisioned,
active** ADAM tenant hostname.

1. **Extract & normalise `domain`:**
   - lowercase; strip a trailing dot; strip any port.
   - reject if empty, > 253 chars, not a syntactically valid DNS hostname, an IP
     literal, or a wildcard (`*`).
2. **Look up** the normalised hostname in the tenant registry (§7). Match both:
   - ADAM subdomains (`<school>.adam.co.za`), and
   - registered custom / vanity domains (`portal.<school>.co.za`).
3. **Decide:** active tenant → `200`; known-but-suspended or unknown → `403`;
   malformed input → `400`.
4. The endpoint is **read-only** and returns only a status — **never echo the
   input** or leak registry detail in the body.

---

## 5. Security

The endpoint is now **network-exposed** (reachable from every school server), so
it cannot rely on "localhost only". Apply defence in depth:

### 5.1 Transport
- Serve over **HTTPS** with a **static** certificate for the management domain.
- It **must not** use on-demand TLS for itself (that would create a
  bootstrapping/recursion deadlock). Provision its cert conventionally.

### 5.2 Caller authentication — shared token in the URL
- Because Caddy cannot attach auth headers to the ask request, carry a
  **fleet-wide shared secret** as the `token` query parameter (baked into each
  school server's `ask` URL via the `TLS_ASK_TOKEN` unit environment variable).
- Compare in **constant time**; reject mismatches with `403` before any registry
  lookup.
- Treat it as a **bearer secret** (it appears in URLs and may land in logs):
  keep request logging from recording the token, and **rotate** it by
  redeploying the school Caddyfiles. This is a first filter, not the primary
  control.

### 5.3 Caller authentication — network controls (primary)
- **Source-IP allowlist:** restrict access to the school servers' egress IPs
  (cloud firewall / security group, or a Caddy `remote_ip` matcher on the
  management side). This is the strongest practical control.
- **(Optional) mTLS:** issue each school server a client certificate and require
  it. Strongest, but verify your Caddy version actually presents a client cert on
  the ask request before relying on it.
- Prefer running the endpoint on a **private management network / VPN** where
  feasible, so it is not exposed to the public internet at all.

### 5.4 Input & abuse handling
- Strictly validate/normalise `domain` (§4.1) before any registry/DB access;
  never build a query by string-concatenating the raw input.
- **Rate-limit** per source IP and **log every decision** (timestamp, caller IP,
  domain, allow/deny, reason) for audit and to detect probing. Denying unknown
  domains is what actually prevents ACME abuse — the registry is the gate.

---

## 6. Availability & failure modes

This endpoint sits in the **TLS issuance path** for first-seen domains, so its
availability matters:

- **Endpoint down / slow / unreachable:** Caddy **fails closed** — it will not
  issue certs for *new* domains until the endpoint recovers. **Already-issued,
  cached certificates keep serving normally.** So an outage blocks *new
  onboarding*, not existing sites.
- **Renewals:** Caddy renews on-demand certs ahead of expiry with retries and may
  re-consult `ask` during maintenance. A brief outage is tolerated; a prolonged
  outage spanning a renewal window risks a lapse. → Run the endpoint **highly
  available** (redundant, health-checked instances) and **monitor/alert** on it.
- **Keep it fast & self-contained:** cache registry lookups in memory with a
  short TTL so a registry/DB hiccup does not cascade into TLS failures. The
  endpoint should be **stateless** (state lives in the registry) and horizontally
  scalable.

---

## 7. Source of truth: the tenant registry

The endpoint answers from an **authoritative central registry** of live tenant
hostnames. Recommended shape:

- A store/table on the management server: `hostname`, `school_id`, `target
  server`, `status` (`active` / `suspended`), `created_at`, `updated_at`.
- **Onboarding integration (critical):** the flow that today runs
  `new_school.sh` must **register the tenant's hostname(s) centrally *before* the
  first request**, or the first HTTPS hit will be denied and no cert issues.
  Support multiple hostnames per school (ADAM subdomain + any vanity domains).
- **Offboarding:** removing/suspending a tenant deregisters its hostnames; Caddy
  then stops renewing and the cert lapses naturally.
- **Avoid** deriving the list by scanning each school server's `config.*.ini`
  over the network — it couples the endpoint to server internals and risks
  staleness. Prefer the explicit registry updated at provisioning time. (If a
  registry does not yet exist, the provisioning tooling is the place to create
  one.)

---

## 8. Reference behaviour (pseudocode, stack-agnostic)

```
GET /v1/tls-authorize?token=<t>&domain=<d>

if !constant_time_equals(t, EXPECTED_TOKEN):        return 403
d = normalise(d)                                    # lower, strip dot/port
if !is_valid_hostname(d):                           return 400
if registry.is_active_tenant(d):                    return 200
return 403
```

Any HTTP stack works (a few lines in Go/PHP/Node/Python behind the management
server's existing TLS). It has no dependency on ADAM code.

---

## 9. Acceptance tests

- **Known active domain**, valid token, from an allowlisted IP → `200`.
- **Unknown domain** → `403`; **suspended tenant** → `403`.
- **Malformed `domain`** (empty, IP, wildcard, junk) → `400`.
- **Missing/wrong token** → `403`.
- **Non-allowlisted source IP** → blocked at the network layer.
- **End-to-end:** register a new hostname centrally → point its DNS at a school
  server → hit it over HTTPS → confirm Caddy obtains and serves a cert; then
  suspend it centrally → confirm no renewal on expiry.
- **Chaos:** take the endpoint offline → confirm existing tenant sites keep
  serving from cached certs, and only *new-domain* issuance is blocked.

---

## 10. Open items for the implementer

- Confirm the management server's stack and where the **tenant registry** lives
  (or create it as part of provisioning).
- Wire **onboarding/offboarding** to register/deregister hostnames (hook into the
  `new_school.sh` flow or the central onboarding tool).
- Pin, on the target Caddy/FrankenPHP version: (a) that `domain` is appended with
  `&` to a query-bearing ask URL, and (b) whether renewals re-invoke `ask`.
- Decide the caller-auth mix (token + IP allowlist at minimum; mTLS / private
  network if available) and the token-rotation procedure.
</content>
