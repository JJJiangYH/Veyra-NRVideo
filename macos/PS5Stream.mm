// SPDX-License-Identifier: GPL-3.0-only
#import "PS5Stream.h"

#if VEYRA_MACOS_PS5
#import <AudioToolbox/AudioToolbox.h>
#import <LocalAuthentication/LocalAuthentication.h>
#import <Security/Security.h>
#import "RemoteAVC.h"

#include "veyra/remoteplay/ChiakiBackend.h"
#include <atomic>
#include <cstring>
#include <mutex>
#include <thread>

namespace rp = veyra::remoteplay;

namespace {
NSString *operationError(const rp::BackendResult& result) {
    return [NSString stringWithFormat:@"PS5 串流操作失败（%s，%d）。", result.operation.c_str(), result.code];
}

NSDictionary *credentialKey(NSString *host, const rp::AccountId& account) {
    NSString *number = [NSString stringWithUTF8String:rp::accountIdToBase64(account).c_str()];
    LAContext *context = [LAContext new];
    context.interactionNotAllowed = YES;
    return @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: @"io.veyra.macos.ps5",
        (__bridge id)kSecAttrAccount: [NSString stringWithFormat:@"%@/%@", host.lowercaseString, number],
        (__bridge id)kSecUseAuthenticationContext: context
    };
}

std::optional<rp::PairingCredentials> readCredentials(NSDictionary *key, const rp::AccountId& account) {
    NSMutableDictionary *query = [key mutableCopy];
    query[(__bridge id)kSecReturnData] = @YES;
    CFTypeRef value = nullptr;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &value);
    if (status == errSecItemNotFound) return std::nullopt;
    if (status != errSecSuccess) throw std::runtime_error("钥匙串无法读取 PS5 配对数据。");
    NSData *data = CFBridgingRelease(value);
    rp::PairingCredentials credentials;
    if (data.length != credentials.registrationKey.size() + credentials.sessionKey.size())
        throw std::runtime_error("钥匙串中的 PS5 配对数据无效。");
    credentials.accountId = account;
    std::memcpy(credentials.registrationKey.data(), data.bytes, credentials.registrationKey.size());
    std::memcpy(credentials.sessionKey.data(), static_cast<const uint8_t *>(data.bytes) + credentials.registrationKey.size(),
                credentials.sessionKey.size());
    return credentials;
}

void storeCredentials(NSDictionary *key, const rp::PairingCredentials& credentials) {
    NSMutableData *bytes = [NSMutableData dataWithBytes:credentials.registrationKey.data() length:credentials.registrationKey.size()];
    [bytes appendBytes:credentials.sessionKey.data() length:credentials.sessionKey.size()];
    NSMutableDictionary *entry = [key mutableCopy];
    entry[(__bridge id)kSecValueData] = bytes;
    OSStatus status = SecItemAdd((__bridge CFDictionaryRef)entry, nullptr);
    if (status == errSecDuplicateItem) {
        NSDictionary *update = @{(__bridge id)kSecValueData: bytes};
        status = SecItemUpdate((__bridge CFDictionaryRef)key, (__bridge CFDictionaryRef)update);
    }
    [bytes resetBytesInRange:NSMakeRange(0, bytes.length)];
    if (status != errSecSuccess) throw std::runtime_error("钥匙串无法保存 PS5 配对数据。");
}

void deliverPS5Video(void *context, void *, OSStatus status, VTDecodeInfoFlags, CVImageBufferRef image, CMTime pts, CMTime) {
    if (status != noErr || !image) return;
    VeyraPS5Stream *stream = (__bridge VeyraPS5Stream *)context;
    auto callback = stream.onVideo;
    if (callback) callback(image, pts);
}
}

@implementation VeyraPS5Stream {
    std::atomic<bool> _started;
    std::stop_source _stop;
    std::mutex _inputMutex;
    rp::ControllerState _input;
    RemoteAVCDecoder _video;
    std::vector<uint8_t> _sps, _pps;
    CMAudioFormatDescriptionRef _audioFormat;
    CMTime _clockOrigin, _audioEpoch, _lastVideoTime;
    rp::HostTime _inboxOrigin;
    uint32_t _channels, _sampleRate;
}

+ (BOOL)available { return YES; }

