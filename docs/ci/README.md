# Woodpecker CI 演示速查

自用稿子。演示顺序按本文走，细节翻各分册。

- [01 - 自动构建](01-自动构建.md) — 不用管，自己跑
- [02 - 手动构建](02-手动构建.md) — 要人点一下
- [03 - 合并触发](03-合并触发.md) — PR 和合并
- [04 - 跳过构建](04-跳过构建.md) — 让它别跑
- [05 - 复制即用](05-复制即用.md) — 不解释原理，直接抄

## 环境

| 项 | 值 |
|---|---|
| Woodpecker | 3.18.1 |
| 地址 | `https://delete-jackie-hardware-joe.trycloudflare.com` |
| 仓库 | `bluto-man/vue-cropperjs`，repo id = `1` |
| 配置文件 | 仓库根目录 `.woodpecker.yml` |

隧道是 trycloudflare 临时的，cloudflared 一重启 URL 就变，webhook 会失效。演示前先开一下页面确认还活着。

## 一句话总纲

> 三种触发方式：**push 自动跑**、**按钮手动跑**、**PR 开和合并时跑**。三者互不冲突，同一份配置文件通吃，靠 `when.event` 控制哪种事件跑哪一步。

## 当前配置

```yaml
steps:
  - name: hello
    image: alpine
    commands:
      - echo "Woodpecker 跑起来了"
      - uname -a
      - date
      - echo "手动触发测试"
    when:
      - event: [push, manual, pull_request]
```

`when.event` 这行是全场重点，演示时多停一秒：**列表里写了哪些事件，这一步才在哪些场景下跑。**

## 演示动线（10 分钟）

| 步 | 动作 | 看什么 | 讲什么 |
|---|---|---|---|
| 1 | 打开 Activity 页 | 已有 4 条记录 | 先把"绿=成功、红=失败、手图标=手动"的读法交代清楚 |
| 2 | 本地改一行，`git push` | 不碰浏览器，几秒后自己冒出新记录 | 这就是自动构建，见 [01](01-自动构建.md) |
| 3 | 点 Run pipeline | 新记录标 `MANUAL` | 手动兜底，见 [02](02-手动构建.md) |
| 4 | 提交信息带 `[SKIP CI]` 再 push | Activity 没动静 | 跳过，见 [04](04-跳过构建.md) |
| 5 | 开个 PR，再合并 | PR 开时跑一次，合并后又跑一次 | 见 [03](03-合并触发.md) |

第 5 步最花时间，时间紧就只讲不做，拿 [03](03-合并触发.md) 的表格说明。

## 全事件对照表

Woodpecker 3.x 支持的 `event` 值，按"要不要人工介入"分三类：

| 事件 | 谁触发 | 类别 |
|---|---|---|
| `push` | 推送提交到分支 | 🟢 自动 |
| `tag` | 推送 tag | 🟢 自动 |
| `cron` | 定时任务到点 | 🟢 自动 |
| `release` | 创建 release / pre-release / draft | 🟢 自动 |
| `pull_request` | PR 打开，或往 PR 推新提交 | 🟡 合并流程 |
| `pull_request_closed` | PR 关闭**或合并** | 🟡 合并流程 |
| `pull_request_metadata` | PR 标题/正文/标签/里程碑改动 | 🟡 合并流程 |
| `manual` | 有人点 Run pipeline | 🔴 手动 |
| `deployment` | 创建部署（Woodpecker UI 或 GitHub webhook） | 🔴 手动 |

不写 `when.event` 的话所有事件都跑，Woodpecker 会给一条 lint 警告提醒你加过滤。

## 已有的 4 条记录（现成素材）

演示时直接拿这四条讲，四种情况刚好齐了：

| 编号 | 状态 | 事件 | commit | 讲点 |
|---|---|---|---|---|
| #1 | ✅ 成功 41s | push | `0a4d94d` | 第一次接通，push 自动触发 |
| #2 | ❌ 失败 | push | `36ccc5a` | YAML 写坏了，`when` 键重复 |
| #3 | ✅ 成功 7s | push | `4e07977` | 修好后重跑 |
| #4 | ✅ 成功 12s | manual | `4e07977` | 手动点的，ref 显示 `refs/heads/master` |

`#2` 那条时长栏写的是 `not started yet` —— 值得单独说一句：**配置解析阶段就挂了，容器根本没起来**。这和"容器起来了但命令返回非零"是两种失败，排查方向完全不同。

## 网络备忘

本机直连 github.com:443 会超时（实测两次各 75 秒）。推送走本地代理：

```bash
git -c http.proxy=http://127.0.0.1:7890 push origin master
```

嫌麻烦可以只给 GitHub 配代理，不影响其他仓库：

```bash
git config --global http.https://github.com.proxy http://127.0.0.1:7890
```

代理是 `iKuuuVPNC` 开的 7890 端口。演示前先测一下：

```bash
curl -s -m 20 -x http://127.0.0.1:7890 -o /dev/null -w "%{http_code}\n" https://github.com
```

## 不看 UI 也能查状态

投屏切页面麻烦的话，命令行直接拉：

```bash
curl -s "https://delete-jackie-hardware-joe.trycloudflare.com/api/repos/1/pipelines" \
  | python3 -c "
import sys,json
for d in json.load(sys.stdin)[:5]:
    print(f\"#{d['number']}  {d['status']:<8} event={d['event']:<8} {d['commit'][:8]}  {d.get('message','').splitlines()[0]}\")
"
```

流水线列表接口匿名可读，日志接口要登录态。
