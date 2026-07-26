# 麥注 mczy — 專案執行規劃

> **設計的真實來源是 [`README.md`](README.md)**(動機、架構、sexp-over-stdio 協定、設計決策)。
> 本檔只負責**執行與追蹤層**:里程碑、產出、驗收條件、依賴、風險。設計細節一律連回 README,不重述。
> 兩者若有出入,**以 README 為準**,並回頭修正本檔,避免出現第二份會漂移的真相。

---

## 現況

**early-alpha:可行性已鎖定,M2 已跑通。** 關鍵路徑 `M0 → M2` 已走完——接縫靠讀碼消除(M0),
由一個跑通選字/回改/整句重排/commit 的獨立引擎證實(M1),並由 elisp 前端證實一般 buffer 內的 M2 顯示/選字/commit 路徑。
後面兩步是工程,不是賭注。

```
M0 讀碼 ✅ ──→ M1 engine spike(★ 閘門)✅ ──→ M2 elisp 顯示 ✅ ──→ ▶ M3 按鍵路由 ──→ M4 接 everywhere
        │                                                │
        └── 橫向:授權確認 ✅ · 協定定案 ✅ · build/打包(CMake 已立) · 測試策略(已起步)
```

---

## 里程碑

> 驗收條件全部取自 README 既有的成功訊號,未自行發明。各里程碑詳見 README「開發路線」一節。

### M0 — 讀 `fcitx5-mcbopomofo`,消掉最後一個未知量 ✅ **已完成**
- **產出已交付:** [`docs/m0-seam-notes.md`](docs/m0-seam-notes.md)(釘在上游 commit `c29fd08`)。三個接縫問題皆有可指到原始碼位置的答案;另發現 README sexp 草案需改為 state tagged union(見筆記 §4)。
- **目標:** 把 C++ 那側的成本從估算變成已知。
- **產出:** 一份接縫筆記,回答 README 列的三個問題——
  ① controller 的純度(多少純 C++ 可原封搬走 vs. 與 fcitx5 型別纏住的量);
  ② 狀態接縫在哪幾個呼叫點(= 我們吐 `(state …)` 的位置);
  ③ 一個 keyevent 餵進 controller 的入口/回傳形狀(= stdin 餵 key 後該 `read` 回什麼)。
- **驗收:** 三個問題都有具體、可指到原始碼位置的答案;sexp 協定 schema 可據此定案(見橫向工作流)。
- **依賴:** 無。**這是起點。**
- **風險:** 低——純讀碼。唯一變數是接縫比預期髒,但那只是把工作量算清楚,不改變可行性。

### M1 — spike `mczy-engine`(★ 可行性閘門) ✅ **已通過**
- **產出已交付:** [`engine/`](engine/) — 獨立 binary `mczy-engine`,重用 `KeyHandler`+`Engine/*`(上游 submodule,釘 `c29fd08`,未改一行),對 stdio 講 sexp。
- **驗收已過:** [`engine/test_roundtrip.sh`](engine/test_roundtrip.sh) — 餵 `5j/ jp6` → 「中文」→ 游標左移 → 空白叫候選 → 選同音字「鐘」→ **整句重排成「鐘文」** → commit「鐘文」。選字/回改/整句重排/commit 全通。**可行性鎖定。**
- **接法:** fcitx 耦合全壓在 `McBopomofo.cpp`,本步以 `main.cpp`(sexp 迴圈)+ ~15 行 fcitx-shim 標頭取代,引擎碼零改動。詳見 [`engine/README.md`](engine/README.md)。
- **目標:** 把 Gramambular2 + Mandarin + McBopomofoLM + 重用的 `InputController` 連成一個獨立 binary,對 stdio 講 sexp。
- **產出:** 一個能跑的 `mczy-engine`:stdin 餵 key,stdout 回完整 `(state …)`,`commit` 吐 `(commit "…")`。
- **驗收:** **餵一串 key → `read` 回完整 state → 選字/回改/commit 跑得通。這一步成立,可行性就鎖定。**
- **依賴:** M0(接縫與協定定案)。
- **風險:** 全專案最高,但這正是把它排第二的理由——失敗要在這裡失敗,不要拖到後面。

