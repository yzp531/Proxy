#!/usr/bin/env python3
"""PAC 数据维护工具（唯一负责渲染 PAC 文件的地方）。

用法：
    tools.py info                  输出当前状态 JSON
    tools.py render                按模板 + 数据重新生成 proxy.pac / global.pac
    tools.py set-proxy IP[:PORT]   修改代理地址并重新渲染
    tools.py set-rules FILE        用文件中的域名（每行一个）替换国内域名表并重新渲染
    tools.py update                从上游重新抓取国内域名名单（需联网），完成后重新渲染
"""

import json
import os
import re
import sys
import time
import urllib.request
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
SITE = os.path.dirname(HERE)
DATA = os.path.join(HERE, "data")
WORK = os.path.join(HERE, "work")
TPL = os.path.join(HERE, "templates")

PROXY_FILE = os.path.join(DATA, "proxy.txt")
DOMAIN_FILE = os.path.join(DATA, "cn-domains.txt")
EXTRA_FILE = os.path.join(DATA, "extra-domains.txt")
DATE_FILE = os.path.join(DATA, "list-generated.txt")
STATUS_FILE = os.path.join(DATA, "status.json")
RENDERED_FILE = os.path.join(DATA, "rendered.json")
LOCK_FILE = os.path.join(DATA, "update.lock")

CHINA_LIST_URLS = [
    "https://raw.githubusercontent.com/felixonmars/dnsmasq-china-list/master/accelerated-domains.china.conf",
    "https://cdn.jsdelivr.net/gh/felixonmars/dnsmasq-china-list@master/accelerated-domains.china.conf",
]
POPULAR_SOURCES = [
    ("Cisco Umbrella top-1m", "http://s3-us-west-1.amazonaws.com/umbrella-static/top-1m.csv.zip"),
    ("Majestic Million", "https://downloads.majestic.com/majestic_million.csv"),
]
UA = {"User-Agent": "pac-tools/1.0"}

DOMAIN_RE = re.compile(r"^[a-z0-9]([a-z0-9\-_.]*[a-z0-9])?$")


# ---------------------------------------------------------------- 基础读写


def read_text(path, default=""):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return fh.read()
    except OSError:
        return default


def write_atomic(path, content):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(content)
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)


def now():
    return time.strftime("%Y-%m-%d %H:%M:%S")


def read_domains():
    return [ln.strip().lower() for ln in read_text(DOMAIN_FILE).splitlines() if ln.strip()]


def write_status(state, message=""):
    write_atomic(STATUS_FILE, json.dumps(
        {"state": state, "message": message, "updated": now()},
        ensure_ascii=False) + "\n")


def read_status():
    try:
        return json.loads(read_text(STATUS_FILE, "{}"))
    except ValueError:
        return {}


# ---------------------------------------------------------------- 校验


def valid_domain(host):
    if not host or len(host) > 253 or ".." in host:
        return False
    if not DOMAIN_RE.match(host):
        return False
    return "." in host or host.isalnum()


def valid_proxy(addr):
    """接受 1.2.3.4:7890、proxy.lan:7890 或省略端口的形式。"""
    if not addr or len(addr) > 253 or any(c in addr for c in " \t\"'`$&|;<>()\\"):
        return False
    host, _, port = addr.partition(":")
    if _:
        if not port.isdigit() or not 1 <= int(port) <= 65535:
            return False
    if not host or len(host) > 253:
        return False
    if re.match(r"^\d+\.\d+\.\d+\.\d+$", host):
        return all(0 <= int(p) <= 255 for p in host.split("."))
    return valid_domain(host)


# ---------------------------------------------------------------- 渲染


