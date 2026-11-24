// SPDX-License-Identifier: GPL-3.0-only
#import "Interpolation.h"
#include "../include/veyra/obs/FrameBus.h"
#import <Foundation/Foundation.h>
#include <fcntl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

@implementation VeyraOBSOutput {
    int _fd;
    uint64_t _epoch;
    uint64_t _sequence;
    NSURL *_path;
    dispatch_queue_t _work;
    dispatch_semaphore_t _slot;
}

- (instancetype)initWithCacheDirectory:(NSURL *)base {
    self = [super init];
    if (!self) return nil;
    _fd = -1;
    if (!base) return nil;
    NSURL *folder = [base URLByAppendingPathComponent:@VEYRA_OBS_FOLDER isDirectory:YES];
    if (![NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES
                                               attributes:@{NSFilePosixPermissions:@0700} error:NULL]) return nil;
    _path = [folder URLByAppendingPathComponent:@VEYRA_OBS_FILE];
    _fd = open(_path.fileSystemRepresentation, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (_fd < 0) return nil;
    struct stat file;
    if (fstat(_fd, &file) != 0 || !S_ISREG(file.st_mode) || file.st_uid != getuid() || file.st_nlink != 1 ||
        (file.st_mode & 077) != 0) return nil;
    _work = dispatch_queue_create("io.veyra.obs", DISPATCH_QUEUE_SERIAL);
    _slot = dispatch_semaphore_create(1);
    arc4random_buf(&_epoch, sizeof(_epoch));
    return self;
}

- (void)dealloc {
    if (_fd < 0) return;
    if (_sequence && flock(_fd, LOCK_EX | LOCK_NB) == 0) {
        struct veyra_obs_header header;
        if (pread(_fd, &header, sizeof(header), 0) == sizeof(header) && header.epoch == _epoch) {
            ftruncate(_fd, 0);
        }
        flock(_fd, LOCK_UN);
    }
    close(_fd);
}

- (BOOL)publish:(CVPixelBufferRef)frame {
    const size_t width = CVPixelBufferGetWidth(frame);
    const size_t height = CVPixelBufferGetHeight(frame);
    const size_t stride = CVPixelBufferGetBytesPerRow(frame);
    if (CVPixelBufferGetPixelFormatType(frame) != kCVPixelFormatType_32BGRA ||
        width == 0 || height == 0 || width > VEYRA_OBS_MAX_WIDTH || height > VEYRA_OBS_MAX_HEIGHT ||
        stride < width * 4 || stride > VEYRA_OBS_MAX_WIDTH * 4 + 1024 ||
        dispatch_semaphore_wait(_slot, DISPATCH_TIME_NOW) != 0) return NO;
    CVPixelBufferRetain(frame);
    dispatch_async(_work, ^{
        [self writeFrame:frame width:width height:height stride:stride];
        CVPixelBufferRelease(frame);
        dispatch_semaphore_signal(self->_slot);
    });
    return YES;
}

- (void)writeFrame:(CVPixelBufferRef)frame width:(size_t)width height:(size_t)height stride:(size_t)stride {
    if (flock(_fd, LOCK_EX | LOCK_NB) != 0) return;
    if (CVPixelBufferLockBaseAddress(frame, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) {
        flock(_fd, LOCK_UN);
        return;
    }
    const size_t length = stride * height;
    const void *base = CVPixelBufferGetBaseAddress(frame);
    struct veyra_obs_header header = {
        .magic = VEYRA_OBS_MAGIC, .epoch = _epoch, .sequence = ++_sequence,
        .version = VEYRA_OBS_VERSION, .width = (uint32_t)width, .height = (uint32_t)height, .stride = (uint32_t)stride
    };
    BOOL sent = base && pwrite(_fd, base, length, sizeof(header)) == (ssize_t)length &&
        pwrite(_fd, &header, sizeof(header), 0) == sizeof(header);
    if (!sent) ftruncate(_fd, 0);
    CVPixelBufferUnlockBaseAddress(frame, kCVPixelBufferLock_ReadOnly);
    flock(_fd, LOCK_UN);
}
@end
