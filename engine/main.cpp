// mczy-engine — McBopomofo's interactive controller (KeyHandler) driven over
// sexp-over-stdio, instead of fcitx5's preedit/candidate API.
//
// This is the M1 feasibility spike. It reuses KeyHandler + InputState + the
// McBopomofo engine unmodified (see engine/vendor) and replaces ONLY the fcitx5
// frontend (McBopomofo.cpp) with this stdio loop. The seam this implements is
// documented in docs/m0-seam-notes.md:
//   · key entry  -> KeyHandler::handle(Key, state, StateCallback, ErrorCallback)
//   · state seam -> the StateCallback (here: serialize InputState -> sexp)
//   · commit     -> Committing state, or Empty entered from a NotEmpty state
//
// Protocol (one turn = request -> 0..N state sexps + a (done ...) terminator):
//   stdin :  (key "j")            ascii char
//            (key left)           named key: left right up down home end
//                                            space return esc backspace tab delete
//            (key left shift)     trailing tokens shift / ctrl add modifiers
//            (select 0)           pick candidate N (0-based) in a choosing state
//            (reset)              clear all composing state
//   stdout:  (inputting (buffer "中文") (cursor 2))
//            (choosing (buffer "中文") (cursor 2) (candidates "中文" "鐘紋" ...))
//            (commit "中文")
//            (marking (head "中") (marked "文") (tail "") (acceptable t))
//            (empty)
//            (done t|nil)         terminator; value = whether the key was absorbed
// cursor is a CODEPOINT index (engine-internal cursorIndex is a UTF-8 byte
// offset; we convert so Emacs's char-indexed strings line up — see seam notes).

#include <cstdlib>
#include <fstream>
#include <iostream>
#include <memory>
#include <string>
#include <vector>

#include "Engine/McBopomofoLM.h"
#include "Engine/UTF8Helper.h"
#include "Engine/VariantAnnotator.h"
#include "InputState.h"
#include "Key.h"
#include "KeyHandler.h"  // also pulls UserPhraseAdder (LanguageModelLoader.h)

using namespace McBopomofo;

namespace {

// --- minimal dependencies KeyHandler needs but we don't really use -----------

class NoopUserPhraseAdder : public UserPhraseAdder {
 public:
  void addUserPhrase(const std::string_view&, const std::string_view&) override {}
  void removeUserPhrase(const std::string_view&, const std::string_view&) override {}
};

// Persists marked phrases to a user file and reloads them into the LM so the
// just-added phrase is immediately selectable.  File format mirrors upstream
// LanguageModelLoader: one "<phrase> <reading>" line per phrase.
class FileUserPhraseAdder : public UserPhraseAdder {
 public:
  FileUserPhraseAdder(std::shared_ptr<McBopomofoLM> lm, std::string path)
      : lm_(std::move(lm)), path_(std::move(path)) {}

  void addUserPhrase(const std::string_view& reading,
                     const std::string_view& phrase) override {
    {
      std::ofstream out(path_, std::ios::app);
      // ponytail: one shared dict file; a second engine instance appending
      // concurrently could interleave lines.  Fine for single-composition use;
      // add locking only if multi-buffer simultaneous adds become real.
      if (!out) return;
      out << phrase << " " << reading << "\n";
    }
    lm_->loadUserPhrases(path_.c_str(), nullptr);
  }

  // ponytail: mark-to-add only for v1; excluded-phrase removal is a later add.
  void removeUserPhrase(const std::string_view&,
                        const std::string_view&) override {}

