#pragma once
#include "VisualCore.h"
#include <FreeRTOS.h>
#include <queue.h>
extern "C" {
#include "avcodec.h"
extern int vipnn_control(void*,int,int);
}

// SDK 4.1.0 integration: borrow raw input ONLY inside this synchronous
// preprocess->postprocess invocation. Only derived features enter the queue.
static QueueHandle_t visualQueue;
static nn_preprocess_t originalPreprocess;
static const uint8_t* inputRgb;
static size_t inputBytes;
static int inputW,inputH;
static uint32_t frameSerial;
static uint32_t rgbFailures=0;
static bird::Frame callbackFrame;
static bird::Core visual;

static int capturePreprocess(void* data,nn_data_param_t* p,void* tensor,nn_tensor_param_t* tp){
    inputRgb=nullptr;inputBytes=0;
    if(p&&data&&p->codec_type==AV_CODEC_ID_RGB888&&p->img.width==576&&p->img.height==320&&p->size_in_byte>=576*320*3){
        inputRgb=(const uint8_t*)data;inputBytes=p->size_in_byte;inputW=p->img.width;inputH=p->img.height;
    }
    return originalPreprocess?originalPreprocess(data,p,tensor,tp):PP_USE_INPUT;
}
static void captureResult(void* result,void*){
    if(!result||!visualQueue)return;
    vipnn_out_buf_t* out=(vipnn_out_buf_t*)result;
    bird::Frame& f=callbackFrame;memset(&f,0,sizeof(f));f.ms=millis();f.sequence=++frameSerial;
    if(!inputRgb)rgbFailures++;
    if(out->res_cnt<0||out->res_cnt>MAX_DETECT_OBJ_NUM||out->res_size!=sizeof(objdetect_res_t)){inputRgb=nullptr;return;}
    objdetect_res_t* objects=(objdetect_res_t*)&out->res[0];
    for(int i=0;i<out->res_cnt;i++){
        const detobj_t& d=objects[i].res;
        if(!isfinite(d.score)||d.score<.20f||!isfinite(d.classes)||int(d.classes)!=0)continue;
        if(!isfinite(d.top_x)||!isfinite(d.top_y)||!isfinite(d.bot_x)||!isfinite(d.bot_y))continue;
        bird::Box b={bird::clip(d.top_x),bird::clip(d.top_y),bird::clip(d.bot_x),bird::clip(d.bot_y)};
        if(bird::area(b)<=0)continue;
        if(f.count>=bird::MAX_TRACKS){f.overflow++;continue;}
        bird::Detection& dst=f.items[f.count++];dst.box=b;dst.score=int(d.score*100);
        if(dst.score>=20 && inputRgb)bird::extractInto(dst.feature,inputRgb,inputBytes,inputW,inputH,b);
    }
    // Exclude overlapping bird crops from appearance grouping.
    for(int i=0;i<f.count;i++)for(int j=i+1;j<f.count;j++)if(bird::iou(f.items[i].box,f.items[j].box)>.15f){f.items[i].feature.valid=false;f.items[j].feature.valid=false;}
    inputRgb=nullptr;inputBytes=0;
    xQueueOverwrite(visualQueue,&f);
}
class VisualDetector : public NNObjectDetection {
public:
    vipnn_ctx_t* context(){return _p_mmf_context?(vipnn_ctx_t*)_p_mmf_context->priv:nullptr;}
};
static bool attachVision(VisualDetector& detector){
    vipnn_ctx_t* ctx=detector.context();
    if(!ctx||!ctx->params.model)return false;
    visualQueue=xQueueCreate(1,sizeof(bird::Frame));if(!visualQueue)return false;
    originalPreprocess=ctx->params.model->preprocess;
    ctx->params.model->preprocess=capturePreprocess;
    vipnn_control(ctx,CMD_VIPNN_SET_DISPPOST,(int)captureResult);
    return true;
}
static void printThumb(const uint8_t* data){
    static const char hex[]="0123456789abcdef";
    Serial.print('"');for(int i=0;i<bird::THUMB_BYTES;i++){Serial.print(hex[data[i]>>4]);Serial.print(hex[data[i]&15]);}Serial.print('"');
}
#include "VisitArchive.h"
static void emitVisualEvent(const char* type,const bird::Track& t,uint32_t now){
    rememberVisit(t,strcmp(type,"END")==0);
    Serial.print("@EVENT {\"type\":\"");Serial.print(type);
    Serial.print("\",\"id\":");Serial.print(t.id);
    Serial.print(",\"group\":");Serial.print(t.group);
    Serial.print(",\"boot\":\"");Serial.print(archiveBoot);Serial.print("\",\"visitArchive\":true,\"archiveEvictions\":");Serial.print(archiveEvictions);
    Serial.print(",\"day\":");Serial.print(visual.day);
    Serial.print(",\"ms\":");Serial.print(now);
    Serial.print(",\"first_ms\":");Serial.print(t.first);
    Serial.print(",\"last_ms\":");Serial.print(t.last);
    Serial.print(",\"eligible\":");Serial.print(t.eligible?"true":"false");
    if(strcmp(type,"GROUP")==0){
        Serial.print(",\"groupingAlgorithm\":\"spatial-anchor-v1\",\"decision\":");Serial.print(t.groupDecision);
        Serial.print(",\"meanLimit\":");Serial.print(visual.groupThreshold,4);
        Serial.print(",\"anchorLimit\":");Serial.print(bird::Core::ANCHOR_THRESHOLD*visual.groupThreshold/.24f,4);
        Serial.print(",\"regionLimit\":");Serial.print(bird::Core::REGION_THRESHOLD*visual.groupThreshold/.24f,4);
        Serial.print(",\"candidateGroup\":");Serial.print(t.candidateGroup);
        Serial.print(",\"meanDistance\":");Serial.print(t.meanDistance,4);
        Serial.print(",\"anchorDistance\":");Serial.print(t.anchorDistance,4);
        Serial.print(",\"regionDifference\":");Serial.print(t.regionDifference,4);
    }
    Serial.println("}");
}
static void emitVisualStatus(uint32_t now){
    Serial.print("@VISION {\"version\":\"0.3.0\",\"ms\":");Serial.print(now);
    Serial.print(",\"groupingAlgorithm\":\"spatial-anchor-v1\",\"photoCapture\":true,\"allDayGrouping\":true,\"deleteGroups\":true,\"confidenceControl\":true,\"sameFrameThumbs\":true,\"confidence\":");Serial.print(visual.confidence);Serial.print(",\"epoch\":");Serial.print(visual.clockValid?visual.epoch(now):0);
    Serial.print(",\"boot\":\"");Serial.print(archiveBoot);Serial.print("\",\"visitArchive\":true,\"archiveEvictions\":");Serial.print(archiveEvictions);
    Serial.print(",\"day\":");Serial.print(visual.day);
    Serial.print(",\"similarityControl\":true,\"similarityThreshold\":");Serial.print(visual.similarityThreshold);
    Serial.print(",\"clockValid\":");Serial.print(visual.clockValid?"true":"false");
    Serial.print(",\"inWindow\":");Serial.print(visual.window(now)?"true":"false");
    Serial.print(",\"frameAgeMs\":");Serial.print(visual.lastSequence?uint32_t(now-visual.lastFrame):0xffffffffu);
    Serial.print(",\"sequence\":");Serial.print(visual.lastSequence);
    Serial.print(",\"overflow\":");Serial.print(visual.overflows);
    Serial.print(",\"rgbFailures\":");Serial.print(rgbFailures);
    Serial.print(",\"totalVisits\":");Serial.print(visual.total);
    Serial.print(",\"dailyVisits\":");Serial.print(visual.daily);
    Serial.print(",\"tracks\":[");bool comma=false;
    for(int i=0;i<bird::MAX_TRACKS;i++){
        const bird::Track& t=visual.tracks[i];if(!t.used||!t.confirmed||t.ignored)continue;
        if(comma)Serial.print(',');comma=true;
        Serial.print("{\"id\":");Serial.print(t.id);Serial.print(",\"group\":");Serial.print(t.group);
        Serial.print(",\"visible\":");Serial.print(t.visible&&uint32_t(now-t.last)<300&&t.score>=visual.confidence?"true":"false");
        Serial.print(",\"eligible\":");Serial.print(t.eligible?"true":"false");
        Serial.print(",\"assigned\":");Serial.print(t.assigned?"true":"false");
        Serial.print(",\"awaitingClock\":");Serial.print(t.awaitingClock?"true":"false");
        Serial.print(",\"samples\":");Serial.print(t.samples);
        Serial.print(",\"score\":");Serial.print(t.score);
        printGrouping(t.samples,t.eligible,t.groupDecision,t.groupDecision?t.decisionThreshold:visual.similarityThreshold,t.similarity,t.candidateGroup,t.candidateGeneration,t.candidateDay);
        Serial.print(",\"durationMs\":");Serial.print(uint32_t(t.last-t.first));
        Serial.print(",\"xMin\":");Serial.print(t.box.x1,4);Serial.print(",\"yMin\":");Serial.print(t.box.y1,4);
        Serial.print(",\"xMax\":");Serial.print(t.box.x2,4);Serial.print(",\"yMax\":");Serial.print(t.box.y2,4);Serial.print('}');
    }
    Serial.print("],\"groups\":[");comma=false;
    for(int i=0;i<bird::MAX_GROUPS;i++){
        const bird::Group& g=visual.groups[i];if(!g.used)continue;
        if(comma)Serial.print(',');comma=true;
        Serial.print("{\"id\":");Serial.print(i+1);Serial.print(",\"generation\":");Serial.print(g.generation);Serial.print(",\"visits\":");Serial.print(g.visits);
        Serial.print('}');
    }
    Serial.println("]}");
}

// Bound UART bandwidth: send only one stored same-frame crop per report.
static void emitGroupThumbnail(){
    static int cursor=0;
    for(int n=0;n<bird::MAX_GROUPS;n++){
        int i=cursor;cursor=(cursor+1)%bird::MAX_GROUPS;
        const bird::Group& g=visual.groups[i];if(!g.used)continue;
        Serial.print("@THUMB {\"day\":");Serial.print(visual.day);
        Serial.print(",\"generation\":");Serial.print(g.generation);
        Serial.print(",\"width\":");Serial.print(bird::THUMB_SIDE);
        Serial.print(",\"thumb\":");printThumb(g.thumb);Serial.println("}");break;
    }
}