def render():
    proxy = read_text(PROXY_FILE).strip()
    domains = read_domains()
    if not valid_proxy(proxy):
        raise SystemExit("代理地址不合法: %r" % proxy)
    if len(domains) < 100:
        raise SystemExit("域名表异常（%d 条），已放弃渲染" % len(domains))

    # 模板里 {{DOMAINS}} 后面自带分号，最后一行不要重复加
    blob = "\n".join(
        '"%s\\n" +' % d if i < len(domains) - 1 else '"%s\\n"' % d
        for i, d in enumerate(domains)
    )
    date = read_text(DATE_FILE).strip() or time.strftime("%Y-%m-%d")

    tpl = read_text(os.path.join(TPL, "proxy.tpl"))
    body = (tpl.replace("{{PROXY}}", proxy)
               .replace("{{DOMAINS}}", blob)
               .replace("{{COUNT}}", str(len(domains)))
               .replace("{{DATE}}", date))
    if "{{" in body:
        raise SystemExit("模板渲染后仍有占位符未替换")
    write_atomic(os.path.join(SITE, "proxy.pac"), body)

    gtpl = read_text(os.path.join(TPL, "global.tpl"))
    gbody = gtpl.replace("{{PROXY}}", proxy)
    if "{{" in gbody:
        raise SystemExit("global 模板渲染后仍有占位符未替换")
    write_atomic(os.path.join(SITE, "global.pac"), gbody)

    write_atomic(RENDERED_FILE, json.dumps(
        {"rendered_at": now(), "rules": len(domains), "proxy": proxy},
        ensure_ascii=False) + "\n")
    return len(domains)


# ---------------------------------------------------------------- 上游更新


def fetch(url, timeout=180):
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read()


def load_china_list():
    last = None
    for url in CHINA_LIST_URLS:
        try:
            raw = fetch(url).decode("utf-8", "replace")
            entries = set()
            for line in raw.splitlines():
                m = re.match(r"server=/([^/]+)/", line)
                if m:
                    entries.add(m.group(1).lower())
            if len(entries) > 10000:
                return entries
            last = "条目过少：%d" % len(entries)
        except Exception as exc:  # noqa: BLE001
            last = str(exc)
    raise SystemExit("获取国内域名源失败：%s" % last)


def load_popular():
    last = None
    for name, url in POPULAR_SOURCES:
        try:
            data = fetch(url)
            hosts = []
            if url.endswith(".zip"):
                os.makedirs(WORK, exist_ok=True)
                zpath = os.path.join(WORK, "popular.zip")
                with open(zpath, "wb") as fh:
                    fh.write(data)
                with zipfile.ZipFile(zpath) as zf:
                    name_in_zip = zf.namelist()[0]
                    text = zf.read(name_in_zip).decode("utf-8", "replace")
                os.remove(zpath)
            else:
                text = data.decode("utf-8", "replace")
            for line in text.splitlines():
                parts = line.strip().split(",")
                if not parts[0].isdigit():
                    continue  # 表头或空行
                if len(parts) == 2:            # Umbrella: rank,domain
                    hosts.append(parts[1].lower())
                elif len(parts) >= 6:          # Majestic: GlobalRank,TldRank,Domain,...
                    hosts.append(parts[2].lower())
            if len(hosts) > 10000:
                return name, hosts
            last = "%s 解析结果过少：%d" % (name, len(hosts))
        except Exception as exc:  # noqa: BLE001
            last = "%s: %s" % (name, exc)
    raise SystemExit("获取热门站点清单失败：%s" % last)


def match_domains(china_set, hosts):
    """逐级剥离子域，取最长命中项（不归并到主域，避免误伤海外站点）。"""
    hits = set()
    for host in hosts:
        labels = host.split(".")
        for i in range(len(labels) - 1):
            suffix = ".".join(labels[i:])
            if suffix in china_set:
                hits.add(suffix)
                break
    return hits


