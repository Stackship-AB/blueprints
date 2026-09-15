# Keycloak: a custom theme from your own registry

The Keycloak blueprint can load a theme — login pages, account console, emails —
that you build and host yourself. The theme reaches Keycloak as a small container
image in a private registry you connect to the platform as a **deployment source**.
Nothing is downloaded at startup and no registry credential enters the pod.

This guide builds that image from a theme repository, publishes it, and deploys
Keycloak with it.

## How it works

```
theme repo ──CI──▶ image in your registry ──pulled by the node──▶ init container
                   (/theme/acme-theme.jar)                         copies the jar into
                                                                   /opt/keycloak/providers
```

1. Your repository holds the theme sources and a Dockerfile. CI packs the theme
   into a `.jar` and builds a tiny image with that jar under `/theme/`.
2. The image is pushed to a registry, e.g. `ghcr.io/acme/keycloak-theme`.
3. That registry is connected to the boundary under **Deployment sources**.
4. When you deploy Keycloak with **Custom Theme** switched on, the platform pulls
   the image through that source, and an init container copies every
   `/theme/*.jar` into Keycloak's providers directory before Keycloak starts.
   Keycloak picks the theme up on boot.
5. You choose the theme per realm, in the admin console or in `realm.json`.

## 1. Create the theme repository

```
keycloak-theme/
├── Dockerfile
├── .dockerignore
├── .github/workflows/publish.yml
└── theme-src/
    ├── META-INF/
    │   └── keycloak-themes.json
    └── theme/
        └── acme/
            ├── login/
            │   ├── theme.properties
            │   ├── messages/
            │   │   └── messages_en.properties
            │   └── resources/
            │       ├── css/custom.css
            │       └── img/logo.svg
            └── account/            # optional, same pattern per theme type
```

Everything under `theme-src/` ends up at the root of the jar, and that layout is
what Keycloak requires: a `META-INF/keycloak-themes.json` that lists the themes,
and each theme under `theme/<name>/<type>/`.

### `theme-src/META-INF/keycloak-themes.json`

List every theme in the jar and each type it provides. A type that is listed
here but has no directory, or the other way round, is the most common reason a
theme does not show up.

```json
{
  "themes": [
    {
      "name": "acme",
      "types": ["login"]
    }
  ]
}
```

Add `"account"` or `"email"` to `types` when you add those directories.

### `theme-src/theme/acme/login/theme.properties`

Extend Keycloak's own login theme rather than starting from scratch. A child
theme inherits every template and resource it does not replace, so a stylesheet
and a logo are often all you need.

```properties
parent=keycloak.v2
import=common/keycloak

# `styles` replaces the parent's list, so keep the parent's stylesheet first.
styles=css/styles.css css/custom.css
```

`keycloak.v2` is the PatternFly 5 login theme Keycloak 26 ships. To extend the
classic theme instead, use `parent=keycloak` and
`styles=css/login.css css/custom.css`.

### `theme-src/theme/acme/login/resources/css/custom.css`

```css
/* Brand colour for primary buttons and links. */
:root {
  --pf-v5-global--primary-color--100: #0b5fff;
  --pf-v5-global--link--Color: #0b5fff;
}

/* Replace the realm name heading with a logo. Selectors follow the parent
   theme's templates, so check them against the Keycloak version you deploy. */
#kc-header-wrapper {
  background: url("../img/logo.svg") no-repeat center / contain;
  height: 64px;
  color: transparent;
}
```

### `theme-src/theme/acme/login/messages/messages_en.properties` (optional)

Override any message key from the parent theme:

```properties
loginAccountTitle=Sign in to Acme
```

To replace a whole page, copy that `.ftl` template from Keycloak's
`keycloak.v2/login` theme, for the same Keycloak version you deploy, into
`theme-src/theme/acme/login/` and edit it there. Templates you do not copy keep
following Keycloak's upgrades.

