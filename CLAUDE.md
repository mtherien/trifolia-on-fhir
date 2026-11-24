# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Trifolia-on-FHIR (ToF) is a web-based authoring tool for FHIR Implementation Guides (STU3, R4, R5). It's an Nx 18 monorepo with:

- `apps/server`: NestJS 10 API backed by MongoDB (Mongoose). It also serves the built client and published IGs.
- `apps/client`: Angular 17 SPA (ng-bootstrap, angular-oauth2-oidc).
- `apps/tools`: a yargs CLI for maintenance tasks (`generate-typescript`, `migrate-db`, `update-db`).
- `libs/tof-lib`: code shared by all apps, imported through the path aliases in `tsconfig.base.json` (`@trifolia-fhir/tof-lib`, `@trifolia-fhir/models`, `@trifolia-fhir/r4`, `@trifolia-fhir/stu3`, `@trifolia-fhir/r5`). Older code imports it by relative path (`../../../../libs/tof-lib/src/lib/...`).

Work goes on the `development` branch. `master` is the release branch and the Nx `defaultBase`. Commit messages are prefixed with the Jira key (`TOFDEV-###: ...`).

## Commands

The `ng` npm script is an alias for `nx`. Run Nx directly with `npx nx <target> <project>`.

```bash
npm install
npx nx build server            # -> dist/apps/server
npx nx build client            # -> dist/apps/client
npm run build-watch:main       # watch-build server + client concurrently
npm run build-prod:all         # production builds of server, client, tools
npm start                      # nx serve server (build + run the Nest app on :49366)
npx nx serve client            # Angular dev server; proxies /api and /socket.io to :49366 (proxy.conf.json)

npx nx test server             # Jest; also: client, tof-lib, tools
npx nx test server --testFile=apps/server/src/app/fsh.controller.spec.ts   # single spec file
npx nx test tof-lib -t "name of test"                                       # filter by test name

npm run migrate:create -- <name>   # new migrate-mongo migration
npm run migrate:up | migrate:down | migrate:status
```

To run a production-style build, build both apps, then run `node main.js` from `dist/apps/server`. The server serves the client statically from `../client`.

No project defines an Nx `lint` target, so `npm run lint` doesn't do anything useful. Formatting uses Prettier through `nx format:write` / `nx format:check`.

Local MongoDB: `docker-compose up mongodb`. The full stack runs with `docker-compose up`.

## Runtime requirements

Run the server on Node 20, the version the Docker image uses. Builds work on newer Node, but the server crashes at startup on Node 23+ because dependencies use removed `util`/`buffer` APIs (`jsonwebtoken` → `buffer-equal-constant-time` uses `SlowBuffer`). Without a Node 20 install, `npx -y node@20 main.js` works.

Every API endpoint requires a JWT from an OIDC provider (`auth.jwksUri`). There is no local or anonymous login mode.

The export/publish features run the HL7 FHIR IG Publisher as a child process. They need Java on the PATH, and Jekyll available to the user running the server.

## Configuration

The server uses the `config` npm package. Defaults live in `apps/server/src/config/default.json` and are copied into `dist/apps/server/config` at build time. To override them, add `local.json` or `<NODE_ENV>.json` in that directory, or set environment variables (mapped in `custom-environment-variables.json`, e.g. `DATABASE_URI`, `DATABASE_MIGRATEATSTART`, `SERVER_ENABLESECURITY`, `AUTH_*`).

On startup the server runs pending Mongo migrations if `database.migrateAtStart` is true. Otherwise it **exits** when migrations are pending.

## Architecture

### Storage model

ToF used to proxy everything to an external FHIR server. It now stores everything in MongoDB. `BaseFhirController` and `test/tof.xml` (SoapUI FHIR-server capability tests) date from that design. Some legacy code paths still build FHIR server URLs.

The core Mongo collections, each with a Nest module containing `*.schema.ts`, `*.service.ts`, and `*.controller.ts`:

- `fhirResource` (`fhir-resources/`): wraps a raw FHIR JSON resource in `resource`, plus `fhirVersion`, `versionId`, `projects[]`, and `references` / `referencedBy` (polymorphic refs to `FhirResource` / `NonFhirResource` / `Project`). Deletes are soft (`isDeleted`).
- `nonFhirResource` (`non-fhir-resources/`): IG content that isn't a FHIR resource, such as pages, CDA examples, and publishing templates. It uses Mongoose discriminators, with types in `non-fhir-resources/types` and the enum in `libs/tof-lib/src/lib/models/non-fhir-resource-type.ts`.
- `projects`, `users`, `groups`, `history`, `audit`.

Generic CRUD lives in `base/base-data.service.ts` (aggregation-pipeline search with pagination that filters out soft-deleted docs) and `base/base-data.controller.ts`. The resource-specific controllers at the top level of `apps/server/src/app/` (`implementation-guide.controller.ts`, `structure-definition.controller.ts`, `value-set.controller.ts`, …) extend `FhirResourcesController` and keep the older REST routes (`api/implementationGuides`, `api/structureDefinitions`, …) that the client still calls. Entity types shared with the client (`IFhirResource`, `IProject`, `IBaseEntity`, …) live in `@trifolia-fhir/models`.

### Request pipeline (`apps/server/src/main.ts`)

- The `fhirversion` header (`stu3` | `r4` | `r5`, default `r4`) selects a `Fhir` instance (`FhirInstances` in `helper.ts`). That instance is attached to the request as `req.fhir` (`ITofRequest`).
- `Content-Type: application/xml` request bodies are converted to JSON. If `Accept: application/xml` is set, responses are converted back to XML.
- Socket.io is attached to the HTTP server (`req.io`, `req.ioConnections`) and used to stream progress for long-running publish/export jobs.
- Auth uses a Passport bearer strategy (`auth.strategy.ts`) that validates JWTs against `auth.jwksUri`. Controllers use `@UseGuards(AuthGuard('bearer'))`. `AuditInterceptor` is a global `APP_INTERCEPTOR`.
- Swagger UI is served at `/api-docs`.

### FHIR version handling

`libs/tof-lib/src/lib/{stu3,r4,r5}/fhir.ts` contain hand-written class models for each FHIR version. Code usually branches on `fhirVersion` / `req.fhirServerVersion` and casts to the version-specific type. Exporters follow the same pattern: `export/html.factory.ts` chooses `html.stu3.ts` or `html.r4.ts`, which subclass `HtmlExporter` in `html.ts`.

### Export / publishing

`ExportService` and `export/` build IG packages. HTML export writes an IG Publisher project from templates in `apps/server/src/assets/ig-export/` (including the `_genonce` / `_updatePublisher` .sh/.bat scripts), spawns the IG Publisher jar, and reports progress over socket.io. MS Word export is in `export/msword.ts`. FSH conversion goes through `fsh.controller.ts`, using `fsh-sushi` and `gofsh`.

### Client

The Angular app is organized by feature folders under `apps/client/src/app` (one per resource type plus `projects`, `implementation-guide-view`, `publish`, `export`, `import`, `manage`, …). HTTP services that wrap each server route are in `shared/`. An HTTP interceptor in `app.module.ts` adds the `implementationGuideId` and `fhirversion` headers to API calls when an IG context is active (`ConfigService.igContext`). Requests can opt out with an `ignoreContext` header. Help documentation is static content in `apps/client/src/help`.

### Migrations

Mongo schema and data migrations are migrate-mongo scripts in `apps/server/src/db-migrations/migrations/`, configured by `migrate-mongo-config.ts` (runtime) and `migrate-mongo-config-cli.js` (npm scripts). Any change to the shape of stored documents needs a migration.
