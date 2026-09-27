# Infrastructure

`infrastructure/` contains cluster capabilities managed independently of application workloads. Organize resources by responsibility, not by environment.

```text
infrastructure/
├── controllers/
│   └── traefik/
├── services/
│   └── postgresql/
└── configs/
```

- `controllers/` contains Kubernetes controllers, operators, admission components, and cluster networking/control-plane integrations.
- `services/` contains infrastructure-managed runtime services whose lifecycle is owned by the infrastructure layer.
- `configs/` contains shared configuration consumed by infrastructure controllers or services, such as issuers, middleware, policy, or controller-specific custom resources.

Each concrete capability owns its `base/` and `overlays/`. Environment selection belongs in `clusters/<environment>/kustomization.yaml`; the infrastructure tree defines what can be deployed, while the cluster tree defines what is deployed.

The ownership rule is: application-specific workloads and dependencies belong under `apps/`; shared or independently managed cluster capabilities belong under `infrastructure/`; concrete target composition belongs under `clusters/`.
