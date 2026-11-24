// SPDX-License-Identifier: GPL-3.0-only
#import "GameStream.h"

@implementation VeyraPCApp
- (instancetype)initWithName:(NSString *)name identifier:(NSInteger)identifier {
    self = [super init];
    if (self) {
        _name = [name copy];
        _identifier = identifier;
    }
    return self;
}
@end

#if VEYRA_MACOS_MOONLIGHT

#import <AudioToolbox/AudioToolbox.h>
#import <LocalAuthentication/LocalAuthentication.h>
#import <Security/Security.h>
#import "RemoteAVC.h"

#include <Limelight.h>
#include <opus_multistream.h>
#include "veyra/moonlight/Pairing.h"

#include <array>
#include <atomic>
#include <cstring>
#include <memory>
#include <mutex>
#include <vector>

using namespace veyra::moonlight;

@interface VeyraPCStream ()
- (int)decode:(PDECODE_UNIT)frame;
- (int)prepareAudio:(POPUS_MULTISTREAM_CONFIGURATION)configuration;
- (void)decodeAudio:(const unsigned char *)bytes length:(int)length;
- (void)freeAudio;
- (void)freeVideo;
- (void)connectionEnded:(int)reason;
@end

namespace {
std::mutex sessionLock;
VeyraPCStream *currentSession;
VeyraPCStream *session() {
    std::lock_guard guard(sessionLock);
    return currentSession;
}
int videoFrame(PDECODE_UNIT frame) { return [session() decode:frame]; }
int audioSetup(int configuration, const POPUS_MULTISTREAM_CONFIGURATION opus, void *context, int flags) {
    return [session() prepareAudio:opus];
}
void audioData(char *data, int size) {
    [session() decodeAudio:reinterpret_cast<const unsigned char *>(data) length:size];
}
void audioDone() { [session() freeAudio]; }
void videoDone() { [session() freeVideo]; }
void stopped(int error) { [session() connectionEnded:error]; }

NSString *stringOf(const std::string& input) {
    return [[NSString alloc] initWithBytes:input.data() length:input.size() encoding:NSUTF8StringEncoding] ?: @"";
}

Identity pcIdentity() {
    NSDictionary *key = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: @"io.veyra.macos.moonlight",
        (__bridge id)kSecAttrAccount: @"client-identity"
    };
    NSMutableDictionary *lookup = [key mutableCopy];
    lookup[(__bridge id)kSecReturnData] = @YES;
    LAContext *context = [LAContext new];
    context.interactionNotAllowed = YES;
    lookup[(__bridge id)kSecUseAuthenticationContext] = context;
    CFTypeRef found = nullptr;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)lookup, &found);
    if (status == errSecSuccess && found) {
        NSData *data = CFBridgingRelease(found);
        NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        if ([dict isKindOfClass:NSDictionary.class] &&
            [dict[@"cert"] isKindOfClass:NSString.class] && [dict[@"key"] isKindOfClass:NSString.class] &&
            [dict[@"id"] isKindOfClass:NSString.class]) {
            Identity previous{[dict[@"cert"] UTF8String], [dict[@"key"] UTF8String], [dict[@"id"] UTF8String]};
            if (previous.valid()) return previous;
        }
        throw std::runtime_error("invalid stored client identity");
    }
    if (status != errSecItemNotFound) throw std::runtime_error("Keychain cannot read the client identity");
    Identity identity = createIdentity();
    NSDictionary *payload = @{@"cert": stringOf(identity.certPem), @"key": stringOf(identity.keyPem),
                              @"id": stringOf(identity.uniqueId)};
    NSData *bytes = [NSJSONSerialization dataWithJSONObject:payload options:0 error:NULL];
    NSMutableDictionary *addition = [key mutableCopy];
    addition[(__bridge id)kSecValueData] = bytes;
    addition[(__bridge id)kSecUseAuthenticationContext] = context;
    if (!bytes || SecItemAdd((__bridge CFDictionaryRef)addition, NULL) != errSecSuccess)
        throw std::runtime_error("Keychain cannot save the client identity");
    return identity;
}

void deliverVideo(void *user, void *opaque, OSStatus status, VTDecodeInfoFlags flags,
                  CVImageBufferRef image, CMTime pts, CMTime duration) {
    if (status == noErr && image) {
        VeyraPCStream *stream = (__bridge VeyraPCStream *)user;
        auto callback = stream.onVideo;
        if (callback) callback(image, pts);
    }
}

}

@implementation VeyraPCStream {
    dispatch_queue_t _control;
    std::atomic<bool> _cancel;
    std::atomic<bool> _streaming;
    std::unique_ptr<ServerClient> _client;
    ServerInfo _host;
    RemoteAVCDecoder _decoder;
    OpusMSDecoder *_opus;
    CMAudioFormatDescriptionRef _audioFormat;
    int _channels;
    int _sampleRate;
    int _samplesPerFrame;
    CMTime _videoEpoch;
    CMTime _audioPTS;
}

