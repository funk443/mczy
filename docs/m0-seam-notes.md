# M0 — `fcitx5-mcbopomofo` 接縫筆記

> 任務:讀 [`fcitx5-mcbopomofo`](https://github.com/openvanilla/fcitx5-mcbopomofo),帶著 README「第一步」列的三個問題,把 C++ 那側的成本從估算變成已知,消掉最後一個未知量。
>
> **來源版本(citation 全部釘在這顆 commit):** `c29fd08` (2026-06-10)。所有 `檔名:行號` 皆對應此版,行號會隨上游漂移,引用時請對齊此 commit。
>
> **命名對照(讀 M1 前先記住):** README 講的「InputController」**在這個 repo 裡叫 `KeyHandler`**(`src/KeyHandler.{h,cpp}`)。literal 的 `InputController` 類別是 McBopomofo 的 **macOS IMKit 前端**,不在本 repo;它在這裡的對應物是 fcitx5 前端類別 `McBopomofoEngine`。本筆記凡提「controller」皆指 `KeyHandler`。

---

## 結論先講(TL;DR)

1. **純度高、接縫乾淨。** 互動編輯狀態機(`KeyHandler`)、按鍵型別(`Key`)、狀態物件(`InputState`)、斷句引擎(`Engine/*`)**完全沒用到 fcitx5 型別**,可原封搬進 `mczy-engine`。
2. **唯一非平凡的 fcitx 耦合在「資料路徑解析」**:`PathCompat.h` 包 `fcitx::StandardPath` 去找詞庫/LM 資料檔與使用者目錄,`LanguageModelLoader` 靠它載入 LM。mczy-engine 要把這層換成自己的路徑邏輯(CLI 參數 / env / 固定安裝路徑)。約 25 行 + 幾個呼叫點,是工作量不是賭注。
3. **狀態接縫是一個 callback,不是 return value。** `KeyHandler::handle()` 不回傳 state,它在產生新狀態時呼叫注入的 `StateCallback`。前端(`McBopomofoEngine::enterNewState`)在這個 callback 裡用一條 `dynamic_cast` 鏈把 state 攤給 fcitx。**mczy 把這條鏈整條換成「印 sexp 到 stdout」即可。**
4. **README 的 sexp 草案 schema 對不上引擎真正的輸出契約**,需據本筆記重訂(見 §4)。真正的契約是:**state 是 tagged union**(扁平 `composingBuffer` 字串 + byte `cursorIndex`,候選清單只在 choosing 狀態出現),不是 README 想像的「每個 node 帶自己的候選 + `(active t)`」的 lattice。

---

## Q1 — controller 的純度

### 接縫地圖(`src/` 非測試檔,是否 reference fcitx)

| 檔案 | fcitx? | 對 mczy 的意義 |
| --- | --- | --- |
| `InputState.{h,cpp}`、`Key.h`、`InputMode.h`、`Format.h`、`NumberInputHelper.*`、`InputMacro.*`、`TimestampedPath.*` | 純 | 原封搬走 |
| `Engine/*`(`gramambular2`、`Mandarin`、`McBopomofoLM`、`UserOverrideModel`、`ParselessLM` …) | 純(上游共用引擎庫) | 原封搬走;這就是 README 要重用的引擎 |
| `KeyHandler.{h,cpp}` | 「reference」**僅止於註解** | **實質為純 C++**,可搬走(見下) |
| `Log.{h,cpp}` | `Log.h` 包 `fcitx-utils/log.h` 的 `FCITX_LOGC` 巨集 | 換成 `fprintf(stderr,…)`,一個檔 |
| `PathCompat.h` | `fcitx::StandardPath` | **要重接**:資料路徑解析(見下) |
| `LanguageModelLoader.{h,cpp}` | `.cpp` 透過 `PathCompat` 解析路徑 | **要重接或繞過**:建 LM 的入口 |
| `DictionaryService.{h,cpp}` | i18n + `fcitx::startProcess`(xdg-open)+ locate | 選配功能(查外部辭典),spike 可丟空實作 |
| `McBopomofo.{h,cpp}` | **整個就是 fcitx 前端** | **不搬**;它的職責由 `mczy.el` + sexp 序列化取代 |

判定方式(這份 grep 就是「纏住多少」的可引證答案):

```
$ grep -lE '\bfcitx' src/*.h src/*.cpp   # 排除 *Test.cpp;Engine/ 為上游純引擎
```

### `KeyHandler` 實質是純的

`KeyHandler.{h,cpp}` 裡所有 `fcitx`/`FCITX` token 都是**註解**——`KeyHandler.h:69`(一句過時的 "Given a fcitx5 KeyEvent" 註解,實際參數是本地 `Key` 型別)、`KeyHandler.cpp:542`、`KeyHandler.cpp:1447`。**沒有任何 fcitx 型別出現在邏輯裡。** grep 把 `KeyHandler.cpp` 標成 coupled,只是因為它 `#include "Log.h"`(日誌巨集)+ 註解字串命中。

設計上它本來就是前端無關的:

- 建構子(`KeyHandler.h:58-62`)吃的全是引擎/抽象型別:`LanguageModel`、`VariantAnnotator`、`UserPhraseAdder`、`LocalizedStrings`——**沒有任何 fcitx context**。
- `LocalizedStrings`(`KeyHandler.h:333-366`)是**依賴注入的純虛介面**,作者註解明寫「so that KeyHandler itself is not concerned with how localization is implemented」。在地化字串由前端提供,正是為了讓 controller 不沾前端。
- `Key`(`Key.h:35-85`)是自包 struct(`ascii` + `KeyName` enum + shift/ctrl 旗標),註解明說它**只反映 KeyHandler 要處理的鍵,不試圖代表任何通用 IME 框架的鍵狀態**。fcitx → `Key` 的轉換留在前端(見 Q3 的 `MapFcitxKey`)。

### 唯一非平凡的耦合:資料路徑解析

要建一個 `KeyHandler`,得先有 LM。前端的接法是:

```
LanguageModelLoader → getLM() / getVariantAnnotator() → new KeyHandler(...)   // McBopomofo.cpp:466-471
```

而 `LanguageModelLoader.cpp` 靠 `PathCompat.h` 找資料檔:

- `PathCompat.h:36-58` — `fcitx5_compat::locate(path)` = `fcitx::StandardPath::global().locate(PkgData, …)`;`userDirectory()` 同理。
- `LanguageModelLoader.cpp:54,62,64,74` — 用 `locate()` 找內建 LM、PUA/變體表、associated-phrases 資料。
- `LanguageModelLoader.cpp:84` — 用 `userDirectory()` 找使用者詞庫目錄。

**這是 M1 唯一要動腦的 C++ 成本**,而且很小:把 `PathCompat`(~25 行)換成 mczy 自己的路徑邏輯(編譯時固定安裝路徑 / CLI 參數 / env var),`LanguageModelLoader` 其餘照用;或者更省,spike 階段直接拿資料檔路徑構造 `ParselessLM`/`McBopomofoLM`,繞過 `LanguageModelLoader`。`DictionaryService` 同類耦合(`DictionaryService.cpp:26-28,100,148`),但它是「查辭典」選配功能,spike 給 `KeyHandler` 注入一個空的 `DictionaryServices` 即可。

**量化:** 要對 stdio 講 sexp 的最小可行引擎,需要重接的 fcitx 耦合 ≈ `PathCompat.h` + `Log.h` 兩個小檔的替換,加上「不搬 `McBopomofo.{h,cpp}`、改由 elisp 負責」。引擎邏輯本身(`KeyHandler` + `InputState` + `Engine/*`)零改動。

---

## Q2 — 狀態接縫在哪(= 我們吐 `(state …)` 的位置)

### 接縫是一個注入的 callback,不是回傳值

`KeyHandler` 不回傳狀態。它在產生新狀態時呼叫前端注入的 callback(`KeyHandler.h:64-66`):

```cpp
using StateCallback = std::function<void(std::unique_ptr<McBopomofo::InputState>)>;
using ErrorCallback = std::function<void(void)>;   // = beep / 出錯訊號
```

前端在 `keyEvent` 裡把這個 callback 接成「進入新狀態」的入口(`McBopomofo.cpp:884-891`):

```cpp
keyHandler_->handle(MapFcitxKey(key, origKey), state_.get(),
    [this, context](std::unique_ptr<InputState> next) {
      handleStateOrSequence(context, std::move(next));   // → enterNewState
    },
    [](){ /* beep? */ });
```

**所以 mczy 的接法非常直接:把 `StateCallback` 實作成「序列化這個 `InputState` 成 sexp、印到 stdout」。** 這就是 `(state …)` 吐出的位置,不必改 `KeyHandler` 一行。

### 攤狀態的那條 `dynamic_cast` 鏈(mczy 要照抄的對象)

`McBopomofoEngine::enterNewState`(`McBopomofo.cpp:1497-1561`)是中央派發點:對 `InputState` 的具體子型別做一條 `dynamic_cast` 鏈,每個分支呼叫對應 handler,把狀態攤給 fcitx 的 API。fcitx 的輸出呼叫點 = mczy 改印 sexp 的點:

| `InputState` 子型別 | handler | fcitx 輸出呼叫 | mczy 對應 sexp |
| --- | --- | --- | --- |
| `Committing` | `handleCommittingState` (`:1594`) | `context->commitString(text)` (`:1600`) | `(commit "…")` |
| `Empty` | `handleEmptyState` (`:1575`) | 若前一狀態是 `NotEmpty`,`commitString(prev->composingBuffer)` (`:1581`);reset panel | commit 前一段 + 清空 |
| `EmptyIgnoringPrevious` | `:1586` | 只 reset,不 commit | 清空(丟棄前狀態) |
| `Inputting` | `handleInputtingState` (`:1605`) | `updatePreedit` | `(inputting …)` |
| `ChoosingCandidate` 及另外 ~9 個帶候選的狀態 | `handleCandidatesState` (`:1613`) | 建 `fcitx::CommonCandidateList` + `updatePreedit` | `(choosing … (candidates …))` |
| `Marking` | `handleMarkingState` (`:1841`) | preedit 分 head/marked/tail 上色 | `(marking …)` |

`updatePreedit`(`McBopomofo.cpp:1912-1940`)就是把 `NotEmpty` 攤成 preedit 的地方,**確認了扁平字串模型**:

- preedit = `state->composingBuffer`(整句一條字串)+ `setCursor(state->cursorIndex)`(`:1928,1930`)。**沒有逐 node 結構。**
- 整個前端**唯一**的逐段上色是 `Marking` 狀態的 head/markedText/tail(`:1920-1923`,marked 段套 `HighLight`)——那是 Shift+左右「標記詞加詞」用的,不是一般選字。
- `tooltip` → `setAuxDown`(底下一行輔助訊息)。

### 兩個會改寫 README「回合制」假設的協定發現

1. **一個 key 可能吐出多個 state event,不是一個。** callback 收到的可能是 `StateSequence`(`InputState.h:372-383`),由 `handleStateOrSequence`(`McBopomofo.cpp:1563-1573`)逐一拆開重入 `enterNewState`。**而且 commit 本身就是一個 state**(`Committing` → `commitString`;`Empty` 會 commit 前一段)。所以一個 key 很可能產生「commit 一段 + 進入新的 inputting 狀態」兩個事件。
   → **README 的「餵一個 key → 回一個完整 state」太窄。** 一個回合 = **0..N 個 state sexp + 一個 accepted bool**。協定必須有**回合結束標記**,讓 elisp 端 `read` 到回合關閉為止;若只 `read` 一個 sexp,會漏掉 commit。

2. **候選翻頁/選字邏輯住在前端膠水,不在 `KeyHandler` 裡。** 當候選面板開著時,`keyEvent` 走的是另一條路(`McBopomofo.cpp:827-882`):`handleCandidateKeyEvent` 配合 fcitx `CommonCandidateList` 做「選字鍵 → 索引」對應與翻頁。`KeyHandler` 這側對外的入口是 `candidateSelected(candidate, originalCursor, stateCallback)`(`KeyHandler.h:87-89`)。
   → mczy 要在 elisp 重做這層很薄的翻頁/選字鍵對應,乾淨的接法:`(select N)` → engine 呼叫 `keyHandler_->candidateSelected(candidates[N], originalCursor, stateCallback)`。(詳見 Q3。)

---

## Q3 — 按鍵進去的形狀(= stdin 餵 key 後該 `read` 回什麼)

### controller 入口

```cpp
// KeyHandler.h:73-74
bool handle(Key key, McBopomofo::InputState* state,
            StateCallback stateCallback, ErrorCallback errorCallback);
```

- **輸入:** 一個本地 `Key`(非 fcitx 型別)+ 當前 state 指標 + 兩個 callback。
- **回傳 `bool`:** `true` = 這個 key 被吃掉(已處理),`false` = 放行讓它穿透(`KeyHandler.h:69-72`)。**這就是「吃掉了沒」。**
- **「要不要重畫」** 不靠回傳值,靠 `stateCallback` 有沒有被呼叫、以及被呼叫幾次(見 Q2:可能 0..N 次)。

### fcitx → `Key` 的轉換(mczy 換成 sexp → `Key`)

前端進入點 `McBopomofoEngine::keyEvent`(`McBopomofo.cpp:781-897`)做的事,就是 mczy-engine 的 stdin 迴圈要做的事:

1. 濾掉 release 事件與 Alt/Super 組合(`:787,795`)——這些「放行/不處理」。
2. `MapFcitxKey(key, origKey)`(`McBopomofo.cpp:64-189`)把 `fcitx::Key` 轉成本地 `Key`:處理 CapsLock、把方向鍵/Home/End/Backspace/Return/Esc/Space/Tab/數字小鍵盤對應到 `Key::KeyName` 或 ascii。
3. 若候選面板開著 → 走 `handleCandidateKeyEvent`(`:853`);否則 → `keyHandler_->handle(...)`(`:884`)。
4. 依 `handle` 回傳的 `accepted` 決定 `keyEvent.filterAndAccept()`(吃掉)或不動(放行)(`:893-896`)。

**對 mczy 的意義:** stdin 收到 `(key …)` → engine 把它建成 `Key`(等同 `MapFcitxKey` 的反向、但來源是 elisp 已分類好的鍵)→ 呼叫 `handle` → `StateCallback` 印出 0..N 個 `(state …)`/`(commit …)` → 最後印出回合終結 + accepted 旗標(elisp 據此決定要不要把鍵放給 Emacs 自己處理)。

---

## §4 — 由接縫推出的 sexp schema(給 M0→M1 的「schema 定案」橫向工作流)

> 這不是定案,是「接縫長這樣,所以 schema 該長這樣」。M1 動工前的 schema 定案直接吃這節。

### stdin(Emacs → engine)

維持 README 草案,但補上候選選字的真實接法:

```lisp
(key "j")          ; ascii
(key left)         ; 具名鍵:left/right/up/down/home/end/backspace/return/esc/space/tab
(key left shift)   ; 修飾鍵:shift/ctrl(對應 Key.shiftPressed/ctrlPressed)
(select 2)         ; 在 choosing 狀態選第 N 個候選 → keyHandler_->candidateSelected(candidates[N], originalCursor, cb)
(reset)            ; 對應 KeyHandler::reset()
```

### stdout(engine → Emacs)— **改成 state tagged union,而非 per-node lattice**

state 是「狀態機的當前狀態」,不是「lattice 的逐 node dump」。lattice / 逐 node 的注音保留在 engine 的 `grid_` 裡(回改靠它),**不外露**;外露的是攤平後的 `composingBuffer` + cursor,候選清單只在 choosing 狀態出現:

```lisp
(empty)                                         ; Empty / EmptyIgnoringPrevious
(commit "住在")                                  ; Committing.text(或 Empty 時 commit 前一段)
(inputting (buffer "住在") (cursor 2))           ; Inputting:整句攤平字串 + cursor
(choosing (buffer "住在") (cursor 2)             ; ChoosingCandidate
          (candidates ("住" "煮" "築"))
          (original-cursor 1))
(marking (head "住") (marked "在這") (tail "")   ; Marking:唯一帶逐段上色的狀態
         (cursor 3) (acceptable t))
```

一個回合 = 依序印出的多個上述 sexp + 一個終結標記(例:`(done t)` 或 `(accepted t)` / `(accepted nil)`)。elisp 端 `read` 直到讀到終結標記。

### 三個必須在定案時釘死的細節

1. **`cursorIndex` 是 UTF-8 byte offset,不是字元數。** `getComposedString` 明寫 "UTF-8 (so \"byte\") cursor per fcitx5 requirement"(`KeyHandler.cpp:1446-1447`)。但 Emacs `read` 回來的字串是**字元索引**。→ **engine 序列化時就把它換成 codepoint 索引再印**(C++ 端對 head 子字串算 `CodePointCount` 即可),別把 byte offset 丟給 elisp。
2. **「active node 上色」README 想要、但前端契約沒給。** 一般 `Inputting`/`ChoosingCandidate` 的 preedit 只有整句字串 + cursor,沒有 node 邊界。要做 README 講的「`active` node 套 highlight」,有兩條路:(a) 比照 fcitx,只在 cursor 處示意 + 另開候選清單;(b) 低成本擴充——`ChoosingCandidate` 已知 `originalCursor`、每個候選帶 `reading`,engine 可額外吐出 active node 的 span(起訖 codepoint),讓 mczy.el 精準上色。建議 (b),因為 README 明確要這個手感。
3. **escape 紀律(README 已標,重申並落到序列化點):** `commitString`/候選字串裡含 `"` 與 `\` 必須 escape,否則 `read` 會斷在半路。落點就是 `StateCallback` 的序列化函式。

---

## 對里程碑與待決事項的影響

- **M1(engine spike)的 C++ 成本已知且低:** 重用 `KeyHandler` + `InputState` + `Engine/*`(零改),只需(a)替 `PathCompat`/`LanguageModelLoader` 換資料路徑來源,(b)stub `Log.h`,(c)寫 `StateCallback`/`ErrorCallback` 的 sexp 序列化,(d)stdin 的 `(key …)`/`(select …)` → `Key`/`candidateSelected` 解析迴圈,(e)注入空的 `DictionaryServices` 與一份 `LocalizedStrings` 實作(可給最小可用字串)。
- **協定 schema 定案(橫向):** 用 §4。重點修正:state 改 tagged union、一回合 0..N 事件需終結標記、cursor 改 codepoint、候選選字走 `(select N)` → `candidateSelected`。
- **授權確認(橫向、M1 前阻斷項):** 本筆記未碰授權,維持 README/plan 的 OPEN。`KeyHandler`/`Engine` 程式碼皆帶 MIT 風格 header(`KeyHandler.h:1-22`),詞庫授權仍須與上游確認。
- **OPEN — 引擎執行檔名(`mczy-engine` vs `mczyd`):** 本筆記不決定,維持 OPEN。
