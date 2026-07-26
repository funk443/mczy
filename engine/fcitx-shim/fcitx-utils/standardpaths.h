// No-op shim for fcitx's StandardPaths. mczy-engine resolves data
// paths itself (CLI arg / env), so PathCompat.h only needs this to *compile*,
// never to actually locate anything. Real impl lives in fcitx5; not linked here.
#ifndef MCZY_SHIM_FCITX_UTILS_STANDARDPATHS_H_
#define MCZY_SHIM_FCITX_UTILS_STANDARDPATHS_H_

#include <string>

namespace fcitx {

enum class StandardPathsType { Config, PkgConfig, Data, PkgData, Cache, Runtime, Addon };

class StandardPaths {
 public:
  static StandardPaths& global() {
    static StandardPaths instance;
    return instance;
  }
  std::string locate(StandardPathsType, const std::string&) const { return {}; }
  std::string userDirectory(StandardPathsType) const { return {}; }
};

}  // namespace fcitx

#endif  // MCZY_SHIM_FCITX_UTILS_STANDARDPATHS_H_