 private:
  std::shared_ptr<McBopomofoLM> lm_;
  std::string path_;
};

// Cribbed from upstream KeyHandlerTest's MockLocalizedString — these strings are
// only used for tooltips/marking UI text, fine as plain English for the spike.
class LocalizedStrings : public KeyHandler::LocalizedStrings {
 public:
  std::string cursorIsBetweenSyllables(const std::string& a,
                                       const std::string& b) override {
    return "between " + a + " and " + b;
  }
  std::string syllablesRequired(size_t n) override {
    return std::to_string(n) + " syllables required";
  }
  std::string syllablesMaximum(size_t n) override {
    return std::to_string(n) + " syllables maximum";
  }
  std::string phraseAlreadyExists() override { return "phrase already exists"; }
  std::string pressEnterToAddThePhrase() override {
    return "press Enter to add the phrase";
  }
  std::string markedWithSyllablesAndStatus(const std::string& marked,
                                           const std::string& reading,
                                           const std::string& status) override {
    return "Marked: " + marked + ", syllables: " + reading + ", " + status;
  }
  std::string bopomofoFontAnnotationModeTooltip(bool, bool) override {
    return "Bopomofo annotation mode";
  }
  std::string markingNotAvailableInFontAnnotationMode() override {
    return "Cannot add new phrases when Bopomofo annotation is on";
  }
};

// --- sexp serialization ------------------------------------------------------

std::string escapeSexp(const std::string& s) {
  std::string out;
  out.reserve(s.size() + 2);
  for (char c : s) {
    if (c == '"' || c == '\\') out += '\\';
    out += c;
  }
  return out;
}

// engine cursorIndex is a UTF-8 byte offset; emit it as a codepoint index.
size_t codepointCursor(const std::string& buf, size_t byteIndex) {
  if (byteIndex > buf.size()) byteIndex = buf.size();
  return CodePointCount(buf.substr(0, byteIndex));
}

void emitNotEmpty(const char* tag, InputStates::NotEmpty* s) {
  std::cout << "(" << tag << " (buffer \"" << escapeSexp(s->composingBuffer)
            << "\") (cursor " << codepointCursor(s->composingBuffer, s->cursorIndex)
            << ")";
}

// Serialize one InputState. Most-derived dynamic_casts first (Inputting,
// ChoosingCandidate, Marking all derive from NotEmpty).
void emitState(InputState* s) {
  using namespace InputStates;
  if (auto* cc = dynamic_cast<ChoosingCandidate*>(s)) {  // incl. ChoosingPunctuationList
    emitNotEmpty("choosing", cc);
    std::cout << " (candidates";
    for (const auto& cand : cc->candidates)
      std::cout << " \"" << escapeSexp(cand.value) << "\"";
    std::cout << "))\n";
  } else if (auto* m = dynamic_cast<Marking*>(s)) {
    std::cout << "(marking (head \"" << escapeSexp(m->head) << "\") (marked \""
              << escapeSexp(m->markedText) << "\") (tail \"" << escapeSexp(m->tail)
              << "\") (acceptable " << (m->acceptable ? "t" : "nil") << "))\n";
  } else if (auto* in = dynamic_cast<Inputting*>(s)) {
    emitNotEmpty("inputting", in);
    std::cout << ")\n";
  } else if (auto* ne = dynamic_cast<NotEmpty*>(s)) {
    emitNotEmpty("state", ne);  // other NotEmpty states (dictionary, assoc, ...)
    std::cout << ")\n";
  } else if (auto* c = dynamic_cast<Committing*>(s)) {
    std::cout << "(commit \"" << escapeSexp(c->text) << "\")\n";
  } else {
    std::cout << "(empty)\n";  // Empty / EmptyIgnoringPrevious / others
  }
}

// --- tiny sexp command parser (line = one request) ---------------------------
// ponytail: line-oriented, single-quoted-token tokenizer — not a general sexp
// reader. The request grammar is flat; a full parser would be dead weight.

struct Cmd {
  std::string verb;
  std::vector<std::string> args;
};

bool parseCmd(const std::string& line, Cmd* out) {
  size_t open = line.find('(');
  size_t close = line.rfind(')');
  if (open == std::string::npos || close == std::string::npos || close <= open)
    return false;
  std::string in = line.substr(open + 1, close - open - 1);
  std::vector<std::string> toks;
  for (size_t i = 0; i < in.size();) {
    char c = in[i];
    if (c == ' ' || c == '\t') { ++i; continue; }
    if (c == '"') {  // quoted token, with \" and \\ escapes
      std::string t;
      ++i;
      while (i < in.size() && in[i] != '"') {
        if (in[i] == '\\' && i + 1 < in.size()) ++i;
        t += in[i++];
      }
      if (i < in.size()) ++i;  // closing quote
      toks.push_back(t);
    } else {
      std::string t;
      while (i < in.size() && in[i] != ' ' && in[i] != '\t') t += in[i++];
      toks.push_back(t);
    }
  }
  if (toks.empty()) return false;
  out->verb = toks[0];
  out->args.assign(toks.begin() + 1, toks.end());
  return true;
}

Key buildKey(const std::vector<std::string>& args) {
  if (args.empty()) return Key();
  const std::string& spec = args[0];
  bool shift = false, ctrl = false;
  for (size_t i = 1; i < args.size(); ++i) {
    if (args[i] == "shift") shift = true;
    else if (args[i] == "ctrl") ctrl = true;
  }
  using KN = Key::KeyName;
  if (spec == "left") return Key::namedKey(KN::LEFT, shift, ctrl);
  if (spec == "right") return Key::namedKey(KN::RIGHT, shift, ctrl);
  if (spec == "up") return Key::namedKey(KN::UP, shift, ctrl);
  if (spec == "down") return Key::namedKey(KN::DOWN, shift, ctrl);
  if (spec == "home") return Key::namedKey(KN::HOME, shift, ctrl);
  if (spec == "end") return Key::namedKey(KN::END, shift, ctrl);
  if (spec == "space") return Key::asciiKey(Key::SPACE, shift, ctrl);
  if (spec == "return" || spec == "enter") return Key::asciiKey(Key::RETURN, shift, ctrl);
  if (spec == "esc" || spec == "escape") return Key::asciiKey(Key::ESC, shift, ctrl);
  if (spec == "backspace" || spec == "bs") return Key::asciiKey(Key::BACKSPACE, shift, ctrl);
  if (spec == "tab") return Key::asciiKey(Key::TAB, shift, ctrl);
  if (spec == "delete" || spec == "del") return Key::asciiKey(Key::DELETE, shift, ctrl);
  return Key::asciiKey(spec.empty() ? 0 : spec[0], shift, ctrl);
}

}  // namespace

