#include <FL/Fl.H>
#include <FL/Fl_Box.H>
#include <FL/Fl_Button.H>
#include <FL/Fl_Input.H>
#include <FL/Fl_Multiline_Input.H>
#include <FL/Fl_Text_Buffer.H>
#include <FL/Fl_Text_Display.H>
#include <FL/Fl_Window.H>

#include <atomic>
#include <condition_variable>
#include <cstdlib>
#include <deque>
#include <memory>
#include <mutex>
#include <string>
#include <thread>

#include "openclaw/gateway_client.hpp"

namespace {
using openclaw::ConnectResult;
using openclaw::DeviceStore;
using openclaw::Frame;
using openclaw::GatewayClient;

struct Command {
  enum class Type { Connect, Send, Abort, Stop } type;
  std::string gateway;
  std::string session;
  std::string text;
};

class DesktopApp {
 public:
  DesktopApp()
      : window_(920, 720, "OpenClaw Desktop 0.8.0-dev"),
        gateway_(90, 18, 500, 30, "Gateway:"),
        session_(675, 18, 220, 30, "Session:"),
        status_(20, 58, 875, 24, "Offline"),
        transcript_(20, 90, 875, 470),
        prompt_(20, 575, 705, 95),
        connect_(740, 575, 155, 30, "Connect"),
        send_(740, 615, 155, 30, "Send"),
        abort_(740, 655, 155, 30, "Pause / Stop") {
    const char* env_url = std::getenv("OPENCLAW_GATEWAY_URL");
    gateway_.value(env_url ? env_url : "ws://127.0.0.1:18789");
    session_.value("main");
    status_.align(FL_ALIGN_LEFT | FL_ALIGN_INSIDE);
    transcript_.buffer(&buffer_);
    transcript_.textfont(FL_HELVETICA);
    transcript_.textsize(15);
    prompt_.when(FL_WHEN_ENTER_KEY_ALWAYS);

    connect_.callback([](Fl_Widget*, void* self) { static_cast<DesktopApp*>(self)->connect(); }, this);
    send_.callback([](Fl_Widget*, void* self) { static_cast<DesktopApp*>(self)->send(); }, this);
    abort_.callback([](Fl_Widget*, void* self) { static_cast<DesktopApp*>(self)->abort(); }, this);
    prompt_.callback([](Fl_Widget*, void* self) { static_cast<DesktopApp*>(self)->send(); }, this);

    window_.resizable(transcript_);
    window_.callback([](Fl_Widget*, void* self) { static_cast<DesktopApp*>(self)->shutdown(); }, this);
    window_.end();
    window_.show();
    worker_ = std::thread([this] { worker_loop(); });
  }

  ~DesktopApp() { shutdown(); }

  int run() { return Fl::run(); }

 private:
  void enqueue(Command c) {
    {
      std::lock_guard<std::mutex> lock(command_mutex_);
      commands_.push_back(std::move(c));
    }
    command_cv_.notify_one();
  }

  void connect() {
    set_status("Connecting…");
    enqueue({Command::Type::Connect, gateway_.value(), session_.value(), {}});
  }

  void send() {
    std::string text = prompt_.value();
    if (text.empty()) return;
    buffer_.append(("\nYou: " + text + "\n").c_str());
    prompt_.value("");
    transcript_.scroll(buffer_.count_lines(0, buffer_.length()), 0);
    enqueue({Command::Type::Send, gateway_.value(), session_.value(), std::move(text)});
  }

  void abort() { enqueue({Command::Type::Abort, gateway_.value(), session_.value(), {}}); }

  void shutdown() {
    bool expected = false;
    if (!closing_.compare_exchange_strong(expected, true)) return;
    enqueue({Command::Type::Stop, {}, {}, {}});
    if (worker_.joinable()) worker_.join();
    window_.hide();
  }

  void set_status(const std::string& text) {
    std::lock_guard<std::mutex> lock(ui_mutex_);
    pending_status_ = text;
    Fl::awake(&DesktopApp::awake_cb, this);
  }

  void append(const std::string& text) {
    std::lock_guard<std::mutex> lock(ui_mutex_);
    pending_text_ += text;
    if (!text.empty() && text.back() != '\n') pending_text_ += '\n';
    Fl::awake(&DesktopApp::awake_cb, this);
  }

