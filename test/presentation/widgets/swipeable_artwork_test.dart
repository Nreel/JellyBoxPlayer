import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jplayer/src/presentation/widgets/swipeable_artwork.dart';
import 'package:just_audio_background/just_audio_background.dart';

import '../../app_wrapper.dart';
import '../../provider_container.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  MediaItem item(String id) => MediaItem(id: id, title: id);
  final localQueue = [item('l0'), item('l1'), item('l2')];
  final remoteQueue = [item('r0'), item('r1'), item('r2')];

  testWidgets('follows currentIndex across a remote queue empty-refill',
  (tester) async {
    final props = ValueNotifier<({List<MediaItem> queue, int? index})>(
      (queue: localQueue, index: 1),
    );
    addTearDown(props.dispose);

    await tester.pumpWidget(
      createTestApp(
        providerContainer: createProviderContainer(),
        home: Scaffold(
          body: ValueListenableBuilder<
            ({List<MediaItem> queue, int? index})
          >(
            valueListenable: props,
            builder: (_, value, _) => SwipeableArtwork(
              queue: value.queue,
              currentIndex: value.index,
              artworkBuilder: (item) => Center(child: Text(item?.id ?? '')),
              horizontalPadding: 8,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final controller = tester.widget<PageView>(find.byType(PageView)).controller;
    expect(controller?.page, 1.0);

    // A continuity claim drops the remote session: the queue provider empties
    // and the index is unknown, so the controller clamps back to page 0.
    props.value = (queue: const [], index: null);
    await tester.pumpAndSettle();
    expect(controller?.page, 0.0);

    // The accepted handoff doc lands before the remote queue is fetched, so a
    // move scheduled here has nothing to move across.
    props.value = (queue: const [], index: 1);
    await tester.pumpAndSettle();
    expect(controller?.page, 0.0);

    // The fetched queue refills; the artwork must land on the current track,
    // not the first one.
    props.value = (queue: remoteQueue, index: 1);
    await tester.pumpAndSettle();
    expect(controller?.page, 1.0);
    expect(find.text('r1'), findsOneWidget);
  });
}
