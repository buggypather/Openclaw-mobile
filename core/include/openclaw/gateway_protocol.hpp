#pragma once
#include <cstdint>
#include <optional>
#include <string>
#include <vector>
namespace openclaw {
struct Challenge { std::string nonce; std::int64_t ts{0}; };
struct Frame { enum class Kind { Response, Event, Unknown }; Kind kind{Kind::Unknown}; std::string id,event,payload,error; bool ok{false}; std::optional<std::uint64_t> seq; };
class GatewayProtocol {
 public:
  static constexpr int wire_version = 4;
  static std::string connect(const std::string& id,const std::string& token,const std::string& platform="cli",const std::string& deviceJson="");
  static std::string request(const std::string& id,const std::string& method,const std::string& paramsJson="{}");
  static std::string chat_send(const std::string& id,const std::string& sessionKey,const std::string& message,const std::string& idempotencyKey,const std::string& sessionId="",const std::string& attachmentsJson="");
  static std::string chat_abort(const std::string& id,const std::string& sessionKey,const std::string& runId="");
  static std::string chat_history(const std::string& id,const std::string& sessionKey,int limit=100);
  static std::string sessions_list(const std::string& id,int limit=60);
  static std::string sessions_subscribe(const std::string& id,int limit=60);
  static std::string health(const std::string& id);
  static Frame parse(const std::string& json);
  static std::optional<Challenge> challenge(const std::string& json);
  static std::string escape(const std::string& value);
};
}
