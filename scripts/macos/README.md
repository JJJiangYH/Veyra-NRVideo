# Veyra macOS 构建与 HDR 验证

需要 Apple Silicon、macOS 26 或更新版本、带 macOS 26 或更新 SDK 的 Xcode，以及 CMake 3.24 或更新版本。

```sh
cmake -S . -B build-macos -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0
cmake --build build-macos --target veyra_macos --parallel 2
```

应用位于 `build-macos/macos/Veyra.app`，使用本机临时签名。核心构建支持本地视频和图片、屏幕与采集卡输入。可选的 FFmpeg、Moonlight、Chiaki 和 libdatachannel 通过 `macos/` 下的 CMake 变量配置。OBS 插件使用独立构建目录并开启 `VEYRA_BUILD_OBS_FILTER`。

## HDR 批处理命令

```sh
scripts/macos/build-hdr-tools.sh ./hdr-tools
./hdr-tools/process-gta prepare recording.mp4 source-30-video.mp4
ffmpeg -i source-30-video.mp4 -i recording.mp4 -map 0:v:0 -map 1:a -c copy source-30.mp4
./hdr-tools/process-gta enhance source-30.mp4 enhanced-60-video.mp4
ffmpeg -i enhanced-60-video.mp4 -i source-30.mp4 -map 0:v:0 -map 1:a -c copy enhanced-60.mp4
./hdr-tools/process-gta verify enhanced-60.mp4 60
./hdr-tools/make-comparison source-30.mp4 enhanced-60.mp4 comparison-video.mp4
ffmpeg -i comparison-video.mp4 -i source-30.mp4 -map 0:v:0 -map 1:a -c copy comparison.mp4
./hdr-tools/audit-media audio recording.mp4 source-30.mp4 enhanced-60.mp4 comparison.mp4
```

`prepare` 用于游戏实帧为 30 fps、采集文件为 59.94 fps 的横屏 1080p／4K PQ HDR 录像。它根据相邻帧亮度差异跟踪重复帧的相位，输出 29.97 fps。1080p 路径先在源分辨率生成中间帧，再用 MetalFX HDR 放大到 4K。4K 路径在原分辨率生成中间帧。两条路径均输出 10-bit PQ HDR 59.94 fps，并报告离线耗时。左右对照使用同一段素材，左侧保持 29.97 fps 源帧，右侧播放处理后的 59.94 fps 帧。
