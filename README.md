# Trifolia-on-FHIR

## Requirements

* [Node.js](https://nodejs.org/) 26 (the version used by the Docker image). Node 20 also works.
* [MongoDB](https://www.mongodb.com/) - all projects, resources, users and history are stored in MongoDB
* An OpenID Connect provider (for example Keycloak or Auth0) - every API request requires a signed access token. See "Authentication" below.
* [Java](https://www.java.com/en/download/) - to run the IG Publisher
* [Jekyll](https://jekyllrb.com/docs/installation/) - to run the IG Publisher without errors
    * Jekyll must be available to the user that is running the Node.js server. Consider adding the Ruby installation directory to the global PATH.

The project is an [Nx](https://nx.dev/) workspace. There is no need to install the Angular CLI globally; use `npx nx` (or the `npm run` scripts below).

## Building/Running

```bash
npm install                 # install node modules
npx nx build client         # build the client application (output to dist/apps/client)
npx nx build server         # build the server application (output to dist/apps/server)
npx nx build tools          # build the command-line tools (output to dist/apps/tools)
cd dist/apps/server         # working directory should be the output of the server
node main.js                # run the server application, which also hosts the client application
```

Alternatively, `npm run build:all` builds the client, server, and tools concurrently, and `npm run build-prod:all` does the same with the production configuration.

The server listens on port 49366 by default. The REST API is under `/api` and the Swagger UI is at `/api-docs`.

### Docker

`docker-compose up` builds and runs ToF along with a MongoDB container. Authentication settings are passed through the `AUTH_*` and `SERVER_ENABLESECURITY` environment variables (see "Configuration" below).

### Developers

```bash
npm run build-watch:main    # watch-build the server and client concurrently
npm start                   # build and run the server (nx serve server)
npx nx serve client         # optional: Angular dev server, proxies /api and /socket.io to localhost:49366
```

Run unit tests (Jest) per project:

```bash
npx nx test server
npx nx test client
npx nx test tof-lib
npx nx test server --testFile=apps/server/src/app/fsh.controller.spec.ts   # a single spec file
```

A local MongoDB can be started with `docker-compose up mongodb`.

Changes during development should be applied to the `development` branch. Once they are QA'd and approved, they are merged into the `master` branch and a release is made based on the master branch.

## Configuration

The configuration files are in the `dist/apps/server/config` directory (copied from `apps/server/src/config` during the build). You may create a `local.json` file that overrides `default.json` properties. Alternatively, you may create an environment-specific config file and use the `NODE_ENV` environment variable to indicate the name of the environment.

Example:
```
dist/apps/server/config/production.json
NODE_ENV=production
```

Some settings can also be provided as environment variables. The mapping is defined in `config/custom-environment-variables.json`:

| Environment variable | Config property |
| -------------------- | --------------- |
| `DATABASE_URI` | `database.uri` |
| `DATABASE_MIGRATEATSTART` | `database.migrateAtStart` |
| `SERVER_ENABLESECURITY` | `server.enableSecurity` |
| `AUTH_CLIENTID`, `AUTH_SCOPE`, `AUTH_LOGOUTURL`, `AUTH_DOMAIN`, `AUTH_SECRET`, `AUTH_ISSUER`, `AUTH_JWKSURI` | `auth.*` |

## Database

ToF stores its data in MongoDB, configured by `database.uri` (for example `mongodb://user:pwd@localhost:27017/tof?authSource=admin`). An external FHIR server is no longer required.

Schema changes are managed with [migrate-mongo](https://github.com/seppevs/migrate-mongo). Migrations are in `apps/server/src/db-migrations/migrations`.

* If `database.migrateAtStart` is `true`, pending migrations are applied automatically when the server starts.
* If it is `false` and migrations are pending, the server logs an error and exits. Apply them manually:

```bash
npm run migrate:status      # list applied and pending migrations
npm run migrate:up          # apply pending migrations
npm run migrate:down        # revert the last migration
npm run migrate:create -- <name>   # create a new migration
```

The `migrate:*` scripts read `database.uri` from the source configuration directory, `apps/server/src/config` (not `dist`). Put a `local.json` there, or set `DATABASE_URI`, to point them at your database.

## Using NGINX as a reverse proxy for ToF

There are some rules in NGINX that are specific for WebSoocket to work properly. Specifically (proxy_http_version 1.1 & proxy_set_header Connection "Upgrade"). These are used to ensure that websocket will communicate through the proxy seemlessly to the upstream server.

Comments are in the configuration below to help illustrate the intent of each directive.

```
server {
        listen 80;
        server_name tof.example.com;

        location / {
                # Always return HTTPS
                return 301 https://$host$request_uri;
        }
}

server {
        listen          443 ssl;
        server_name     tof.example.com;
        error_log       /var/log/nginx/trifolia-fhir-error.log warn;
		
        location / {
                proxy_pass          http://someserver.local:49366;

                proxy_http_version  1.1;                                          # Because the WebSocket protocol uses the Upgrade header
                proxy_set_header    Host              $host;                      # Pass the proxied address to the upstream server
                proxy_set_header    X-Real-Ip         $remote_addr;               # Pass the origianl IP of the client
                proxy_set_header    X-Forwarded-For   $proxy_add_x_forwarded_for; 
                proxy_set_header    X-Forwarded-Proto $scheme;                    # Pass original protocol
                proxy_set_header    Upgrade           $http_upgrade;              # Upgrade connection if needed (needed by Websocket)
                proxy_set_header    Connection        "Upgrade";                  # Needed for WebSocket as an upgrade to HTTP protocol

                proxy_read_timeout  600s;                                         # Timeout for larger files

                proxy_buffers       16 4k;                                        # Buffers for larger files
                proxy_buffer_size   16k;

                client_max_body_size 200M;                                        # Request Entity Too Large
        }
}
```

## Authentication

ToF has no built-in login. The client signs users in with an OpenID Connect provider (implicit flow), and the server validates the bearer token on every API request against the provider's JWKS endpoint. `server.enableSecurity` does not turn authentication off; it only controls per-resource permission checks.

The `auth` configuration properties are:

| Property | Description |
| -------- | ----------- |
| `auth.issuer` | The provider's issuer URL. The client loads `<issuer>/.well-known/openid-configuration` from it. |
| `auth.clientId` | The client ID registered with the provider. |
| `auth.scope` | Scopes requested at login, e.g. `openid profile email`. |
| `auth.jwksUri` | The JWKS endpoint the server uses to verify token signatures. |
| `auth.logoutUrl` | The provider's logout endpoint. |
| `auth.domain` | Only used to build the OAuth2 login links in the Swagger UI (`https://<domain>/authorize`). |

A user is an administrator when the access token has a top-level `roles` claim that contains `admin`.

See the Wiki's [Authentication](https://github.com/lantanagroup/trifolia-on-fhir/wiki/Authentication) page for more information.

### Local development with Keycloak

[Keycloak](https://www.keycloak.org/) can run in Docker as a local provider.

1. Start Keycloak in development mode:

    ```bash
    docker run -d --name tof-keycloak -p 8080:8080 \
      -e KC_BOOTSTRAP_ADMIN_USERNAME=admin -e KC_BOOTSTRAP_ADMIN_PASSWORD=admin \
      quay.io/keycloak/keycloak:26.0.7 start-dev
    ```

    Development mode stores its data inside the container. Stopping and starting the container keeps the configuration; removing it (`docker rm`) does not.

2. Once http://localhost:8080 responds, create a realm, client, admin role, and user with the admin CLI that ships in the container:

    ```bash
    kc() { docker exec tof-keycloak /opt/keycloak/bin/kcadm.sh "$@"; }

    kc config credentials --server http://localhost:8080 --realm master --user admin --password admin
    kc create realms -s realm=tof -s enabled=true -s sslRequired=none

    # Public client using the implicit flow. Direct access grants allow fetching tokens with curl for API testing.
    kc create clients -r tof -s clientId=tof -s publicClient=true -s implicitFlowEnabled=true \
      -s standardFlowEnabled=true -s directAccessGrantsEnabled=true \
      -s 'redirectUris=["http://localhost:49366/*","http://localhost:4200/*"]' \
      -s 'webOrigins=["http://localhost:49366","http://localhost:4200"]' \
      -s 'attributes={"post.logout.redirect.uris":"http://localhost:49366/*##http://localhost:4200/*"}'

    # Put realm roles in a top-level "roles" claim, which is where ToF looks for "admin"
    CID=$(kc get clients -r tof -q clientId=tof --fields id --format csv --noquotes)
    kc create clients/$CID/protocol-mappers/models -r tof -s name=roles -s protocol=openid-connect \
      -s protocolMapper=oidc-usermodel-realm-role-mapper \
      -s 'config={"claim.name":"roles","multivalued":"true","jsonType.label":"String","access.token.claim":"true","id.token.claim":"true","userinfo.token.claim":"true"}'

    # Admin role and a test user
    kc create roles -r tof -s name=admin
    kc create users -r tof -s username=tofadmin -s email=tofadmin@example.com -s emailVerified=true \
      -s firstName=ToF -s lastName=Admin -s enabled=true
    kc set-password -r tof --username tofadmin --new-password tofadmin
    kc add-roles -r tof --uusername tofadmin --rolename admin
    ```

    The same settings can be made in the admin console at http://localhost:8080 (login `admin` / `admin`).

3. Create `apps/server/src/config/local.json` (it is ignored by git). The build copies it to `dist/apps/server/config`:

    ```json
    {
      "database": {
        "uri": "mongodb://localhost:27017/tof"
      },
      "auth": {
        "clientId": "tof",
        "scope": "openid profile email",
        "issuer": "http://localhost:8080/realms/tof",
        "jwksUri": "http://localhost:8080/realms/tof/protocol/openid-connect/certs",
        "logoutUrl": "http://localhost:8080/realms/tof/protocol/openid-connect/logout"
      }
    }
    ```

    Adjust `database.uri` for your MongoDB instance.

4. Build and start the server (see "Building/Running"), open http://localhost:49366, and log in as `tofadmin` / `tofadmin`.

To call the API directly, get a token with the password grant:

```bash
TOKEN=$(curl -s -d grant_type=password -d client_id=tof -d username=tofadmin -d password=tofadmin \
  -d scope=openid http://localhost:8080/realms/tof/protocol/openid-connect/token \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')
curl -H "Authorization: Bearer $TOKEN" http://localhost:49366/api/projects
```

The Swagger UI's OAuth2 login does not work with this setup, because it builds an `https://` URL from `auth.domain`.

## Features/functionality
* FHIR Versions (selected per project)
    * STU3
    * R4
    * R5 (under development and not yet fully tested)
* Projects that group an implementation guide with its resources, pages, and examples
* OAuth2 Authentication
* User and group based permissions
* Resource history and auditing
* Export
    * FHIR Bundle (JSON or XML)
    * HTML, by executing the FHIR IG Publisher (with options)
    * MS Word
* Import (from files, resource text, or VSAC)
* FHIR Shorthand (FSH) conversion using SUSHI and GoFSH
* Type-aheads for value set and code system selection
* Selection based directly on value sets from FHIR specification

### Resource UI Support

| Resource | Create | Edit | Save | Validate | Versions | Additional | Not supported | Notes |
| -------- | ------ | ---- | ---- | -------- | ------ | ------ | ----- | ------ |
| ImplementationGuide | X | X | X | X | DSTU3, R4 | | | |
| StructureDefinition | X | X | X | X | DSTU3, R4 | | | Element definitions support both DSTU3 and R4. Other properties in StructureDefinition may be different for R4. |
| ValueSet | X | X | X | X | DSTU3, R4 | $expand | .compose.include.concept.designation | |
| CodeSystem | X | X | X | X | DSTU3, R4 | | | |
| CapabilityStatement | X | X | X | X | DSTU3, R4 | | | |
| OperationDefinition | X | X | X | X | DSTU3, R4 | | | |
| Questionnaire | X | X | X | X | DSTU3, R4 | | | |

## Additional

See the [WIKI](https://github.com/lantanagroup/trifolia-on-fhir/wiki) and [Help Documentation](https://trifolia-fhir-dev.lantanagroup.com/help) for more information.