## 2. Package the theme as an image

The image has one job: carry the jar under `/theme/`, with a shell and `cp`
available for the init container that copies it. The build stage packs the jar
with the JDK's `jar` tool, so nobody needs Java installed locally.

### `Dockerfile`

```dockerfile
# Pack theme-src/ into a jar. Only the build stage needs a JDK.
FROM docker.io/library/eclipse-temurin:21-jdk-alpine AS build
COPY theme-src/ /src/
RUN mkdir /out && jar --create --file /out/acme-theme.jar -C /src .

# What the platform pulls: busybox for /bin/sh and cp, plus the jar.
FROM docker.io/library/busybox:1.37
COPY --from=build /out/acme-theme.jar /theme/acme-theme.jar
```

The requirements the Keycloak blueprint puts on this image:

| Requirement | Why |
|---|---|
| One or more `.jar` files directly in `/theme/` | The init container copies `/theme/*.jar`. With no jar there, the pod stops with `Init:Error` instead of starting Keycloak without your theme. |
| `/bin/sh` and `cp` | The init container runs a shell command. A `scratch` or distroless image cannot do this; `busybox` or `alpine` can. |
| Files readable by uid 1000 | The init container runs as Keycloak's user. `COPY` creates files readable by everyone, so this holds unless you change permissions. |
| A lowercase repository name | The **Theme Image** field only accepts a repository reference such as `ghcr.io/acme/keycloak-theme`. |

A jar can contain Java code as well as CSS and templates, and Keycloak loads
everything in its providers directory. Treat this image like application code:
build it from a repository you control, and only deploy images you trust.

### `.dockerignore`

```
.git
.github
```

### Try it locally (optional)

With Docker available, check the theme before publishing:

```bash
docker build -t keycloak-theme:dev .
docker create --name theme keycloak-theme:dev
docker cp theme:/theme/acme-theme.jar ./acme-theme.jar
docker rm theme

docker run --rm -p 8080:8080 \
  -e KC_BOOTSTRAP_ADMIN_USERNAME=admin -e KC_BOOTSTRAP_ADMIN_PASSWORD=admin \
  -v "$PWD/acme-theme.jar:/opt/keycloak/providers/acme-theme.jar:ro" \
  docker.io/keycloak/keycloak:26.7.3 \
  start-dev --spi-theme--cache-themes=false
```

Open `http://localhost:8080/admin`, go to **Realm settings → Themes**, choose
`acme` as the login theme, and sign out to see it. Theme caching is switched off
here so edits show up after a restart. Leave it on in production.

## 3. Publish it

Build on every push to `main` and push the image to your registry. This example
uses GitHub Container Registry.

### `.github/workflows/publish.yml`

```yaml
name: Publish Keycloak theme

on:
  push:
    branches: [main]
    tags: ["v*"]

permissions:
  contents: read
  packages: write

jobs:
  image:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - id: meta
        uses: docker/metadata-action@v5
        with:
          images: ghcr.io/${{ github.repository_owner }}/keycloak-theme
          tags: |
            type=sha
            type=semver,pattern={{version}}
            type=raw,value=latest,enable={{is_default_branch}}

      - id: build
        uses: docker/build-push-action@v6
        with:
          context: .
          push: true
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}

      - name: Digest to deploy
        run: echo "Theme Tag: ${{ steps.build.outputs.digest }}" >> "$GITHUB_STEP_SUMMARY"
```

The run summary shows the image digest (`sha256:…`). That is the value to deploy
when you want the exact bytes this run built.

Any registry and any CI system work the same way: build the Dockerfile and push
the result. On GitLab the image would be `registry.gitlab.com/<group>/keycloak-theme`,
logged in with `CI_REGISTRY_USER` and `CI_REGISTRY_PASSWORD`.

## 4. Connect the registry as a deployment source

Keycloak pulls the image with a credential stored on the platform, so the image
can stay private.

