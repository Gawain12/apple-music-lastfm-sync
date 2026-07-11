# Apple Music Last.fm Sync

macOS 原生 Swift 命令行工具，把 Apple Music / Music.app 的播放记录安全地同步到 Last.fm。

## 推荐流程

### 1. 下载

优先从 GitHub Releases 下载已经编译好的可执行文件：

<https://github.com/Gawain12/apple-music-lastfm-sync/releases>

解压后执行：

```sh
chmod +x lastfm-sync
./lastfm-sync help
```

当前 Release 提供 Apple Silicon（arm64）版本。也可以从仓库源码编译：

```sh
swiftc LastFmAppleMusicSync.swift -parse-as-library \
  -framework AppKit -framework CryptoKit -framework Foundation -framework Security \
  -o lastfm-sync
```

### 2. 创建 API 并授权

```sh
./lastfm-sync setup       # 自动打开 Last.fm API 创建页面
./lastfm-sync configure   # 输入 API key 和 shared secret
./lastfm-sync auth        # 自动打开授权页面，授权后回终端按 Enter
./lastfm-sync migrate     # 如果旧版本用了 Keychain，可迁移并删除旧条目
```

默认配置保存在 `~/.config/apple-music-lastfm-sync.env`，目录权限 700、文件权限 600，不会写进仓库或命令行参数。也可以使用环境变量覆盖配置文件：

```sh
export LASTFM_API_KEY="..."
export LASTFM_SHARED_SECRET="..."
export LASTFM_SESSION_KEY="..."
export LASTFM_USERNAME="..."
```

环境变量优先于配置文件；配置文件优先于旧版 Keychain。需要继续使用 Keychain 时可执行 `configure --keychain`。API key、shared secret 和 session key 虽然可以手动撤销，但仍然是可写入账号的凭据，不要提交到 GitHub。第一次访问 Music.app 时，macOS 可能会询问 Automation 权限，需要允许。

### 3. 先检查，不上传

```sh
./lastfm-sync list --since-days 14
./lastfm-sync list --all --limit 20
./lastfm-sync status
```

`list` 是只读检查命令：不会上传，也不会推进同步游标。它会显示播放时间、Unix 时间戳、艺人、曲名、专辑、专辑艺人、时长、来源和去重状态。

记录很多时不会刷屏。默认最多展示 100 条样本，同时给出总数、状态分布、时间范围、总时长、热门艺人和热门专辑；使用 `--limit N` 调整样本数量，`--full` 才强制展开全部，`--json` 输出摘要和样本 JSON。

第一次使用可以选择全库：

```sh
./lastfm-sync list --all --limit 20
```

这里的“全库”是 Music.app 中所有有 `played date` 的曲目，每首曲目通常只有 Apple Music 当前暴露的最后一次播放时间，不等于完整的 Apple Music 逐次播放事件数据库。

### 4. 确认后同步

```sh
./lastfm-sync sync --since-days 14   # 检查后的最近 14 天
./lastfm-sync sync                    # 按上次同步游标继续
./lastfm-sync sync --all --yes       # 明确确认后同步全库
```

上传的数据包含：

- 原始播放时间的 Unix timestamp
- artist、track、album、album artist
- duration
- `chosenByUser=1`

程序会把扫描结果写入本地 pending 队列。只有 Last.fm 明确接受，或远端已经存在相同艺人、曲名和时间的记录，才会从队列移除。崩溃、断网和限流都可以安全重试，不会把未确认的数据当成成功。

状态文件位置：

```text
~/Library/Application Support/Apple Music Last.fm Sync/state.json
```

里面会记录同步游标、pending 数量、最近扫描/提交时间、最近 100 次运行记录和错误信息。`status` 可以直接查看这些信息。

全库超过 100 条时，`sync --all` 默认只扫描并入队，不上传；确认检查无误后再加 `--yes`。待处理超过 500 条时，为避免重新下载整个 Last.fm 历史，远端重复检查会跳过，但本地指纹和 pending 队列仍然有效。

### 5. 可选定时同步

这是用户级 launchd 任务，不需要管理员权限，也不是常驻后台进程：

```sh
./lastfm-sync schedule install --interval 3600
./lastfm-sync schedule status
./lastfm-sync schedule uninstall
```

安装时会记录当前可执行文件的绝对路径，所以请先把二进制放到稳定位置。日志在：

```text
~/Library/Logs/AppleMusicLastFmSync.log
~/Library/Logs/AppleMusicLastFmSync.error.log
```

## 下载 Last.fm 历史

Last.fm `user.getRecentTracks` 支持分页，工具可以把账号可读取的历史导出为 JSONL：

```sh
./lastfm-sync download --output ~/Downloads/lastfm-history.jsonl
./lastfm-sync download --from 1704067200 --to 1735689600 \
  --output ~/Downloads/lastfm-2024.jsonl
./lastfm-sync download --max-pages 1 --output /tmp/lastfm-page.jsonl
```

不加 `--max-pages` 会继续分页直到结束。导出包含 timestamp、artist、track、album、URL 和 `source: "unknown"`。

## 重要限制

1. Music.app 通常只暴露每首曲目的最新 `played date`，无法恢复两次扫描之间同一首歌的每一次播放。因此想尽量完整，应该定时运行，而不是几个月后一次性补扫。
2. Last.fm 的 scrobble API 没有可靠的电脑/手机字段。工具只把本程序发出的记录标记为 `computer`，下载的远端历史保持 `unknown`，不会猜测来源。
3. Last.fm API 错误 29 表示限流。程序会保留 pending 并记录错误，稍后重试；不会误报上传成功。
4. 全库中的很旧记录可能被 Last.fm 以时间过旧忽略，这种记录会记录为永久忽略，不会无限重试。

## 开源

- GitHub: <https://github.com/Gawain12/apple-music-lastfm-sync>
- License: MIT
- 官方 API: <https://www.last.fm/api>
