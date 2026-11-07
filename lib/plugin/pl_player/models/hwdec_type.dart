// mpv --hwdec=help
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kDebugMode;

enum HwDecType {
  no('no', '启用软解'),
  auto('auto', '启用任意可用解码器'),
  autoSafe('auto-safe', '启用最佳解码器'),
  autoCopy('auto-copy', '启用带拷贝功能的最佳解码器'),
  d3d12va('d3d12va', 'DirectX 12 (Windows10 及以上)'),
  d3d12vaCopy('d3d12va-copy', 'DirectX 12 (Windows10 及以上) (非直通)'),
  d3d11va('d3d11va', 'DirectX 11 (Windows8 及以上)'),
  d3d11vaCopy('d3d11va-copy', 'DirectX 11 (Windows8 及以上) (非直通)'),
  dxva2('dxva2', 'DXVA2 (Windows7 及以上)'),
  dxva2Copy('dxva2-copy', 'DXVA2 (Windows7 及以上) (非直通)'),
  videotoolbox('videotoolbox', 'VideoToolbox (macOS / iOS)'),
  videotoolboxCopy('videotoolbox-copy', 'VideoToolbox (macOS / iOS) (非直通)'),
  vaapi('vaapi', 'VAAPI (Linux)'),
  vaapiCopy('vaapi-copy', 'VAAPI (Linux) (非直通)'),
  nvdec('nvdec', 'NVDEC (NVIDIA独占)'),
  nvdecCopy('nvdec-copy', 'NVDEC (NVIDIA独占) (非直通)'),
  drm('drm', 'DRM (Linux)'),
  drmCopy('drm-copy', 'DRM (Linux) (非直通)'),
  vulkan('vulkan', 'Vulkan (全平台) (实验性)'),
  vulkanCopy('vulkan-copy', 'Vulkan (全平台) (实验性) (非直通)'),
  vdpau('vdpau', 'VDPAU (Linux)'),
  vdpauCopy('vdpau-copy', 'VDPAU (Linux) (非直通)'),
  mediacodec('mediacodec', 'MediaCodec (Android)'),
  mediacodecCopy('mediacodec-copy', 'MediaCodec (Android) (非直通)'),
  cuda('cuda', 'CUDA (NVIDIA独占) (过时)'),
  cudaCopy('cuda-copy', 'CUDA (NVIDIA独占) (过时) (非直通)'),
  crystalhd('crystalhd', 'CrystalHD (全平台) (过时)'),
  rkmpp('rkmpp', 'Rockchip MPP (仅部分Rockchip芯片)'),
  amf('amf', 'AMF (AMD独占)'),
  amfCopy('amf-copy', 'AMF (AMD独占) (非直通)'),
  qsv('qsv', 'Quick Sync Video (Intel独占)'),
  qsvCopy('qsv-copy', 'Quick Sync Video (Intel独占) (非直通)'),
  ;

  final String hwdec;
  final String desc;
  const HwDecType(this.hwdec, this.desc);

  static final String kHwdec = Platform.isAndroid
      ? kDebugMode
            ? autoSafe.hwdec
            : [mediacodec.hwdec, autoSafe.hwdec].join(',')
      : Platform.isWindows
      // Windows on ARM（骁龙 8cx 等）上的 libmpv 没有编译 OpenGL，mpv 的客户端
      // 渲染 API 只能走 CPU 软件渲染；软件渲染器只吃 CPU 帧，所以硬件解码只能
      // 用**回拷**的 d3d11va-copy（d3d11va 的 GPU 帧它接不住）。mpv 的 hwdec 是
      // 一条**优先级列表**：前面的初始化失败会自动试下一个 —— 实测（本地探针
      // + 真实 H.264 流）d3d11va,d3d11va-copy,auto 最终落到 d3d11va-copy，
      // 日志里会打印「Using hardware decoding (d3d11va-copy)」；只写 d3d11va
      // 则会静默退回软解。
      ? [d3d11va.hwdec, d3d11vaCopy.hwdec, auto.hwdec].join(',')
      : auto.hwdec;
}
