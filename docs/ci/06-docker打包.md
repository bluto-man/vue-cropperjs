# Docker 打包说明

本文讲两件事：Woodpecker 本身是怎么用 Docker 跑流水线的，以及本项目的镜像是怎么打出来的。这两个 Docker 不是一回事，容易混。

## 一、Woodpecker 用 Docker 跑每个步骤

`.woodpecker.yml` 里每个 `step` 都是**一个独立的容器**，跑完即销毁。

```yaml
- name: build
  image: node:16-alpine      # agent 执行 docker pull node:16-alpine
  commands:                  # 在该容器内依次执行
    - yarn install --frozen-lockfile
    - yarn build
```

执行过程：

1. agent 拉取 `node:16-alpine`
2. 起一个容器，把克隆好的仓库挂载到 `/woodpecker/src/<forge>/<owner>/<repo>`，并设为工作目录
3. 把 `commands` 拼成一个 shell 脚本丢进去执行
4. 退出码为 0 则该步骤成功，非 0 则整条流水线中断，后续步骤不再执行

**步骤之间共享工作目录**，所以 `build` 步骤 `yarn install` 装出来的 `node_modules`、编译出的 `dist/`，后面的步骤能直接用。但**容器本身不共享** —— 在 A 步骤 `apk add` 装的系统包，到 B 步骤就没了，因为那是另一个容器。

`clone` 这个步骤是 Woodpecker 自动插入的，不用自己写。

## 二、本项目镜像的构建

镜像内容是**示例站点**（`example/` 目录下的 Vue CLI 应用），用 nginx 托管。组件库本体是 npm 包，不需要镜像。

`Dockerfile` 分三个阶段：

| 阶段 | 基础镜像 | 干什么 |
|---|---|---|
| `lib` | `node:16-alpine` | 编译组件库，产出 `dist/VueCropper.js` |
| `demo` | `node:16-alpine` | 编译示例站点，产出静态文件 |
| 运行时 | `nginx:alpine` | 只拷入静态文件对外提供服务 |

两个关键点：

**1. 为什么锁 node:16**

`example/` 用的是 `vue-cli-service` 3.x，底层是 webpack 4。Node 17 及以上改了 OpenSSL 默认策略，webpack 4 会报：

```
error:0308010C:digital envelope routines::unsupported
```

用 node:16 直接绕开。硬要用新版 Node 的话，得设 `NODE_OPTIONS=--openssl-legacy-provider`。

**2. 示例站点用的是本仓库代码，不是 npm 上的版本**

`example/package.json` 里依赖的是 `vue-cropperjs: ^4.0.0`，`yarn install` 装的是 npm 上的发布版。所以 Dockerfile 里多了一行覆盖：

```dockerfile
COPY --from=lib /src/dist/VueCropper.js ./node_modules/vue-cropperjs/dist/VueCropper.js
```

把阶段 1 刚编出来的产物盖上去，这样镜像里跑的才是当前代码。

**多阶段的意义**：最终镜像只有 `nginx:alpine` 加静态文件，几十 MB；如果单阶段构建，两份 `node_modules` 会让镜像涨到 1 GB 以上。

## 三、流水线里怎么触发

镜像构建只在**打 tag** 时执行：

```yaml
- name: docker-publish
  image: woodpeckerci/plugin-docker-buildx
  settings:
    repo: bluto-man/vue-cropperjs
    tags:
      - ${CI_COMMIT_TAG}
      - latest
    username:
      from_secret: docker_username
    password:
      from_secret: docker_password
  when:
    - event: tag
```

这个步骤没有 `commands`，因为用的是插件。**插件本质也是个容器**，只是它的镜像里预置了脚本，`settings` 下的字段会转成 `PLUGIN_REPO`、`PLUGIN_TAGS` 这样的环境变量传进去。

`${CI_COMMIT_TAG}` 是 Woodpecker 内置变量，打 `v4.0.2` 这个 tag 就会产出 `bluto-man/vue-cropperjs:v4.0.2` 和 `:latest` 两个镜像。

### 触发矩阵

| 事件 | build | release-build | docker-publish |
|---|---|---|---|
| push | | | |
| pull_request | | | |
| 手动 Run pipeline | ✓ | | |
| 打 tag | | ✓ | ✓ |

**push 和 PR 一律不跑**，日常提交不会产生任何构建。只有两种入口：手动点 Run pipeline，或者打 tag。

### 让 tag 也停下来等人点

光靠 `when` 做不到「tag 推上去先挂起、点一下才跑」—— `when` 只决定跑不跑，不决定什么时候跑。要挂起得开仓库的审批开关：

**仓库 → Settings → General → Approvals**，选 **All events**（或 `Require approval for all events`）。

开了之后，打 tag 的流程变成：

1. `git push origin v4.0.2`
2. Woodpecker 列表里出现一条 `TAG` 记录，状态是 **blocked / pending**，不执行任何步骤
3. 点进去，点 **Approve**
4. `release-build` 和 `docker-publish` 才开始跑

想反悔就点 Decline，这条记录作废，镜像不会被推出去。发布类操作建议一直开着这个开关。

> 注意：这一步依赖 webhook。GitHub 的 tag 推送事件要能送达 Woodpecker，列表里才会出现那条待审批记录。webhook 没通的话，打 tag 在 Woodpecker 这边是完全无感的。

## 四、前置配置

### 必须先配 secret

镜像仓库凭据不能写进 yml，要在 Woodpecker UI 里配：**仓库 → Settings → Secrets**，加两条：

| 名称 | 值 |
|---|---|
| `docker_username` | Docker Hub 用户名 |
| `docker_password` | Docker Hub Access Token（别用登录密码） |

Events 勾上 `tag`，否则 tag 触发时读不到。

### 换成 GitHub Container Registry

想推到 ghcr.io 而不是 Docker Hub，改 `settings` 加一行 `registry`：

```yaml
settings:
  registry: ghcr.io
  repo: ghcr.io/bluto-man/vue-cropperjs
```

密码用 GitHub Personal Access Token，需要 `write:packages` 权限。

## 五、本地验证

不想每次推 tag 才知道 Dockerfile 有没有写错，可以本地先跑：

```bash
cd vue-cropperjs
docker build -t vue-cropperjs:test .
docker run --rm -p 8080:80 vue-cropperjs:test
# 浏览器打开 http://localhost:8080
```

首次构建要装两套 node_modules，比较慢。

## 六、发布流程

```bash
# 1. 改版本号，保持和 tag 一致
#    package.json 里 "version": "4.0.2"

# 2. 提交
git commit -am "chore: 发布 4.0.2"
git push origin master          # 触发 build

# 3. 打 tag 并单独推送
git tag v4.0.2
git push origin v4.0.2          # 触发 release-build + docker-publish
```

注意 `git push` 不会自动带上 tag，必须单独推。

## 已知问题

- **`package.json` 的 version 和 tag 目前对不上**（前者 4.0.1，已有 tag v4.0.2），流水线不会因此报错，但发布前应手动对齐。想让 CI 强制校验，可以在 `release-build` 里加一行比对，不一致就 `exit 1`。
- **Dockerfile 尚未实际构建验证过。** 首次推 tag 前建议先按第五节本地跑一遍。
