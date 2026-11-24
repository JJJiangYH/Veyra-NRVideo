// SPDX-License-Identifier: GPL-3.0-only
#if VEYRA_MACOS_XBOX
#import <Foundation/Foundation.h>
#import <LocalAuthentication/LocalAuthentication.h>
#import <Security/Security.h>

#include "veyra/xbox/Account.h"
#include <nlohmann/json.hpp>

static constexpr NSUInteger maximumResponseBytes = 16 * 1024 * 1024;

@interface VeyraXboxHTTPResponse : NSObject <NSURLSessionDataDelegate>
@property(nonatomic) NSMutableData *data;
@property(nonatomic) dispatch_semaphore_t ready;
@property(nonatomic) NSInteger status;
@property(nonatomic) NSError *error;
@property(nonatomic) BOOL tooLarge;
@end

@implementation VeyraXboxHTTPResponse
- (instancetype)init {
    self = [super init];
    if (self) {
        _ready = dispatch_semaphore_create(0);
        _data = [NSMutableData data];
    }
    return self;
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition))completion {
    _status = [(NSHTTPURLResponse *)response statusCode];
    _tooLarge = response.expectedContentLength > static_cast<long long>(maximumResponseBytes);
    completion(_tooLarge ? NSURLSessionResponseCancel : NSURLSessionResponseAllow);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    if (data.length > maximumResponseBytes - _data.length) {
        _tooLarge = YES;
        [task cancel];
    } else {
        [_data appendData:data];
    }
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response
        newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest * _Nullable))completion {
    completion(nil);
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    _error = error;
    dispatch_semaphore_signal(_ready);
}
@end

namespace veyra::xbox {
namespace {
class MacHTTPS final : public HttpsTransport {
public:
    explicit MacHTTPS(const std::atomic<bool>* cancel) : cancel_(cancel) {}
    HttpsResponse send(const HttpsRequest& request) override {
        @autoreleasepool {
            if (cancel_ && *cancel_) throw NetworkError("cancelled");
            // Region endpoints can come from a token response. Keep authentication
            // headers within the service origin and reject URL authority delimiters.
            if (request.host.empty() || request.host.find_first_not_of("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-") != std::string::npos ||
                request.path.empty() || request.path[0] != '/' || request.path.find_first_of("\r\n") != std::string::npos)
                throw NetworkError("invalid Xbox service URL");
            std::string url = "https://" + request.host + request.path;
            NSURL *address = [NSURL URLWithString:[NSString stringWithUTF8String:url.c_str()]];
            if (!address) throw NetworkError("invalid Xbox service URL");
            auto *query = [NSMutableURLRequest requestWithURL:address cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                timeoutInterval:std::max(1, request.timeoutMs) / 1000.0];
            query.HTTPMethod = [NSString stringWithUTF8String:request.method.c_str()];
            for (auto& [key, value] : request.headers)
                [query setValue:[NSString stringWithUTF8String:value.c_str()] forHTTPHeaderField:[NSString stringWithUTF8String:key.c_str()]];
            if (!request.body.empty()) query.HTTPBody = [NSData dataWithBytes:request.body.data() length:request.body.size()];
            auto *reply = [VeyraXboxHTTPResponse new];
            auto *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
            configuration.timeoutIntervalForResource = query.timeoutInterval;
            configuration.HTTPCookieStorage = nil;
            configuration.URLCredentialStorage = nil;
            auto *session = [NSURLSession sessionWithConfiguration:configuration delegate:reply delegateQueue:nil];
            [[session dataTaskWithRequest:query] resume];
            while (dispatch_semaphore_wait(reply.ready, dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC))) {
                if (cancel_ && *cancel_) {
                    [session invalidateAndCancel];
                    throw NetworkError("cancelled");
                }
            }
            [session finishTasksAndInvalidate];
            if (reply.tooLarge) throw NetworkError("response larger than 16 MB");
            if (reply.error) throw NetworkError("macOS HTTPS request failed (" + std::to_string(reply.error.code) + ")");
            HttpsResponse result;
            result.status = int(reply.status);
            if (reply.data.length)
                result.body.assign(static_cast<const char *>(reply.data.bytes), reply.data.length);
            return result;
        }
    }
private:
    const std::atomic<bool> *cancel_;
};

NSDictionary *tokenKey(const std::filesystem::path& file) {
    auto *context = [LAContext new];
    context.interactionNotAllowed = YES;
    return @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
             (__bridge id)kSecAttrService: @"io.veyra.macos.xbox",
             (__bridge id)kSecAttrAccount: [NSString stringWithUTF8String:file.c_str()],
             (__bridge id)kSecUseAuthenticationContext: context};
}
}

std::shared_ptr<HttpsTransport> makeMacHttpsTransport(const std::atomic<bool>* cancel) {
    return std::make_shared<MacHTTPS>(cancel);
}

std::filesystem::path dataDirectory() {
    const auto *value = std::getenv("VEYRA_XBOX_DATA");
    if (value && *value) return value;
    NSURL *library = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    return std::filesystem::path(library.fileSystemRepresentation) / "Veyra" / "xbox";
}

std::optional<SavedTokens> loadTokens(const std::filesystem::path& file) {
    NSMutableDictionary *query = [tokenKey(file) mutableCopy];
    query[(__bridge id)kSecReturnData] = @YES;
    CFTypeRef value = nullptr;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)query, &value) != errSecSuccess) return std::nullopt;
    NSData *bytes = CFBridgingRelease(value);
    if (!bytes.length || bytes.length > (1u << 20)) return std::nullopt;
    const auto *first = static_cast<const char *>(bytes.bytes);
    try {
        auto json = nlohmann::json::parse(first, first + bytes.length);
        SavedTokens tokens;
        tokens.refreshToken = json.value("refresh", "");
        tokens.accessToken = json.value("access", "");
        tokens.accessExpiresAt = json.value("accessExpires", int64_t(0));
        tokens.userHash = json.value("uhs", "");
        if (!tokens.refreshToken.empty()) return tokens;
    } catch (const nlohmann::json::exception&) {}
    return std::nullopt;
}

bool saveTokens(const std::filesystem::path& file, const SavedTokens& tokens) {
    auto json = nlohmann::json{{"refresh", tokens.refreshToken}, {"access", tokens.accessToken},
        {"accessExpires", tokens.accessExpiresAt}, {"uhs", tokens.userHash}}.dump();
    auto *value = [NSMutableData dataWithBytes:json.data() length:json.size()];
    auto *secret = static_cast<volatile char *>(json.data());
    for (size_t i = 0; i < json.size(); ++i) secret[i] = 0;
    NSDictionary *query = tokenKey(file);
    NSMutableDictionary *entry = [query mutableCopy];
    entry[(__bridge id)kSecValueData] = value;
    auto status = SecItemAdd((__bridge CFDictionaryRef)entry, nullptr);
    if (status == errSecDuplicateItem) {
        NSDictionary *update = @{(__bridge id)kSecValueData: value};
        status = SecItemUpdate((__bridge CFDictionaryRef)query, (__bridge CFDictionaryRef)update);
    }
    [value resetBytesInRange:NSMakeRange(0, value.length)];
    return status == errSecSuccess;
}

void removeTokens(const std::filesystem::path& file) {
    SecItemDelete((__bridge CFDictionaryRef)tokenKey(file));
}
}
#endif
