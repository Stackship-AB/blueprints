# Stackship Blueprints

The public blueprint catalog. A Stackship platform pulls this repository and
seeds every blueprint under [`blueprints/`](./blueprints) into its catalog,
where operators deploy them as container instances.

## Layout

```
blueprints/
  <slug>/
    template.yaml   # required — the blueprint document
    icon.svg        # optional — icon.svg | icon.png | icon.jpg | icon.webp
```

**The directory name is the slug.** It is what a deploy resolves, so it wins
over `metadata.slug` if the two disagree.

Only `blueprints/` is walked. Everything else in this repository — this README,
tooling, CI — is ignored by the seeder.

## Pointing a cluster at your own catalog

Fork this repository (or build one with the same layout, public over HTTPS) and
set the blueprint catalog repository during install:

```
Blueprints__Catalog__RepositoryUrl = https://github.com/<you>/blueprints.git
Blueprints__Catalog__Ref           = main        # branch, tag or commit
```

Pin `Ref` to a tag for a catalog that does not move underneath you.

## Authoring

A blueprint is one document — metadata, parameters, outputs, and a
parameterized container-instance spec:

```yaml
apiVersion: blueprints.stackship.se/v2
kind: BlueprintTemplate
metadata:
  slug: pocketbase
  title: PocketBase
  version: "0.31.0"
parameters: [...]
outputs: [...]
instance:
  components: [...]
  endpoints: [...]
```

Rules the platform enforces when it reads a template:

- **The parser binds strictly.** An unknown key is a hard failure, never a
  silently dropped field — the difference between a typo and an incident.
- **Icons are inlined, never linked.** A sibling `icon.*` is read off disk and
  stored as a data URI; `metadata.icon` must itself be a `data:` URI. A remote
  URL would be fetched by every browser that opens the catalog, handing a host
  the template author chose a log of who browsed what. Types: `svg+xml`, `png`,
  `webp`, `jpeg`. Limit: 128 KiB decoded.
- **Two substitution syntaxes, and the difference is timing.** `{{...}}` is
  resolved once when the platform reads the template — only
  `{{domain_suffix}}` and `{{cert_issuer}}`, and only in parameter defaults,
  output values, and endpoint `hostname`/`issuer`. `[%...%]` is resolved per
  deploy. Anything that varies by instance must be `[%...%]`; there is no
  instance yet when the `{{...}}` macros run.
- **A template can only describe a container instance.** There is no raw
  Kubernetes YAML anywhere in the pipeline, which is what makes third-party
  templates safe to run.