### M2 — elisp 顯示骨架 ✅ **已完成**
- **產出已交付:** [`mczy.el`](mczy.el) — M2 frontend rewrite:process/filter/pending stream framing、state parser、底部組字 buffer renderer、自訂候選鍵、左右/`C-b`/`C-f` 游標回改、commit 插字;[`test-mczy.el`](test-mczy.el) — ERT self-check,含真 engine smoke。
- **驗收已過:** `emacs --batch -l test-mczy.el`(15/15 tests)、`emacs --batch -f batch-byte-compile mczy.el`、`./engine/test_roundtrip.sh`。真 engine smoke 跑通「中文」→ 回改候選「鐘」→ 整句重排「鐘文」→ commit。
- **目標:** 底部專屬組字 buffer + 候選鍵選字,先在**一般 Emacs buffer** 裡把組字回改跑通(先不接系統輸入法機制)。
- **產出:** `mczy.el` 雛形:walk engine 回的 state 樹、畫底部 buffer、`active` node 套 highlight、數字選字、游標左右移回改。
- **驗收:** 在一般 buffer 裡能完成「整句打完 → 回頭改選同音字 → 整句重排 → commit」。
- **依賴:** M1(要有 engine 回 state 才有東西可畫)。顯示機制可參考 pyim。
- **風險:** 中。

### M3 — 按鍵路由
- **目標:** 接進 `input-method-function` / `toggle-input-method`,組字中攔下 `self-insert`,處理 corner case。
- **產出:** isearch / minibuffer / `C-g` / focus 切換 都不爆;minibuffer 打字時狀態窗改放一般窗(README「顯示與操作」列的 corner case)。
- **驗收:** 在上述各情境切進切出輸入法都不殘留、不卡死、不誤吞鍵。
- **規劃中納入(雙空格中英 toggle):** 不變式——mczy-mode 內連按兩下空格 → self-insert;self-insert 內連按兩下空格 → 切回注音(雙向對稱)。
  **第一下空格不吞**,照常給 engine(有 pending → 叫選字單;無 pending → 照常),**第二下**連續空格才 toggle ⇒ 不必延遲第一個空格,只要一個連續空格計數器(非空格鍵歸零)。
  切換已定案:**注音→self-insert** 先把目前整句 commit 出去、再留一個半形空格;**self-insert→注音** 把雙空格收斂成一個半形空格。兩向分隔都是**一個半形空格**(ASCII,非全形)。
  定位短英文插入;長英文直接 `toggle-input-method` 離開 mczy-mode。設計見 [`README.md`](README.md)「顯示與操作 › 中英快速切換」。借 sis 的相鄰空格偵測,但策略對稱(sis 預設不對稱:單空格進、雙空格出);mczy 沒有 OS 輸入源,故實作為**一條 routing rule**(暫停/恢復把鍵餵進 engine),正好落在本里程碑的按鍵路由裡。
  讀碼參考:`~/.emacs.d/straight/repos/emacs-smart-input-source/sis.el` 的 `sis--inline-check-to-activate` /
  `sis--inline-fly-check-deactivate` / `sis--inline-deactivate`(相鄰雙空格判斷在 `(+ 2 back-to) = point`、tighten-tail 留一空格)。
