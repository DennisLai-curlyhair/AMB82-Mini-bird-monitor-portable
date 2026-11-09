#include "VisualCore.h"
#include <assert.h>
#include <stdio.h>
#include "appearance_fixtures.h"
using namespace bird;
static uint32_t seq=0;
static Frame frame(uint32_t ms,int count=1){Frame f={};f.sequence=++seq;f.ms=ms;f.count=count;for(int i=0;i<count;i++){f.items[i].box=Box{.1f+i*.4f,.1f,.3f+i*.4f,.4f};f.items[i].score=90;f.items[i].feature.valid=true;f.items[i].feature.v[i]=1;}return f;}
static bird::Core visual;
struct TestSerial { template<class T> void print(const T&){} template<class T> void print(const T&,int){} template<class T> void println(const T&){} };
static TestSerial Serial;
static void printThumb(const uint8_t*){}
static void useRealRandomGenerator(bool){}
static long random(long upper){static long n=1;return n++%upper;}
#include "VisitArchive.h"
int main(){
    Core low;assert(low.confidence==20);assert(!low.setConfidence(19));assert(low.setConfidence(20));
    low.sync(20000u*86400+3600,0);
    for(uint32_t m=0;m<=2500;m+=100){Frame f=frame(m);f.items[0].score=19;low.process(f);}
    assert(low.total==0);
    for(uint32_t m=2600;m<=5200;m+=100){Frame f=frame(m);f.items[0].score=20;low.process(f);}
    assert(low.total==1);

    Core c;assert(c.sync(1792285200u,0)); // 2026-10-18 09:00 Taipei (verified separately)
    // Use an epoch computed to fall at 09:00 local regardless of fixture date.
    c=Core{};assert(c.sync(20000u*86400+3600,0));assert(c.window(0));
    for(uint32_t m=0;m<=300000;m+=100)c.process(frame(m));
    assert(c.total==1&&c.daily==1&&c.groups[0].visits==1);
    Frame same=frame(300100);c.process(same);uint32_t n=c.total;c.process(same);assert(c.total==n);
    c.process(frame(301000,0));c.process(frame(302000));assert(c.total==1);
    c.process(frame(306000,0));assert(!c.tracks[0].used);
    c.process(frame(306100));c.process(frame(306200));c.process(frame(306300));assert(c.total==2);
    // A queued frame can predate the most recent TIME command by milliseconds.
    Core synced;synced.sync(20000u*86400+3600,0);
    for(uint32_t m=0;m<=2500;m+=100)synced.process(frame(m));
    const uint32_t savedDay=synced.day;
    assert(synced.sync(20000u*86400+3604,4000));
    synced.process(frame(3950));
    assert(synced.day==savedDay&&synced.daily==1&&synced.groups[0].visits==1);
    synced.expire(4050);
    assert(synced.daily==1&&synced.groups[0].visits==1);
    // millis wrap and genuine midnight must still behave correctly.
    Core wrapped;wrapped.sync(20000u*86400+3600,0xfffffff0u);
    assert(wrapped.epoch(984)==20000u*86400+3601);
    Core midnight;midnight.sync(20000u*86400+16*3600-1,0);
    midnight.expire(1000);const uint32_t newDay=midnight.day;
    midnight.process(frame(900,0));assert(midnight.day==newDay);
    Core multi;multi.sync(20000u*86400+3600,0);
    for(uint32_t m=0;m<=2500;m+=100)multi.process(frame(m,2));
    assert(multi.total==2&&multi.daily==2&&multi.groups[0].visits==1&&multi.groups[1].visits==1);
    // Detection ordering reverses without crossing: IDs must stay spatially attached.
    Frame rev=frame(2600,2);Detection tmp=rev.items[0];rev.items[0]=rev.items[1];rev.items[1]=tmp;multi.process(rev);
    assert(multi.total==2&&multi.tracks[0].box.x1<.2f);
    Core gap;gap.process(frame(0));gap.process(frame(100,0));gap.process(frame(200));gap.process(frame(300));assert(gap.total==0);gap.process(frame(400));assert(gap.total==1&&gap.daily==0);
    // Crossing 08:00 must remain a single all-day arrival.
    Core clock;clock.sync(20000u*86400-1,0);
    for(uint32_t m=0;m<=2000;m+=100)clock.process(frame(m));assert(clock.total==1&&clock.daily==1);
    assert(!clock.sync(1700000000,2100)); // reject backwards time
    clock.sync(20001u*86400+3600,2200);assert(clock.daily==0&&clock.tracks[0].group==0);
    Core closing;closing.sync(20000u*86400+9*3600,0);assert(!closing.window(0));
    // Classification can finish after 17:00 without splitting a visit.
    Core evening;evening.sync(20000u*86400+9*3600-1,0);
    for(uint32_t m=0;m<=5000;m+=100)evening.process(frame(m));
    assert(!evening.window(5000)&&evening.total==1&&evening.daily==1&&evening.groups[0].visits==1);
    assert(evening.deleteGroup(evening.day,evening.groups[0].generation,5000));
    assert(evening.daily==0&&evening.total==0);
    Core night;night.sync(20000u*86400+16*3600-4,0);
    for(uint32_t m=0;m<=3000;m+=100)night.process(frame(m));
    assert(night.daily==1&&night.groups[0].visits==1);
    for(uint32_t m=3100;m<=5000;m+=100)night.process(frame(m));
    assert(night.total==1&&night.daily==0&&!night.groups[0].used);
    night.process(frame(9000,0));
    for(uint32_t m=9100;m<=12000;m+=100)night.process(frame(m));
    assert(night.total==2&&night.daily==1&&night.groups[0].visits==1);
    Core stale;stale.process(frame(0));stale.process(frame(100));stale.process(frame(200));stale.expire(4000);assert(!stale.tracks[0].used&&stale.total==1);
    // Capacity produces unassigned, not forced species labels.
    Core full;full.sync(20000u*86400+3600,0);for(int i=0;i<MAX_GROUPS;i++){full.groups[i].used=true;full.groups[i].mean[31]=1;}
    for(uint32_t m=0;m<=2500;m+=100)full.process(frame(m));assert(full.tracks[0].assigned&&full.tracks[0].group==0);
    Core deletion;deletion.sync(20000u*86400+3600,0);
    for(uint32_t m=0;m<=2500;m+=100)deletion.process(frame(m,2));
    uint32_t gen=deletion.groups[0].generation;
    assert(!deletion.deleteGroup(deletion.day+1,gen,2500));
    assert(deletion.deleteGroup(deletion.day,gen,2500));
    assert(deletion.daily==1&&deletion.total==1&&!deletion.groups[0].used);
    assert(deletion.groups[1].used&&deletion.tracks[0].ignored);
    assert(!deletion.deleteGroup(deletion.day,gen,2500));
    for(uint32_t m=2600;m<=5000;m+=100)deletion.process(frame(m,2));
    assert(deletion.daily==1&&!deletion.groups[0].used);
    deletion.process(frame(9000,0));
    for(uint32_t m=9100;m<=10600;m+=100)deletion.process(frame(m,2));
    assert(deletion.daily==3&&deletion.groups[0].generation!=gen);
    assert(!deletion.deleteGroup(deletion.day,gen,10600));
    Core gate;gate.sync(20000u*86400+3600,0);assert(gate.setConfidence(80));
    for(uint32_t m=0;m<4000;m+=100){Frame f=frame(m);f.items[0].score=79;gate.process(f);}
    assert(gate.total==0&&gate.daily==0&&!gate.groups[0].used);
    for(uint32_t m=4000;m<7000;m+=100){Frame f=frame(m);f.items[0].score=80;gate.process(f);}
    assert(gate.total==1&&gate.groups[0].visits==1);
    assert(!gate.setConfidence(19)&&!gate.setConfidence(101));
    Core resetSamples;resetSamples.sync(20000u*86400+3600,0);
    for(uint32_t m=0;m<=1200;m+=100)resetSamples.process(frame(m));
    assert(resetSamples.tracks[0].samples==3);
    resetSamples.setConfidence(95);assert(resetSamples.tracks[0].samples==0);
    for(uint32_t m=1300;m<4000;m+=100)resetSamples.process(frame(m));
    assert(!resetSamples.groups[0].used);
    // Moderate feature variation remains one group; clearly different colours split.
    Core varied;varied.sync(20000u*86400+3600,0);
    for(uint32_t m=0;m<=2500;m+=100)varied.process(frame(m));
    varied.process(frame(6000,0));
    for(uint32_t m=6100;m<=8600;m+=100){
        Frame f=frame(m);f.items[0].feature.v[0]=.75f;f.items[0].feature.v[1]=.25f;
        varied.process(f);
    }
    assert(varied.groups[0].visits==2&&!varied.groups[1].used);
    Core early;
    for(uint32_t m=0;m<=2500;m+=100)early.process(frame(m));
    assert(early.total==1&&early.daily==0&&early.tracks[0].samples==5);
    early.sync(20000u*86400+3603,3000);
    assert(early.daily==0); // sync alone cannot count an absent bird
    early.process(frame(3100));
    assert(early.total==1&&early.daily==1&&early.groups[0].visits==1);
    early.process(frame(3200));assert(early.daily==1);
    Core earlyGone;earlyGone.process(frame(0));earlyGone.process(frame(100));earlyGone.process(frame(200));
    earlyGone.sync(20000u*86400+3601,1000);earlyGone.process(frame(1100,0));
    assert(earlyGone.daily==0);
    Core earlyClosed;for(uint32_t m=0;m<=2500;m+=100)earlyClosed.process(frame(m));
    earlyClosed.sync(20000u*86400+9*3600,3000);earlyClosed.process(frame(3100));
    assert(earlyClosed.daily==1&&earlyClosed.groups[0].visits==1);
    uint8_t rgb[32*32*3]={};memset(rgb,255,32*32);
    Feature red=extract(rgb,sizeof(rgb),32,32,Box{0,0,1,1});assert(red.valid&&red.thumb[0]==255&&red.thumb[1]==0);
    memset(rgb,0,sizeof(rgb));memset(rgb+32*32,255,32*32);
    Feature green=extract(rgb,sizeof(rgb),32,32,Box{0,0,1,1});assert(green.valid&&distance(red.v,green.v)>.22f);
    float sum=0;for(int i=0;i<32;i++)sum+=red.v[i];assert(fabsf(sum-1)<.0001f);
    assert(!extract(rgb,10,32,32,Box{0,0,1,1}).valid);
    assert(!extract(rgb,sizeof(rgb),32,32,Box{0,0,.1f,.1f}).valid);
    assert(!extract(rgb,sizeof(rgb),32,32,Box{NAN,0,1,1}).valid);
    Feature crop19=extract(visit19,sizeof(visit19),24,24,Box{0,0,1,1});
    Feature crop20=extract(visit20,sizeof(visit20),24,24,Box{0,0,1,1});
    printf("Archived crops: distance %.4f, worst region %.4f\n",distance(crop19.v,crop20.v),regionDistance(crop19.v,crop20.v));
    Core appearances;appearances.sync(20000u*86400+3600,0);
    for(uint32_t m=0;m<=2500;m+=100){Frame f=frame(m);f.items[0].feature=crop19;appearances.process(f);}
    appearances.process(frame(6000,0));
    for(uint32_t m=6100;m<=8600;m+=100){Frame f=frame(m);f.items[0].feature=crop20;appearances.process(f);}
    assert(appearances.groups[0].visits==1&&appearances.groups[1].visits==1);
    // Repeating the same appearance must return to the same group.
    appearances.process(frame(12000,0));
    for(uint32_t m=12100;m<=14600;m+=100){Frame f=frame(m);f.items[0].feature=crop19;appearances.process(f);}
    assert(appearances.groups[0].visits==2&&appearances.groups[1].visits==1);
    // Small exposure changes should not force another group for this fixture.
    uint8_t dimmed[sizeof(visit19)];for(size_t i=0;i<sizeof(dimmed);i++)dimmed[i]=uint8_t(visit19[i]*.9f);
    Feature darker=extract(dimmed,sizeof(dimmed),24,24,Box{0,0,1,1});
    appearances.process(frame(18000,0));
    for(uint32_t m=18100;m<=20600;m+=100){Frame f=frame(m);f.items[0].feature=darker;appearances.process(f);}
    assert(appearances.groups[0].visits==3&&appearances.groups[1].visits==1);
    // Same global colours but a different regional arrangement must not merge.
    Core spatial;spatial.sync(20000u*86400+3600,0);
    for(uint32_t m=0;m<=2500;m+=100){Frame f=frame(m);for(int z=0;z<3;z++)f.items[0].feature.v[32+16*z+z]=1;spatial.process(f);}
    spatial.process(frame(6000,0));
    for(uint32_t m=6100;m<=8600;m+=100){Frame f=frame(m);for(int z=0;z<3;z++)f.items[0].feature.v[32+16*z+(2-z)]=1;spatial.process(f);}
    assert(spatial.groups[0].visits==1&&spatial.groups[1].visits==1);
    // A drifting centroid alone cannot admit an appearance far from the founder.
    Core drift;drift.sync(20000u*86400+3600,0);
    drift.groups[0].used=true;drift.groups[0].visits=10;
    drift.groups[0].mean[0]=1;drift.groups[0].anchor[1]=1;
    for(uint32_t m=0;m<=2500;m+=100)drift.process(frame(m));
    assert(drift.groups[0].visits==10&&drift.groups[1].visits==1);
    assert(drift.tracks[0].candidateGroup==1&&drift.tracks[0].groupDecision==1);
    assert(drift.tracks[0].meanDistance==0&&drift.tracks[0].anchorDistance>.26f);
    // One threshold gates all three distances; changing it never regroups history.
    assert(fabsf(Core::similarityScore(.24f,.26f,.32f)-76)<.001f);
    Core tuning;tuning.sync(20000u*86400+3600,0);
    assert(!tuning.setSimilarity(-1)&&!tuning.setSimilarity(101));
    assert(tuning.setSimilarity(100));
    for(uint32_t m=0;m<=2500;m+=100)tuning.process(frame(m));
    tuning.process(frame(6000,0));
    for(uint32_t m=6100;m<=8600;m+=100){Frame f=frame(m);f.items[0].feature.v[0]=.75f;f.items[0].feature.v[1]=.25f;tuning.process(f);}
    assert(tuning.groups[0].visits==1&&tuning.groups[1].visits==1);
    assert(tuning.tracks[0].groupDecision==1&&tuning.tracks[0].similarity<100);
    assert(tuning.tracks[0].candidateGeneration==tuning.groups[0].generation);
    assert(tuning.setSimilarity(0));assert(tuning.groups[1].visits==1);
    tuning.process(frame(12000,0));
    for(uint32_t m=12100;m<=14600;m+=100)tuning.process(frame(m));
    assert(tuning.groups[0].visits==2&&tuning.tracks[0].groupDecision==2);
    assert(tuning.tracks[0].decisionThreshold==0);
    printf("Grouping memory: Core=%zu Frame=%zu bytes\n",sizeof(Core),sizeof(Frame));
    initVisitArchive();char previousBoot[33];memcpy(previousBoot,archiveBoot,33);
    initVisitArchive();assert(strcmp(previousBoot,archiveBoot)!=0);
    bird::Track archived={};archived.used=true;archived.confirmed=true;
    archived.id=1;archived.first=100;archived.last=2000;archived.score=88;
    archived.bestSampleBox=Box{.1f,.2f,.6f,.8f};archived.bestSampleScore=88;archived.bestSampleMs=1500;archived.bestSampleSequence=9;
    memset(archived.thumb,123,sizeof(archived.thumb));
    rememberVisit(archived,false);rememberVisit(archived,false);
    assert(archiveInsert==1&&archivedVisits[0].imageMs==1500&&archivedVisits[0].image[0]==123&&archivedVisits[0].imageBox.x1==.1f);
    rememberVisit(archived,true);assert(archivedVisits[0].ended);
    for(int i=2;i<=33;i++){archived.id=i;rememberVisit(archived,true);}
    assert(archiveEvictions==1&&archivedVisits[0].id==33);
    printf("PASS: dwell, gaps, confirmation, multi-target, order, clock/window, rollover, stale, capacity, RGB and histogram\n");
}
