#pragma once
#include <stdint.h>
#include <string.h>
#include <math.h>

// Portable dual-scale state machine. No serial I/O, waiting loops or camera access.
namespace weight {
static const uint32_t STALE_MS=1500, STABLE_MS=3000, SETTLE_MS=1000, CAL_TIMEOUT_MS=30000, CHANGE_CONFIRM_MS=5000;
static const int CAL_SAMPLES=20;
// Initial experimental tolerances; verify using the installed cells before claiming accuracy.
static constexpr double STABLE_SPAN_G=2.0, ZERO_SPAN_COUNTS=1000.0, ZERO_MAX_SPAN_COUNTS=10000.0;
static void sortValues(double* values,int n){
    for(int i=1;i<n;i++){double v=values[i];int j=i;while(j>0&&values[j-1]>v){values[j]=values[j-1];j--;}values[j]=v;}
}
enum Mode { IDLE, ZERO, MASS, TARE };
struct Scale {
    double zero=0,countsPerGram=0,zeroNoise=0,knownGrams=0;
    bool zeroReady=false,calibrated=false,seen=false,saturated=false;
    int32_t samples[5]={};int count=0,next=0;uint32_t lastSample=0;
    bool stableWindow=false,stable=false,hasTrusted=false;
    double minimum=0,maximum=0,trusted=0;uint32_t stableSince=0,trustedAt=0;
    Mode mode=IDLE;uint32_t started=0;int discarded=0,collected=0;
    int32_t calibration[CAL_SAMPLES]={};int calNext=0;uint32_t lastCalSample=0;
    bool changePending=false;int32_t rawLatest=0;
    uint32_t rejectedWindows=0;double calibrationSpan=0;
    char request[33]={},phase[12]={},reason[40]={};bool event=false;
    void result(const char* state,const char* why){
        strncpy(phase,state,sizeof(phase)-1);strncpy(reason,why,sizeof(reason)-1);event=true;
    }
    void clearFilter(){count=next=0;stableWindow=stable=false;changePending=false;}
    bool fresh(uint32_t now) const {return seen&&uint32_t(now-lastSample)<=STALE_MS&&!saturated&&count>0;}
    double mean() const {
        double sorted[5];for(int i=0;i<count;i++)sorted[i]=samples[i];sortValues(sorted,count);
        return count?sorted[count/2]:0; // median rejects isolated spikes
    }
    double robustSpan() const {
        if(count<5)return 0;
        double sorted[5];for(int i=0;i<5;i++)sorted[i]=samples[i];sortValues(sorted,5);
        return sorted[3]-sorted[1]; // one isolated extreme at either end is ignored
    }
    double jumpLimit() const {
        double limit=fmax(10.0,fabs(trusted)*.10);
        return fmax(limit,6.0*zeroNoise/fabs(countsPerGram));
    }
    bool displayReady(uint32_t now) const {return calibrated&&fresh(now)&&count==5&&mode==IDLE&&!changePending;}
    double grams() const {return (mean()-zero)/countsPerGram;}
    void fail(const char* why){mode=IDLE;result("FAILED",why);clearFilter();}
    void sample(int32_t raw,uint32_t now,bool trustedAllowed){
        if(seen&&uint32_t(now-lastSample)>STALE_MS){clearFilter();collected=calNext=0;}
        rawLatest=raw;seen=true;lastSample=now;saturated=raw==-8388608L||raw==8388607L;
        if(saturated){clearFilter();if(mode!=IDLE)fail("ADC_SATURATED");return;}
        samples[next]=raw;next=(next+1)%5;if(count<5)count++;
        // Manual calibration relies on sensor stability, not camera/bird state.
        if(mode!=IDLE){
            if(uint32_t(now-started)>CAL_TIMEOUT_MS){fail("SAMPLE_TIMEOUT");return;}
            if(uint32_t(now-started)<SETTLE_MS)return;
            if(discarded<4){discarded++;return;}
            if(collected&&uint32_t(now-lastCalSample)<100)return;
            lastCalSample=now;
            calibration[calNext]=raw;calNext=(calNext+1)%CAL_SAMPLES;
            if(collected<CAL_SAMPLES)collected++;
            if(collected<CAL_SAMPLES)return;
            double sorted[CAL_SAMPLES],diffs[CAL_SAMPLES-1];
            for(int i=0;i<CAL_SAMPLES;i++)sorted[i]=calibration[i];
            // Adjacent changes estimate local noise, while the full span still rejects drift.
            for(int i=1;i<CAL_SAMPLES;i++)diffs[i-1]=fabs(double(calibration[(calNext+i)%CAL_SAMPLES])-calibration[(calNext+i-1)%CAL_SAMPLES]);
            sortValues(sorted,CAL_SAMPLES);sortValues(diffs,CAL_SAMPLES-1);
            double average=0;for(int i=1;i<CAL_SAMPLES-1;i++)average+=sorted[i];average/=(CAL_SAMPLES-2);
            const double span=sorted[CAL_SAMPLES-2]-sorted[1];calibrationSpan=span;
            const char* waitReason=nullptr;
            double factor=countsPerGram;
            if(mode==ZERO){
                double limit=fmax(ZERO_SPAN_COUNTS,fmin(ZERO_MAX_SPAN_COUNTS,6.0*diffs[(CAL_SAMPLES-1)/2]));
                if(span>limit)waitReason="WAIT_EMPTY_STABLE";
            }else if(mode==MASS){
                double delta=average-zero,noise=fmax(span,zeroNoise);factor=delta/knownGrams;
                if(fabs(delta)<100||fabs(delta)<noise*10||!isfinite(factor)||factor==0)waitReason="WAIT_MASS_SIGNAL";
                else if(span/fabs(factor)>STABLE_SPAN_G)waitReason="WAIT_MASS_STABLE";
            }else if(span/fabs(countsPerGram)>STABLE_SPAN_G)waitReason="WAIT_TARE_STABLE";
            if(waitReason){
                rejectedWindows++;strncpy(reason,waitReason,sizeof(reason)-1);return;
            }
            if(mode==ZERO){zero=average;zeroNoise=span;zeroReady=true;calibrated=false;countsPerGram=0;}
            else if(mode==MASS){countsPerGram=factor;calibrated=true;}
            else{zero=average;zeroNoise=span;}
            mode=IDLE;hasTrusted=false;clearFilter();result("COMPLETE","OK");return;
        }
        if(!calibrated||count<5){stableWindow=stable=false;return;}
        const double value=grams();
        changePending=hasTrusted&&fabs(value-trusted)>jumpLimit();
        if(!trustedAllowed){stableWindow=stable=false;return;}
        if(robustSpan()/fabs(countsPerGram)>STABLE_SPAN_G){stableWindow=stable=false;return;}
        if(!stableWindow){stableWindow=true;stableSince=now;minimum=maximum=value;}
        if(value<minimum)minimum=value;if(value>maximum)maximum=value;
        if(maximum-minimum>STABLE_SPAN_G){stable=false;stableSince=now;minimum=maximum=value;}
        stable=uint32_t(now-stableSince)>=(changePending?CHANGE_CONFIRM_MS:STABLE_MS);
        if(stable){trusted=value;trustedAt=now;hasTrusted=true;changePending=false;}
    }
    void tick(uint32_t now,bool allowed){
        if(!fresh(now)||!allowed)stableWindow=stable=false;
        if(seen&&uint32_t(now-lastSample)>STALE_MS)clearFilter();
        if(mode!=IDLE){
            if(uint32_t(now-started)>CAL_TIMEOUT_MS)fail("SAMPLE_TIMEOUT");
        }
    }
    // Return rejection reason without replacing an in-progress command's identity.
    const char* command(const char* id,const char* action,double gramsValue,uint32_t now,bool allowed){
        if(!strcmp(id,request)) {event=true;return nullptr;} // duplicate request never repeats tare
        if(mode!=IDLE&&strcmp(action,"CANCEL"))return "BUSY";
        if(!strcmp(action,"CANCEL")){mode=IDLE;clearFilter();strncpy(request,id,32);result("COMPLETE","CANCELLED");return nullptr;}
        if(!strcmp(action,"REMEASURE")){clearFilter();hasTrusted=false;strncpy(request,id,32);result("COMPLETE","REMEASURING");return nullptr;}
        Mode wanted= !strcmp(action,"ZERO")?ZERO:!strcmp(action,"MASS")?MASS:!strcmp(action,"TARE")?TARE:IDLE;
        if(wanted==IDLE)return "UNKNOWN_ACTION";
        if(!fresh(now))return "SENSOR_UNAVAILABLE";
        if(wanted==MASS&&(!zeroReady||!isfinite(gramsValue)||gramsValue<=0||gramsValue>1000000))return "ZERO_REQUIRED_OR_INVALID_MASS";
        if(wanted==TARE&&!calibrated)return "CALIBRATED_WEIGHT_REQUIRED"; // TARE collects its own stable window, independent of vision.
        strncpy(request,id,32);mode=wanted;knownGrams=gramsValue;started=now;discarded=collected=calNext=0;rejectedWindows=0;calibrationSpan=0;
        stableWindow=stable=false;result("ACCEPTED","COLLECTING");return nullptr;
    }
    const char* status(uint32_t now,bool visionValid,bool bird,bool allowed) const {
        if(saturated)return "SATURATED";
        if(!seen||uint32_t(now-lastSample)>STALE_MS)return "OFFLINE";
        if(mode!=IDLE)return "CALIBRATING";
        if(!calibrated)return zeroReady?"AWAITING_MASS":"UNCALIBRATED";
        if(!visionValid)return "VISION_UNAVAILABLE";
        if(bird)return "BIRD_INTERFERENCE";
        if(!allowed)return "SETTLING";
        if(changePending)return "CHANGE_PENDING";
        return stable?"STABLE":"UNSTABLE";
    }
};
struct Core {
    Scale scales[2];bool visionValid=false,bird=false,clearStarted=false;uint32_t clearSince=0;
    void vision(bool valid,bool present,uint32_t now){
        visionValid=valid;bird=present;
        if(!valid||present)clearStarted=false;
        else if(!clearStarted){clearStarted=true;clearSince=now;}
    }
    bool allowed(uint32_t now) const{return visionValid&&!bird&&clearStarted&&uint32_t(now-clearSince)>=STABLE_MS;}
    void tick(uint32_t now){for(int i=0;i<2;i++)scales[i].tick(now,allowed(now));}
};
}
