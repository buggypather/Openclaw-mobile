#pragma once
#include <chrono>
#include <functional>
#include <memory>
#include <optional>
#include <string>
#include "openclaw/device_identity.hpp"
#include "openclaw/gateway_protocol.hpp"
#include "openclaw/recovery.hpp"
namespace openclaw {
struct GatewayUrl { bool secure{false}; std::string host{"127.0.0.1"}; std::string port{"18789"}; std::string target{"/"}; };
GatewayUrl parse_gateway_url(const std::string& url);
struct ConnectResult { enum class State { Connected, PairingRequired, Failed }; State state{State::Failed}; std::string requestId, message; };
class GatewayClient {
 public:
  using EventHandler=std::function<void(const Frame&,const std::string&)>;
  GatewayClient(std::string url, DeviceStore& store, std::string bootstrapToken={});
  ~GatewayClient();
  GatewayClient(const GatewayClient&)=delete; GatewayClient& operator=(const GatewayClient&)=delete;
  ConnectResult connect(std::chrono::milliseconds timeout=std::chrono::seconds(10));
  void close(); bool connected() const;
  std::string call(const std::string& method,const std::string& params="{}",std::chrono::milliseconds timeout=std::chrono::seconds(30));
  std::string send_chat(const std::string& sessionKey,const std::string& message,const std::string& sessionId={},const std::string& attachmentsJson={});
  std::string abort_chat(const std::string& sessionKey,const std::string& runId={});
  HydrationResult hydrate(const std::string& sessionKey,int historyLimit=100);
  ConnectResult reconnect(const std::string& sessionKey={},int maxAttempts=8);
  bool recovery_needed() const;
  void clear_recovery_needed();
  void pump(const EventHandler& onEvent,std::chrono::milliseconds duration=std::chrono::milliseconds(250));
 private: struct Impl; std::unique_ptr<Impl> p_;
};
}