def do_update():
    with open(LOCK_FILE, "w") as fh:
        fh.write(str(os.getpid()))
    try:
        write_status("running", "正在获取国内域名源…")
        china = load_china_list()
        write_status("running", "正在获取热门站点清单…（国内域名源 %d 条）" % len(china))
        source, hosts = load_popular()
        write_status("running", "正在匹配规则…（热门站点 %d 条）" % len(hosts))

        hits = match_domains(china, hosts)
        extras = {d.strip().lower() for d in read_text(EXTRA_FILE).splitlines() if d.strip()}
        domains = sorted(hits | extras)

        if len(domains) < 2000:
            raise SystemExit("匹配结果异常（%d 条），已保留原名单" % len(domains))

        old = len(read_domains())
        write_atomic(DOMAIN_FILE, "\n".join(domains) + "\n")
        write_atomic(DATE_FILE, time.strftime("%Y-%m-%d") + "\n")
        count = render()
        message = "更新完成：%d 条域名（原 %d 条），数据源 %s，热门清单 %s" % (
            count, old, "dnsmasq-china-list", source)
        write_status("ok", message)
        return message
    except SystemExit as exc:
        write_status("error", str(exc))
        raise
    except Exception as exc:  # noqa: BLE001
        write_status("error", "更新失败：%s" % exc)
        raise
    finally:
        if os.path.exists(LOCK_FILE):
            os.remove(LOCK_FILE)


def update_locked():
    if os.path.exists(LOCK_FILE):
        age = time.time() - os.path.getmtime(LOCK_FILE)
        if age < 1800:
            print(json.dumps({"ok": False, "error": "已有更新任务在进行中"},
                             ensure_ascii=False))
            return 1
        os.remove(LOCK_FILE)
    do_update()
    print(json.dumps({"ok": True, "message": read_status().get("message", "")},
                     ensure_ascii=False))
    return 0


# ---------------------------------------------------------------- 命令


def cmd_info():
    info = {
        "ok": True,
        "proxy": read_text(PROXY_FILE).strip(),
        "rules": len(read_domains()),
        "list_date": read_text(DATE_FILE).strip(),
        "status": read_status(),
    }
    info.update({k: v for k, v in read_rendered().items()})
    print(json.dumps(info, ensure_ascii=False))
    return 0


def read_rendered():
    try:
        return json.loads(read_text(RENDERED_FILE, "{}"))
    except ValueError:
        return {}


def cmd_set_proxy(addr):
    if not valid_proxy(addr):
        print(json.dumps({"ok": False, "error": "代理地址不合法"}, ensure_ascii=False))
        return 1
    write_atomic(PROXY_FILE, addr + "\n")
    count = render()
    print(json.dumps({"ok": True, "proxy": addr, "rules": count,
                      "rendered_at": now()}, ensure_ascii=False))
    return 0


def cmd_set_rules(path):
    domains = sorted({ln.strip().lower() for ln in read_text(path).splitlines() if ln.strip()})
    bad = [d for d in domains if not valid_domain(d)][:5]
    if bad:
        print(json.dumps({"ok": False, "error": "域名格式不合法：%s" % ", ".join(bad)},
                         ensure_ascii=False))
        return 1
    if len(domains) < 100:
        print(json.dumps({"ok": False, "error": "域名过少（%d 条）" % len(domains)},
                         ensure_ascii=False))
        return 1
    write_atomic(DOMAIN_FILE, "\n".join(domains) + "\n")
    write_atomic(DATE_FILE, time.strftime("%Y-%m-%d") + "\n")
    count = render()
    print(json.dumps({"ok": True, "rules": count}, ensure_ascii=False))
    return 0


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    cmd = argv[1]
    if cmd == "info":
        return cmd_info()
    if cmd == "render":
        count = render()
        print(json.dumps({"ok": True, "rules": count, "rendered_at": now()},
                         ensure_ascii=False))
        return 0
    if cmd == "set-proxy":
        if len(argv) < 3:
            return 2
        return cmd_set_proxy(argv[2])
    if cmd == "set-rules":
        if len(argv) < 3:
            return 2
        return cmd_set_rules(argv[2])
    if cmd == "update":
        return update_locked()
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
