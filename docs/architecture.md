# mczy 架構與設計

本文記錄 `mczy` 的內部運作:元件切分、Emacs 與引擎之間的溝通協定、組字顯示與操作邏輯,以及幾個關鍵設計取捨。
讀者預設已看過 [README](../README.md);這裡講的是「怎麼做到的」。

接縫層面的逐檔考據(McBopomofo controller 從前端剝離的細節、行號引用)另見
[`m0-seam-notes.md`](m0-seam-notes.md)。

---

## 整體架構

```
鍵盤
  │  按鍵
  ▼
┌─────────────────────────────────────────────┐
│ Emacs  (mczy.el - 純 elisp)                │
│   · 按鍵路由(接進 input-method-function)      │
│   · 游標旁 overlay 顯示組字/候選(終端可用)     │
│   · 候選鍵選字 / 游標移動回改                   │
└──────────────┬───────────────▲───────────────┘
               │ 餵 key         │ 回傳 state
               │   sexp over stdio(回合制)
               ▼               │
┌─────────────────────────────────────────────┐
│ mczy-engine  (自包 C++ binary,裝時編一次)   │
│   ├─ McBopomofo InputController  互動編輯狀態  │
│   ├─ Gramambular2                組句路徑搜尋  │
│   ├─ Mandarin / libFormosa       按鍵→注音音節 │
│   └─ McBopomofoLM + 詞庫          字詞與機率    │
└──────────────┬──────────────────────────────┘
               │  commit 後的純文字
               ▼
       emacs-everywhere
               │
               ▼
   Emacs 以外的任何視窗 / 應用程式
```

核心想法是**讓 Emacs 把系統耦合層整個吸收掉**。一般輸入法的痛點不在選字演算法,而在系統耦合:要向
IBus / IMKit / TSF 註冊、跑常駐 daemon、接 focus 協定、跟桌面搶熱鍵、要權限,而且每個平台一套完全不同的框架。
Emacs 本來就是一個有自己 buffer、自己游標、自己 commit 時機的文字環境——拿它當現成的 input host,就頂掉了系統那一層。
換來的唯一代價是引擎那顆 C++ binary 要在安裝時編譯一次。

### 元件職責

| 元件 | 歸屬 | 職責 |
| --- | --- | --- |
| `mczy.el` | 純 elisp | 按鍵路由、游標旁 overlay 顯示、候選鍵選字、commit、交棒給 emacs-everywhere |
| `mczy-engine` | C++ binary | 把下面四件外包重活包成一個 stdio 程式 |
| McBopomofo **InputController** | 重用 C++ | **互動編輯狀態機**:游標停在哪個 node、左移重選同音字、釘字後重走整句、Shift+左右拉區塊加詞、Backspace/Enter/Esc/聲調/標點的處理 |
| **Gramambular2** | 重用 C++ | 組句演算法:在 node 格子上走機率最高的路徑 |
| **Mandarin / libFormosa** | 重用 C++ | 把按鍵拼成合法注音音節 |
| **McBopomofoLM** + 詞庫 | 重用 C++ + 資料 | 提供有哪些字詞、各自的機率 |

> **關鍵認識:** Gramambular2 是「演算法」,不是「輸入行為」。真正讓「整句回改」成立的是
> **InputController** 那層——它既不是系統膠水(Emacs 不會幫你吸收掉),也不在斷句引擎裡。
> 它是這個專案真正的肉,所以**重用 McBopomofo 現成的 C++ controller**,而不是在 elisp 裡重寫一遍。
> (在 `fcitx5-mcbopomofo` 的原始碼裡,這個 controller 對應的類別叫 `KeyHandler`;詳見
> [`m0-seam-notes.md`](m0-seam-notes.md)。)

### 為什麼是 McBopomofo

要的不是「能打字」,而是小麥注音那個**整句打完 → 回頭改選同音字 → 整句重排 → 再送出**的手感。

這個手感的核心是 Gramambular2:你打的不是一個個已定案的字,而是一串**還沒 commit 的「讀音節點」格子**,
引擎在這個 lattice 上走出機率最高的整句。關鍵在於**每個節點都還記得自己的注音**——所以把游標移回某個位置
重選同音字時,引擎能就地重走路徑、讓後面的字跟著重排。

這一點說明了為什麼不走 pyim 或 liberime/RIME:它們有整句,但模型不同,給不出「節點層保留讀音、回頭就地改選」
的那種手感。也說明了為什麼**不能只靠 emacs-everywhere 的 buffer 編輯來補**——一旦變成 buffer 裡的純文字,
注音就丟了,只剩刪掉重打,沒有同音字改選。回改的能力住在引擎的組字狀態裡,不住在編輯器的文字裡。

而 McBopomofo 的引擎本身就是**乾淨拆開的開源專案**(已有 macOS 原生、fcitx5、PIME/Windows、Web/CLI 等多種前端),
所以直接用它的引擎,不必重造,也不必逆向它的 web/cli 協定。

