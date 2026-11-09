#pragma once
#include <stdint.h>
#include <stddef.h>
#include <math.h>
#include <string.h>

// Portable board-side algorithm. No heap allocation, SDK or host inference.
namespace bird {
static const int MAX_TRACKS = 8, MAX_GROUPS = 16, DIM = 80, THUMB_SIDE = 24, THUMB_BYTES = THUMB_SIDE*THUMB_SIDE*3;
static const uint32_t LOST_MS = 3000, SAMPLE_MS = 500;
struct Box { float x1,y1,x2,y2; };
inline float low(float a,float b){return a<b?a:b;}
inline float high(float a,float b){return a>b?a:b;}
inline float clip(float a){return high(0.f,low(1.f,a));}
inline float area(Box b){return high(0.f,b.x2-b.x1)*high(0.f,b.y2-b.y1);}
inline float iou(Box a,Box b){float x=high(0.f,low(a.x2,b.x2)-high(a.x1,b.x1));float y=high(0.f,low(a.y2,b.y2)-high(a.y1,b.y1));float v=x*y;return v/high(.000001f,area(a)+area(b)-v);}
struct Feature { float v[DIM]; uint8_t thumb[THUMB_BYTES]; bool valid; };
struct Detection { Box box; int score; Feature feature; };
struct Frame { uint32_t sequence,ms; int count,overflow; Detection items[MAX_TRACKS]; };

// RGB888 planar, as used by Ameba SDK 4.1.0 YOLO input. Sample within crop;
// no independent camera fetch, no JPEG decode, and no dangling frame pointer.
inline void extractInto(Feature& f,const uint8_t* rgb,size_t bytes,int w,int h,Box b){
    memset(&f,0,sizeof(f));
    if(!rgb || w<1 || h<1 || bytes<size_t(w)*h*3) return;
    if(!isfinite(b.x1)||!isfinite(b.y1)||!isfinite(b.x2)||!isfinite(b.y2))return;
    b.x1=clip(b.x1);b.y1=clip(b.y1);b.x2=clip(b.x2);b.y2=clip(b.y2);
    if((b.x2-b.x1)*w<16 || (b.y2-b.y1)*h<16)return;
    Box photo=b;
    float dx=(b.x2-b.x1)*.1f,dy=(b.y2-b.y1)*.1f;
    b.x1+=dx;b.x2-=dx;b.y1+=dy;b.y2-=dy;
    uint8_t gray[16][16];
    const int plane=w*h;
    for(int y=0;y<16;y++)for(int x=0;x<16;x++){
        int ix=int((b.x1+(x+.5f)/16*(b.x2-b.x1))*w);
        int iy=int((b.y1+(y+.5f)/16*(b.y2-b.y1))*h);
        if(ix>=w)ix=w-1;if(iy>=h)iy=h-1;
        int p=iy*w+ix;
        float r=rgb[p]/255.f,g=rgb[p+plane]/255.f,bl=rgb[p+2*plane]/255.f;
        float mx=high(r,high(g,bl)),mn=low(r,low(g,bl)),d=mx-mn;
        float hue=0,sat=mx>0?d/mx:0;
        if(d>0){if(mx==r)hue=(g-bl)/d;else if(mx==g)hue=2+(bl-r)/d;else hue=4+(r-g)/d;hue/=6;if(hue<0)hue+=1;}
        int hb=int(hue*8);if(hb>7)hb=7;
        int vb=int(mx*8);if(vb>7)vb=7;
        float hf=hue*8-hb,sw=low(1.f,sat/.5f);
        f.v[hb]+=.6f*(1-hf)*(1-sw)/256;
        f.v[(hb+1)%8]+=.6f*hf*(1-sw)/256;
        f.v[hb+8]+=.6f*(1-hf)*sw/256;
        f.v[(hb+1)%8+8]+=.6f*hf*sw/256;
        f.v[16+vb]+=.2f/256;
        // Three vertical regions preserve where colours occur, unlike a global histogram.
        int zone=y<5?0:(y<11?1:2),base=32+zone*16;
        float pixels=zone==1?96.f:80.f;
        f.v[base+hb]+=(1-hf)*(1-sw)/pixels;
        f.v[base+(hb+1)%8]+=hf*(1-sw)/pixels;
        f.v[base+hb+8]+=(1-hf)*sw/pixels;
        f.v[base+(hb+1)%8+8]+=hf*sw/pixels;
        gray[y][x]=uint8_t((r*.299f+g*.587f+bl*.114f)*255);

    }
    // Rotation-tolerant LBP population histogram, weighted below colour.
    for(int y=1;y<15;y++)for(int x=1;x<15;x++){
        int n=0;for(int dy=-1;dy<=1;dy++)for(int dx=-1;dx<=1;dx++)if(dx||dy)n+=gray[y+dy][x+dx]>=gray[y][x];
        if(n>7)n=7;f.v[24+n]+=.2f/196;
    }
    for(int y=0;y<THUMB_SIDE;y++)for(int x=0;x<THUMB_SIDE;x++){
        int ix=int((photo.x1+(x+.5f)/THUMB_SIDE*(photo.x2-photo.x1))*w);
        int iy=int((photo.y1+(y+.5f)/THUMB_SIDE*(photo.y2-photo.y1))*h);
        if(ix>=w)ix=w-1;if(iy>=h)iy=h-1;
        int p=iy*w+ix,t=(y*THUMB_SIDE+x)*3;
        f.thumb[t]=rgb[p];f.thumb[t+1]=rgb[p+plane];f.thumb[t+2]=rgb[p+2*plane];
    }
    f.valid=true;return;
}
inline Feature extract(const uint8_t* rgb,size_t bytes,int w,int h,Box b){
    Feature f;extractInto(f,rgb,bytes,w,h,b);return f;
}
inline float regionDistance(const float* a,const float* b){
    float worst=0;
    for(int z=0;z<3;z++){float d=0;for(int k=32+z*16;k<48+z*16;k++)d+=fabsf(a[k]-b[k]);worst=high(worst,d*.5f);}
    return worst;
}
inline float distance(const float* a,const float* b){
    float global=0,spatial=0;
    for(int k=0;k<32;k++)global+=fabsf(a[k]-b[k]);
    for(int k=32;k<DIM;k++)spatial+=fabsf(a[k]-b[k]);
    return .5f*(global*.5f)+.5f*(spatial/6.f);
}
struct Group { bool used; float mean[DIM],anchor[DIM]; uint32_t visits,generation; uint8_t thumb[THUMB_BYTES]; };
struct Track {
    bool used,confirmed,visible,eligible,assigned,ignored,awaitingClock;
    uint32_t id,first,last,lastSample,eligibleDay,bestSampleMs,bestSampleSequence;
    int hits,samples,group,score,bestSampleScore;
    // Distances to nearest existing centroid, its fixed anchor and worst colour region.
    int candidateGroup,groupDecision; // 1=new, 2=matched, 3=capacity
    float meanDistance,anchorDistance,regionDifference,similarity;
    int decisionThreshold; uint32_t candidateGeneration,candidateDay;
    Box box,bestSampleBox;float sum[DIM];uint8_t thumb[THUMB_BYTES];
};
typedef void (*EventFn)(const char*,const Track&,uint32_t);
class Core {
public:
    Track tracks[MAX_TRACKS]={};Group groups[MAX_GROUPS]={};
    uint32_t nextGroup=0,nextId=0,total=0,daily=0,day=0,lastFrame=0,lastSequence=0,overflows=0;
    uint32_t syncMs=0,syncEpoch=0;bool clockValid=false;
    EventFn event=nullptr;
    // Total-variation distance threshold: experimental, not species confidence.
    float groupThreshold=.24f;
    static constexpr float ANCHOR_THRESHOLD=.26f, REGION_THRESHOLD=.32f;
    int confidence=20,similarityThreshold=76;
    bool setSimilarity(int value){
        if(value<0||value>100)return false;
        similarityThreshold=value;groupThreshold=(100-value)/100.f;return true;
    }
    // Normalize all three legacy limits to one score; 76% retains default gates.
    static float similarityScore(float d,float a,float r){
        return 100.f*(1.f-clip(high(d,high(a*(.24f/.26f),r*(.24f/.32f)))));
    }
    bool setConfidence(int value){
        if(value<20||value>100)return false;
        if(value!=confidence){
            confidence=value;
            for(int i=0;i<MAX_TRACKS;i++)if(tracks[i].used&&!tracks[i].assigned){
                tracks[i].samples=0;tracks[i].bestSampleScore=0;
                memset(tracks[i].sum,0,sizeof(tracks[i].sum));
            }
        }
        return true;
    }
    uint32_t epoch(uint32_t now) const {
        // Queued images may predate TIME. Signed modular delta also handles
        // millis wrap; host resynchronizes every minute (well below 2^31 ms).
        int32_t delta=(int32_t)(now-syncMs);
        int64_t seconds=delta>=0?delta/1000:-((-(int64_t)delta+999)/1000);
        return uint32_t(int64_t(syncEpoch)+seconds);
    }
    bool window(uint32_t now) const {if(!clockValid)return false;uint32_t s=(epoch(now)+28800)%86400;return s>=8*3600&&s<17*3600;}
    bool sync(uint32_t value,uint32_t now){
        if(value<1700000000u || value>4100000000u)return false;
        // Do not destroy today's groups on a backwards clock correction.
        if(clockValid && value+2<epoch(now))return false;
        syncEpoch=value;syncMs=now;clockValid=true;rollDay(now);return true;
    }
    void rollDay(uint32_t now){
        if(!clockValid)return;uint32_t d=(epoch(now)+28800)/86400;
        if(day>=d)return; // Late frames must never roll the daily state backwards.
        day=d;daily=0;memset(groups,0,sizeof(groups));
        for(int i=0;i<MAX_TRACKS;i++)if(tracks[i].used){tracks[i].eligible=false;tracks[i].group=0;tracks[i].assigned=false;}
    }
    void expire(uint32_t now){
        rollDay(now);
        for(int i=0;i<MAX_TRACKS;i++){
            Track& t=tracks[i];if(!t.used)continue;
            if(uint32_t(now-t.last)>LOST_MS){if(t.confirmed&&event)event("END",t,now);t=Track{};}
        }
    }
    bool deleteGroup(uint32_t expectedDay,uint32_t generation,uint32_t now){
        rollDay(now);
        if(expectedDay!=day || !generation)return false;
        for(int i=0;i<MAX_GROUPS;i++){
            Group& g=groups[i];if(!g.used||g.generation!=generation)continue;
            uint32_t removed=g.visits;
            daily=daily>=removed?daily-removed:0;
            total=total>=removed?total-removed:0;
            for(int j=0;j<MAX_TRACKS;j++){
                Track& t=tracks[j];
                if(t.used&&t.group==i+1){
                    t.ignored=true;t.eligible=false;t.assigned=true;t.group=0;
                }
            }
            g=Group{};return true;
        }
        return false;
    }
    void classify(Track& t,uint32_t now){
        if(t.score<confidence || t.ignored || t.assigned || t.samples<5 || !t.eligible || t.eligibleDay!=day)return;
        float v[DIM];for(int k=0;k<DIM;k++)v[k]=t.sum[k]/t.samples;
        int best=-1,empty=-1;float bd=2,nearest=-1;
        t.decisionThreshold=similarityThreshold;t.similarity=-1;t.candidateGeneration=0;t.candidateDay=day;
        t.meanDistance=t.anchorDistance=t.regionDifference=-1;t.candidateGroup=0;
        for(int g=0;g<MAX_GROUPS;g++){
            if(!groups[g].used){if(empty<0)empty=g;continue;}
            float d=distance(v,groups[g].mean),a=distance(v,groups[g].anchor);
            float r=high(regionDistance(v,groups[g].mean),regionDistance(v,groups[g].anchor));
            float score=similarityScore(d,a,r);
            if(score>nearest){nearest=score;t.similarity=score;t.candidateGroup=g+1;t.candidateGeneration=groups[g].generation;t.meanDistance=d;t.anchorDistance=a;t.regionDifference=r;}
            if(d<bd&&score+0.00001f>=similarityThreshold){bd=d;best=g;}
        }
        t.groupDecision=best>=0?2:1;
        if(best>=0){
            t.candidateGroup=best+1;t.candidateGeneration=groups[best].generation;t.meanDistance=distance(v,groups[best].mean);
            t.anchorDistance=distance(v,groups[best].anchor);
            t.regionDifference=high(regionDistance(v,groups[best].mean),regionDistance(v,groups[best].anchor));
            t.similarity=similarityScore(t.meanDistance,t.anchorDistance,t.regionDifference);
        }else best=empty;
        if(best<0)t.groupDecision=3;
        t.assigned=true;
        if(best>=0){Group& g=groups[best];
            if(!g.used){g.used=true;g.generation=++nextGroup;memcpy(g.anchor,v,sizeof(g.anchor));memcpy(g.thumb,t.thumb,sizeof(g.thumb));}
            for(int k=0;k<DIM;k++)g.mean[k]=(g.mean[k]*g.visits+v[k])/(g.visits+1);
            g.visits++;t.group=best+1;
        } // group=0 when all slots full: never force a match.
        if(event)event("GROUP",t,now);
    }
    void process(const Frame& f){
        if(f.sequence==lastSequence)return;lastSequence=f.sequence;lastFrame=f.ms;
        expire(f.ms);overflows+=f.overflow;
        bool dt[MAX_TRACKS]={},tt[MAX_TRACKS]={};
        for(int i=0;i<MAX_TRACKS;i++)tracks[i].visible=false;
        int count=f.count<MAX_TRACKS?f.count:MAX_TRACKS;
        // Global greedy one-to-one matching. Spatial gates prevent distant jumps.
        for(int pass=0;pass<MAX_TRACKS;pass++){
            int bi=-1,bj=-1;float best=1.1f;
            for(int i=0;i<MAX_TRACKS;i++)if(tracks[i].used&&!tt[i])for(int j=0;j<count;j++)if(!dt[j]&&f.items[j].score>=confidence){
                Box a=tracks[i].box,b=f.items[j].box;float ov=iou(a,b);
                float dx=(a.x1+a.x2-b.x1-b.x2)*.5f,dy=(a.y1+a.y2-b.y1-b.y2)*.5f;
                float dist=sqrtf(dx*dx+dy*dy),ratio=area(b)/high(area(a),.000001f);
                if(ratio<.25f||ratio>4 || (ov<.1f&&dist>.12f))continue;
                float cost=(1-ov)*.7f+dist*.3f;
                if(cost<best){best=cost;bi=i;bj=j;}
            }
            if(bi<0)break;tt[bi]=true;dt[bj]=true;update(tracks[bi],f.items[bj],f.ms);
        }
        for(int i=0;i<MAX_TRACKS;i++)if(tracks[i].used&&!tt[i]&&!tracks[i].confirmed)tracks[i].hits=0;
        for(int j=0;j<count;j++)if(!dt[j]&&f.items[j].score>=confidence){
            int slot=-1;for(int i=0;i<MAX_TRACKS;i++)if(!tracks[i].used){slot=i;break;}
            if(slot<0){overflows++;continue;}
            Track& t=tracks[slot];t=Track{};t.used=true;t.id=++nextId;t.first=f.ms;
            t.awaitingClock=!clockValid;t.eligible=clockValid;t.eligibleDay=day;update(t,f.items[j],f.ms);
        }
    }
    void update(Track& t,const Detection& d,uint32_t now){
        t.box=d.box;t.score=d.score;t.last=now;t.visible=true;t.hits++;if(t.ignored)return;
        // Only tracks born before the first clock sync may gain eligibility.
        // Require a fresh accepted detection, not merely an old retained track.
        if(t.awaitingClock&&clockValid){
            t.awaitingClock=false;t.eligible=clockValid;t.eligibleDay=day;
            if(t.eligible&&t.confirmed){daily++;if(event)event("ELIGIBLE",t,now);}
        }
        if(!t.confirmed&&t.hits>=3){t.confirmed=true;total++;
            if(t.eligible&&t.eligibleDay==day)daily++;else t.eligible=false;
            if(event)event("START",t,now);
        }
        if(t.confirmed&&d.feature.valid&&d.score>=confidence&&t.samples<5 &&
           (t.samples==0||uint32_t(now-t.lastSample)>=SAMPLE_MS)){
            for(int k=0;k<DIM;k++)t.sum[k]+=d.feature.v[k];
            if(d.score>t.bestSampleScore){memcpy(t.thumb,d.feature.thumb,sizeof(t.thumb));t.bestSampleScore=d.score;t.bestSampleMs=now;t.bestSampleSequence=lastSequence;t.bestSampleBox=d.box;}t.samples++;t.lastSample=now;
        }
        classify(t,now);
    }
};
}
