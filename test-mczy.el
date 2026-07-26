;;; test-mczy.el --- Self-check tests for mczy.el -*- lexical-binding: t; -*-

;;; Commentary:
;; Run with:
;;   emacs --batch -l test-mczy.el
;;
;; The composition-path tests drive the real `input-method-function' entry:
;; events are queued in `unread-command-events' and read by the same
;; `read-key-sequence' loop the command loop would use (inside `translate',
;; `input-method-function' is bound to nil, so the queue is read raw -- exactly
;; the production path).  `execute-kbd-macro' is deliberately NOT used: keyboard
;; macros bypass `input-method-function', so they cannot exercise mczy.
;; Live GUI typing still needs a human to confirm by hand.

;;; Code:

(require 'ert)
(require 'org)

(let ((default-directory (file-name-directory (or load-file-name buffer-file-name))))
  (load (expand-file-name "mczy.el" default-directory) nil t))

(defmacro mczy-test--with-buffer (&rest body)
  "Run BODY in a temp target buffer with an isolated overlay."
  (declare (indent 0))
  `(let ((mczy--editing-buffer nil)
         (mczy--overlay nil))
     (unwind-protect
         (with-temp-buffer
           (setq mczy--editing-buffer (current-buffer))
           ,@body)
       (when (overlayp mczy--overlay)
         (ignore-errors (delete-overlay mczy--overlay))))))

