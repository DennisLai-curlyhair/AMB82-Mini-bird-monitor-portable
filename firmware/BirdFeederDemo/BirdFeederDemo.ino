#include <Arduino.h>
#include <StreamIO.h>
#include <VideoStream.h>
#include <UVCD.h>
#include <NNObjectDetection.h>
#include <vector>
#include "VisualRuntime.h"
#include "WeightRuntime.h"

#define STREAM_CHANNEL 0
#define CHANNEL_NN 3
#define NN_WIDTH 576
#define NN_HEIGHT 320

static const int BIRD_CLASS_ID = 0;
static const float CONFIDENCE_THRESHOLD = 0.20f;
static const float NMS_THRESHOLD = 0.30f;
static const float NEAR_AREA_THRESHOLD = 0.06f;
static const float CLOSE_AREA_THRESHOLD = 0.18f;
static const uint8_t DETECT_CONFIRM_FRAMES = 2;
static const uint32_t VISIT_CLEAR_MS = 5000;
static const uint32_t STATUS_INTERVAL_MS = 1000;

Video cameraUvc;
VideoSetting streamConfig(VIDEO_HD, 20, VIDEO_JPEG, 0);
VideoSetting nnConfig(NN_WIDTH, NN_HEIGHT, 10, VIDEO_RGB, 0);
VisualDetector detector;
UVCD usbUvc;
StreamIO streamToUvc(1, 1);
StreamIO streamToDetector(1, 1);

uint32_t visitId = 0;
uint32_t lastSeenMs = 0;
uint32_t lastStatusMs = 0;
uint32_t lastNnReportMs = 0;
uint8_t detectionStreak = 0;
bool visitActive = false;
bool uvcDisconnected = false;
int bestScore = 0;
float bestArea = 0.0f;
char proximity[8] = "NONE";
char decision[12] = "PENDING";
char commandBuffer[80];
size_t commandLength = 0;

static const char *proximityForArea(float area) {
    if (area >= CLOSE_AREA_THRESHOLD) return "CLOSE";
    if (area >= NEAR_AREA_THRESHOLD) return "NEAR";
    return "FAR";
}

static void emitBird(const char *eventName) {
    Serial.print("@BIRD "); Serial.print(eventName); Serial.print(' ');
    Serial.print(visitId); Serial.print(' '); Serial.print(bestScore); Serial.print(' ');
    Serial.print(bestArea, 4); Serial.print(' '); Serial.println(proximity);
}

static void emitStatus() {
    Serial.print("@STATUS "); Serial.print(visitActive ? "ACTIVE " : "IDLE ");
    Serial.print(visitId); Serial.print(' '); Serial.print(bestScore); Serial.print(' ');
    Serial.print(bestArea, 4); Serial.print(' '); Serial.print(proximity); Serial.print(' ');
    Serial.println(decision);
}

static void processCommand(const char *command) {
    if(weightCommand(command))return;
    if (strncmp(command,"SIMILARITY ",11)==0){
        char* end=nullptr;long value=strtol(command+11,&end,10);
        bool ok=end!=command+11&&*end==0&&value>=0&&value<=100&&visual.setSimilarity((int)value);
        emitVisualStatus(millis());
        Serial.print("@SIMILARITY ");Serial.print(value);Serial.println(ok?" OK":" REJECTED");return;
    }
    if (strncmp(command,"CONFIDENCE ",11)==0){
        char* end=nullptr;long value=strtol(command+11,&end,10);
        bool ok=end!=command+11&&*end==0&&visual.setConfidence((int)value);
        emitVisualStatus(millis());
        Serial.print("@CONFIDENCE ");Serial.print(value);Serial.println(ok?" OK":" REJECTED");return;
    }
    if (strncmp(command, "DELETE_GROUP ", 13) == 0) {
        unsigned long day=0,generation=0;char extra=0;
        bool valid=sscanf(command+13,"%lu %lu %c",&day,&generation,&extra)==2;
        bool ok=valid&&visual.deleteGroup(day,generation,millis());
        emitVisualStatus(millis());
        Serial.print("@GROUP_DELETE ");Serial.print(day);Serial.print(' ');
        Serial.print(generation);Serial.println(ok?" OK":" REJECTED");
        return;
    }
    if (strncmp(command, "TIME ", 5) == 0) {
        char* end = nullptr;
        unsigned long value = strtoul(command + 5, &end, 10);
        bool ok = end != command + 5 && *end == 0 && visual.sync((uint32_t)value, millis());
        Serial.println(ok ? "@SYSTEM TIME_OK" : "@ERROR TIME_REJECTED");
        return;
    }
    if (strcmp(command, "STATUS") == 0) {
        emitStatus();
    } else {
        Serial.print("@ERROR UNKNOWN_COMMAND "); Serial.println(command);
    }
}

static void pollSerialCommands() {
    static bool overflow=false;
    for(int n=0;n<64&&Serial.available()>0;n++){
        char c=(char)Serial.read();if(c=='\r')continue;
        if(c=='\n'){
            if(overflow)Serial.println("@ERROR COMMAND_TOO_LONG");
            else{commandBuffer[commandLength]='\0';if(commandLength)processCommand(commandBuffer);}
            commandLength=0;overflow=false;
        }else if(commandLength<sizeof(commandBuffer)-1)commandBuffer[commandLength++]=c;
        else overflow=true;
    }
}

