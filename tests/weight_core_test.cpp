#include "WeightCore.h"
#include <assert.h>
#include <stdio.h>
using namespace weight;
static uint32_t now=10000;
static void sample(Scale& s,int32_t raw,int n=1,bool allowed=true){for(int i=0;i<n;i++){now+=100;s.sample(raw,now,allowed);s.tick(now,allowed);}}
static const char* id1="11111111111111111111111111111111";
static const char* id2="22222222222222222222222222222222";
static const char* id3="33333333333333333333333333333333";
static const char* id4="44444444444444444444444444444444";
int main(){
 Core c;c.vision(true,false,now);assert(!c.allowed(now));now+=3000;c.vision(true,false,now);assert(c.allowed(now));
 Scale& s=c.scales[0];sample(s,1000,5);
 assert(!s.calibrated&&!s.command(id1,"ZERO",0,now,true));
 assert(!strcmp(s.phase,"ACCEPTED"));sample(s,1000,40);
 assert(s.zeroReady&&!s.calibrated&&!strcmp(s.phase,"COMPLETE"));
 sample(s,11000,5);assert(!s.command(id2,"MASS",100,now,true));sample(s,11000,40);
 assert(s.calibrated&&s.countsPerGram==100);sample(s,11000,40);
 assert(s.stable&&s.hasTrusted&&s.trusted==100);
 assert(!c.scales[1].calibrated); // independent channels
 const double zero=s.zero,factor=s.countsPerGram;
 assert(!s.command(id3,"REMEASURE",0,now,true));assert(s.zero==zero&&s.countsPerGram==factor&&!s.hasTrusted);
 assert(!strcmp(s.status(now,true,false,true),"UNSTABLE"));
 sample(s,6000,40);assert(s.stable&&s.trusted==50);
 assert(!s.command(id4,"TARE",0,now,true));sample(s,6000,40);sample(s,6000,40);
 assert(s.zero==6000&&s.countsPerGram==factor&&s.trusted==0);
 const auto started=s.started;assert(!s.command(id4,"TARE",0,now,true)&&s.started==started&&s.mode==IDLE);
 sample(s,7000,40);const double trusted=s.trusted;
 sample(s,21000,10,false);assert(!s.stable&&s.trusted==trusted);
 c.vision(true,true,now);assert(!c.allowed(now));c.vision(false,false,now);assert(!c.allowed(now));
 assert(!s.command(id1,"ZERO",0,now,false));
 assert(!s.command(id2,"CANCEL",0,now,false));
 s.tick(now+STALE_MS+1,true);assert(!s.fresh(now+STALE_MS+1)&&!s.stable);
 sample(s,7000,1);assert(!s.stable&&s.count==1);
 sample(s,8388607,1);assert(s.saturated&&!s.fresh(now));sample(s,7000,5);
 // Failed recalibration preserves the prior valid factor.
 assert(!s.command(id1,"MASS",100,now,true));
 sample(s,7000,5);s.tick(now+CAL_TIMEOUT_MS+1,true);
 assert(!strcmp(s.phase,"FAILED")&&s.calibrated&&s.countsPerGram==factor);
 sample(s,7000,5);assert(!s.command(id2,"ZERO",0,now,true));
 for(int i=0;i<40;i++)sample(s,i%2?20000:7000);
 assert(s.mode==ZERO&&s.rejectedWindows>0&&s.zero==6000&&s.calibrated);
 s.tick(now+CAL_TIMEOUT_MS+1,true);assert(!strcmp(s.phase,"FAILED")&&s.zero==6000&&s.calibrated);
 sample(s,7000,5);assert(!s.command(id3,"ZERO",0,now,true));
 assert(!strcmp(s.command(id1,"MASS",100,now,true),"BUSY"));
 assert(!s.command(id4,"CANCEL",0,now,true)&&s.mode==IDLE);
 assert(!strcmp(s.reason,"CANCELLED"));
 // Negative slope is valid; calibration does not assume the load-cell polarity.
 Scale negative;sample(negative,50000,5);assert(!negative.command(id1,"ZERO",0,now,true));sample(negative,50000,40);
 sample(negative,40000,5);assert(!negative.command(id2,"MASS",100,now,true));sample(negative,40000,40);sample(negative,40000,40);
 assert(negative.countsPerGram==-100&&negative.trusted==100);
 assert(negative.command(id3,"MASS",NAN,now,true));
 assert(negative.command(id3,"MASS",0,now,true));
 assert(negative.command(id3,"MASS",1000001,now,true));
 // A rolling disturbance cannot be declared stable; reconnect starts a new window.
 for(int i=0;i<60;i++)sample(negative,i%2?35000:40000);
 assert(!negative.stable);
 // A single raw spike cannot turn a 160 g reading into 110 g.
 Scale robust;robust.zeroReady=robust.calibrated=true;robust.countsPerGram=100;
 sample(robust,16000,40);assert(robust.trusted==160);
 sample(robust,11000);assert(robust.grams()==160&&!robust.changePending);
 sample(robust,16000,5);assert(robust.trusted==160);
 // A sustained real step must be hidden until confirmed, then accepted.
 sample(robust,11000,10);assert(robust.changePending&&!robust.displayReady(now)&&robust.trusted==160);
 sample(robust,11000,60);assert(robust.stable&&robust.trusted==110&&robust.displayReady(now));
 sample(robust,23000,10);assert(robust.changePending&&robust.trusted==110);
 sample(robust,23000,60);assert(robust.trusted==230&&robust.stable);
 // Continued alternating disturbances cannot become a new trusted weight.
 for(int i=0;i<100;i++)sample(robust,i%2?11000:23000);
 assert(!robust.stable&&robust.trusted==230);
 // Bird interference and lost samples must interrupt the confirmation interval.
 sample(robust,11000,20);sample(robust,11000,20,false);sample(robust,11000,20);
 assert(robust.changePending&&robust.trusted==230);
 sample(robust,11000,60);assert(robust.trusted==110);
 // Noisy initialization waits instead of failing, then succeeds when quiet.
 Scale waiting;sample(waiting,1000,5);assert(!waiting.command(id1,"ZERO",0,now,true));
 for(int i=0;i<60;i++)sample(waiting,i%2?40000:1000);
 assert(waiting.mode==ZERO&&waiting.rejectedWindows>0&&!waiting.zeroReady);
 sample(waiting,1000,40);assert(waiting.zeroReady&&waiting.zero==1000);
 // Modest zero noise above the old fixed cap can calibrate, within a bounded tolerance.
 Scale noisy;sample(noisy,10000,5);assert(!noisy.command(id1,"ZERO",0,now,true));
 for(int i=0;i<40;i++)sample(noisy,i%2?11000:9000);
 assert(noisy.zeroReady&&noisy.zeroNoise==2000);
 // An isolated outlier in every 20 calibration samples is trimmed out.
 sample(waiting,11000,5);assert(!waiting.command(id2,"MASS",100,now,true));
 for(int i=0;i<60;i++)sample(waiting,i%20==15?800000:11000);
 assert(waiting.calibrated&&waiting.countsPerGram==100);
 // Slow drift cannot exploit the adaptive zero-noise allowance.
 Scale drift;sample(drift,1000,5);assert(!drift.command(id1,"ZERO",0,now,true));
 for(int i=0;i<70;i++)sample(drift,1000+i*200);
 assert(!drift.zeroReady&&drift.mode==ZERO);
 // Failed mass calibration keeps the previously usable coefficient.
 sample(waiting,11000,5);assert(!waiting.command(id3,"MASS",100,now,true));
 for(int i=0;i<310;i++)sample(waiting,i%2?11000:51000);
 assert(waiting.calibrated&&waiting.countsPerGram==100&&!strcmp(waiting.phase,"FAILED"));
 // All manual calibration steps succeed even with vision/bird gating closed.
 Scale manual;sample(manual,1000,5,false);
 assert(!manual.command(id1,"ZERO",0,now,false));sample(manual,1000,40,false);
 assert(manual.zeroReady&&!strcmp(manual.phase,"COMPLETE"));
 sample(manual,11000,5,false);assert(!manual.command(id2,"MASS",100,now,false));
 sample(manual,11000,40,false);assert(manual.calibrated&&manual.countsPerGram==100);
 sample(manual,1000,5,false);assert(!manual.stable);
 assert(!manual.command(id3,"TARE",0,now,false));sample(manual,1000,40,false);
 assert(manual.zero==1000&&!strcmp(manual.phase,"COMPLETE"));
 sample(manual,11000,50,false);assert(!manual.stable&&!manual.hasTrusted);
 // Removing camera gating must not allow unstable calibration or hide sensor failures.
 assert(!manual.command(id4,"MASS",100,now,false));
 for(int i=0;i<310;i++)sample(manual,i%2?1000:51000,1,false);
 assert(!strcmp(manual.phase,"FAILED")&&manual.countsPerGram==100);
 sample(manual,1000,5,false);assert(!manual.command(id1,"ZERO",0,now,false));
 sample(manual,8388607,1,false);assert(!strcmp(manual.reason,"ADC_SATURATED"));
 assert(manual.command(id2,"ZERO",0,now,false));
 printf("PASS: independent calibration, polarity, tare, remeasure, noise, stale, bird gating, timeout, cancellation, replay\n");
}