---

## 溝通協定:sexp over stdio(回合制)

Emacs 與 `mczy-engine` 之間**不用 JSON**,直接用**類 Lisp 的 S-expression** 溝通。
Emacs 這側 `read` 進來就是可以直接 `car` / `nth` / `pcase` 的 Lisp 物件,中間沒有任何解析/轉換層,
零阻抗。C++ 那側也只是 print 括號,連 JSON library 都不必 link。

採**回合制**:Emacs 餵一個 key,engine 回這一回合的狀態——**0..N 個 state sexp + 一個 `(done …)` 終結**。
filter 用 `accept-process-output` 同步 `read` 到 `(done …)` 為止,不做非同步推送。

### Schema

> state 是**控制器的狀態機狀態**——一條攤平的組字字串 + 游標,候選只在選字狀態出現;逐 node 的注音與
> 路徑留在引擎的 grid 裡(回改靠它,但不必序列化、**不上線**)。這形狀來自實測引擎的對外契約,而非
> 一開始想像的「每個 node 帶自己的候選 + `active` 旗標」的 lattice;考據見 [`m0-seam-notes.md`](m0-seam-notes.md)。

送出(stdin),一行一個指令:

```lisp
(key "j")          ; 一般按鍵
(key left)         ; 具名鍵:left right up down home end space return esc backspace tab delete
(key left shift)   ; 後綴 shift / ctrl 加修飾鍵
(select 0)         ; 在選字狀態選第 N 個候選(0-based)
(reset)            ; 清空組字
```

回傳(stdout),一回合依序印出 0..N 個 state,最後一個 `(done …)` 收尾:

```lisp
(inputting (buffer "中文") (cursor 2))                       ; 組字中:整句字串 + 游標
(choosing  (buffer "中文") (cursor 1) (candidates "中文" "中" "終" "鐘" …))  ; 選字
(commit "鐘文")                                               ; 已定文字(送給 emacs-everywhere)
(marking (head "中") (marked "文") (tail "") (acceptable t))  ; Shift 標記加詞
(empty)                                                      ; 回到地基狀態
(done t)                                                     ; 終結;值 = 這個 key 是否被吃掉(t/nil)
```

- `cursor` 是 **codepoint 索引**(引擎內部是 UTF-8 byte offset,序列化時換成字元數,直接對齊 Emacs 字串索引)。
- 一個 key 可能吐出多個事件(例:commit 一段 + 進入新組字),所以要 `read` 到 `(done …)` 為止,別只取一個。
- `read` 一次拿一個 sexp,walk 一遍畫成游標旁的 overlay;選字狀態的 `candidates` 直接攤成數字選單。

