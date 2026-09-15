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

镜像构建只在**打 tag** 时执行。**当前配置是只构建、不推送**：

```yaml
- name: docker-build
  image: woodpeckerci/plugin-docker-buildx
  privileged: true
  settings:
    dry_run: true
    repo: bluto-man/vue-cropperjs
    dockerfile: Dockerfile
    platforms: linux/amd64
    tags:
      - ${CI_COMMIT_TAG}
      - latest
  when:
    - event: tag
```

这个步骤没有 `commands`，因为用的是插件。**插件本质也是个容器**，只是它的镜像里预置了脚本，`settings` 下的字段会转成 `PLUGIN_REPO`、`PLUGIN_TAGS` 这样的环境变量传进去。

`${CI_COMMIT_TAG}` 是 Woodpecker 内置变量，打 `v4.0.2` 这个 tag 就会产出 `bluto-man/vue-cropperjs:v4.0.2` 和 `:latest` 两个镜像。

两个容易踩的设置：

**`dry_run: true`** —— 插件跳过 login 和 push，只验证镜像能不能构建出来。当前阶段只想验证流水线，还不想真发布，所以开着。**开了它就不需要配任何 secret。** 以后真要推镜像，去掉这行，再按第四节补上 `username` / `password`。

**`privileged: true`** —— 这个不是可选项。buildx 插件要在容器内部再起一个 docker daemon，非特权容器里起不来，会直接报错。对应地，仓库必须在 Woodpecker 里被标记为 **trusted**，否则 `privileged` 会被忽略。这个开关一般只有实例管理员能改。

### 触发矩阵

| 事件 | build | release-build | docker-build |
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
4. `release-build` 和 `docker-build` 才开始跑

想反悔就点 Decline，这条记录作废，镜像不会被推出去。发布类操作建议一直开着这个开关。

> 注意：这一步依赖 webhook。GitHub 的 tag 推送事件要能送达 Woodpecker，列表里才会出现那条待审批记录。webhook 没通的话，打 tag 在 Woodpecker 这边是完全无感的。

## 四、前置配置

### 必须开 trusted

`privileged: true` 只有在仓库被标记为 trusted 时才生效：**仓库 → Settings → General → Trusted**。这个开关通常只有 Woodpecker 管理员可见，自建实例用 admin 账号登录就能改。

没开的话 `docker-build` 这一步会挂，前面两步不受影响。

### secret：当前不需要

`dry_run: true` 的情况下插件不会 login，**下面这两条 secret 可以先不配**。等哪天要真推镜像了再回来看这节。

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

**Apple 芯片上要特别慢。** 想完全复刻 CI 环境的话得加 `--platform linux/amd64`：

```bash
docker build --platform linux/amd64 -t vue-cropperjs:test .
```

但这会走 QEMU 模拟，`example/` 那套 webpack 编译在模拟层下能跑十几分钟（CI 上是原生 amd64，几分钟就完）。只是想验证 Dockerfile 写没写错的话，不加 `--platform` 用本机 arm64 跑更快，绝大多数错误（文件路径写错、依赖装不上、构建脚本报错）照样能暴露出来。

**注意退出码会被管道吃掉。** 习惯性写 `docker build ... | tail -40` 的话，`$?` 拿到的是 `tail` 的退出码，永远是 0，构建失败了也看不出来。要么别接管道，要么先 `set -o pipefail`。

## 六、触发流程

```bash
# 1. 改版本号，保持和 tag 一致
#    package.json 里 "version": "4.0.3"

# 2. 提交
git add .woodpecker.yml yarn.lock
git commit -m "chore: 发布 4.0.3"
git push origin master          # 不触发任何步骤

# 3. 打 tag 并单独推送
git tag v4.0.3
git push origin v4.0.3          # 触发 release-build + docker-build
```

三个要点：

- **`git push` 不会自动带上 tag**，必须单独推。最后那条 `git push origin v4.0.3` 才是真正让流水线动起来的命令，前面都是铺垫。
- **push 到 master 现在不触发任何东西**（`build` 已收窄为 `manual`），所以第 2 步是安全的。
- **老 tag 不会补跑。** webhook 只在新 tag 被推上去的那一刻发一次，仓库里那十几个历史 tag 不会因为现在装了 CI 就重发一遍。要测必须打个新号。

## 七、yarn.lock 与 --frozen-lockfile

本项目的 `yarn install` 全部带 `--frozen-lockfile`，意思是「锁文件必须已经是最新的，不准我改」，对不上就直接退出：

```
error Your lockfile needs to be updated, but yarn was run with `--frozen-lockfile`.
```

这个仓库**从上游继承下来时就是坏的**：`package.json` 声明 `cropperjs: ^1.5.6`，但 `yarn.lock` 里只有 `cropperjs@^1.1.3 → 1.4.3`。作者当年升了版本号没重新生成锁文件。平时 `yarn install`（不加 flag）会自动补上所以没人发现，一加 `--frozen-lockfile` 立刻暴露。

修法是重新解析后提交锁文件：

```bash
npx --yes yarn@1.22.19 install --ignore-scripts
git add yarn.lock
```

本机没装 yarn 也不用装，`npx` 直接拉一个 1.x 跑就行。`--ignore-scripts` 是因为只要锁文件，不需要真的把包编出来。

> **改完检查一下 registry。** 如果本机配了淘宝镜像，新解析的条目 `resolved` 会指向 `registry.npmmirror.com`，而其余两百多条还是 `registry.yarnpkg.com`。锁文件里混两个源很危险 —— CI 的 agent 不一定能访问 npmmirror，那一个包就会拉不下来。统一成官方源即可，两个源代理的是同一个 npmjs tarball，sha1 和 integrity 都不用动，只换主机名是安全的：
>
> ```bash
> grep -c "registry.npmmirror.com" yarn.lock    # 应该是 0
> ```

`example/yarn.lock` 是同步的，没有这个问题。

## 已知问题

- **`package.json` 的 version 要手动跟 tag 对齐**（已对齐到 4.0.4）。流水线不校验这个，对不上也不报错。想让 CI 强制校验，可以在 `release-build` 里加一行比对，不一致就 `exit 1`。
- **镜像目前只构建不推送**（`dry_run: true`），Docker Hub 上不会出现任何东西。这是当前阶段有意为之，不是故障。
- **`privileged` 依赖仓库的 trusted 标记**，没开的话 `docker-build` 必挂。这个改不了就只能先把该步骤注释掉，留前两步验证 tag 触发。