+ (BOOL)available { return YES; }

- (instancetype)init {
    self = [super init];
    if (self) {
        _control = dispatch_queue_create("io.veyra.moonlight", DISPATCH_QUEUE_SERIAL);
        _cancel = false;
        _streaming = false;
        _videoEpoch = kCMTimeInvalid;
        _audioPTS = kCMTimeInvalid;
    }
    return self;
}

- (void)pairHost:(NSString *)host announcePIN:(void (^)(NSString *))announcePIN
      completion:(void (^)(NSArray<VeyraPCApp *> *, NSString *))completion {
    dispatch_async(_control, ^{
        @autoreleasepool {
            if (self->_cancel) return;
            try {
                NSString *trimmed = [host stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                if (!trimmed.length || trimmed.length > 253 ||
                    [trimmed rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location != NSNotFound) {
                    throw std::runtime_error("invalid Sunshine host");
                }
                NSURLComponents *address = [NSURLComponents componentsWithString:[@"http://" stringByAppendingString:trimmed]];
                if (!address.host.length || address.user || address.password || address.query || address.fragment ||
                    address.path.length || (address.port && (address.port.intValue < 1 || address.port.intValue > 65535))) {
                    throw std::runtime_error("请输入 Sunshine 主机名或地址，可附带 HTTP 端口。");
                }
                NSString *hostname = address.host;
                if ([hostname hasPrefix:@"["] && [hostname hasSuffix:@"]"])
                    hostname = [hostname substringWithRange:NSMakeRange(1, hostname.length - 2)];
                Identity identity = pcIdentity();
                NSString *storage = [@"Sunshine-cert-" stringByAppendingString:trimmed.lowercaseString];
                NSString *saved = [NSUserDefaults.standardUserDefaults stringForKey:storage] ?: @"";
                auto client = std::make_unique<ServerClient>(identity, HostAddress{hostname.UTF8String,
                    address.port ? uint16_t(address.port.intValue) : kDefaultHttpPort},
                    saved.UTF8String, kDefaultHttpsPort, true);
                client->setCancel(&self->_cancel);
                ServerInfo info = client->serverInfo();
                client->setHttpsPort(info.httpsPort);
                if (info.uniqueId.empty() || info.appVersion.empty()) throw std::runtime_error("host returned no GameStream identity");
                if (!info.paired) {
                    if (saved.length && !info.pairStatusKnown)
                        throw std::runtime_error("paired host certificate could not be verified");
                    std::string pin = generatePin();
                    announcePIN(stringOf(pin));
                    auto result = pairWithHost(*client, identity, info, pin, &self->_cancel);
                    if (result.result != PairResult::Paired) throw std::runtime_error(result.detail);
                    client->setPinnedServerCertificate(result.serverCertPem);
                    auto checked = client->serverInfo();
                    if (!checked.paired || !checked.pairStatusKnown || checked.uniqueId != info.uniqueId)
                        throw std::runtime_error("host certificate pairing could not be confirmed");
                    [NSUserDefaults.standardUserDefaults setObject:stringOf(result.serverCertPem) forKey:storage];
                    info = std::move(checked);
                }
                auto list = client->appList();
                NSMutableArray<VeyraPCApp *> *apps = [NSMutableArray array];
                for (const auto& app : list) {
                    if (app.id > 0) [apps addObject:[[VeyraPCApp alloc] initWithName:stringOf(app.name) identifier:app.id]];
                }
                self->_client = std::move(client);
                self->_host = std::move(info);
                completion(apps, nil);
            } catch (const std::exception& error) { completion(nil, stringOf(error.what())); }
        }
    });
}

- (void)startApplication:(NSInteger)identifier completion:(void (^)(NSString *))completion {
    dispatch_async(_control, ^{
        @autoreleasepool {
            if (self->_cancel) return;
            if (!self->_client || identifier <= 0) { completion(@"请先配对 Sunshine 主机。"); return; }
            {
                std::lock_guard guard(sessionLock);
                if (currentSession) { completion(@"已有 PC 串流连接。"); return; }
                currentSession = self;
            }
            try {
                LaunchRequest launch;
                launch.appId = int(identifier);
                launch.surroundAudioInfo = SURROUNDAUDIOINFO_FROM_AUDIO_CONFIGURATION(AUDIO_CONFIGURATION_STEREO);
                auto key = crypto::randomBytes(20);
                if (key.size() != 20) throw std::runtime_error("无法生成会话密钥");
                std::memcpy(launch.remoteInputKey.data(), key.data(), 16);
                std::memcpy(launch.remoteInputKeyId.data(), key.data() + 16, 4);
                launch.extraQuery = LiGetLaunchUrlQueryParameters();

                STREAM_CONFIGURATION config;
                LiInitializeStreamConfiguration(&config);
                config.width = launch.width;
                config.height = launch.height;
                config.fps = launch.fps;
                config.bitrate = 20000;
                config.packetSize = 1024;
                config.streamingRemotely = STREAM_CFG_AUTO;
                config.audioConfiguration = AUDIO_CONFIGURATION_STEREO;
                config.supportedVideoFormats = VIDEO_FORMAT_H264;
                config.clientRefreshRateX100 = 6000;
                config.encryptionFlags = ENCFLG_ALL;
                std::memcpy(config.remoteInputAesKey, launch.remoteInputKey.data(), 16);
                std::memcpy(config.remoteInputAesIv, launch.remoteInputKeyId.data(), 4);
                auto rtsp = self->_client->launch(self->_host.currentGame == identifier ? "resume" : "launch",
                                                 launch, self->_host.nvidiaServerSoftware);
                SERVER_INFORMATION host;
                LiInitializeServerInformation(&host);
                host.address = self->_client->address().host.c_str();
                host.serverInfoAppVersion = self->_host.appVersion.c_str();
                host.serverInfoGfeVersion = self->_host.gfeVersion.empty() ? nullptr : self->_host.gfeVersion.c_str();
                host.rtspSessionUrl = rtsp.c_str();
                host.serverCodecModeSupport = self->_host.serverCodecModeSupport;
                DECODER_RENDERER_CALLBACKS video;
                LiInitializeVideoCallbacks(&video);
                video.submitDecodeUnit = videoFrame;
                video.cleanup = videoDone;
                AUDIO_RENDERER_CALLBACKS audio;
                LiInitializeAudioCallbacks(&audio);
                audio.init = audioSetup;
                audio.cleanup = audioDone;
                audio.decodeAndPlaySample = audioData;
                CONNECTION_LISTENER_CALLBACKS listener;
                LiInitializeConnectionCallbacks(&listener);
                listener.connectionTerminated = stopped;
                self->_videoEpoch = kCMTimeInvalid;
                self->_audioPTS = kCMTimeInvalid;
                if (self->_cancel) throw std::runtime_error("PC 串流已取消。");
                int code = LiStartConnection(&host, &config, &listener, &video, &audio, nullptr, 0, nullptr, 0);
                if (code) throw std::runtime_error("Sunshine 串流失败 (" + std::to_string(code) + ")");
                self->_streaming = true;
                completion(nil);
            } catch (const std::exception& error) {
                {
                    std::lock_guard guard(sessionLock);
                    if (currentSession == self) currentSession = nil;
                }
                completion(stringOf(error.what()));
            }
        }
    });
}

- (void)stop {
    _cancel = true;
    {
        std::lock_guard guard(sessionLock);
        if (currentSession == self && !_streaming) LiInterruptConnection();
    }
    dispatch_async(_control, ^{
        if (session() != self) return;
        if (self->_streaming.exchange(false)) {
            LiSendMultiControllerEvent(0, 0, 0, 0, 0, 0, 0, 0, 0);
            LiStopConnection();
        }
        std::lock_guard guard(sessionLock);
        if (currentSession == self) currentSession = nil;
    });
}

- (void)connectionEnded:(int)reason {
    auto callback = self.onStatus;
    if (!_cancel && callback) callback([NSString stringWithFormat:@"PC 串流已结束（%d）。", reason]);
    [self stop];
}

- (void)controllerConnected:(BOOL)connected {
    dispatch_async(_control, ^{
        if (self->_streaming && session() == self)
            LiSendMultiControllerEvent(0, connected ? 1 : 0, 0, 0, 0, 0, 0, 0, 0);
    });
}

- (void)controllerButtons:(int)buttons leftTrigger:(uint8_t)lt rightTrigger:(uint8_t)rt
                     leftX:(int16_t)lx leftY:(int16_t)ly rightX:(int16_t)rx rightY:(int16_t)ry {
    dispatch_async(_control, ^{
        if (self->_streaming && session() == self)
            LiSendMultiControllerEvent(0, 1, buttons, lt, rt, lx, ly, rx, ry);
    });
}

- (int)decode:(PDECODE_UNIT)frame {
    @autoreleasepool {
        std::span<const uint8_t> sps, pps;
        std::vector<uint8_t> sample;
        for (PLENTRY item = frame->bufferList; item; item = item->next) {
            if (!item->data || item->length <= 0) continue;
            const std::span bytes(reinterpret_cast<const uint8_t *>(item->data), size_t(item->length));
            const auto nal = bytes.subspan(annexBPrefixLength(bytes));
            if (nal.empty()) continue;
            if (item->bufferType == BUFFER_TYPE_SPS) sps = nal;
            else if (item->bufferType == BUFFER_TYPE_PPS) pps = nal;
            else if (item->bufferType == BUFFER_TYPE_PICDATA) {
                forEachAnnexBNal(bytes, [&](auto data) { appendLengthPrefixedNAL(sample, data); });
            }
        }
        if (!sps.empty() && !pps.empty() &&
            !_decoder.configure(sps, pps, {deliverVideo, (__bridge void *)self})) return DR_NEED_IDR;
        const CMTime sourcePTS = CMTimeMake(int64_t(frame->presentationTimeUs), 1000000);
        if (!CMTIME_IS_VALID(_videoEpoch))
            _videoEpoch = CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), sourcePTS);
        const CMTime pts = CMTimeAdd(_videoEpoch, sourcePTS);
        return _decoder.decode(sample, pts) ? DR_OK : DR_NEED_IDR;
    }
}

