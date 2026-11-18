import 'dart:io' show Platform;

import 'package:audio_service_platform_interface/audio_service_platform_interface.dart';
import 'package:PiliPlus/services/audio_handler.dart';
import 'package:PiliPlus/services/audio_session.dart';
import 'package:PiliPlus/services/windows_smtc_service.dart';

VideoPlayerServiceHandler? videoPlayerServiceHandler;
AudioSessionHandler? audioSessionHandler;

Future<void> setupServiceLocator() async {
  if (Platform.isWindows) {
    AudioServicePlatform.instance = WindowsSmtcAudioService();
  }
  final audio = await initAudioService();
  videoPlayerServiceHandler = audio;
  if (!Platform.isWindows) {
    audioSessionHandler = AudioSessionHandler();
  }
}