- (void)startHost:(NSString *)host account:(NSString *)account registrationPIN:(NSString *)pin
       completion:(void (^)(NSString *))completion {
    if (_started.exchange(true)) { completion(@"PS5 串流已启动。"); return; }
    dispatch_queue_t work = dispatch_queue_create("io.veyra.ps5", DISPATCH_QUEUE_SERIAL);
    dispatch_async(work, ^{
        @autoreleasepool {
            try {
                auto accountID = rp::accountIdFromDecimal(account.UTF8String);
                if (!accountID) accountID = rp::accountIdFromBase64(account.UTF8String);
                if (!rp::validHost(host.UTF8String) || !accountID) {
                    completion(@"请输入 PS5 的局域网地址和有效的 PSN Account ID。");
                    return;
                }
                if (self->_stop.stop_requested()) return;
                NSDictionary *key = credentialKey(host, *accountID);
                rp::PairingCredentials credentials;
                if (pin.length) {
                    if (!rp::parsePairingPin(pin.UTF8String)) {
                        completion(@"PS5 配对码应为 8 位数字。");
                        return;
                    }
                    auto registration = rp::pairLocalPs5(host.UTF8String, *accountID, pin.UTF8String, self->_stop.get_token());
                    if (self->_stop.stop_requested()) return;
                    if (!registration.result.ok) {
                        completion(operationError(registration.result));
                        return;
                    }
                    credentials = std::move(registration.credentials);
                    storeCredentials(key, credentials);
                } else {
                    auto saved = readCredentials(key, *accountID);
                    if (!saved) {
                        completion(@"首次连接需要在 PS5 的「关联设备」获取配对码。");
                        return;
                    }
                    credentials = std::move(*saved);
                }
                [self runHost:host credentials:std::move(credentials) completion:completion];
            } catch (const std::exception& error) {
                completion([NSString stringWithUTF8String:error.what()] ?: @"PS5 串流失败。");
            }
        }
    });
}

- (void)runHost:(NSString *)host credentials:(rp::PairingCredentials)credentials
     completion:(void (^)(NSString *))completion {
    rp::SessionInbox inbox;
    rp::ChiakiBackend backend;
    rp::NativeConnectRequest request;
    request.host = host.UTF8String;
    request.credentials = std::move(credentials);
    _clockOrigin = CMClockGetTime(CMClockGetHostTimeClock());
    _inboxOrigin = rp::monotonic100ns();
    _audioEpoch = kCMTimeInvalid;
    _lastVideoTime = kCMTimeInvalid;
    const auto token = inbox.begin(_inboxOrigin);
    const auto result = backend.start(request, token);
    if (!result.ok) { completion(operationError(result)); return; }
    completion(nil);
    const rp::HostTime connectionDeadline = _inboxOrigin + 30 * 10'000'000;
    rp::ControllerState previousInput;
    NSString *failure = nil;
    bool connected = false;
    auto nextSnapshot = _inboxOrigin;
    while (!_stop.stop_requested()) {
        @autoreleasepool {
            const auto now = rp::monotonic100ns();
            if (now >= nextSnapshot) {
                nextSnapshot = now + 1'000'000;
                auto status = inbox.snapshot();
                connected = connected || status.state == rp::SessionState::WaitingFirstFrame || status.state == rp::SessionState::Streaming;
                if (status.state == rp::SessionState::LoginPinRequired) {
                    failure = @"PS5 请求主机登录 PIN，请先在主机上解锁。";
                    break;
                }
                if (status.state == rp::SessionState::Failed || (!connected && now >= connectionDeadline)) {
                    failure = [NSString stringWithFormat:@"PS5 串流连接已结束（%d）。", status.errorCode];
                    break;
                }
            }
            for (int i = 0; i < 3; ++i) {
                auto packet = inbox.tryVideo(now);
                if (!packet) break;
                if (packet->resetDecoder) { _video.reset(); _sps.clear(); _pps.clear(); }
                if (packet->configBefore) [self decodePS5:packet->configBefore->payload.bytes() pts:kCMTimeInvalid];
                if (![self decodePS5:packet->sample.payload.bytes() pts:[self hostTime:packet->sample.arrival100ns]])
                    inbox.decodeFailed(token.generation());
            }
            for (int i = 0; i < 8; ++i) {
                auto pcm = inbox.tryAudio();
                if (!pcm) break;
                [self deliverAudio:*pcm];
            }
            if (inbox.takeIdrRequest(now)) (void)backend.requestIdr();
            rp::ControllerState input;
            { std::lock_guard lock(_inputMutex); input = _input; }
            if (input != previousInput && backend.submitController(input).ok) previousInput = input;
            std::this_thread::sleep_for(std::chrono::milliseconds(2));
        }
    }
    (void)backend.submitController(rp::ControllerState{});
    inbox.invalidate();
    (void)backend.stop();
    inbox.finishStop();
    _video.reset();
    auto status = self.onStatus;
    if (!_stop.stop_requested() && failure && status) status(failure);
}

- (CMTime)hostTime:(rp::HostTime)time {
    return CMTimeAdd(_clockOrigin, CMTimeMake(time - _inboxOrigin, 10'000'000));
}

- (BOOL)decodePS5:(std::span<const uint8_t>)packet pts:(CMTime)pts {
    bool changed = false;
    std::vector<uint8_t> sample;
    forEachAnnexBNal(packet, [&](auto nal) {
        uint8_t kind = nal[0] & 0x1f;
        if (kind == 7 || kind == 8) {
            auto& set = kind == 7 ? _sps : _pps;
            changed = changed || !std::ranges::equal(nal, set);
            set.assign(nal.begin(), nal.end());
        } else {
            appendLengthPrefixedNAL(sample, nal);
        }
    });
    if (changed && !_sps.empty() && !_pps.empty() &&
        !_video.configure(_sps, _pps, {deliverPS5Video, (__bridge void *)self})) return NO;
    if (!CMTIME_IS_NUMERIC(pts)) return YES;
    if (CMTIME_IS_VALID(_lastVideoTime) && CMTimeCompare(pts, _lastVideoTime) <= 0)
        pts = CMTimeAdd(_lastVideoTime, CMTimeMake(1, 10'000'000));
    _lastVideoTime = pts;
    return _video.decode(sample, pts);
}

