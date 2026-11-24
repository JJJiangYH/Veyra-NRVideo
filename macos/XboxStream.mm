// SPDX-License-Identifier: GPL-3.0-only
#import "XboxStream.h"

#if VEYRA_MACOS_XBOX
#import "RemoteAVC.h"
#import <AudioToolbox/AudioToolbox.h>

#include "veyra/xbox/Account.h"
#include "veyra/xbox/WebRtcSession.h"
#include <opus_multistream.h>
#include <algorithm>
#include <thread>

namespace xbox = veyra::xbox;
using namespace std::chrono;

namespace {
class XboxSignaling final : public xbox::Signaling {
public:
    XboxSignaling(xbox::StreamApi& api, std::string id) : api_(api), id_(std::move(id)) {}
    std::string exchangeSdp(const std::string& offer) override { return api_.exchangeSdp(id_, offer); }
    std::vector<xbox::IceCandidate> exchangeIce(const std::vector<xbox::IceCandidate>& local) override {
        return api_.exchangeIce(id_, local);
    }
private:
    xbox::StreamApi& api_;
    std::string id_;
};

class XboxSessionLease {
public:
    XboxSessionLease(const xbox::StreamingAccess& access, std::string identifier)
        : access_(access), id(std::move(identifier)) {}
    ~XboxSessionLease() {
        try { xbox::StreamApi(xbox::makeMacHttpsTransport(), access_.host, access_.gsToken).stop(id); }
        catch (const std::exception&) {}
    }
private:
    const xbox::StreamingAccess& access_;
public:
    const std::string id;
};

struct RTPClock {
    CMTime origin = kCMTimeInvalid;
    uint32_t last = 0;
    int64_t position = 0;
    CMTime map(uint32_t stamp, int rate) {
        if (!CMTIME_IS_VALID(origin)) {
            origin = CMClockGetTime(CMClockGetHostTimeClock());
        } else {
            position += static_cast<int32_t>(stamp - last);
        }
        last = stamp;
        return CMTimeAdd(origin, CMTimeMake(position, rate));
    }
};

void deliverXboxVideo(void *context, void *, OSStatus status, VTDecodeInfoFlags, CVImageBufferRef image, CMTime timestamp, CMTime) {
    if (status != noErr || !image) return;
    VeyraXboxStream *stream = (__bridge VeyraXboxStream *)context;
    auto callback = stream.onVideo;
    if (callback) callback(image, timestamp);
}

NSString *safeException(const std::exception& error) {
    if (auto service = dynamic_cast<const xbox::ServiceError*>(&error)) {
        return [NSString stringWithFormat:@"Xbox 服务返回 HTTP %d。", service->status];
    }
    if (dynamic_cast<const xbox::NetworkError*>(&error)) return @"无法连接 Xbox 服务或连接超时。";
    return @"Xbox 串流未能建立。";
}
}

@implementation VeyraXboxStream {
    dispatch_queue_t _worker;
    std::atomic<bool> _cancel, _ended, _needsKeyframe;
    std::unique_ptr<xbox::Account> _account;
    std::vector<xbox::Console> _consoles;
    std::mutex _inputMutex;
    xbox::GamepadFrame _gamepad;
    bool _inputActive;
    RemoteAVCDecoder _decoder;
    std::vector<uint8_t> _sps, _pps;
    RTPClock _videoClock, _audioClock;
    OpusDecoder *_opus;
    CMAudioFormatDescriptionRef _audioFormat;
}

+ (BOOL)available { return YES; }

- (instancetype)init {
    self = [super init];
    if (self) _worker = dispatch_queue_create("io.veyra.xbox", DISPATCH_QUEUE_SERIAL);
    return self;
}

- (void)listConsolesAnnounceCode:(void (^)(NSString *))announceCode
    completion:(void (^)(NSArray<NSString *> *, NSString *))completion {
    dispatch_async(_worker, ^{
        @autoreleasepool {
            try {
                auto transport = xbox::makeMacHttpsTransport(&self->_cancel);
                self->_account = std::make_unique<xbox::Account>(transport, xbox::dataDirectory() / "session");
                if (!self->_account->signedIn()) {
                    auto code = self->_account->beginSignIn();
                    announceCode([NSString stringWithUTF8String:code.userCode.c_str()] ?: @"");
                    auto expires = steady_clock::now() + seconds(std::clamp(code.expiresInSeconds, 1, 1800));
                    int delay = std::clamp(code.intervalSeconds, 1, 120);
                    while (!self->_account->signedIn() && !self->_cancel) {
                        auto next = std::min(expires, steady_clock::now() + seconds(delay));
                        while (!self->_cancel && steady_clock::now() < next) std::this_thread::sleep_for(milliseconds(100));
                        if (self->_cancel) return;
                        if (steady_clock::now() >= expires) {
                            completion(nil, @"Xbox 登录码已过期。");
                            return;
                        }
                        auto result = self->_account->pollSignIn(code);
                        if (result == xbox::SignInPoll::SlowDown) delay = std::min(delay + 5, 120);
                        if (result != xbox::SignInPoll::Pending && result != xbox::SignInPoll::SlowDown && result != xbox::SignInPoll::Done) {
                            completion(nil, @"Xbox 设备码登录未完成。");
                            return;
                        }
                    }
                }
                if (self->_cancel) return;
                auto access = self->_account->streamingAccess();
                xbox::StreamApi api(transport, access.host, access.gsToken);
                self->_consoles = api.consoles();
                auto *names = [NSMutableArray<NSString *> array];
                for (const auto& entry : self->_consoles) {
                    NSString *name = [NSString stringWithUTF8String:entry.name.c_str()];
                    [names addObject:name.length ? name : @"Xbox"];
                }
                completion(names, nil);
            } catch (const std::exception& error) {
                if (!self->_cancel) completion(nil, safeException(error));
            }
        }
    });
}