int main(int argc, char** argv) {
  std::string dataPath = argc > 1 ? argv[1] : "";
  if (dataPath.empty()) {
    if (const char* env = std::getenv("MCZY_DATA")) dataPath = env;
  }
  if (dataPath.empty()) {
    std::cerr << "usage: mczy-engine <path-to-mcbopomofo-data.txt>\n"
              << "   or: MCZY_DATA=<path> mczy-engine\n";
    return 2;
  }

  auto lm = std::make_shared<McBopomofoLM>();
  lm->loadLanguageModel(dataPath.c_str());
  if (!lm->isDataModelLoaded()) {
    std::cerr << "error: could not load language model from: " << dataPath << "\n";
    return 1;
  }

  // Optional user-phrase dictionary: argv[2] or $MCZY_USER_PHRASES.  Created
  // if missing (append+reload need it to exist) and loaded so previously added
  // phrases work on startup.
  std::string userPhrasesPath = argc > 2 ? argv[2] : "";
  if (userPhrasesPath.empty()) {
    if (const char* env = std::getenv("MCZY_USER_PHRASES"))
      userPhrasesPath = env;
  }
  std::shared_ptr<UserPhraseAdder> userPhraseAdder;
  if (userPhrasesPath.empty()) {
    userPhraseAdder = std::make_shared<NoopUserPhraseAdder>();
  } else {
    std::ofstream touch(userPhrasesPath, std::ios::app);  // ensure it exists
    touch.close();
    lm->loadUserPhrases(userPhrasesPath.c_str(), nullptr);
    userPhraseAdder = std::make_shared<FileUserPhraseAdder>(lm, userPhrasesPath);
  }

  auto keyHandler = std::make_unique<KeyHandler>(
      lm, std::make_shared<VariantAnnotator>(), userPhraseAdder,
      std::make_unique<LocalizedStrings>());
  // KeyHandler calls onAddNewPhrase_ after a successful mark-add; it is an
  // unset std::function by default, so calling it would abort.  Set it (no-op
  // is enough -- the phrase is already persisted by the adder).
  keyHandler->setOnAddNewPhrase([](const std::string&) {});

  // Mirror McBopomofoEngine::enterNewState: hold the previous state so that
  // entering Empty from a NotEmpty state commits that buffer (the commit-on-
  // empty seam), and unpack StateSequence so one key can yield many events.
  std::unique_ptr<InputState> state = std::make_unique<InputStates::Empty>();

  auto processOne = [&](std::unique_ptr<InputState> s) {
    using namespace InputStates;
    if (dynamic_cast<EmptyIgnoringPrevious*>(s.get())) {
      std::cout << "(empty)\n";
      state = std::make_unique<Empty>();
      return;
    }
    if (dynamic_cast<Empty*>(s.get())) {
      if (auto* ne = dynamic_cast<NotEmpty*>(state.get()))
        if (!ne->composingBuffer.empty())
          std::cout << "(commit \"" << escapeSexp(ne->composingBuffer) << "\")\n";
      std::cout << "(empty)\n";
      state = std::move(s);
      return;
    }
    emitState(s.get());
    state = std::move(s);
  };

  KeyHandler::StateCallback stateCallback =
      [&](std::unique_ptr<InputState> next) {
        if (auto* seq = dynamic_cast<InputStates::StateSequence*>(next.get())) {
          for (auto& s : seq->states) processOne(std::move(s));
        } else {
          processOne(std::move(next));
        }
      };
  KeyHandler::ErrorCallback errorCallback = [&]() { std::cout << "(error)\n"; };

  std::string line;
  while (std::getline(std::cin, line)) {
    Cmd cmd;
    if (!parseCmd(line, &cmd)) continue;
    bool accepted = true;

    if (cmd.verb == "key") {
      accepted = keyHandler->handle(buildKey(cmd.args), state.get(),
                                    stateCallback, errorCallback);
    } else if (cmd.verb == "select") {
      auto* cc = dynamic_cast<InputStates::ChoosingCandidate*>(state.get());
      long n = cmd.args.empty() ? -1 : std::strtol(cmd.args[0].c_str(), nullptr, 10);
      if (cc && n >= 0 && static_cast<size_t>(n) < cc->candidates.size()) {
        // copy out before the callback can reassign `state` (frees cc)
        auto candidate = cc->candidates[n];
        size_t originalCursor = cc->originalCursor;
        keyHandler->candidateSelected(candidate, originalCursor, stateCallback);
      } else {
        std::cout << "(error)\n";
      }
    } else if (cmd.verb == "reset") {
      keyHandler->reset();
      state = std::make_unique<InputStates::Empty>();
      std::cout << "(empty)\n";
    } else {
      std::cout << "(error)\n";
    }

    std::cout << "(done " << (accepted ? "t" : "nil") << ")" << std::endl;
  }
  return 0;
}