static bool ensureUvcConnected() {
    bool connected = usbUvc.isUsbUvcConnected(cameraUvc.videostream_status(STREAM_CHANNEL));
    if (!connected && !uvcDisconnected) {
        uvcDisconnected = true;
        Serial.println("@SYSTEM UVC_DISCONNECTED");
    } else if (connected && uvcDisconnected) {
        uvcDisconnected = false;
        Serial.println("@SYSTEM UVC_CONNECTED");
    }
    return connected;
}

static void uvcWorker(void*) {
    // SDK waits on a format-change semaphore. Keep it off the Arduino loop so
    // UART TIME, tracking, and status continue without an open browser camera.
    for (;;) {
        usbUvc.nnbegin(cameraUvc.getStream(STREAM_CHANNEL), streamToUvc.linker,
                       STREAM_CHANNEL, cameraUvc.videostream_status(STREAM_CHANNEL));
        vTaskDelay(1);
    }
}

void setup() {
    Serial.begin(115200);
    initVisitArchive();
    initWeights();
    delay(500);
    Serial.println("@SYSTEM BOOT");

    cameraUvc.configVideoChannel(STREAM_CHANNEL, streamConfig);
    cameraUvc.configVideoChannel(CHANNEL_NN, nnConfig);
    usbUvc.configVideo(streamConfig);
    cameraUvc.videoInit();

    detector.configVideo(nnConfig);
    detector.configThreshold(CONFIDENCE_THRESHOLD, NMS_THRESHOLD);
    detector.modelSelect(OBJECT_DETECTION, CUSTOMIZED_YOLOV7TINY, NA_MODEL, NA_MODEL);
    detector.begin();
    visual.event = emitVisualEvent;
    if (!attachVision(detector)) {
        Serial.println("@ERROR VISION_INIT_FAILED");
        while (true) delay(1000);
    }

    streamToUvc.registerInput(cameraUvc.getStream(STREAM_CHANNEL));
    streamToUvc.registerOutput(usbUvc);
    if (streamToUvc.begin() != 0) Serial.println("@ERROR UVC_STREAM_LINK");
    cameraUvc.channelBegin(STREAM_CHANNEL);

    streamToDetector.registerInput(cameraUvc.getStream(CHANNEL_NN));
    streamToDetector.setStackSize();
    streamToDetector.setTaskPriority();
    streamToDetector.registerOutput(detector);
    if (streamToDetector.begin() != 0) Serial.println("@ERROR NN_STREAM_LINK");
    cameraUvc.channelBegin(CHANNEL_NN);

    Serial.println("@SYSTEM MODEL CUSTOM_YOLOV7_TINY_FLASH");
    Serial.println("@SYSTEM UVC USB_UVC_CLASS");
    Serial.println("@SYSTEM READY");

    if(xTaskCreate(uvcWorker,"uvc-format",2048,nullptr,1,nullptr)!=pdPASS) {
        Serial.println("@ERROR UVC_TASK_FAILED");
    }
}

void loop() {
    pollWeights(millis());
    pollSerialCommands();
    ensureUvcConnected();
    static bird::Frame frame;
    uint32_t now = millis();
    if (visualQueue && xQueueReceive(visualQueue, &frame, 0) == pdTRUE) {
        // Each inference sequence is processed once, never repeatedly counted.
        visual.process(frame);
        for(int i=0;i<bird::MAX_TRACKS;i++)if(visual.tracks[i].used)rememberVisit(visual.tracks[i],false);
        int visible = 0;
        const bird::Track* largest = nullptr;
        for (int i=0; i<bird::MAX_TRACKS; i++) {
            const bird::Track& t = visual.tracks[i];
            if (t.used && t.confirmed && t.visible && t.score>=visual.confidence && !t.ignored) {
                visible++;
                if (!largest || bird::area(t.box)>bird::area(largest->box)) largest=&t;
            }
        }
        if (largest) {
            visitId=largest->id;bestScore=largest->score;bestArea=bird::area(largest->box);
            strncpy(proximity,proximityForArea(bestArea),sizeof(proximity)-1);
            lastSeenMs=now;
            if (!visitActive) { visitActive=true;strcpy(decision,"PENDING");emitBird("PRESENT"); }
        }
        if (uint32_t(now-lastNnReportMs)>=1000) {
            Serial.print("@NN COUNT ");Serial.println(frame.count);
            if(largest) {
                Serial.print("@BBOX ");Serial.print(largest->score);Serial.print(' ');
                Serial.print(largest->box.x1,4);Serial.print(' ');Serial.print(largest->box.y1,4);Serial.print(' ');
                Serial.print(largest->box.x2,4);Serial.print(' ');Serial.println(largest->box.y2,4);
                emitBird("UPDATE");
            }
            lastNnReportMs=now;
        }
    }
    visual.expire(now);
    if(visitActive && uint32_t(now-lastSeenMs)>bird::LOST_MS) {
        Serial.print("@BIRD CLEAR ");Serial.print(visitId);Serial.print(' ');Serial.println(decision);
        visitActive=false;bestScore=0;bestArea=0;strcpy(proximity,"NONE");
    }
    static uint32_t lastReport=0;
    if(uint32_t(now-lastReport)>=1000){emitVisualStatus(now);static uint32_t archiveTick=0;if(++archiveTick%4==0)emitGroupThumbnail();else emitArchivedVisit(now);lastReport=now;}
    emitWeights(millis());
    delay(1);
}