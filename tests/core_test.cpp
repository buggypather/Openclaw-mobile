#include <cassert>
#include <filesystem>
#include "openclaw/core.hpp"
#include "openclaw/device_identity.hpp"
#include "openclaw/gateway_client.hpp"
#include "openclaw/recovery.hpp"
int main(){using namespace openclaw;
 Core c; auto r=c.chat("hello"); assert(r.ok);
 auto ch=GatewayProtocol::challenge(R"({"type":"event","event":"connect.challenge","payload":{"nonce":"abc","ts":1737264000000}})"); assert(ch&&ch->nonce=="abc");
 auto tmp=std::filesystem::temp_directory_path()/"openclaw-mobile-test"; std::filesystem::remove_all(tmp); DeviceStore st(tmp.string()); auto d=st.load_or_create_identity(); assert(d.deviceId.size()==64); assert(st.load_or_create_identity().deviceId==d.deviceId);
 std::vector<std::string> scopes={"operator.read","operator.write","operator.approvals"}; auto payload=build_device_auth_payload_v3(d,"cli","cli","operator",scopes,ch->ts,"tok",ch->nonce,"cli","desktop"); assert(payload.rfind("v3|",0)==0); assert(!sign_device_payload(d,payload).empty());
 st.store_token({"secret-device-token","operator",scopes}); assert(st.load_token()&&st.load_token()->token=="secret-device-token");
 auto pr=parse_pairing_required(R"({"type":"res","ok":false,"error":{"code":"PAIRING_REQUIRED","details":{"requestId":"req-42","recommendedNextStep":"approve"}}})"); assert(pr&&pr->requestId=="req-42");
 auto ht=parse_hello_device_token(R"({"type":"res","ok":true,"payload":{"type":"hello-ok","auth":{"deviceToken":"dt-1","role":"operator","scopes":["operator.read","operator.write"]}}})"); assert(ht&&ht->token=="dt-1"&&ht->scopes.size()==2);
 auto send=GatewayProtocol::chat_send("c1","main","hello","idem","",R"([{"type":"file","fileName":"a.txt","mimeType":"text/plain","content":"YQ=="}])"); assert(send.find("\"attachments\"")!=std::string::npos); auto abort=GatewayProtocol::chat_abort("a1","main","run-1"); assert(abort.find("chat.abort")!=std::string::npos&&abort.find("run-1")!=std::string::npos);
 auto u=parse_gateway_url("ws://127.0.0.1:18789/ws"); assert(!u.secure&&u.host=="127.0.0.1"&&u.port=="18789"&&u.target=="/ws"); auto us=parse_gateway_url("wss://example.com/gateway"); assert(us.secure&&us.port=="443");
 SequenceTracker tr; Frame e1; e1.kind=Frame::Kind::Event; e1.seq=10; auto q1=tr.observe(e1); assert(q1.accept&&!q1.gap); Frame e2=e1; e2.seq=12; auto q2=tr.observe(e2); assert(q2.accept&&q2.gap&&q2.expected&&*q2.expected==11); Frame dup=e2; auto q3=tr.observe(dup); assert(!q3.accept); tr.reset_connection(); Frame fresh=e1; fresh.seq=1; assert(tr.observe(fresh).accept); ReconnectPolicy rp; assert(rp.next_delay_ms()==500); assert(rp.next_delay_ms()==1000);
 std::filesystem::remove_all(tmp); return 0; }
