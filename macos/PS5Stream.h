// SPDX-License-Identifier: GPL-3.0-only
#import "GameStream.h"

NS_ASSUME_NONNULL_BEGIN
@interface VeyraPS5Stream : NSObject <VeyraStreamInput>
@property(class, nonatomic, readonly) BOOL available;
@property(nonatomic, copy, nullable) void (^onVideo)(CVPixelBufferRef buffer, CMTime timestamp);
@property(nonatomic, copy, nullable) void (^onAudio)(CMSampleBufferRef sample);
@property(nonatomic, copy, nullable) void (^onStatus)(NSString *message);
- (void)startHost:(NSString *)host account:(NSString *)account registrationPIN:(NSString *)pin
       completion:(void (^)(NSString * _Nullable error))completion
    NS_SWIFT_NAME(start(host:account:registrationPIN:completion:));
@end
NS_ASSUME_NONNULL_END
