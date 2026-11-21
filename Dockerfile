# syntax=docker/dockerfile:1
# check=error=true

# One image for the whole app: Vite builds the React frontend, and Rails serves
# it next to the API and Action Cable. Render builds this (see render.yaml).
#
#   docker build -t devops-sim .
#   docker run -p 3000:3000 -e SECRET_KEY_BASE=$(openssl rand -hex 64) devops-sim

# --- frontend ---------------------------------------------------------------
FROM docker.io/library/node:22-slim AS frontend
WORKDIR /frontend
COPY frontend/package.json frontend/package-lock.json ./
RUN npm ci
COPY frontend/ ./
RUN npm run build

# --- backend ----------------------------------------------------------------
# Keep in step with backend/.ruby-version
ARG RUBY_VERSION=3.3.14
FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base
WORKDIR /rails

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y curl libjemalloc2 sqlite3 && \
    ln -s /usr/lib/$(uname -m)-linux-gnu/libjemalloc.so.2 /usr/local/lib/libjemalloc.so && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development:test" \
    LD_PRELOAD="/usr/local/lib/libjemalloc.so"

FROM base AS build
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git libyaml-dev pkg-config && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

COPY backend/Gemfile backend/Gemfile.lock ./
RUN bundle install && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git && \
    bundle exec bootsnap precompile -j 1 --gemfile

COPY backend/ ./
RUN bundle exec bootsnap precompile -j 1 app/ lib/

# The built frontend goes into public/. Its index.html is served by
# FrontendController so it isn't cached; the hashed assets are.
COPY --from=frontend /frontend/dist/ ./public/
RUN mv public/index.html public/app.html && mkdir -p storage log tmp

FROM base
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash
COPY --chown=rails:rails --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --chown=rails:rails --from=build /rails /rails
USER 1000:1000

# SQLite lives in storage/. On Render's free plan it starts empty on every deploy.
VOLUME /rails/storage

ENTRYPOINT ["/rails/bin/docker-entrypoint"]
EXPOSE 3000
CMD ["./bin/rails", "server"]
