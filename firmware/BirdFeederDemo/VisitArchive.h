#pragma once
// Bounded RAM replay cache. Host upserts (device,boot,track); no arrival is
// synthesized by the host. Offline beyond cache capacity can lose visits.
static char archiveBoot[33];
static const int VISIT_CACHE=32;
struct ArchivedVisit {
    bool used,ended,dirty,hasImage;
    uint32_t id,first,last,imageMs,imageSequence,groupDay,groupGeneration;
    int group,peak,threshold,imageScore;
    int samples,decision,similarityThreshold,candidate;
    float similarity;uint32_t candidateGeneration,candidateDay;bool eligible;
    bird::Box imageBox;
    uint8_t image[bird::THUMB_BYTES];
};
static ArchivedVisit archivedVisits[VISIT_CACHE];
static uint32_t archiveEvictions=0;
static int archiveInsert=0,archiveRead=0;
static void initVisitArchive(){
    useRealRandomGenerator(true);
    snprintf(archiveBoot,sizeof(archiveBoot),"%08lx%08lx%08lx%08lx",
        (unsigned long)random(0x7fffffffL),(unsigned long)random(0x7fffffffL),
        (unsigned long)random(0x7fffffffL),(unsigned long)random(0x7fffffffL));
}
static void rememberVisit(const bird::Track& t,bool ended){
    if(!t.confirmed)return;
    ArchivedVisit* a=nullptr;
    for(int i=0;i<VISIT_CACHE;i++)if(archivedVisits[i].used&&archivedVisits[i].id==t.id){a=&archivedVisits[i];break;}
    if(!a){
        a=&archivedVisits[archiveInsert];archiveInsert=(archiveInsert+1)%VISIT_CACHE;
        if(a->used)archiveEvictions++;
        memset(a,0,sizeof(*a));a->used=true;a->id=t.id;a->first=t.first;a->threshold=visual.confidence;
    }
    if(a->last!=t.last||a->ended!=ended)a->dirty=true;
    a->last=t.last;a->ended=ended;
    if(t.score>a->peak)a->peak=t.score;
    a->samples=t.samples;a->decision=t.groupDecision;a->eligible=t.eligible;
    a->similarityThreshold=t.groupDecision?t.decisionThreshold:visual.similarityThreshold;
    a->candidate=t.candidateGroup;a->candidateGeneration=t.candidateGeneration;a->candidateDay=t.candidateDay;
    a->similarity=t.candidateGroup?t.similarity:-1;

    if(t.group>0 && visual.groups[t.group-1].used){
        a->group=t.group;a->groupDay=visual.day;a->groupGeneration=visual.groups[t.group-1].generation;
    }
    if(t.bestSampleScore>a->imageScore){
        a->hasImage=true;a->imageScore=t.bestSampleScore;a->imageMs=t.bestSampleMs;
        a->imageBox=t.bestSampleBox;a->imageSequence=t.bestSampleSequence;memcpy(a->image,t.thumb,sizeof(a->image));a->dirty=true;
    }
}
static void printGrouping(int samples,bool eligible,int decision,int threshold,float score,int candidate,uint32_t generation,uint32_t day){
    Serial.print(",\"grouping\":{\"samples\":");Serial.print(samples);
    Serial.print(",\"eligible\":");Serial.print(eligible?"true":"false");
    Serial.print(",\"decision\":");Serial.print(decision);
    Serial.print(",\"threshold\":");Serial.print(threshold);
    Serial.print(",\"score\":");if(candidate&&decision)Serial.print(score,2);else Serial.print("null");
    Serial.print(",\"candidate\":");Serial.print(candidate);
    Serial.print(",\"candidate_generation\":");Serial.print(generation);
    Serial.print(",\"candidate_day\":");Serial.print(day);Serial.print('}');
}
static void emitArchivedVisit(uint32_t now){
    int found=-1;
    // New/changed visits first, so a short host video ring can match the sample.
    for(int n=0;n<VISIT_CACHE;n++){int i=(archiveRead+n)%VISIT_CACHE;if(archivedVisits[i].used&&archivedVisits[i].dirty){found=i;break;}}
    if(found>=0)archiveRead=(found+1)%VISIT_CACHE;
    else for(int n=0;n<VISIT_CACHE;n++){int i=archiveRead;archiveRead=(archiveRead+1)%VISIT_CACHE;if(archivedVisits[i].used){found=i;break;}}
    if(found<0)return;
    ArchivedVisit& a=archivedVisits[found];
    Serial.print("@VISIT {\"boot\":\"");Serial.print(archiveBoot);
    Serial.print("\",\"id\":");Serial.print(a.id);
    Serial.print(",\"ms\":");Serial.print(now);
    Serial.print(",\"epoch\":");Serial.print(visual.clockValid?visual.epoch(now):0);
    Serial.print(",\"first_ms\":");Serial.print(a.first);
    Serial.print(",\"last_ms\":");Serial.print(a.last);
    Serial.print(",\"ended\":");Serial.print(a.ended?"true":"false");
    Serial.print(",\"peak\":");Serial.print(a.peak);
    Serial.print(",\"threshold\":");Serial.print(a.threshold);
    Serial.print(",\"group\":");Serial.print(a.group);
    Serial.print(",\"group_day\":");Serial.print(a.groupDay);
    Serial.print(",\"generation\":");Serial.print(a.groupGeneration);
    printGrouping(a.samples,a.eligible,a.decision,a.similarityThreshold,a.similarity,a.candidate,a.candidateGeneration,a.candidateDay);
    Serial.print(",\"image_ms\":");Serial.print(a.imageMs);
    Serial.print(",\"image_sequence\":");Serial.print(a.imageSequence);
    Serial.print(",\"image_bbox\":[");Serial.print(a.imageBox.x1,4);Serial.print(',');Serial.print(a.imageBox.y1,4);
    Serial.print(',');Serial.print(a.imageBox.x2,4);Serial.print(',');Serial.print(a.imageBox.y2,4);Serial.print(']');
    Serial.print(",\"image_score\":");Serial.print(a.imageScore);
    Serial.print(",\"evictions\":");Serial.print(archiveEvictions);
    Serial.print(",\"width\":");Serial.print(bird::THUMB_SIDE);
    Serial.print(",\"thumb\":");if(a.hasImage)printThumb(a.image);else Serial.print("null");
    Serial.println("}");a.dirty=false;
}