- **拆包:** **M3a** 核心路由(`register-input-method` + `input-method-function` + composition-time keymap + `(done nil)` fall-through + commit,一般 buffer 跑通)→ **M3b** corner cases(isearch / minibuffer / `C-g` / focus,多為接框架既有 hook)→ **M3c** 雙空格 toggle(內部旗標)。M2 的 render/parse/process/commit 核心保留,只換掉「啟動 + 攔鍵」層(刪全域 emulation-keymap 機制 → 順手化解 org/evil 互搶)。
- **依賴:** M2。
- **真正風險:** 同步 `accept-process-output` 的 engine round-trip 塞在 `input-method-function` 裡會不會卡——`quail`(純 elisp)不阻塞、**不是**這條的範本;阻塞範本看 pyim-with-daemon / ddskk-server。M3a 要在一般 buffer 正面證實,M3b 再到 minibuffer/isearch 壓測。
- **紀律:別自己發明。** 主範本是 Emacs 內建 `quail.el`(同型:`input-method-function` 入口 + translation keymap + guidance buffer,翻譯外包給 engine、bottom buffer = guidance buffer);次要 ddskk / pyim / egg-tamago。空格中英切換照抄 sis。

### M4 — 接 emacs-everywhere
- **目標:** commit 後的純文字交給 emacs-everywhere 送進 Emacs 以外的視窗。
- **產出:** commit → everywhere 的串接;三層可編輯(IM 組字格 / buffer / 送出前)走通。
- **驗收:** 在自己的桌面環境,從任一外部視窗叫出 mczy、打一句中文、送出成功。
- **依賴:** M3。
- **風險:** 低-中。Wayland 合成輸入那道牆仍在,但自己用只需在自己 compositor 上設定一次——是**設定問題,不是架構問題**。

---

## 橫向工作流(線性路線圖藏起來的東西)

| 工作流 | 狀態 | 備註 |
| --- | --- | --- |
| **授權確認** | ✅ 已解除 | 本專案自身程式碼為 MIT([`LICENSE`](LICENSE))。上游程式碼與詞庫 `data.txt` 同為 MIT,且**本 repo 不重新散布**——皆以 submodule 釘在上游 commit,由使用者自上游取得。套件名另取(`mczy`,不用 McBopomofo)以免與上游混淆。 |
| **協定 schema 定案** | ✅ 已定案 | M0 接縫筆記 §4 + M1 spike 實證形狀,已回寫進 README「溝通協定」取代草案(state tagged union,非草案的 per-node lattice)。 |
| **build / 打包** | 🟡 進行中 | engine CMake 已立,`cmake --build` 一鍵編出 binary(submodule + ICU,見 [`engine/README.md`](engine/README.md));elisp 可 byte-compile。尚缺:安裝時自動編 engine/elisp(對齊 vterm 體感)。 |
| **測試策略** | 🟡 進行中 | engine 回合制好測:[`engine/test_roundtrip.sh`](engine/test_roundtrip.sh);elisp M2 有 [`test-mczy.el`](test-mczy.el) 覆蓋 framing/render/commit/真 engine smoke/自訂候選鍵/`C-b`/`C-f`/org-mode keymap。尚缺:elisp 側 M3 corner case 可重跑清單。 |

---

## 待決事項(OPEN — 不猜,等資訊到位再定)

- ~~**OPEN — 授權條款(散布前阻斷項):**~~ **已解除。** 本專案 MIT;上游碼與詞庫同為 MIT 且不由本 repo 重新散布(submodule)。
- ~~**OPEN — 引擎執行檔名:**~~ **已定:`mczy-engine`。**
- ~~**OPEN — sexp 協定 schema:**~~ **已定案。** state 為 tagged union、一回合 0..N 事件 + `(done …)` 終結、cursor 用 codepoint、候選走 `(select N)`。實證形狀已回寫進 [`README.md`](README.md)「溝通協定」;依據見 [`docs/m0-seam-notes.md`](docs/m0-seam-notes.md) §4。

---

## 下一步

M0、M1、M2 已完成,**可行性已鎖定且 elisp 顯示骨架已跑通**(`mczy-engine` 與 `mczy.el`
皆跑通選字/回改/整句重排/commit)。接著:

1. **M3 — 按鍵路由**:接 `input-method-function` / `toggle-input-method`,組字中攔下 `self-insert`,處理 `(done nil)` fall-through、isearch / minibuffer / `C-g` / focus 切換等 corner case。
2. **M4 — 接 emacs-everywhere**:commit 後的純文字送進 Emacs 以外的視窗。
