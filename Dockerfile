# 多阶段构建：前两阶段只负责编译，产物拷进第三阶段，
# 最终镜像里不含 node_modules 和构建工具，体积只有几十 MB。

# ---- 阶段 1：编译组件库本体 ----
# 用 node:16 是因为 example 里的 vue-cli-service 3.x 基于 webpack 4，
# 在 Node 17+ 上会报 digital envelope routines::unsupported。
FROM node:16-alpine AS lib
WORKDIR /src
# 先只拷依赖清单，这样改源码时这层缓存不会失效
COPY package.json yarn.lock .babelrc ./
RUN yarn install --frozen-lockfile
COPY VueCropper.js ./
RUN yarn build

# ---- 阶段 2：编译示例站点 ----
FROM node:16-alpine AS demo
WORKDIR /app
COPY example/package.json example/yarn.lock ./
RUN yarn install --frozen-lockfile
COPY example/ ./
# 用阶段 1 刚编出来的组件覆盖 npm 装的版本，
# 保证示例跑的是本仓库当前代码，而不是 npm 上的旧版
COPY --from=lib /src/dist/VueCropper.js ./node_modules/vue-cropperjs/dist/VueCropper.js
RUN yarn build

# ---- 阶段 3：运行时 ----
FROM nginx:alpine
COPY --from=demo /app/dist /usr/share/nginx/html
EXPOSE 80
