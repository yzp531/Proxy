/* ============================================================
 *  PAC 自动代理配置 —— 国内直连，海外走代理
 *  地址：https://www.xiecailiao.vip/proxy.pac
 *  代理：{{PROXY}}
 * ------------------------------------------------------------
 *  匹配顺序：
 *    1. 本机 / 局域网地址（localhost、无点主机名、127.x、10.x、
 *       172.16-31.x、192.168.x、169.254.x、0.x、*.local/*.lan/
 *       *.home/*.internal/*.i-xx.top）      → DIRECT
 *    2. 纯 IP 访问（内网直连；公网 IP 也直连，见文末说明）→ DIRECT
 *    3. 国内域名（下表 + 国内顶级域）        → DIRECT
 *    4. 其余域名（含全部海外站点）           → PROXY {{PROXY}}
 *    代理不可用时回退 DIRECT，离开该局域网仍可上网。
 * ============================================================ */

var PROXY_ADDR = "{{PROXY}}";
var PROXY_RULE = "PROXY " + PROXY_ADDR;
var FALLBACK   = PROXY_RULE + "; DIRECT";

/* ------------------------------------------------------------
 * 国内域名表
 * 来源：Loyalsoldier/v2ray-rules-dat 的 direct-list.txt（增强版）
 *       （约 11 万条，比原 dnsmasq-china-list 多 700+ 条）
 * 本表取其中被全球访问量前 100 万域名清单（Cisco Umbrella top-1m）
 * 真实命中的条目，共 {{COUNT}} 条，另人工补充少量常用域名。
 * 生成日期：{{DATE}}
 * ------------------------------------------------------------ */
var CN_DOMAINS =
{{DOMAINS}};

/* 手动添加的海外代理域名（明确走代理，不回退直连）
 * 生成日期：{{DATE}} */
var PROXY_DOMAINS =
{{PROXY_DOMAINS}};

/* 国内顶级域：整域直连。
 * cn 覆盖 .cn / .com.cn / .net.cn / .gov.cn / .edu.cn 等全部后缀；
 * 其余为中文顶级域（.中国 .公司 .网络）。
 * 注：.top / .wang 同为国内注册局运营，但海外站点使用较多，故不列入。 */
var CN_TLDS = ["cn", "xn--fiqs8s", "xn--55qx5d", "xn--io0a7i"];

/* 本机与局域网后缀 */
var LOCAL_SUFFIXES = [".local", ".lan", ".home", ".internal", ".localhost", ".i-xx.top"];

/* 内网网段前缀（172.16.0.0/12 逐段列出，PAC 里没有位运算） */
var PRIVATE_PREFIXES = [
    "10.", "127.", "0.", "169.254.", "192.168.",
    "172.16.", "172.17.", "172.18.", "172.19.", "172.20.",
    "172.21.", "172.22.", "172.23.", "172.24.", "172.25.",
    "172.26.", "172.27.", "172.28.", "172.29.", "172.30.", "172.31."
];

var _cnMap = null;

function _startsWith(s, p) {
    return s.length >= p.length && s.substring(0, p.length) === p;
}

function _endsWith(s, p) {
    return s.length > p.length && s.substring(s.length - p.length) === p;
}

/* 首次调用时把域名表建为哈希表，之后复用 */
function getCnMap() {
    if (_cnMap !== null) { return _cnMap; }
    var map = {};
    var list = CN_DOMAINS.split("\n");
    var i;
    for (i = 0; i < list.length; i++) {
        if (list[i] !== "") { map[list[i]] = 1; }
    }
    for (i = 0; i < CN_TLDS.length; i++) { map[CN_TLDS[i]] = 1; }
    _cnMap = map;
    return map;
}

function isIpLiteral(host) {
    var i, ch;
    for (i = 0; i < host.length; i++) {
        ch = host.charAt(i);
        if (ch !== "." && (ch < "0" || ch > "9")) { return false; }
    }
    return host.length > 0 && host.indexOf(".") > 0;
}

function isPrivateIp(host) {
    var i;
    for (i = 0; i < PRIVATE_PREFIXES.length; i++) {
        if (_startsWith(host, PRIVATE_PREFIXES[i])) { return true; }
    }
    return false;
}

function FindProxyForURL(url, host) {
    if (!host) { return FALLBACK; }
    host = host.toLowerCase();
    /* 去掉 FQDN 末尾的点，例如 baidu.com. */
    if (host.charAt(host.length - 1) === ".") { host = host.substring(0, host.length - 1); }

    /* 1) IPv6（本机 / 链路本地）直连 */
    if (host.indexOf(":") >= 0) { return "DIRECT"; }

    /* 2) 单标签主机名：localhost、nas、路由器名等 */
    if (host.indexOf(".") < 0) { return "DIRECT"; }

    /* 3) 本机与局域网后缀 */
    var i;
    for (i = 0; i < LOCAL_SUFFIXES.length; i++) {
        if (_endsWith(host, LOCAL_SUFFIXES[i])) { return "DIRECT"; }
    }

    /* 4) 纯 IP 访问：内网直连，公网 IP 同样直连
     *    （IP 直连在国内基本是路由器面板、内网服务、国内 CDN 节点，
     *      走代理反而更容易连不上；如需改为走代理，把下一行换成
     *      return isPrivateIp(host) ? "DIRECT" : FALLBACK; ） */
    if (isIpLiteral(host)) { return "DIRECT"; }

    /* 5) 国内域名直连：逐级剥离子域，命中即直连 */
    var map = getCnMap();
    var labels = host.split(".");
    for (i = 0; i < labels.length; i++) {
        if (map[labels.slice(i).join(".")] === 1) { return "DIRECT"; }
    }

    /* 6) 手动添加的海外代理域名：明确走代理，不回退直连 */
    var proxyList = PROXY_DOMAINS.split("\n");
    for (i = 0; i < proxyList.length; i++) {
        if (proxyList[i] !== "" && host === proxyList[i]) { return PROXY_RULE; }
    }

    /* 7) 其余（海外站点）走代理，代理不通则直连 */
    return FALLBACK;
}
