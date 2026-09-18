#include "openclaw/recovery.hpp"
#include <algorithm>
namespace openclaw {
SequenceDecision SequenceTracker::observe(const Frame& f){SequenceDecision d;if(!f.seq)return d;if(lastOuter_){if(*f.seq<=*lastOuter_){d.accept=false;return d;}auto e=*lastOuter_+1;if(*f.seq!=e){d.gap=true;d.expected=e;}}lastOuter_=*f.seq;return d;}
void SequenceTracker::reset_connection(){lastOuter_.reset();}
std::uint32_t ReconnectPolicy::next_delay_ms(){auto shift=std::min<std::uint32_t>(attempt++,16);std::uint64_t v=(std::uint64_t)baseMs<<shift;return (std::uint32_t)std::min<std::uint64_t>(v,maxMs);}
}