> **唯一紀律:** C++ 吐出的字串裡,`"` 與 `\` 一定要 escape,否則含引號的候選字會讓 `read` 斷在半路。
> 這跟 JSON 要 escape 是同一件事,只是換個符號。落點在引擎的 state 序列化函式。

---

## 顯示與操作

- **啟用方式為 Emacs 正式輸入法**:`C-\`(`toggle-input-method`)或 `M-x set-input-method RET chinese-mczy RET` 開關;
  不是 minor mode。開啟後 mode line 顯示輸入法,再按一次 `C-\` 整個離開。
- **游標旁的 overlay 為唯一顯示路徑**:用 `after-string` overlay 把組字、候選、框選提示畫在游標附近。
  它在 GUI 與終端(`emacs -nw`)下都能用——這正對齊「任何有 Emacs 的機器都能打」的目標,包括 SSH
  進去的終端 Emacs(posframe 在那裡直接陣亡,after-string overlay 不會)。
- **候選鍵可自訂**,預設數字鍵選字;可設定成例如 `(setq mczy-candidate-keys "qweruiop")`,
  在選字狀態用 `q/w/e/r/u/i/o/p` 選前 8 個候選。終端下不需要滑鼠或像素定位。
  互動中也可用 `M-x mczy-set-candidate-keys` 設定並立即重畫候選列。
- **候選分頁**:engine 一次吐全部同音字,前端每頁顯示 `mczy-candidate-keys` 個 + `[頁/總頁]` 指示;
  `PageDown` / `PageUp` 翻頁(只在選字狀態作用,否則照常 fall through),候選鍵選的是**當前頁**對應的字。
  打冷僻字也選得到,不再卡在前 N 個。
- **框選加入自訂字庫**:組字時 `Shift+←` / `Shift+→` 框選一段(2-8 字、且尚未在詞庫中),overlay 顯示
  `head[marked]tail` 與可否加入;按 `Enter` 把該詞加進 `mczy-user-phrases-path`
  (預設 `~/.emacs.d/mczy-user-phrases.txt`),engine 立即 reload → 該詞當下就選得到、並提升其排序。
  自加詞無詞庫授權問題(是使用者自己的資料)。引擎以第三個參數收這個檔路徑。
- 組字中的游標移動支援左右鍵,也支援 Emacs 習慣的 `C-b` / `C-f`。
- 未 commit 的組字顯示在游標旁的 overlay,目標 buffer 只在 commit 後收到純文字,不會被組字中途污染。
- posframe 留作 **GUI 下的選配**,不是基礎。
- **要顧的 corner case:** overlay 貼著游標畫,所以在 minibuffer 裡打中文(`M-x`、isearch、各種 prompt)時,
  組字會直接顯在 minibuffer 那一行——不像舊的底部 buffer 得另開窗跟 echo area 搶地。剩下的只是「IM 在
  minibuffer 裡能正常組字、離開時清乾淨」(`mczy--exit-from-minibuffer`)。打進一般 buffer 或 everywhere
  buffer 沒這問題。(isearch 不走一般 command loop 的 `input-method-function`,而是委派給一個
  inherit-input-method 的 `read-string` minibuffer,所以 isearch ⊆ minibuffer。)

### 中英快速切換:雙空格 toggle

**不變式:mczy 輸入法開著時連按兩下空格 → 切到 self-insert;self-insert 裡連按兩下空格 → 切回注音。** 雙向對稱。
定位是**短英文插入**(打個英文詞、縮寫、人名);要打長篇英文,直接用內建 `toggle-input-method`(`C-\`)整個離開 mczy,不靠這條。

關鍵:**第一下空格不吞**,照常交給 engine——

- 有 pending 組字時,第一下空格本來就是叫**選字單**(McBopomofo 既有行為);
- 無 pending 時照常。

**第二下**連續空格才是 toggle。所以不必 hold/延遲第一個空格(沒有 latency 問題),只要一個**連續空格計數器**:
空格 +1、任何非空格鍵歸零、到 2 觸發切換。

- **注音 → self-insert:** 第二下空格觸發切換。若此時有 pending 組字,**先把目前整句 commit 出去**,再留**一個半形空格**當分隔,然後切到 self-insert。
- **self-insert → 注音:** 兩下空格都是真的 self-insert 進 buffer,切回時**收斂成一個半形空格**當分隔(對應 sis `sis-inline-tighten-tail-rule 'one`),然後切回注音。

兩個方向的分隔都是**一個半形空格**(ASCII space,非全形)。

借 [`sis`(emacs-smart-input-source)](https://github.com/laishulu/emacs-smart-input-source) 的相鄰空格偵測手法,但策略改成對稱
(sis 預設不對稱:單空格進英文、雙空格出)。為什麼是 routing rule 而非獨立子系統:sis 切 OS 輸入源,mczy 自己就是輸入法、
沒 OS 源可切——「切 self-insert」= 暫停把鍵餵進 engine,「切回注音」= 恢復路由,正是按鍵路由本來就要做的事。

> 唯一代價:字面連續雙空格在 mczy 開著時被佔成 toggle(短英文情境罕見;長英文本來就該離開 mczy)。
> 其餘 sis 設計(自動偵測游標前後語言、cursor color、respect prefix 等)在 Emacs 內建輸入法架構下差別不大,不移植。

---

## 三層可編輯(相較系統 IME 的額外好處)

同一段文字,`mczy` 給你三層可編輯,塞在一般文字框裡的小麥只有第一層:

1. **IM 未 commit 組字格** - 同音字回改、整句重排(Gramambular2)
2. **buffer 層** - 自由編輯
3. **emacs-everywhere 送出前** - 整體檢查再送

---

## 設計決策(以及為什麼不那樣做)

- **不用 JSON,用 sexp** - Emacs 當 client,sexp 跟 `read` 天作之合;通用性在這裡沒用,反而是成本。
- **不做 Emacs dynamic module,做獨立 stdio 程序** - module 會把每平台 ABI 耦合加回來,還會在 crash 時拖垮整個 Emacs,正好打到想躲的點。獨立程序讓後端可換,elisp 那側不管後端是 C++ 還是別的都一樣。
- **不堅持純 elisp** - 現代 Emacs(vterm / treesit / pdf-tools / LSP …)早就是「elisp 當膠水、重活外包原生程式」的生態。把選字引擎外包是這條主線,不是例外。
- **不用 pyim / RIME 當引擎** - 給不出小麥那種節點層回改的手感(見上)。
- **不以 posframe 為基礎** - 它靠 GUI child frame,終端生不出來,跟核心動機衝突;留作 GUI 選配。
- **照抄 Emacs 內建 `quail.el` 的同型結構** - `input-method-function` 入口 + composition-time keymap + 組字導引顯示,
  mczy 只把翻譯外包給 engine、用游標旁的 overlay 當組字導引(quail 用 echo area / 底部 buffer)。
