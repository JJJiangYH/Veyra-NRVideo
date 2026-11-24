// SPDX-License-Identifier: GPL-3.0-only
#import "GameStream.h"

NS_ASSUME_NONNULL_BEGIN
@interface VeyraXboxStream : NSObject <VeyraStreamInput>
@property(class, nonatomic, readonly) BOOL available;
@property(nonatomic, copy, nullable) void (^onVideo)(CVPixelBufferRef buffer, CMTime timestamp);
@property(nonatomic, copy, nullable) void (^onAudio)(CMSampleBufferRef sample);
@property(nonatomic, copy, nullable) void (^onStatus)(NSString *message);
- (void)listConsolesAnnounceCode:(void (^)(NSString *code))announceCode
    completion:(void (^)(NSArray<NSString *> * _Nullable names, NSString * _Nullable error))completion
    NS_SWIFT_NAME(listConsoles(announceCode:completion:));
- (void)startConsole:(NSInteger)index completion:(void (^)(NSString * _Nullable error))completion
    NS_SWIFT_NAME(start(console:completion:));
- (void)signOut;
@end
NS_ASSUME_NONNULL_END
