#pragma once
#include "WeightCore.h"
#include <ctype.h>
static weight::Core weighing;
static const uint8_t WEIGHT_DT[2]={1,3},WEIGHT_SCK[2]={2,4};
static uint32_t weightSequence=0;

static bool readWeightRaw(int index,int32_t& raw){
    if(digitalRead(WEIGHT_DT[index])!=LOW)return false;
    const uint32_t mask=ulSetInterruptMask();uint32_t bits=0;
    delayMicroseconds(1);
    for(int bit=0;bit<24;bit++){
        digitalWrite(WEIGHT_SCK[index],HIGH);delayMicroseconds(1);
        bits=(bits<<1)|(digitalRead(WEIGHT_DT[index])==HIGH?1U:0U);
        digitalWrite(WEIGHT_SCK[index],LOW);delayMicroseconds(1);
    }
    digitalWrite(WEIGHT_SCK[index],HIGH);delayMicroseconds(1);
    digitalWrite(WEIGHT_SCK[index],LOW);delayMicroseconds(1);
    bool readyReset=digitalRead(WEIGHT_DT[index])==HIGH;
    vClearInterruptMask(mask);
    if(!readyReset)return false;
    raw=(bits&0x800000U)?int32_t(bits)-16777216L:int32_t(bits);return true;
}
static void initWeights(){
    for(int i=0;i<2;i++){
        pinMode(WEIGHT_DT[i],INPUT_PULLUP);pinMode(WEIGHT_SCK[i],OUTPUT);
        digitalWrite(WEIGHT_SCK[i],HIGH);delayMicroseconds(80);digitalWrite(WEIGHT_SCK[i],LOW);
    }
}
static void weightAck(const char* request,int channel,const char* phase,const char* reason){
    Serial.print("@WEIGHT_ACK {\"boot\":\"");Serial.print(archiveBoot);
    Serial.print("\",\"request_id\":\"");Serial.print(request);
    Serial.print("\",\"channel\":");Serial.print(channel);
    Serial.print(",\"phase\":\"");Serial.print(phase);
    Serial.print("\",\"reason\":\"");Serial.print(reason);Serial.println("\"}");
}
static void emitWeightEvents(){
    for(int i=0;i<2;i++){auto& s=weighing.scales[i];if(s.event){weightAck(s.request,i+1,s.phase,s.reason);s.event=false;}}
}
static bool weightCommand(const char* command){
    if(strncmp(command,"WEIGHT ",7))return false;
    char id[33]={},action[16]={},argument[32]={},extra=0;unsigned channel=0;double grams=0;
    int fields=sscanf(command+7,"%32s %u %15s %31s %c",id,&channel,action,argument,&extra);
    bool valid=strlen(id)==32;
    for(int i=0;id[i];i++)if(!isxdigit((unsigned char)id[i]))valid=false;
    if(!valid||channel<1||channel>2){Serial.println("@ERROR INVALID_WEIGHT_COMMAND");return true;}
    if((!strcmp(action,"MASS")&&fields!=4)||(strcmp(action,"MASS")&&fields!=3)){
        weightAck(id,channel,"REJECTED","INVALID_ARGUMENTS");return true;
    }
    if(!strcmp(action,"MASS")){
        char* end=nullptr;grams=strtod(argument,&end);
        if(end==argument||*end||!isfinite(grams)||grams<=0||grams>1000000){weightAck(id,channel,"REJECTED","INVALID_ARGUMENTS");return true;}
    }
    const char* error=weighing.scales[channel-1].command(id,action,grams,millis(),weighing.allowed(millis()));
    if(error)weightAck(id,channel,"REJECTED",error);else emitWeightEvents();
    return true;
}
static void pollWeights(uint32_t now){
    bool valid=visual.lastSequence&&uint32_t(now-visual.lastFrame)<2000;
    bool present=false;
    // Whole-view conservative gating until food/water ROIs are physically established.
    for(int i=0;i<bird::MAX_TRACKS;i++){
        const auto& t=visual.tracks[i];
        if(t.used&&uint32_t(now-t.last)<bird::LOST_MS&&t.score>=visual.confidence)present=true;
    }
    weighing.vision(valid,present,now);weighing.tick(now);
    for(int i=0;i<2;i++){int32_t raw;if(readWeightRaw(i,raw))weighing.scales[i].sample(raw,now,weighing.allowed(now));}
    emitWeightEvents();
}
static void emitWeights(uint32_t now){
    static uint32_t last=0;if(uint32_t(now-last)<500)return;last=now;
    Serial.print("@WEIGHT {\"version\":1,\"boot\":\"");Serial.print(archiveBoot);
    Serial.print("\",\"seq\":");Serial.print(++weightSequence);Serial.print(",\"ms\":");Serial.print(now);
    Serial.print(",\"vision_valid\":");Serial.print(weighing.visionValid?"true":"false");
    Serial.print(",\"bird_present\":");Serial.print(weighing.bird?"true":"false");
    Serial.print(",\"channels\":[");
    for(int i=0;i<2;i++){
        if(i)Serial.print(',');const auto& s=weighing.scales[i];
        Serial.print("{\"id\":");Serial.print(i+1);
        Serial.print(",\"calibration_independent\":true");
        Serial.print(",\"calibrated\":");Serial.print(s.calibrated?"true":"false");
        Serial.print(",\"zero_ready\":");Serial.print(s.zeroReady?"true":"false");
        Serial.print(",\"status\":\"");Serial.print(s.status(now,weighing.visionValid,weighing.bird,weighing.allowed(now)));
        Serial.print("\",\"raw\":");if(s.fresh(now))Serial.print(s.mean(),1);else Serial.print("null");
        Serial.print(",\"grams\":");if(s.displayReady(now))Serial.print(s.grams(),2);else Serial.print("null");
        Serial.print(",\"stable_g\":");if(s.hasTrusted)Serial.print(s.trusted,2);else Serial.print("null");
        Serial.print(",\"stable_age_ms\":");if(s.hasTrusted)Serial.print(uint32_t(now-s.trustedAt));else Serial.print("null");
        Serial.print(",\"raw_latest\":");if(s.fresh(now))Serial.print(s.rawLatest);else Serial.print("null");
        Serial.print(",\"change_pending\":");Serial.print(s.changePending?"true":"false");
        Serial.print(",\"cal_span\":");Serial.print(s.calibrationSpan,1);
        Serial.print(",\"rejected_windows\":");Serial.print(s.rejectedWindows);
        Serial.print(",\"filter\":\"median5-v1\",\"progress\":");Serial.print(s.collected);
        Serial.print(",\"request_id\":\"");Serial.print(s.request);
        Serial.print("\",\"phase\":\"");Serial.print(s.phase);
        Serial.print("\",\"reason\":\"");Serial.print(s.reason);Serial.print("\"}");
    }
    Serial.println("]}");
}
