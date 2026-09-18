#pragma once
#include <string>
#include "openclaw/gateway_protocol.hpp"
namespace openclaw {
struct Config { std::string gateway{"ws://127.0.0.1:18789"}; std::string token{}; std::string sessionKey{"main"}; };
struct Response { bool ok{false}; std::string text; };
class Core { public: explicit Core(Config config = {}); Response chat(const std::string& prompt) const; std::string gateway() const; const Config& config() const; private: Config config_; };
}