1. Create a **read-only** credential for the registry. For GHCR that is a
   personal access token (classic) with only the `read:packages` scope, ideally
   on a machine account rather than a person's. For other registries use a
   deploy token or robot account with pull access.
2. In the portal, open **Deployment sources** and click **Add Deployment Source**.
3. Choose **Container Registry**. Enter the registry host (`ghcr.io`, a host and
   not a URL), the username, and the token.
4. Save, and use **Verify** to check that the platform can log in.

The source's id is derived from the host, e.g. `ghcr-io`. You pick it by name in
the deploy wizard, so you do not need to remember it.

A public image needs no deployment source. Leave **Theme Registry** at none.

If your platform restricts which registries images can come from, a platform
administrator has to allow your registry host too. Otherwise the deploy is
refused with a message naming the host.

## 5. Deploy Keycloak with the theme

1. Open the **Keycloak** blueprint in the catalog and click **Deploy**.
2. In the configuration step, open **Advanced settings** and fill in:

   | Field | Value |
   |---|---|
   | **Custom Theme** | on |
   | **Theme Registry** | the registry you connected, e.g. `ghcr.io` |
   | **Theme Image** | `ghcr.io/acme/keycloak-theme`, with no tag |
   | **Theme Tag** | a digest such as `sha256:3f1c…`, or a tag such as `1.2.0` |

3. The review step checks, before anything is created, that you may use the
   boundary's deployment sources and that the registry you chose is connected.
   Fix anything it refuses, then deploy.

Prefer a digest in **Theme Tag**. A tag like `latest` can point at new content
without anything changing in Keycloak's configuration, and pods started at
different times could then run different themes.

## 6. Use the theme in a realm

The theme is available to every realm on the instance, and nothing uses it
until you choose it.

- **Admin console:** **Realm settings → Themes**, set **Login theme** to `acme`,
  and save.
- **Realm import:** set it in the `realm.json` you import:

  ```json
  {
    "realm": "customers",
    "loginTheme": "acme",
    "accountTheme": "acme",
    "emailTheme": "acme"
  }
  ```

  Only include the types your jar provides. An import skips a realm that already
  exists, so set the theme in the console for existing realms.

## Updating the theme

1. Merge the change to the theme repository. CI publishes a new image.
2. Edit the Keycloak instance's parameters and set **Theme Tag** to the new
   digest or tag. The Keycloak pod restarts, copies the new jar and loads it.

If you deployed a moving tag such as `latest`, changing the image alone does
nothing until the pod next restarts. Setting a new digest is what makes an update
deliberate and visible in the instance's history.

To remove the theme, first switch every realm that uses it back to a built-in
theme, then turn **Custom Theme** off.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| Review step: "Use the boundary's deployment sources" refused | You lack `kernel/deployments/read` in the boundary. Ask an owner for it. |
| Review step: "Pull through deployment source '…'" refused | No connected container registry has that id. Connect it (step 4) or choose another. |
| Pod stuck in `ImagePullBackOff` on the `theme` init container | The credential cannot pull the image: wrong host, an expired token, or a token without read access to that package. Verify the source, and check the image and tag exist. |
| Pod in `Init:Error` | The image has no `.jar` in `/theme/`, or no `/bin/sh`. Check with `docker run --rm --entrypoint ls <image> /theme`. |
| Theme missing from **Realm settings → Themes** | `META-INF/keycloak-themes.json` is missing from the jar root, or its `name`/`types` do not match the `theme/<name>/<type>/` directories. Check with `jar tf acme-theme.jar` or `unzip -l acme-theme.jar`. |
| Page renders unstyled | `styles` in `theme.properties` dropped the parent's stylesheet. Keep `css/styles.css` (or `css/login.css` for the classic theme) first. |
| Change not visible after an update | The pod still runs the previous image. Deploy a new digest rather than re-pushing the same tag. |