- (void)freeVideo { _decoder.reset(); }


- (int)prepareAudio:(POPUS_MULTISTREAM_CONFIGURATION)config {
    _channels = config->channelCount;
    _sampleRate = config->sampleRate;
    _samplesPerFrame = config->samplesPerFrame;
    if (_channels < 1 || _channels > 8 || _samplesPerFrame < 1 || _samplesPerFrame > 5760) return -1;
    int error = 0;
    _opus = opus_multistream_decoder_create(_sampleRate, _channels, config->streams,
                                            config->coupledStreams, config->mapping, &error);
    if (!_opus || error) { [self freeAudio]; return -1; }
    AudioStreamBasicDescription asbd{};
    asbd.mSampleRate = _sampleRate;
    asbd.mFormatID = kAudioFormatLinearPCM;
    asbd.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    asbd.mBytesPerPacket = _channels * sizeof(int16_t);
    asbd.mFramesPerPacket = 1;
    asbd.mBytesPerFrame = asbd.mBytesPerPacket;
    asbd.mChannelsPerFrame = _channels;
    asbd.mBitsPerChannel = sizeof(int16_t) * 8;
    if (CMAudioFormatDescriptionCreate(nullptr, &asbd, 0, nullptr, 0, nullptr, nullptr, &_audioFormat)) {
        [self freeAudio];
        return -1;
    }
    return 0;
}