  static void awake_cb(void* data) {
    auto* self = static_cast<DesktopApp*>(data);
    std::string text, status;
    {
      std::lock_guard<std::mutex> lock(self->ui_mutex_);
      text.swap(self->pending_text_);
      status.swap(self->pending_status_);
    }
    if (!status.empty()) self->status_.copy_label(status.c_str());
    if (!text.empty()) {
      self->buffer_.append(text.c_str());
      self->transcript_.scroll(self->buffer_.count_lines(0, self->buffer_.length()), 0);
    }
  }

  bool ensure_connected(const Command& cmd) {
    if (client_ && client_->connected() && active_gateway_ == cmd.gateway) return true;
    client_.reset();
    active_gateway_ = cmd.gateway;
    client_ = std::make_unique<GatewayClient>(cmd.gateway, store_, bootstrap_token_);
    auto result = client_->connect();
    if (result.state == ConnectResult::State::PairingRequired) {
      set_status("Pairing required");
      append("Pairing required. On the Gateway host run:\n  openclaw devices approve " + result.requestId);
      return false;
    }
    if (result.state != ConnectResult::State::Connected) {
      set_status("Offline");
      append("Connection failed: " + result.message);
      return false;
    }
    set_status("Connected · " + cmd.gateway);
    if (!cmd.session.empty()) {
      try {
        const auto hydrated = client_->hydrate(cmd.session, 100);
        append("\n[Authoritative history]\n" + hydrated.history + "\n");
      } catch (const std::exception& e) {
        append(std::string("History hydration failed: ") + e.what());
      }
    }
    return true;
  }

  void process(const Command& cmd) {
    if (cmd.type == Command::Type::Stop) return;
    if (!ensure_connected(cmd)) return;
    try {
      switch (cmd.type) {
        case Command::Type::Connect:
          break;
        case Command::Type::Send:
          append("OpenClaw request: " + client_->send_chat(cmd.session, cmd.text));
          break;
        case Command::Type::Abort:
          append("Abort: " + client_->abort_chat(cmd.session));
          break;
        case Command::Type::Stop:
          break;
      }
    } catch (const std::exception& e) {
      append(std::string("Error: ") + e.what());
      set_status("Offline");
    }
  }

  void worker_loop() {
    while (!closing_) {
      Command cmd{Command::Type::Connect, {}, {}, {}};
      bool have = false;
      {
        std::unique_lock<std::mutex> lock(command_mutex_);
        command_cv_.wait_for(lock, std::chrono::milliseconds(150), [this] { return !commands_.empty() || closing_; });
        if (!commands_.empty()) {
          cmd = std::move(commands_.front());
          commands_.pop_front();
          have = true;
        }
      }
      if (have) {
        if (cmd.type == Command::Type::Stop) break;
        process(cmd);
      }
      if (client_ && client_->connected()) {
        try {
          client_->pump([this](const Frame& frame, const std::string& raw) {
            if (frame.event == "agent" || frame.event == "chat" || frame.event == "session.message") append(raw);
          }, std::chrono::milliseconds(50));
        } catch (...) {
          set_status("Reconnecting…");
        }
      }
    }
    if (client_) client_->close();
  }

  Fl_Window window_;
  Fl_Input gateway_;
  Fl_Input session_;
  Fl_Box status_;
  Fl_Text_Display transcript_;
  Fl_Text_Buffer buffer_;
  Fl_Multiline_Input prompt_;
  Fl_Button connect_, send_, abort_;

  DeviceStore store_;
  const std::string bootstrap_token_ = [] {
    const char* p = std::getenv("OPENCLAW_GATEWAY_TOKEN");
    return p ? std::string(p) : std::string();
  }();
  std::unique_ptr<GatewayClient> client_;
  std::string active_gateway_;
  std::thread worker_;
  std::atomic<bool> closing_{false};
  std::mutex command_mutex_, ui_mutex_;
  std::condition_variable command_cv_;
  std::deque<Command> commands_;
  std::string pending_text_, pending_status_;
};
}  // namespace

int main() {
  DesktopApp app;
  return app.run();
}
