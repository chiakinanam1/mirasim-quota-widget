# mirasim-quota-widget

给 [Mirasim](https://mirasim.ai) 桌面客户端加一个 **Apple 菜单栏风格的额度监视窗**:
标题栏常驻胶囊实时显示 5 小时 / 7 天窗口的额度消耗,点击弹出毛玻璃详情面板。

![标题栏胶囊](assets/pill.png)

![详情弹层](assets/popover.png)

## 功能

- **标题栏胶囊**:状态点 + 5h/7d 双迷你进度条 + 已用/总额度数值,30 秒实时刷新
- **详情弹层**(点击胶囊):
  - 大字号 已用/总量 与百分比
  - **均速参考标**:按窗口已流逝时间比例在进度条上打标,并给出「低于均速 x% / 超出均速 x%」
  - 秒级走动的重置倒计时
  - 失效切换(failover)启用时显示提示横幅
- **碰撞感知定位**:自动探测标题栏上的按钮/标签/分栏,停进空档,窗口布局变化实时避让
- **总额度自动校准**:后台任务定期抓取路由 `/v1/limits` 的原始 used/budget,套餐变化自动跟上
- **更新自愈**:mirasim 热更新到新版本目录后,维护任务 5 分钟内自动重新注入,无需手动重装
- 水墨单色设计,自动跟随明暗主题;**零额度消耗**(只读本地接口,无任何计费调用)

## 安装

```powershell
git clone https://github.com/chiakinanam1/mirasim-quota-widget.git
cd mirasim-quota-widget
powershell -ExecutionPolicy Bypass -File install.ps1
```

装完在 Mirasim 里按 `Ctrl+Shift+N` 开一个新窗口(旧窗口关掉即可)——
客户端生产版没有界面重载快捷键,新窗口会全新加载注入后的界面;会话不受影响。

### install.ps1 做了什么

1. 把 `quota-widget.js` 注入 `~/.mirasim/app/` 下**所有版本目录**的
   `renderer/index.html`(桌面)与 `web/index.html`(浏览器版,`http://127.0.0.1:4970`)
2. 注册计划任务 `MirasimQuotaBudget`(每 5 分钟,经 `silent.vbs` 静默运行 `probe-budget.ps1`):
   - 给新出现的版本目录自动补注入(热更新自愈)
   - 探测 Mirasim 路由端口,把 `/v1/limits` 的原始额度写到 `web/quota-budget.json` 供 widget 校准

## 卸载

```powershell
schtasks /Delete /TN MirasimQuotaBudget /F
```

然后删除各版本目录里 `index.html` 中带 `<!-- mirasim-quota-widget -->` 注释的一行、
`assets/quota-widget.js` 与 `web/quota-budget.json`(或等下次 mirasim 热更新自然冲掉)。

## 数据来源与原理

| 数据 | 来源 | 频率 |
|---|---|---|
| 用量百分比/重置时间 | 本地 WebSocket `ws://127.0.0.1:4970/ws` 的 `{type:"getRelay"}` | 30s |
| 总额度(budget) | 路由端口 `GET /v1/limits`(计划任务抓取 → 静态 JSON → widget 拉取) | 5min / 10min |

全部请求都在本机回环,不触发任何模型调用,不消耗账户额度。

## 微调

```js
localStorage.setItem('mqw.right', '200')     // 手动固定距右边缘 px(默认自动避让)
localStorage.setItem('mqw.top', '6')         // 手动固定距顶部 px
localStorage.setItem('mqw.budget5h', '42560')  // 手动覆盖总额度(默认自动校准)
localStorage.setItem('mqw.budget7d', '560000')
```

## 声明

非官方项目,依赖 Mirasim 未公开的本地接口与目录结构(截至 v0.0.223 可用),
新版本可能需要适配。仅在本机读取你自己的额度数据,风险自负。

MIT License
