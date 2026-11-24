// SPDX-License-Identifier: GPL-3.0-only
#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN
@interface VeyraPCApp : NSObject
@property(nonatomic, readonly) NSString *name;
@property(nonatomic, readonly) NSInteger identifier;
- (instancetype)initWithName:(NSString *)name identifier:(NSInteger)identifier;
@end

@protocol VeyraStreamInput <NSObject>
@property(nonatomic, copy, nullable) void (^onVideo)(CVPixelBufferRef buffer, CMTime timestamp);
@property(nonatomic, copy, nullable) void (^onAudio)(CMSampleBufferRef sample);
@property(nonatomic, copy, nullable) void (^onStatus)(NSString *message);
- (void)stop;
- (void)controllerConnected:(BOOL)connected;
- (void)controllerButtons:(int)buttons leftTrigger:(uint8_t)leftTrigger rightTrigger:(uint8_t)rightTrigger
                     leftX:(int16_t)leftX leftY:(int16_t)leftY rightX:(int16_t)rightX rightY:(int16_t)rightY;
@end

@interface VeyraPCStream : NSObject <VeyraStreamInput>
@property(class, nonatomic, readonly) BOOL available;
@property(nonatomic, copy, nullable) void (^onVideo)(CVPixelBufferRef buffer, CMTime timestamp);
@property(nonatomic, copy, nullable) void (^onAudio)(CMSampleBufferRef sample);
@property(nonatomic, copy, nullable) void (^onStatus)(NSString *message);
- (void)pairHost:(NSString *)host announcePIN:(void(^)(NSString *pin))announcePIN
      completion:(void(^)(NSArray<VeyraPCApp *> * _Nullable apps, NSString * _Nullable error))completion
    NS_SWIFT_NAME(pair(host:announcePIN:completion:));
- (void)startApplication:(NSInteger)identifier completion:(void(^)(NSString * _Nullable error))completion
    NS_SWIFT_NAME(start(application:completion:));
@end
NS_ASSUME_NONNULL_END