- (void)startConsole:(NSInteger)index completion:(void (^)(NSString *))completion {
    dispatch_async(_worker, ^{
        @autoreleasepool {
            if (self->_cancel) return;
            if (!self->_account || index < 0 || size_t(index) >= self->_consoles.size()) {
                completion(@"请先登录 Xbox 并选择主机。");
                return;
            }
            bool ready = false;
            try {
                self->_ended = false;
                auto access = self->_account->streamingAccess();
                xbox::StreamApi api(xbox::makeMacHttpsTransport(&self->_cancel), access.host, access.gsToken);
                XboxSessionLease lease(access, api.play(self->_consoles[size_t(index)].serverId));
                auto expires = steady_clock::now() + seconds(45);
                bool sentConnect = false;
                while (!self->_cancel) {
                    auto state = api.state(lease.id);
                    if (state.state == "Provisioned") break;
                    if (state.state == "Failed" || steady_clock::now() >= expires) {
                        completion(@"Xbox 主机未能准备好串流。");
                        return;
                    }
                    if (state.state == "ReadyToConnect" && !sentConnect) {
                        api.connect(lease.id, self->_account->transferToken());
                        sentConnect = true;
                    }
                    for (int i = 0; i < 8 && !self->_cancel; ++i) std::this_thread::sleep_for(milliseconds(80));
                }
                if (self->_cancel) return;
                if (![self prepareAudio]) throw std::runtime_error("Opus initialization failed");
                xbox::WebRtcSession rtc;
                xbox::WebRtcCallbacks callbacks;
                callbacks.video = [self](std::vector<uint8_t>&& packet, uint32_t rtp, int64_t) {
                    @autoreleasepool { [self decodeVideo:packet timestamp:rtp]; }
                };
                callbacks.audio = [self](const uint8_t *packet, size_t size, uint32_t rtp) {
                    @autoreleasepool { [self decodeAudio:packet length:size timestamp:rtp]; }
                };
                callbacks.ended = [self](const std::string&) { self->_ended = true; };
                rtc.setCallbacks(std::move(callbacks));
                XboxSignaling signaling(api, lease.id);
                std::string error;
                if (!rtc.start(signaling, &error)) throw std::runtime_error("WebRTC connection failed");
                const auto readyDeadline = steady_clock::now() + seconds(10);
                while (!self->_cancel && !self->_ended && !rtc.ready() && steady_clock::now() < readyDeadline)
                    rtc.waitReady(milliseconds(100));
                if (self->_cancel) return;
                if (!rtc.ready() || self->_ended) throw std::runtime_error("WebRTC handshake failed");
                ready = true;
                completion(nil);
                auto keepalive = steady_clock::now() + seconds(30);
                while (!self->_cancel && !self->_ended) {
                    xbox::GamepadFrame pad;
                    { std::lock_guard lock(self->_inputMutex); pad = self->_gamepad; }
                    rtc.sendGamepad(pad);
                    if (self->_needsKeyframe.exchange(false)) rtc.requestKeyframe();
                    if (steady_clock::now() >= keepalive) {
                        keepalive += seconds(30);
                        api.keepalive(lease.id);
                    }
                    std::this_thread::sleep_for(milliseconds(16));
                }
                rtc.sendGamepad(xbox::GamepadFrame{});
                rtc.close();
                self->_decoder.reset();
                auto status = self.onStatus;
                if (!self->_cancel && status) status(@"Xbox 主机已结束串流。");
            } catch (const std::exception& error) {
                self->_decoder.reset();
                if (!self->_cancel) {
                    auto status = self.onStatus;
                    if (ready && status) status(safeException(error));
                    else if (!ready) completion(safeException(error));
                }
            }
        }
    });
}

- (void)decodeVideo:(std::span<const uint8_t>)packet timestamp:(uint32_t)rtp {
    if (_cancel) return;
    std::vector<uint8_t> sample;
    bool changed = false;
    bool picture = false;
    forEachAnnexBNal(packet, [&](auto nal) {
        uint8_t kind = nal[0] & 0x1f;
        if (kind == 7 || kind == 8) {
            auto& stored = kind == 7 ? _sps : _pps;
            changed = changed || !std::ranges::equal(nal, stored);
            stored.assign(nal.begin(), nal.end());
        } else {
            picture = picture || (kind >= 1 && kind <= 5);
            appendLengthPrefixedNAL(sample, nal);
        }
    });
    if (changed && !_sps.empty() && !_pps.empty() &&
        !_decoder.configure(_sps, _pps, {deliverXboxVideo, (__bridge void *)self})) {
        _needsKeyframe = true;
        return;
    }
    if (picture && !_decoder.decode(sample, _videoClock.map(rtp, 90000))) _needsKeyframe = true;
}

