# 项目规则

本仓库是 **proxy.i-xx.top** 的 PAC 自动代理切换站点（nginx / OpenResty + 原生前端）。
生产就是这份工作树（`/www/wwwroot/proxy.i-xx.top`），**提交即生效，无需部署**。

## 版本与发布

- **版本号格式 `vX.Y.Z`**（例：`v0.0.1`、`v0.0.2`）；每次发新版本，最后一位加 1。
- **每个版本要有"三件套"，名字都用 `vX.Y.Z`**：

  1. **分支**：`git branch vX.Y.Z <commit>`，并把工作区切到该分支。
     ⚠️ 分支与 tag 同名，一旦打过 tag，`git merge vX.Y.Z` / `git checkout vX.Y.Z`
     会歧义解析到 tag 上，**必须显式写 `refs/heads/vX.Y.Z`**。
  2. **标签**：annotated tag —— `git tag -a vX.Y.Z -m "vX.Y.Z …"`
  3. **Release**：`gh release create vX.Y.Z --latest`（新版本设为 Latest；补发布旧版本时加 `--latest=false`）

- **推送**：分支名与标签名相同，直接 `git push origin vX.Y.Z` 会报
  `src refspec vX.Y.Z matches more than one`，必须写显式 refspec：

  ```bash
  git push origin refs/heads/vX.Y.Z:refs/heads/vX.Y.Z   # 分支
  git push origin refs/tags/vX.Y.Z                      # 标签
  ```

- **远端**：`origin` = `git@github.com:yzp531/Proxy.git`（仓库曾用名 `proxy.i-xx.top`，
  所有版本都发布在这里，不要另开仓库）。
- `main` 与最新版本分支保持一致；新版本从最新版本分支继续。
- 发布后确认线上可用：`https://proxy.i-xx.top/` 与 `https://proxy.i-xx.top/pac` 均返回 200。

## 提交

- 提交信息用 Conventional Commits 前缀（`feat` / `fix` / `chore` …），描述用**中文**。

## PAC 数据

- PAC 只有**一个入口** `pac/tools.py`：`render` / `info` / `set-proxy IP:端口` / `set-rules FILE` / `update`。
  数据源是 `pac/templates/*.tpl` + `pac/data/*.txt`，**不要手改** `proxy.pac` 等生成物。
- PAC 代码保持 **ES3 语法**（Windows WinHTTP 的 JScript 不支持 `let` / `Set` / 箭头函数）。

## 管理密钥

- admin.lua 的写操作（set-proxy / update / abort / add-proxy-domain）与 api.lua 的模式
  切换受 **切换密钥** 保护：正本在 `pac/token.txt`（单行，已 gitignore，不入库）。
- 站点经 Cloudflare 回源，客户端内网 IP 无法出现在服务端，**不要**尝试做局域网
  白名单；浏览器本地只存出示用的凭据（localStorage `pac-switch-token`）。
- 更换密钥 = 重写 `pac/token.txt` 为一行新随机串（`openssl rand -hex 16`），
  全部已填设备需重填一次。

## 前端

- `index.html` 是单文件页面，默认暗色主题，遵循 web-design 规范；
  设计变量集中在 `:root` / `.dark`，改样式优先复用已有变量。
