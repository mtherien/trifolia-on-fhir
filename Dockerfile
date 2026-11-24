FROM node:26-alpine AS build

# Python and G++ are required for some of the node devDependencies
# Java is required for Trifolia-on-FHIR to "Publish" implementation guides
# (Java is used to executed the FHIR IG Publisher)
RUN apk add --no-cache --virtual .gyp make python3 gcc g++ openjdk8-jre build-base fontconfig

RUN mkdir /build

WORKDIR /build

# Only copy the package definitions at first, so that Docker uses a cached version
# of the image when possible. Docker only updates the cached version when the package
# definition files change.
COPY package.json /build/
COPY package-lock.json /build/

RUN npm ci

# Docker should (most of the time) skip the above (when rebuilding) and go straight here
# where actual code files have changed, and need to be re-built.
COPY . .

# Need --max_old_space_size to allocate more ram to node when building. Without it,
# you get an error "Ineffective mark-compacts near heap limit Allocation failed - JavaScript heap out of memory"
RUN node --max_old_space_size=4096 node_modules/nx/bin/nx build client --configuration production
RUN node --max_old_space_size=4096 node_modules/nx/bin/nx build server --configuration production
RUN node --max_old_space_size=4096 node_modules/nx/bin/nx build tools --configuration production

RUN npm prune --production

FROM node:26-alpine

# Ruby and Jekyll are required by the FHIR IG Publisher to generate HTML.
# Java is used to execute the FHIR IG Publisher.
RUN apk update && apk --update --no-cache add ruby-full ruby-dev build-base openjdk11-jre
# Install fonts that are used by ig publisher. Without these, ig publisher throws a bunch of exceptions
RUN apk add --no-cache fontconfig ttf-dejavu
RUN gem install ffi -v 1.15.5
RUN gem install sassc -v 2.4.0 -- --disable-march-tune-native
RUN gem install rouge -v 3.30.0
RUN gem install jekyll -v 3.9.3 --no-document
RUN gem install kramdown-parser-gfm -v 1.1.0 --no-document
RUN gem install bundler --no-document
RUN jekyll -v

COPY --from=build /build/dist/. /ToF/
COPY --from=build /build/node_modules/. /ToF/node_modules/

VOLUME /ToF/apps/server/logs
VOLUME /ToF/apps/server/igs

WORKDIR /ToF/apps/server

EXPOSE 49366

ENTRYPOINT ["node", "main.js"]