(defun mczy-test--overlay-text ()
  "Return the candidate overlay after-string, or empty string."
  (if (overlayp mczy--overlay)
      (or (overlay-get mczy--overlay 'after-string) "")
    ""))

(defun mczy-test--type (events)
  "Drive one composition session typing EVENTS, a list of input events.
Return the result events the input method hands back to the command loop."
  (let ((unread-command-events (copy-sequence (cdr events))))
    (mczy--input-method (car events))))

;;; Pure unit tests (no engine)

(ert-deftest mczy-read-forms-keeps-incomplete-tail ()
  (let ((pending "")
        (forms nil))
    (dolist (chunk '("(input" "ting (buffer \"中" "文\") (cursor 2))\n"
                     "(done nil)\n"))
      (pcase-let ((`(,new-forms . ,rest)
                   (mczy--read-forms (concat pending chunk))))
        (setq forms (append forms new-forms)
              pending rest)))
    (should (equal forms
                   '((inputting (buffer "中文") (cursor 2))
                     (done nil))))
    (should (string= pending ""))))

(ert-deftest mczy-apply-state-and-render ()
  (mczy-test--with-buffer
    (mczy--apply-states
     '((inputting (buffer "中文") (cursor 2))))
    (should (eq mczy--state 'inputting))
    (should (string= mczy--preedit "中文"))
    (should (= mczy--cursor 2))
    (should (string-match-p "中文|" (mczy-test--overlay-text)))

    (mczy--apply-states
     '((choosing (buffer "中文")
                 (cursor 1)
                 (candidates "中文" "中" "終" "鐘"))))
    (should (eq mczy--state 'choosing))
    (should (equal mczy--candidates '("中文" "中" "終" "鐘")))
    (let ((text (mczy-test--overlay-text)))
      (should (string-match-p "中|文" text))
      (should (string-match-p "4: 鐘" text)))))

(ert-deftest mczy-apply-states-returns-commit-strings ()
  (mczy-test--with-buffer
    (let ((commits (mczy--apply-states '((commit "鐘文") (empty)))))
      (should (equal commits '("鐘文")))
      (should (eq mczy--state 'empty))
      (should (string= (mczy-test--overlay-text) "")))))

(ert-deftest mczy-custom-candidate-keys-render ()
  (let ((mczy-candidate-keys "qweruiop"))
    (mczy-test--with-buffer
      (mczy--apply-states
       '((choosing (buffer "中文")
                   (cursor 1)
                   (candidates "中文" "中" "終" "鐘"))))
      (let ((text (mczy-test--overlay-text)))
        (should (string-match-p "q: 中文" text))
        (should (string-match-p "r: 鐘" text))))))

(ert-deftest mczy-set-candidate-keys-refreshes-display ()
  (let ((mczy-candidate-keys "0123456789"))
    (mczy-test--with-buffer
      (mczy--apply-states
       '((choosing (buffer "中文")
                   (cursor 1)
                   (candidates "中文" "中" "終" "鐘"))))
      (should (string-match-p "3: 鐘" (mczy-test--overlay-text)))
      (mczy-set-candidate-keys "qweruiop")
      (let ((text (mczy-test--overlay-text)))
        (should (string-match-p "q: 中文" text))
        (should (string-match-p "r: 鐘" text))))))

(ert-deftest mczy-candidate-paging-render ()
  "Paged candidate display: one page of keys plus a [page/total] indicator."
  (let ((mczy-candidate-keys "012"))      ; page size 3
    (mczy-test--with-buffer
      (setq mczy--state 'choosing
            mczy--candidates '("a" "b" "c" "d" "e" "f" "g") ; 7 -> 3 pages
            mczy--page 0)
      (mczy--render)
      (let ((text (mczy-test--overlay-text)))
        (should (string-match-p "0: a" text))
        (should (string-match-p "2: c" text))
        (should-not (string-match-p ": d" text))
        (should (string-match-p "\\[1/3\\]" text)))
      (setq mczy--page 1)
      (mczy--render)
      (let ((text (mczy-test--overlay-text)))
        (should (string-match-p "0: d" text))
        (should (string-match-p "2: f" text))
        (should (string-match-p "\\[2/3\\]" text)))
      (setq mczy--page 2)                  ; last, partial page (1 item)
      (mczy--render)
      (let ((text (mczy-test--overlay-text)))
        (should (string-match-p "0: g" text))
        (should-not (string-match-p "1: " text))
        (should (string-match-p "\\[3/3\\]" text))))))

(ert-deftest mczy-candidate-layout-vertical ()
  "Vertical layout renders one candidate per line."
  (let ((mczy-candidate-keys "012")
        (mczy-candidate-layout 'vertical))
    (mczy-test--with-buffer
      (setq mczy--state 'choosing
            mczy--candidates '("甲" "乙" "丙")
            mczy--page 0)
      (mczy--render)
      (let ((text (mczy-test--overlay-text)))
        (should (string-match-p "0: 甲" text))
        (should (string-match-p "1: 乙" text))
        ;; vertical: candidates separated by newlines, not spaces
        (should (string-match-p "甲\n" text))
        (should (string-match-p "乙\n" text))))))

(ert-deftest mczy-candidate-page-move-wraps ()
  (let ((mczy-candidate-keys "012"))
    (mczy-test--with-buffer
      (setq mczy--state 'choosing
            mczy--candidates '("a" "b" "c" "d" "e" "f" "g")
            mczy--page 0)
      (should (mczy--page-move 1))  (should (= mczy--page 1))
      (should (mczy--page-move 1))  (should (= mczy--page 2))
      (should (mczy--page-move 1))  (should (= mczy--page 0)) ; wrap forward
      (should (mczy--page-move -1)) (should (= mczy--page 2)) ; wrap back
      ;; outside choosing, page-move declines (so the key falls through)
      (setq mczy--state 'inputting)
      (should-not (mczy--page-move 1)))))

(ert-deftest mczy-page-or-character-pages-or-inputs ()
  "j/k page while choosing; otherwise they fall to character input."
  (let ((mczy-candidate-keys "012")
        sent)
    (cl-letf (((symbol-function 'mczy--run-command)
               (lambda (cmd _fallback) (setq sent cmd))))
      (mczy-test--with-buffer
        (setq mczy--state 'choosing
              mczy--candidates '("a" "b" "c" "d" "e" "f" "g")
              mczy--page 0)
        (mczy--page-or-character 1) (should (= mczy--page 1))   ; page down
        (mczy--page-or-character -1) (should (= mczy--page 0))  ; page up
        (should-not sent)                       ; choosing: no key sent to engine
        ;; not choosing: behaves like normal input
        (setq mczy--state 'inputting)
        (let ((last-command-event ?j))
          (mczy--page-or-character 1))
        (should (equal sent '(key "j")))))))

(ert-deftest mczy-candidate-select-uses-global-index ()
  "A candidate key on page N selects the global engine index, not the
position within the page."
  (let ((mczy-candidate-keys "012")
        sent)
    (cl-letf (((symbol-function 'mczy--run-command)
               (lambda (cmd _fallback) (setq sent cmd))))
      (mczy-test--with-buffer
        (setq mczy--state 'choosing
              mczy--candidates '("a" "b" "c" "d" "e" "f" "g")
              mczy--page 1)
        (let ((last-command-event ?1))       ; key "1" on page 1 -> 1*3 + 1
          (mczy--handle-character))
        (should (equal sent '(select 4)))))))

(ert-deftest mczy-composition-keymap-is-buildable ()
  (let ((map (mczy--composition-keymap)))
    (should (eq (lookup-key map "a") #'mczy--handle-character))
    (should (eq (lookup-key map "5") #'mczy--handle-character))
    (should (commandp (lookup-key map "j")))   ; page down / input
    (should (commandp (lookup-key map "k")))   ; page up / input
    (should (commandp (lookup-key map [return])))
    (should (commandp (lookup-key map (kbd "C-b"))))
    (should (commandp (lookup-key map (kbd "C-f"))))
    (should (eq (lookup-key map [next]) #'mczy--page-next))
    (should (eq (lookup-key map [prior]) #'mczy--page-prev))
    (should (eq (lookup-key map (kbd "C-n")) #'mczy--page-next))
    (should (eq (lookup-key map (kbd "C-p")) #'mczy--page-prev))
    (should (commandp (lookup-key map [S-left])))
    (should (commandp (lookup-key map [S-right])))
    (should (commandp (lookup-key map (kbd "C-S-b"))))
    (should (commandp (lookup-key map (kbd "C-S-f"))))))

(ert-deftest mczy-set-english-chinese-respect-active ()
  "The advice-friendly setters only act in buffers where mczy is active."
  (mczy-test--with-buffer
    (setq mczy--active nil mczy--english-mode nil)
    (mczy-set-english)
    (should-not mczy--english-mode)   ; inactive: no-op
    (setq mczy--active t)
    (mczy-set-english)
    (should mczy--english-mode)
    (mczy-set-chinese)
    (should-not mczy--english-mode)))

;;; Engine-backed composition path (real input-method-function)

(defmacro mczy-test--needs-engine ()
  `(skip-unless (and (file-executable-p (mczy--resolve-path mczy-engine-path))
                     (file-readable-p (mczy--resolve-path mczy-data-path)))))

(ert-deftest mczy-input-method-commits-as-events ()
  (mczy-test--needs-engine)
  (mczy-test--with-buffer
    (unwind-protect
        (progn
          (mczy--start-process)
          ;; 5 j / space j p 6 -> 中文; left; space -> candidates;
          ;; 4 -> 鐘 (candidate index 3, key "4" under default keys); commit.
          (let ((events (mczy-test--type
                         (list ?5 ?j ?/ ?\s ?j ?p ?6
                               'left ?\s ?4 ?\r))))
            (should (equal events (string-to-list "鐘文")))
            ;; commit text is returned as events, not inserted directly
            (should (string= (buffer-string) ""))
            (should (eq mczy--state 'empty))))
      (mczy--stop-process))))

(ert-deftest mczy-input-method-custom-candidate-key ()
  (mczy-test--needs-engine)
  (let ((mczy-candidate-keys "qweruiop"))
    (mczy-test--with-buffer
      (unwind-protect
          (progn
            (mczy--start-process)
            (let ((events (mczy-test--type
                           (list ?5 ?j ?/ ?\s ?j ?p ?6
                                 'left ?\s ?r ?\r))))
              (should (equal events (string-to-list "鐘文")))))
        (mczy--stop-process)))))

(ert-deftest mczy-input-method-falls-through-unabsorbed-key ()
  (mczy-test--needs-engine)
  (mczy-test--with-buffer
    (unwind-protect
        (let ((unread-command-events nil))
          (mczy--start-process)
          ;; `right' in empty state -> engine (done nil) -> fall through.
          ;; The unconsumed key is RETURNED (not pushed to unread, which
          ;; would re-enter the input method and loop forever).
          (let ((events (mczy--input-method 'right)))
            (should (equal events '(right)))
            (should (eq mczy--state 'empty))
            (should (null unread-command-events))))
      (mczy--stop-process))))

(ert-deftest mczy-input-method-falls-through-unused-control-key ()
  (mczy-test--needs-engine)
  (mczy-test--with-buffer
    (unwind-protect
        (let ((unread-command-events nil))
          (mczy--start-process)
          ;; C-x is bound to `mczy--other-command' so read-key-sequence
          ;; resolves it immediately; it falls through without touching the
          ;; engine and is returned, not unread.
          (let ((events (mczy--input-method ?\C-x)))
            (should (equal events (list ?\C-x)))
            (should (eq mczy--state 'empty))
            (should (null unread-command-events))))
      (mczy--stop-process))))

(ert-deftest mczy-input-method-no-spin-on-fall-through ()
  "Regression: driving the REAL command-loop path (read-event honors
`input-method-function') over a fall-through key must terminate -- pushing
it to `unread-command-events' instead of returning it loops forever (GC
storm).  See the bug report \"切換了之後一直跑 garbage collecting\"."
  (mczy-test--needs-engine)
  (mczy-test--with-buffer
    (let ((calls 0))
      (cl-letf* ((orig (symbol-function 'mczy--input-method))
                 ((symbol-function 'mczy--input-method)
                  (lambda (key)
                    (setq calls (1+ calls))
                    (when (> calls 50)
                      (error "mczy--input-method re-entered %d times (spin)" calls))
                    (funcall orig key))))
        (unwind-protect
            (progn
              (activate-input-method "chinese-mczy")
              ;; one engine-ignored key, read through the real IM path
              (setq unread-command-events (list ?\C-x))
              (let ((ev (read-event nil t)))
                (should (eq ev ?\C-x))
                (should (<= calls 2))))
          (deactivate-input-method))))))

(ert-deftest mczy-activate-wires-input-method-function ()
  (mczy-test--needs-engine)
  (mczy-test--with-buffer
    (unwind-protect
        (progn
          (activate-input-method "chinese-mczy")
          (should (eq input-method-function #'mczy--input-method))
          (should (process-live-p mczy--process))
          (should (string= current-input-method "chinese-mczy")))
      (deactivate-input-method))
    ;; deactivation removes our buffer-local binding (reverting to the global
    ;; default, which is `list' -- a passthrough -- on this build).
    (should-not (local-variable-p 'input-method-function))
    (should-not (eq input-method-function #'mczy--input-method))))

(ert-deftest mczy-candidate-paging-engine-select ()
  "Against the real engine: a many-homophone syllable spans pages, and
selecting a later page maps to the right global engine index."
  (mczy-test--needs-engine)
  (mczy-test--with-buffer
    (unwind-protect
        (progn
          (mczy--start-process)
          (dolist (k '("5" "j" "6"))
            (mczy--apply-states (car (mczy--send-command (list 'key k)))))
          (mczy--apply-states (car (mczy--send-command '(key space))))
          (should (eq mczy--state 'choosing))
          (let ((cands mczy--candidates)
                (size (length mczy-candidate-keys)))
            (should (> (length cands) size))   ; genuinely multi-page
            (should (mczy--page-move 1))
            (should (= mczy--page 1))
            (let ((target (nth size cands)))   ; page 1, key 0 -> global `size'
              (mczy--apply-states
               (car (mczy--send-command (list 'select size))))
              (should (string= mczy--preedit target)))))
      (mczy--stop-process))))

(ert-deftest mczy-candidate-paging-live-session ()
  "PageDown pages a live choosing session without aborting it; selecting
from the new page and committing yields exactly one character."
  (mczy-test--needs-engine)
  (mczy-test--with-buffer
    (unwind-protect
        (let ((events (mczy-test--type (list ?5 ?j ?6 ?\s 'next ?0 ?\r))))
          (should (= (length events) 1))
          (should (eq mczy--state 'empty)))
      (mczy--stop-process))))

;;; User dictionary: mark a phrase (Shift+Left/Right) and add it

(ert-deftest mczy-marking-render ()
  (mczy-test--with-buffer
    (mczy--apply-states
     '((marking (head "鐘") (marked "文") (tail "字") (acceptable t))))
    (should (eq mczy--state 'marking))
    (let ((text (mczy-test--overlay-text)))
      (should (string-match-p "鐘文字" text))
      (should (string-match-p "加入自訂字庫" text))))
  (mczy-test--with-buffer
    (mczy--apply-states
     '((marking (head "") (marked "中") (tail "") (acceptable nil))))
    (should (string-match-p "無法加入" (mczy-test--overlay-text)))))

(ert-deftest mczy-shift-key-sends-shift-modifier ()
  (let (sent)
    (cl-letf (((symbol-function 'mczy--run-command)
               (lambda (cmd _fallback) (setq sent cmd))))
      (mczy-test--with-buffer
        (mczy--handle-shift-key 'left)
        (should (equal sent '(key left shift)))))))

(ert-deftest mczy-mark-add-roundtrip ()
  "End-to-end against the real engine: mark a non-dictionary 2-syllable
phrase, add it (no crash), and confirm the reload makes it selectable."
  (mczy-test--needs-engine)
  (let ((tmp (make-temp-file "mczy-up")))
    (mczy-test--with-buffer
      (unwind-protect
          (let ((mczy-user-phrases-path tmp))
            (mczy--start-process)
            (cl-flet ((send (cmd) (mczy--apply-states
                                   (car (mczy--send-command cmd)))))
              ;; compose 中文, then re-pick the first syllable as 鐘 -> 鐘文
              (dolist (k '("5" "j" "/")) (send (list 'key k)))
              (send '(key space))
              (dolist (k '("j" "p" "6")) (send (list 'key k)))
              (send '(key left))
              (send '(key space))
              (send '(select 3))
              (send '(key end))
              ;; mark both syllables -> acceptable (鐘文 is not in the base dict)
              (send '(key left shift))
              (send '(key left shift))
              (should (eq mczy--state 'marking))
              (should (mczy--marking-field mczy--marking 'acceptable))
              ;; add: no crash, returns to inputting, file gets the phrase
              (send '(key return))
              (should (eq mczy--state 'inputting))
              (with-temp-buffer
                (insert-file-contents tmp)
                (should (string-match-p "鐘文" (buffer-string))))
              ;; reload took effect: re-type the reading, 鐘文 is now a candidate
              (send '(reset))
              (dolist (k '("5" "j" "/")) (send (list 'key k)))
              (send '(key space))
              (dolist (k '("j" "p" "6")) (send (list 'key k)))
              (send '(key space))
              (should (eq mczy--state 'choosing))
              (should (member "鐘文" mczy--candidates))))
        (mczy--stop-process)
        (delete-file tmp)))))

(ert-deftest mczy-mark-add-live-session ()
  "Full gesture through the real keymap: compose 鐘文, Shift+Left twice to
mark, Enter to add, Enter to commit -- and the phrase lands in the file."
  (mczy-test--needs-engine)
  (let ((tmp (make-temp-file "mczy-up")))
    (mczy-test--with-buffer
      (unwind-protect
          (let ((mczy-user-phrases-path tmp))
            (let ((events (mczy-test--type
                           (list ?5 ?j ?/ ?\s ?j ?p ?6 'left ?\s ?4
                                 'end 'S-left 'S-left ?\r ?\r))))
              (should (equal events (string-to-list "鐘文")))
              (should (eq mczy--state 'empty))
              (with-temp-buffer
                (insert-file-contents tmp)
                (should (string-match-p "鐘文" (buffer-string))))))
        (mczy--stop-process)
        (delete-file tmp)))))

;;; M3c: double-space Chinese/English toggle

(ert-deftest mczy-single-space-toggles-to-english-when-idle ()
  (mczy-test--needs-engine)
  (mczy-test--with-buffer
    (unwind-protect
        (progn
          (mczy--start-process)
          ;; a space in the empty state self-inserts AND switches to English
          (let ((e1 (mczy--input-method ?\s)))
            (should (equal e1 (list ?\s)))
            (should mczy--english-mode)
            (should (= mczy--space-run 0)))
          ;; in English mode a double space switches back (second one swallowed)
          (should (equal (mczy--input-method ?\s) (list ?\s)))
          (should (null (mczy--input-method ?\s)))
          (should-not mczy--english-mode))
      (mczy--stop-process))))

(ert-deftest mczy-english-mode-passthrough-and-toggle-back ()
  (mczy-test--needs-engine)
  (mczy-test--with-buffer
    (unwind-protect
        (progn
          (mczy--start-process)
          (setq mczy--english-mode t mczy--space-run 0)
          ;; letters pass through as self-insert
          (should (equal (mczy--input-method ?h) (list ?h)))
          (should (= mczy--space-run 0))
          ;; first space self-inserts, second toggles back to Chinese
          (should (equal (mczy--input-method ?\s) (list ?\s)))
          (should (= mczy--space-run 1))
          (should (null (mczy--input-method ?\s)))
          (should-not mczy--english-mode)
          (should (= mczy--space-run 0))
          ;; back in Chinese mode the engine drives again
          (let ((unread-command-events (list ?j ?/ ?\s ?j ?p ?6 ?\r)))
            (should (equal (mczy--input-method ?5)
                           (string-to-list "中文")))))
      (mczy--stop-process))))

(ert-deftest mczy-tone-space-then-select-does-not-toggle-english ()
  "Regression: a bopomofo tone-1 space immediately followed by the
candidate-opening space (as when typing 中 or 窩窩) must drive the engine,
not be misread as the double-space English toggle.  The toggle now fires
only from an empty buffer."
  (mczy-test--needs-engine)
  (mczy-test--with-buffer
    (unwind-protect
        (progn
          (mczy--start-process)
          ;; 5 j / SPC -> 中 (tone-1 space); SPC opens candidates; RET commits.
          (let ((events (mczy-test--type (list ?5 ?j ?/ ?\s ?\s ?\r))))
            (should (equal events (string-to-list "中")))
            (should-not mczy--english-mode)))
      (mczy--stop-process))))

(ert-deftest mczy-non-space-resets-space-run ()
  "In English mode, a non-space key resets the double-space run."
  (mczy-test--needs-engine)
  (mczy-test--with-buffer
    (unwind-protect
        (progn
          (mczy--start-process)
          (setq mczy--english-mode t mczy--space-run 0)
          (should (equal (mczy--input-method ?\s) (list ?\s)))
          (should (= mczy--space-run 1))
          ;; a letter resets the run, so the next space is "first" again
          (should (equal (mczy--input-method ?h) (list ?h)))
          (should (= mczy--space-run 0))
          (should (equal (mczy--input-method ?\s) (list ?\s)))
          (should (= mczy--space-run 1))
          (should mczy--english-mode))
      (mczy--stop-process))))

(ert-deftest mczy-minibuffer-exit-cleans-up ()
  "M3b: leaving an inherit-IM minibuffer must stop the engine and drop the
local `input-method-function' (else each minibuffer use leaks an engine).
Drives the cleanup path directly; the live minibuffer/isearch round-trip
still needs manual verification."
  (mczy-test--needs-engine)
  (mczy-test--with-buffer
    (activate-input-method "chinese-mczy")
    (let ((proc mczy--process))
      (should (process-live-p proc))
      (mczy--exit-from-minibuffer)
      (should-not (process-live-p proc))
      (should-not (local-variable-p 'input-method-function)))))

(ert-deftest mczy-reset-clears-engine-state ()
  (mczy-test--needs-engine)
  (mczy-test--with-buffer
    (unwind-protect
        (progn
          (mczy--start-process)
          ;; leave the engine mid-composition, then reset
          (mczy--apply-states (car (mczy--send-command '(key "5"))))
          (should (eq mczy--state 'inputting))
          (mczy-reset)
          (should (eq mczy--state 'empty))
          ;; engine is genuinely empty: next key starts a fresh syllable
          (mczy--apply-states (car (mczy--send-command '(key "5"))))
          (should (string= mczy--preedit "ㄓ")))
      (mczy--stop-process))))

(ert-deftest mczy-resolves-relative-engine-paths ()
  (let ((mczy-engine-path "engine/build/mczy-engine")
        (mczy-data-path "engine/vendor/fcitx5-mcbopomofo/data/data.txt")
        (default-directory temporary-file-directory))
    (should (file-name-absolute-p (mczy--resolve-path mczy-engine-path)))
    (should (file-executable-p (mczy--resolve-path mczy-engine-path)))
    (should (file-readable-p (mczy--resolve-path mczy-data-path)))))

;;; Scope guard: mczy is an input method, not a minor mode.

(ert-deftest mczy-scope-no-minor-mode ()
  "`mczy-mode-map' is a plain keymap gated via `minor-mode-map-alist'
on the buffer-local `mczy--active' -- convenient for a global binding
like F9, but mczy itself must stay a `define-minor-mode'-free input
method (no `mczy-mode' function, no always-on keymap)."
  (should-not (fboundp 'mczy-mode))
  (should (keymapp mczy-mode-map))
  (should (assq 'mczy--active minor-mode-map-alist)))

(when noninteractive
  (ert-run-tests-batch-and-exit))

(provide 'test-mczy)

;;; test-mczy.el ends here
