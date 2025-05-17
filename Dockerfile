ARG NODE_VERSION=22.14
FROM node:${NODE_VERSION}-bookworm-slim AS base

FROM base AS deps
WORKDIR /opt/medusa/deps
ARG NODE_ENV=development
ENV NODE_ENV=$NODE_ENV

# Install dependencies
COPY package*.json yarn.lock* pnpm-lock.yaml* .yarn* ./
RUN \
  if [ -f yarn.lock ]; then corepack enable yarn && yarn install --immutable; \
  elif [ -f package-lock.json ]; then npm ci; \
  elif [ -f pnpm-lock.yaml ]; then corepack enable pnpm && pnpm install; \
  else echo "Lockfile not found." && exit 1; \
  fi

FROM base AS builder
WORKDIR /opt/medusa/build
ARG NODE_ENV=production
ENV NODE_ENV=$NODE_ENV

# Build the application
COPY --from=deps /opt/medusa/deps .
COPY . .
RUN \
  if [ -f yarn.lock ]; then corepack enable yarn && yarn run build; \
  elif [ -f package-lock.json ]; then npm run build; \
  elif [ -f pnpm-lock.yaml ]; then corepack enable pnpm && pnpm run build; \
  fi

FROM base AS runner
RUN apt-get update \
  && apt-get install --no-install-recommends -y tini=0.19.0-1 \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

USER node
WORKDIR /opt/medusa
COPY --from=builder --chown=node:node /opt/medusa/build .

# 设置默认环境变量
ENV PORT=9000 \
    NODE_ENV=production \
    MEDUSA_RUN_MIGRATION=true \
    MEDUSA_CREATE_ADMIN_USER=false \
    MEDUSA_ADMIN_EMAIL="" \
    MEDUSA_ADMIN_PASSWORD=""

# 创建启动脚本
RUN echo '#!/bin/bash\n\
# 运行数据库迁移\n\
if [[ "${MEDUSA_RUN_MIGRATION}" == "true" ]]; then\n\
  npx medusa db:migrate\n\
fi\n\
\n\
# 创建管理员用户\n\
if [[ "${MEDUSA_CREATE_ADMIN_USER}" == "true" ]]; then\n\
  if [[ -n "${MEDUSA_ADMIN_EMAIL}" ]] && [[ -n "${MEDUSA_ADMIN_PASSWORD}" ]]; then\n\
    CREATE_OUTPUT=$(npx medusa user -e "${MEDUSA_ADMIN_EMAIL}" -p "${MEDUSA_ADMIN_PASSWORD}" 2>&1) || true\n\
    if [[ $CREATE_OUTPUT != *"User"*"already exists"* ]]; then\n\
      echo "管理员用户创建或更新成功"\n\
    else\n\
      echo "管理员用户已存在"\n\
    fi\n\
  else\n\
    echo "警告: 需要设置 MEDUSA_ADMIN_EMAIL 和 MEDUSA_ADMIN_PASSWORD 环境变量来创建管理员用户"\n\
  fi\n\
fi\n\
\n\
# 启动 Medusa\n\
exec npx medusa start\n\
' > /opt/medusa/docker-entrypoint.sh \
  && chmod +x /opt/medusa/docker-entrypoint.sh

EXPOSE $PORT

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/opt/medusa/docker-entrypoint.sh"]
