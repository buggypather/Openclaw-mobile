#include "openclaw/core.hpp"
#include <chrono>
namespace openclaw {
Core::Core(Config config):config_(std::move(config)){}
Response Core::chat(const std::string& prompt) const {if(prompt.empty())return{false,"Prompt is empty"};auto n=std::chrono::steady_clock::now().time_since_epoch().count();return{true,GatewayProtocol::chat_send("chat-"+std::to_string(n),config_.sessionKey,prompt,"run-"+std::to_string(n))};}
std::string Core::gateway()const{return config_.gateway;} const Config& Core::config()const{return config_;}
}
