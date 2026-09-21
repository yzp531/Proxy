# 项目规则

本仓库是 **proxy.i-xx.top** 的 PAC 自动代理切换站点（nginx / OpenResty + 原生前端）。
生产就是这份工作树（`/www/wwwroot/proxy.i-xx.top`），**提交即生效，无需部署**。

## 版本与发布

- **版本号格式 `vX.Y.Z`**（例：`v0.0.1`、`v0.0.2`）；每次发新版本，最后一位加 1。
- **每个版本要有"三件套"，名字都用 `vX.Y.Z`**：

  1. **分支**：`git branch vX.Y.Z <commit>`，并把工作区切到该分支（`git checkout vX.Y.Z`）
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

## 前端

- `index.html` 是单文件页面，默认暗色主题，遵循 web-design 规范；
  设计变量集中在 `:root` / `.dark`，改样式优先复用已有变量。
