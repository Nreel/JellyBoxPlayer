import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:jplayer/src/domain/providers/player_bar_provider.dart';
import 'package:just_audio_background/just_audio_background.dart';

class SwipeableArtwork extends ConsumerStatefulWidget {
  const SwipeableArtwork({
    required this.queue,
    required this.currentIndex,
    required this.artworkBuilder,
    this.borderRadius = 12,
    this.horizontalPadding = 30,
    this.scale = 1,
    super.key,
  });

  final List<MediaItem> queue;
  final int? currentIndex;
  final Widget Function(MediaItem? item) artworkBuilder;
  final double borderRadius;
  final double horizontalPadding;
  final double scale;

  @override
  ConsumerState<SwipeableArtwork> createState() => _SwipeableArtworkState();
}

class _SwipeableArtworkState extends ConsumerState<SwipeableArtwork> {
  late final PageController _controller;
  late int _page;

  int get _currentPage {
    final currentIndex = widget.currentIndex;
    if (currentIndex == null || currentIndex < 0) return 0;
    return currentIndex;
  }

  @override
  void initState() {
    super.initState();
    _page = _currentPage;
    _controller = PageController(initialPage: _page);
  }

  /// Page the controller should land on once a dropped move settles.
  int? _pendingMove;

  @override
  void didUpdateWidget(covariant SwipeableArtwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    final target = _currentPage;
    // The controller can fall behind while [_page] already tracks the target:
    // a remote queue emptied and refilled (handoff round-trip) clamps the
    // page back to 0, and a move scheduled while that empty queue was shown
    // lands nowhere. Re-sync whenever the controller disagrees, not only
    // when the target changed.
    final actual = _controller.hasClients ? _controller.page?.round() : null;
    if (target == _page && (actual == null || actual == target)) return;
    _page = target;
    WidgetsBinding.instance.addPostFrameCallback((_) => _moveTo(target));
  }

  void _moveTo(int target) {
    if (!mounted || !_controller.hasClients) return;
    // Nothing to jump across while the queue is empty; the refill rebuild
    // re-syncs against the controller afterwards.
    if (widget.queue.isEmpty) return;
    if (_controller.position.isScrollingNotifier.value) {
      // A gesture or settle animation in flight swallows the move. Retry it
      // once scrolling ends, unless the user swiped to another page meanwhile.
      _pendingMove = target;
      _controller.position.isScrollingNotifier.addListener(_onScrollSettled);
      return;
    }
    final current = _controller.page?.round();
    if (current == target) return;
    if (current != null && (current - target).abs() == 1) {
      unawaited(
        _controller.animateToPage(
          target,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
        ),
      );
    } else {
      _controller.jumpToPage(target);
    }
  }

  void _onScrollSettled() {
    if (_controller.position.isScrollingNotifier.value) return;
    _controller.position.isScrollingNotifier.removeListener(_onScrollSettled);
    final target = _pendingMove;
    _pendingMove = null;
    if (target != null && mounted && target == _page) _moveTo(target);
  }

  Future<void> _onPageChanged(int page) async {
    if (page == _page) return;
    _page = page;

    if (page < 0 || page >= widget.queue.length) return;
    if (page == widget.currentIndex) return;

    _hapticTick();
    await ref.read(barControlsProvider).skipTo(page, autoPlay: false);
  }

  void _hapticTick() {
    final platform = Theme.of(context).platform;
    if (platform == TargetPlatform.iOS || platform == TargetPlatform.android) {
      unawaited(HapticFeedback.selectionClick());
    }
  }

  @override
  void dispose() {
    if (_pendingMove != null) {
      _pendingMove = null;
      _controller.position.isScrollingNotifier.removeListener(_onScrollSettled);
    }
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final side = math.min<double>(
          math.max<double>(
            constraints.maxWidth - widget.horizontalPadding * 2,
            0,
          ),
          constraints.maxHeight,
        );
        return Center(
          child: SizedBox(
            width: constraints.maxWidth,
            height: side,
            child: PageView.builder(
              controller: _controller,
              onPageChanged: _onPageChanged,
              allowImplicitScrolling: true,
              itemCount: widget.queue.length,
              itemBuilder: (context, page) {
                final item = widget.queue.elementAtOrNull(page);
                return Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: widget.horizontalPadding,
                  ),
                  child: Center(
                    child: AnimatedScale(
                      scale: widget.scale,
                      duration: const Duration(milliseconds: 350),
                      curve: Curves.easeOutCubic,
                      child: SizedBox.square(
                        dimension: side,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(
                            widget.borderRadius,
                          ),
                          child: widget.artworkBuilder(item),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }
}
