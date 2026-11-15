import 'package:flutter/material.dart';

import '../services/app_log.dart';

/// The same account-owned actions remain visible on album detail surfaces.
class AlbumActionBar extends StatelessWidget {
  const AlbumActionBar({
    required this.subscribed,
    required this.subscriptionBusy,
    required this.onSubscribe,
    required this.playLabel,
    required this.onPlay,
    this.subscriptionError,
    this.playBusy = false,
    super.key,
  });

  final bool? subscribed;
  final bool subscriptionBusy, playBusy;
  final String? subscriptionError;
  final String playLabel;
  final VoidCallback? onSubscribe, onPlay;

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      "lib/pages/album_action_bar.dart::AlbumActionBar.build",
    );
    const red = Color(0xffff414a);
    return Material(
      color: Theme.of(context).colorScheme.surface,
      elevation: 8,
      child: SafeArea(
        top: false,
        child: Center(
          heightFactor: 1,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 960),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (subscriptionError != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(
                        subscriptionError!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  Row(
                    children: [
                      Flexible(
                        flex: 2,
                        child: TextButton(
                          onPressed: subscriptionBusy ? null : onSubscribe,
                          style: TextButton.styleFrom(
                            backgroundColor: Theme.of(context)
                                .colorScheme
                                .surfaceContainerLow,
                            foregroundColor: subscribed == true
                                ? Colors.grey
                                : red,
                            minimumSize: const Size(112, 48),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          child: subscriptionBusy
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Text(
                                  subscribed == true
                                      ? '✓ 已订阅'
                                      : subscribed == false
                                      ? '+ 订阅'
                                      : '订阅',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 5,
                        child: FilledButton.icon(
                          onPressed: playBusy ? null : onPlay,
                          style: FilledButton.styleFrom(
                            backgroundColor: red,
                            foregroundColor: Colors.white,
                            minimumSize: const Size(0, 48),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          icon: playBusy
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Icon(
                                  Icons.play_circle_fill_rounded,
                                  size: 21,
                                ),
                          label: Text(
                            playLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
