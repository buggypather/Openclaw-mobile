#include "openclaw/device_identity.hpp"
#include <openssl/evp.h>
#include <openssl/pem.h>
#include <openssl/sha.h>
#include <algorithm>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <stdexcept>
#ifndef _WIN32
#include <sys/stat.h>
#endif
namespace openclaw { namespace {
std::string b64url(const unsigned char* p,size_t n){std::string s(4*((n+2)/3),'\0');int m=EVP_EncodeBlock((unsigned char*)s.data(),p,(int)n);s.resize(m);for(char&c:s){if(c=='+')c='-';else if(c=='/')c='_';}while(!s.empty()&&s.back()=='=')s.pop_back();return s;}
std::string hex(const unsigned char*p,size_t n){static const char*d="0123456789abcdef";std::string s;s.reserve(n*2);for(size_t i=0;i<n;++i){s+=d[p[i]>>4];s+=d[p[i]&15];}return s;}
std::string esc(const std::string&s){std::string o;for(char c:s){if(c=='"'||c=='\\')o+='\\';if(c=='\n')o+="\\n";else if(c!='\r')o+=c;}return o;}
std::string field(const std::string&j,const std::string&k){auto p=j.find("\""+k+"\"");if(p==std::string::npos)return{};p=j.find(':',p);p=j.find('"',p);if(p==std::string::npos)return{};++p;std::string o;bool e=false;for(;p<j.size();++p){char c=j[p];if(e){if(c=='n')o+='\n';else o+=c;e=false;}else if(c=='\\')e=true;else if(c=='"')break;else o+=c;}return o;}
std::vector<std::string> array_field(const std::string&j,const std::string&k){std::vector<std::string>o;auto p=j.find("\""+k+"\"");if(p==std::string::npos)return o;p=j.find('[',p);auto e=j.find(']',p);if(p==std::string::npos||e==std::string::npos)return o;while((p=j.find('"',p+1))<e){auto q=j.find('"',p+1);if(q==std::string::npos||q>e)break;o.push_back(j.substr(p+1,q-p-1));p=q;}return o;}
void secure_write(const std::filesystem::path&p,const std::string&s){std::filesystem::create_directories(p.parent_path());std::ofstream f(p,std::ios::trunc);if(!f)throw std::runtime_error("cannot write "+p.string());f<<s;f.close();
#ifndef _WIN32
chmod(p.c_str(),0600);chmod(p.parent_path().c_str(),0700);
#endif
}
std::string readall(const std::filesystem::path&p){std::ifstream f(p);return f?std::string((std::istreambuf_iterator<char>(f)),{}):std::string{};}
std::string default_root(){if(const char*p=std::getenv("OPENCLAW_MOBILE_HOME"))return p;
#ifdef _WIN32
if(const char*p=std::getenv("USERPROFILE"))return std::string(p)+"\\.openclaw-mobile";return ".openclaw-mobile";
#else
if(const char*p=std::getenv("HOME"))return std::string(p)+"/.openclaw-mobile";return ".openclaw-mobile";
#endif
}
}
DeviceStore::DeviceStore(std::string root):root_(root.empty()?default_root():std::move(root)){}
DeviceIdentity DeviceStore::load_or_create_identity(){auto path=std::filesystem::path(root_)/"identity/device.json";auto old=readall(path);if(!old.empty()){DeviceIdentity d{field(old,"deviceId"),field(old,"publicKey"),field(old,"privateKeyPem")};if(!d.deviceId.empty()&&!d.publicKeyBase64Url.empty()&&!d.privateKeyPem.empty())return d;}
 EVP_PKEY_CTX*ctx=EVP_PKEY_CTX_new_id(EVP_PKEY_ED25519,nullptr);EVP_PKEY*key=nullptr;if(!ctx||EVP_PKEY_keygen_init(ctx)<=0||EVP_PKEY_keygen(ctx,&key)<=0)throw std::runtime_error("Ed25519 generation failed");unsigned char pub[32];size_t pn=32;EVP_PKEY_get_raw_public_key(key,pub,&pn);unsigned char dig[SHA256_DIGEST_LENGTH];SHA256(pub,pn,dig);BIO*b=BIO_new(BIO_s_mem());PEM_write_bio_PrivateKey(b,key,nullptr,nullptr,0,nullptr,nullptr);BUF_MEM*bm;BIO_get_mem_ptr(b,&bm);DeviceIdentity d{hex(dig,sizeof dig),b64url(pub,pn),std::string(bm->data,bm->length)};BIO_free(b);EVP_PKEY_free(key);EVP_PKEY_CTX_free(ctx);secure_write(path,"{\n  \"version\":1,\n  \"deviceId\":\""+d.deviceId+"\",\n  \"publicKey\":\""+d.publicKeyBase64Url+"\",\n  \"privateKeyPem\":\""+esc(d.privateKeyPem)+"\"\n}\n");return d;}
std::optional<DeviceToken> DeviceStore::load_token()const{auto j=readall(std::filesystem::path(root_)/"identity/device-auth.json");if(j.empty())return{};DeviceToken t{field(j,"token"),field(j,"role"),array_field(j,"scopes")};if(t.token.empty())return{};return t;}
void DeviceStore::store_token(const DeviceToken&t)const{std::string a="[";for(size_t i=0;i<t.scopes.size();++i){if(i)a+=',';a+="\""+esc(t.scopes[i])+"\"";}a+=']';secure_write(std::filesystem::path(root_)/"identity/device-auth.json","{\"version\":1,\"token\":\""+esc(t.token)+"\",\"role\":\""+esc(t.role)+"\",\"scopes\":"+a+"}\n");}
void DeviceStore::clear_token()const{std::error_code ec;std::filesystem::remove(std::filesystem::path(root_)/"identity/device-auth.json",ec);}
std::string build_device_auth_payload_v3(const DeviceIdentity&d,const std::string&cid,const std::string&mode,const std::string&role,const std::vector<std::string>&sc,std::int64_t ts,const std::string&tok,const std::string&nonce,const std::string&platform,const std::string&family){std::string ss;for(size_t i=0;i<sc.size();++i){if(i)ss+=',';ss+=sc[i];}return "v3|"+d.deviceId+'|'+cid+'|'+mode+'|'+role+'|'+ss+'|'+std::to_string(ts)+'|'+tok+'|'+nonce+'|'+platform+'|'+family;}
std::string sign_device_payload(const DeviceIdentity&d,const std::string&p){BIO*b=BIO_new_mem_buf(d.privateKeyPem.data(),(int)d.privateKeyPem.size());EVP_PKEY*k=PEM_read_bio_PrivateKey(b,nullptr,nullptr,nullptr);BIO_free(b);if(!k)throw std::runtime_error("invalid private key");EVP_MD_CTX*m=EVP_MD_CTX_new();size_t n=0;if(EVP_DigestSignInit(m,nullptr,nullptr,nullptr,k)<=0||EVP_DigestSign(m,nullptr,&n,(const unsigned char*)p.data(),p.size())<=0)throw std::runtime_error("Ed25519 sign failed");std::vector<unsigned char>s(n);if(EVP_DigestSign(m,s.data(),&n,(const unsigned char*)p.data(),p.size())<=0)throw std::runtime_error("Ed25519 sign failed");EVP_MD_CTX_free(m);EVP_PKEY_free(k);return b64url(s.data(),n);}
std::string device_json(const DeviceIdentity&d,const std::string&sig,std::int64_t ts,const std::string&nonce){return "{\"id\":\""+d.deviceId+"\",\"publicKey\":\""+d.publicKeyBase64Url+"\",\"signature\":\""+sig+"\",\"signedAt\":"+std::to_string(ts)+",\"nonce\":\""+esc(nonce)+"\"}";}
std::optional<PairingRequired> parse_pairing_required(const std::string&j){if(j.find("PAIRING_REQUIRED")==std::string::npos)return{};PairingRequired p{field(j,"requestId"),field(j,"recommendedNextStep")};return p;}
std::optional<DeviceToken> parse_hello_device_token(const std::string&j){auto t=field(j,"deviceToken");if(t.empty())return{};return DeviceToken{t,field(j,"role"),array_field(j,"scopes")};}
}
