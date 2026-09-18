#pragma once
#include <cstdint>
#include <optional>
#include <string>
#include <vector>
namespace openclaw {
struct DeviceIdentity { std::string deviceId, publicKeyBase64Url, privateKeyPem; };
struct DeviceToken { std::string token, role; std::vector<std::string> scopes; };
struct PairingRequired { std::string requestId, recommendedNextStep; };
class DeviceStore {
 public:
  explicit DeviceStore(std::string root = {});
  DeviceIdentity load_or_create_identity();
  std::optional<DeviceToken> load_token() const;
  void store_token(const DeviceToken& token) const;
  void clear_token() const;
  const std::string& root() const { return root_; }
 private: std::string root_;
};
std::string build_device_auth_payload_v3(const DeviceIdentity&, const std::string& clientId,
 const std::string& clientMode,const std::string& role,const std::vector<std::string>& scopes,
 std::int64_t signedAtMs,const std::string& token,const std::string& nonce,
 const std::string& platform,const std::string& deviceFamily);
std::string sign_device_payload(const DeviceIdentity&, const std::string& payload);
std::string device_json(const DeviceIdentity&, const std::string& signature, std::int64_t signedAtMs,const std::string& nonce);
std::optional<PairingRequired> parse_pairing_required(const std::string& responseJson);
std::optional<DeviceToken> parse_hello_device_token(const std::string& responseJson);
}
