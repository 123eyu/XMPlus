import 'package:flutter/material.dart';

import '../services/app_log.dart';
import '../services/app_runtime.dart';
import 'playback_settings_page.dart';

Future<void> showSkipSegmentsSettings(
  BuildContext context,
  AppRuntime runtime,
) {
  AppLog.instance.trace(
    "lib/pages/playback_skip_control.dart::showSkipSegmentsSettings",
  );

  final track = runtime.player.current;
  return showQuickPlaybackSettings(
    context,
    runtime,
    albumId: track?.albumId.isNotEmpty == true ? track!.albumId : null,
    albumTitle: track?.album,
    skipOnly: true,
  );
}

class PlaybackSkipButton extends StatelessWidget {
  const PlaybackSkipButton({required this.runtime, super.key});
  final AppRuntime runtime;

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      "lib/pages/playback_skip_control.dart::PlaybackSkipButton.build",
    );

    return ListenableBuilder(
      listenable: runtime,
      builder: (context, _) {
        AppLog.instance.trace(
          "lib/pages/playback_skip_control.dart::PlaybackSkipButton.build.closure#1",
        );

        final settings = runtime.player.effectiveSettings;
        final enabled =
            settings.skipIntroSeconds > 0 || settings.skipOutroSeconds > 0;
        return IconButton(
          key: const ValueKey('playbackSkipSegments'),
          tooltip: enabled
              ? '片头 ${settings.skipIntroSeconds} 秒 · 片尾 ${settings.skipOutroSeconds} 秒'
              : '跳过片头片尾',
          color: enabled ? Theme.of(context).colorScheme.primary : null,
          icon: const Icon(Icons.content_cut_rounded),
          onPressed: () {
            AppLog.instance.trace(
              "lib/pages/playback_skip_control.dart::PlaybackSkipButton.build.closure#1.closure#1",
            );
            showSkipSegmentsSettings(context, runtime);
          },
        );
      },
    );
  }
}
