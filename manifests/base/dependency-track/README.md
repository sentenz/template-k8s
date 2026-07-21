# Dependency Track

- [1. Usage](#1-usage)
  - [1.1. DNS](#11-dns)
    - [1.1.1. Host-Based](#111-host-based)
    - [1.1.2. Path-Based](#112-path-based)
  - [1.2. Troubleshoot](#12-troubleshoot)
    - [1.2.1. Kubernetes Resources](#121-kubernetes-resources)
    - [1.2.2. Host Services](#122-host-services)
    - [1.2.3. Host Network](#123-host-network)

## 1. Usage

### 1.1. DNS

#### 1.1.1. Host-Based

Host-Based DNS Resolution ([Ingress Name-Based](https://kubernetes.io/docs/concepts/services-networking/ingress/#name-based-virtual-hosting)) is determined by the separate subdomains provided in the request to route traffic to the Frontend and API.

> [!NOTE]
> The DNS query resolves a fully qualified domain name (FQDN) to an IP address.

1. Conceptual Diagram

    ```mermaid
    flowchart LR
      Client[[Client]] -.-> |TLS/HTTPS| lb -.-> IngressCtrl[Ingress Controller]

      subgraph cloud [Cloud Provider]
          lb[External Load Balancer<br>Ingress Managed]
      end


      subgraph Routing
        IngressCtrl -->|host dependency-track.com| SvcWeb[Service Frontend]
        IngressCtrl -->|host api.dependency-track.com| SvcAPI[Service API]
      end

      SvcWeb --> PodsWeb[Pods]
      SvcAPI --> PodsAPI[Pods]
    ```

2. Example and Explanation

    - `values.yaml`
      > The base chart values define the API base URL for the frontend to communicate with the API server.

      ```yaml
      apiBaseUrl: "https://api.dependency-track.localhost"
      ```

    - `patch-dependency-track-ingress.yaml`
      > The ingress configuration for subdomains using `traefik` defined in `overlays`, modifies the base ingress to route traffic to the appropriate services based on the subdomain.
      >
      > - FQDN
      >   - Frontend on `dependency-track.localhost`
      >   - API on `api.dependency-track.localhost`

      > [!NOTE]
      > [Secure an Ingress](https://kubernetes.io/docs/concepts/services-networking/ingress/#tls) by specifying a Secret that contains a TLS private key and certificate.

      ```yaml
      apiVersion: networking.k8s.io/v1
      kind: Ingress
      metadata:
        name: dependency-track
        namespace: dependency-track
        annotations:
          traefik.ingress.kubernetes.io/router.entrypoints: web,websecure
      spec:
        ingressClassName: traefik
        rules:
          - host: "dependency-track.localhost"
            http:
              paths:
                - path: /
                  pathType: Prefix
                  backend:
                    service:
                      name: dependency-track-frontend
                      port:
                        name: web
          - host: "api.dependency-track.localhost"
            http:
              paths:
                - path: /
                  pathType: Prefix
                  backend:
                    service:
                      name: dependency-track-api-server
                      port:
                        name: web
                - path: /api
                  pathType: Prefix
                  backend:
                    service:
                      name: dependency-track-api-server
                      port:
                        name: web
                - path: /health
                  pathType: Prefix
                  backend:
                    service:
                      name: dependency-track-api-server
                      port:
                        name: web
        tls:
          - hosts:
              - "dependency-track.localhost"
              - "api.dependency-track.localhost"
            secretName: dependency-track-tls
      ```

#### 1.1.2. Path-Based

Path-Based DNS Routing ([Ingress Fan-Out](https://kubernetes.io/docs/concepts/services-networking/ingress/#simple-fanout)) directs traffic for the Frontend and API through distinct URL paths under a single hostname.

> [!NOTE]
> The DNS system only resolves domains to an IP addresses. Path-based routing URL paths interpretion is performed by an application gateway, reverse proxy, or load balancer after DNS resolution.

1. Conceptual Diagram

    ```mermaid
    flowchart LR
      Client[[Client]] -.-> |TLS/HTTPS| lb -.-> IngressCtrl[Ingress Controller]

      subgraph cloud [Cloud Provider]
          lb[External Load Balancer<br>Ingress Managed]
      end


      subgraph Routing
        IngressCtrl -->|host dependency-track.com<br>path /| SvcWeb[Service Frontend]
        IngressCtrl -->|host dependency-track.com<br>path /api| SvcAPI[Service API]
      end

      SvcWeb --> PodsWeb[Pods]
      SvcAPI --> PodsAPI[Pods]
    ```

2. Example and Explanation

    - `values.yaml`
      > The base chart values define the API base URL for the frontend to communicate with the API server.

      ```yaml
      apiBaseUrl: "https://dependency-track.localhost"
      ```

    - `patch-dependency-track-ingress.yaml`
      > The ingress configuration for the single hostname using `traefik` defined in `overlays`, modifies the base ingress to route traffic to the appropriate services based on the path.
      >
      > - FQDN
      >   - `dependency-track.localhost`
      > - URL Path
      >   - Frontend on `/`
      >   - API on `/api` and `/health`

      > [!NOTE]
      > [Secure an Ingress](https://kubernetes.io/docs/concepts/services-networking/ingress/#tls) by specifying a Secret that contains a TLS private key and certificate.

      ```yaml
      apiVersion: networking.k8s.io/v1
      kind: Ingress
      metadata:
        name: dependency-track
        namespace: dependency-track
        annotations:
          traefik.ingress.kubernetes.io/router.entrypoints: web,websecure
      spec:
        ingressClassName: traefik
        rules:
          - host: "dependency-track.localhost"
            http:
              paths:
                - path: /api
                  pathType: Prefix
                  backend:
                    service:
                      name: dependency-track-api-server
                      port:
                        name: web
                - path: /health
                  pathType: Prefix
                  backend:
                    service:
                      name: dependency-track-api-server
                      port:
                        name: web
                - path: /
                  pathType: Prefix
                  backend:
                    service:
                      name: dependency-track-frontend
                      port:
                        name: web
        tls:
          - hosts:
              - "dependency-track.localhost"
            secretName: dependency-track-tls
      ```

### 1.2. Troubleshoot

#### 1.2.1. Kubernetes Resources

Ensure the resources are created and running correctly.

```bash
kubectl --kubeconfig=config/kubeconfig.yaml -n dependency-track get secret dependency-track-tls
kubectl --kubeconfig=config/kubeconfig.yaml -n dependency-track get ingress
kubectl --kubeconfig=config/kubeconfig.yaml -n dependency-track get pods
```

#### 1.2.2. Host Services

Verify the services are accessible via HTTP. The `-k` flag skips TLS verification for self-signed certificates.

- Path-Based

  ```bash
  curl -I -k -v --max-time 15 https://dependency-track.localhost/
  curl -I -k -v --max-time 15 https://dependency-track.localhost/api
  curl -I -k -v --max-time 15 https://dependency-track.localhost/health
  ```

- Host-Based

  ```bash
  curl -I -k -v --max-time 15 https://dependency-track.localhost/
  curl -I -k -v --max-time 15 https://api.dependency-track.localhost/
  ```

#### 1.2.3. Host Network

The `hostNetwork: true` setting is used to allow Traefik to bind to ports 80 and 443 on the host network. This is safe for the local Kind development cluster that runs on the same machine as the browser client.

> [!IMPORTANT]
> Do not enable `hostNetwork` for remote clusters, it exposes Traefik on node network interfaces and can conflict with host services or create unwanted exposure.

- `/etc/hosts`
  > Modify for local name resolution, testing services, or overriding DNS entries.

  ```plaintext
  127.0.0.1       dependency-track.localhost
  192.168.1.10    dependency-track.stage.com
  ```

  > [!TIP]
  > The public wildcard DNS service `local.gd` automatically resolves any hostname ending in `*.local.gd` to `127.0.0.1`. In local development scenarios the domain `local.gd` eliminates the need for manual editing of the `/etc/hosts` file.
