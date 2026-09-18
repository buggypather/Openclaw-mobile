#pragma once
#include <cstdint>
#include <optional>
#include <string>
#include "openclaw/gateway_protocol.hpp"
namespace openclaw {
struct SequenceDecision { bool accept{true}; bool gap{false}; std::optional<std::uint64_t> expected; };
class SequenceTracker {
 public:
  SequenceDecision observe(const Frame& frame);
  void reset_connection();
  std::optional<std::uint64_t> last_outer() const { return lastOuter_; }
 private: std::optional<std::uint64_t> lastOuter_;
};
struct ReconnectPolicy {
 std::uint32_t attempt{0};
 std::uint32_t baseMs{500}, maxMs{30000};
 std::uint32_t next_delay_ms();
 void reset(){attempt=0;}
};
struct HydrationResult { std::string sessions; std::string history; bool subscribed{false}; };
}