- (void)deliverAudio:(const rp::PcmBlock&)pcm {
    auto callback = self.onAudio;
    if (!callback || pcm.samples.empty()) return;
    if (!_audioFormat || pcm.channels != _channels || pcm.rate != _sampleRate) {
        if (_audioFormat) CFRelease(_audioFormat);
        _audioFormat = nullptr;
        _channels = pcm.channels;
        _sampleRate = pcm.rate;
        _audioEpoch = kCMTimeInvalid;
        AudioStreamBasicDescription asbd{};
        asbd.mSampleRate = pcm.rate;
        asbd.mFormatID = kAudioFormatLinearPCM;
        asbd.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
        asbd.mBytesPerPacket = asbd.mBytesPerFrame = pcm.channels * sizeof(int16_t);
        asbd.mFramesPerPacket = 1;
        asbd.mChannelsPerFrame = pcm.channels;
        asbd.mBitsPerChannel = sizeof(int16_t) * 8;
        if (CMAudioFormatDescriptionCreate(nullptr, &asbd, 0, nullptr, 0, nullptr, nullptr, &_audioFormat)) return;
    }
    const CMTime position = CMTimeMake(pcm.firstSample, pcm.rate);
    if (!CMTIME_IS_VALID(_audioEpoch) || pcm.discontinuity)
        _audioEpoch = CMTimeSubtract([self hostTime:pcm.arrival100ns], position);
    const CMTime pts = CMTimeAdd(_audioEpoch, position);
    CMBlockBufferRef block = nullptr;
    const size_t size = pcm.samples.size() * sizeof(int16_t);
    if (CMBlockBufferCreateWithMemoryBlock(nullptr, nullptr, size, kCFAllocatorDefault, nullptr, 0, size, 0, &block)) return;
    CMSampleBufferRef sample = nullptr;
    if (!CMBlockBufferReplaceDataBytes(pcm.samples.data(), block, 0, size) &&
        !CMAudioSampleBufferCreateReadyWithPacketDescriptions(nullptr, block, _audioFormat, pcm.frames(), pts, nullptr, &sample)) {
        callback(sample);
        CFRelease(sample);
    }
    CFRelease(block);
}

- (void)controllerConnected:(BOOL)connected {
    std::lock_guard lock(_inputMutex);
    _input = {};
    _input.inputActive = connected;
}

- (void)controllerButtons:(int)buttons leftTrigger:(uint8_t)lt rightTrigger:(uint8_t)rt
                     leftX:(int16_t)lx leftY:(int16_t)ly rightX:(int16_t)rx rightY:(int16_t)ry {
    using Button = rp::ControllerState::Button;
    constexpr std::pair<int, Button> mapping[]{
        {0x0001, Button::Up}, {0x0002, Button::Down}, {0x0004, Button::Left}, {0x0008, Button::Right},
        {0x0010, Button::Options}, {0x0020, Button::Share}, {0x0040, Button::L3}, {0x0080, Button::R3},
        {0x0100, Button::L1}, {0x0200, Button::R1}, {0x0400, Button::PS}, {0x1000, Button::Cross},
        {0x2000, Button::Circle}, {0x4000, Button::Square}, {0x8000, Button::Triangle}
    };
    std::lock_guard lock(_inputMutex);
    if (!_input.inputActive) return;
    _input.buttons = 0;
    for (auto [bit, mapped] : mapping) if (buttons & bit) _input.buttons |= mapped;
    _input.leftX = lx;
    _input.leftY = int16_t(-int(ly));
    _input.rightX = rx;
    _input.rightY = int16_t(-int(ry));
    _input.l2 = lt;
    _input.r2 = rt;
}

- (void)stop { _stop.request_stop(); }
- (void)dealloc { if (_audioFormat) CFRelease(_audioFormat); }
@end

#else
@implementation VeyraPS5Stream
+ (BOOL)available { return NO; }
- (void)startHost:(NSString *)host account:(NSString *)account registrationPIN:(NSString *)pin
       completion:(void (^)(NSString *))completion { completion(@"此构建未包含 PS5 串流组件。"); }
- (void)stop {}
- (void)controllerConnected:(BOOL)connected {}
- (void)controllerButtons:(int)buttons leftTrigger:(uint8_t)lt rightTrigger:(uint8_t)rt
                     leftX:(int16_t)lx leftY:(int16_t)ly rightX:(int16_t)rx rightY:(int16_t)ry {}
@end
#endif