- (void)decodeAudio:(const unsigned char *)bytes length:(int)length {
    @autoreleasepool {
        auto callback = self.onAudio;
        if (!_opus || !_audioFormat || !callback) return;
        std::vector<int16_t> pcm(size_t(_channels * _samplesPerFrame));
        int samples = opus_multistream_decode(_opus, bytes, length, pcm.data(), _samplesPerFrame, 0);
        if (samples <= 0) return;
        CMBlockBufferRef block = nullptr;
        const size_t count = size_t(samples * _channels) * sizeof(int16_t);
        if (CMBlockBufferCreateWithMemoryBlock(nullptr, nullptr, count, kCFAllocatorDefault, nullptr, 0, count, 0, &block))
            return;
        const auto result = CMBlockBufferReplaceDataBytes(pcm.data(), block, 0, count);
        if (!CMTIME_IS_VALID(_audioPTS)) _audioPTS = CMClockGetTime(CMClockGetHostTimeClock());
        CMSampleBufferRef buffer = nullptr;
        if (!result && CMAudioSampleBufferCreateReadyWithPacketDescriptions(nullptr, block, _audioFormat,
                samples, _audioPTS, nullptr, &buffer) == noErr) {
            callback(buffer);
            CFRelease(buffer);
        }
        _audioPTS = CMTimeAdd(_audioPTS, CMTimeMake(samples, _sampleRate));
        CFRelease(block);
    }
}

- (void)freeAudio {
    if (_opus) { opus_multistream_decoder_destroy(_opus); _opus = nullptr; }
    if (_audioFormat) { CFRelease(_audioFormat); _audioFormat = nullptr; }
}

- (void)dealloc { [self freeVideo]; [self freeAudio]; }
@end

#else

@implementation VeyraPCStream
+ (BOOL)available { return NO; }
- (void)pairHost:(NSString *)host announcePIN:(void (^)(NSString *))announcePIN
      completion:(void (^)(NSArray<VeyraPCApp *> *, NSString *))completion { completion(nil, @"此构建未包含 PC 串流组件。"); }
- (void)startApplication:(NSInteger)identifier completion:(void (^)(NSString *))completion { completion(@"此构建未包含 PC 串流组件。"); }
- (void)stop {}
- (void)controllerConnected:(BOOL)connected {}
- (void)controllerButtons:(int)buttons leftTrigger:(uint8_t)lt rightTrigger:(uint8_t)rt
                     leftX:(int16_t)lx leftY:(int16_t)ly rightX:(int16_t)rx rightY:(int16_t)ry {}
@end

#endif