- (BOOL)prepareAudio {
    int error = OPUS_OK;
    _opus = opus_decoder_create(48000, 2, &error);
    if (!_opus || error) return NO;
    AudioStreamBasicDescription asbd{};
    asbd.mSampleRate = 48000;
    asbd.mFormatID = kAudioFormatLinearPCM;
    asbd.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    asbd.mBytesPerPacket = asbd.mBytesPerFrame = 4;
    asbd.mFramesPerPacket = 1;
    asbd.mChannelsPerFrame = 2;
    asbd.mBitsPerChannel = 16;
    return CMAudioFormatDescriptionCreate(nullptr, &asbd, 0, nullptr, 0, nullptr, nullptr, &_audioFormat) == noErr;
}

- (void)decodeAudio:(const uint8_t *)packet length:(size_t)length timestamp:(uint32_t)rtp {
    auto callback = self.onAudio;
    if (_cancel || !callback || length > INT32_MAX) return;
    int16_t pcm[2 * 5760];
    int frames = opus_decode(_opus, packet, int(length), pcm, 5760, 0);
    if (frames <= 0) return;
    CMBlockBufferRef block = nullptr;
    const size_t size = size_t(frames) * 4;
    if (CMBlockBufferCreateWithMemoryBlock(nullptr, nullptr, size, kCFAllocatorDefault, nullptr, 0, size, 0, &block)) return;
    CMSampleBufferRef sample = nullptr;
    if (!CMBlockBufferReplaceDataBytes(pcm, block, 0, size) &&
        !CMAudioSampleBufferCreateReadyWithPacketDescriptions(nullptr, block, _audioFormat, frames,
            _audioClock.map(rtp, 48000), nullptr, &sample)) {
        callback(sample);
        CFRelease(sample);
    }
    CFRelease(block);
}

- (void)controllerConnected:(BOOL)connected {
    std::lock_guard lock(_inputMutex);
    _gamepad = {};
    _inputActive = connected;
}

- (void)controllerButtons:(int)buttons leftTrigger:(uint8_t)lt rightTrigger:(uint8_t)rt
                     leftX:(int16_t)lx leftY:(int16_t)ly rightX:(int16_t)rx rightY:(int16_t)ry {
    constexpr std::pair<int, uint16_t> mapping[]{
        {0x0001, xbox::BtnUp}, {0x0002, xbox::BtnDown}, {0x0004, xbox::BtnLeft}, {0x0008, xbox::BtnRight},
        {0x0010, xbox::BtnMenu}, {0x0020, xbox::BtnView}, {0x0040, xbox::BtnLeftThumb}, {0x0080, xbox::BtnRightThumb},
        {0x0100, xbox::BtnLeftShoulder}, {0x0200, xbox::BtnRightShoulder}, {0x0400, xbox::BtnNexus},
        {0x1000, xbox::BtnA}, {0x2000, xbox::BtnB}, {0x4000, xbox::BtnX}, {0x8000, xbox::BtnY}
    };
    std::lock_guard lock(_inputMutex);
    if (!_inputActive) return;
    _gamepad.buttons = 0;
    for (auto [bit, mapped] : mapping) if (buttons & bit) _gamepad.buttons |= mapped;
    _gamepad.leftX = lx;
    _gamepad.leftY = ly;
    _gamepad.rightX = rx;
    _gamepad.rightY = ry;
    _gamepad.leftTrigger = uint16_t(lt) * 257;
    _gamepad.rightTrigger = uint16_t(rt) * 257;
}

- (void)stop { _cancel = true; }
- (void)signOut {
    _cancel = true;
    dispatch_async(_worker, ^{
        auto account = xbox::Account(xbox::makeMacHttpsTransport(), xbox::dataDirectory() / "session");
        account.signOut();
    });
}
- (void)dealloc {
    if (_opus) opus_decoder_destroy(_opus);
    if (_audioFormat) CFRelease(_audioFormat);
}
@end

#else
@implementation VeyraXboxStream
+ (BOOL)available { return NO; }
- (void)listConsolesAnnounceCode:(void (^)(NSString *))announceCode
    completion:(void (^)(NSArray<NSString *> *, NSString *))completion { completion(nil, @"此构建未包含 Xbox 串流组件。"); }
- (void)startConsole:(NSInteger)index completion:(void (^)(NSString *))completion {
    completion(@"此构建未包含 Xbox 串流组件。");
}
- (void)stop {}
- (void)signOut {}
- (void)controllerConnected:(BOOL)connected {}
- (void)controllerButtons:(int)buttons leftTrigger:(uint8_t)lt rightTrigger:(uint8_t)rt
                     leftX:(int16_t)lx leftY:(int16_t)ly rightX:(int16_t)rx rightY:(int16_t)ry {}
@end
#endif
