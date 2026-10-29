import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jplayer/src/core/enums/enums.dart';
import 'package:jplayer/src/data/backend/library_query.dart';
import 'package:jplayer/src/data/backend/media_server_capabilities.dart';
import 'package:jplayer/src/data/backend/media_server_client.dart';
import 'package:jplayer/src/data/providers/media_server_client_provider.dart';
import 'package:jplayer/src/domain/models/models.dart';
import 'package:jplayer/src/domain/providers/current_library_provider.dart';
import 'package:jplayer/src/domain/providers/current_user_provider.dart';
import 'package:jplayer/src/domain/providers/items_filter_provider.dart';
import 'package:jplayer/src/presentation/pages/browse_page.dart';
import 'package:jplayer/src/providers/connectivity_provider.dart';
import 'package:mocktail/mocktail.dart';

import '../../app_wrapper.dart';
import '../../provider_container.dart';

class _MockClient extends Mock implements MediaServerClient {}

class _MockUser extends Mock implements User {}

class _NoLibrary extends CurrentLibraryNotifier {
  @override
  FutureOr<LibraryItem?> build() => null;
}

LibraryItem _song(String id, String name) =>
    LibraryItem(id: id, name: name, kind: ItemKind.song);

void main() {
  setUpAll(() {
    registerFallbackValue(LibraryQuery());
    registerFallbackValue(ItemKind.album);
  });

  testWidgets('Songs sort dropdown re-queries with the chosen sort', (
    tester,
  ) async {
    final client = _MockClient();
    final songQueries = <LibraryQuery>[];
    var songFetches = 0;

    List<LibraryItem> pageFor(int fetch) => fetch == 0
        ? List.generate(3, (i) => _song('a$i', 'Alpha $i'))
        : List.generate(3, (i) => _song('b$i', 'Bravo $i'));

    when(() => client.getAllSongs(any())).thenAnswer((inv) async {
      songQueries.add(inv.positionalArguments.first as LibraryQuery);
      final items = pageFor(songFetches++);
      return LibraryPage(items: items, totalRecordCount: items.length);
    });
    when(() => client.getAlbums(any())).thenAnswer(
      (_) async => const LibraryPage(),
    );
    when(() => client.getArtists(any())).thenAnswer(
      (_) async => const LibraryPage(),
    );
    when(() => client.getGenres(any())).thenAnswer(
      (_) async => const LibraryPage(),
    );
    when(() => client.getPlaylists(any())).thenAnswer(
      (_) async => const LibraryPage(),
    );
    when(
      () => client.letterOffset(any(), any(), any()),
    ).thenAnswer((_) async => null);
    when(() => client.capabilities).thenAnswer(
      (_) => const MediaServerCapabilities(),
    );

    final mockUser = _MockUser();
    when(() => mockUser.userId).thenReturn('u1');

    final container = createProviderContainer(
      overrides: [
        mediaServerClientProvider.overrideWith((_) => client),
        isOfflineProvider.overrideWith((_) => false),
        currentLibraryProvider.overrideWith(_NoLibrary.new),
        currentUserProvider.overrideWith((_) => mockUser),
      ],
    );

    await tester.pumpWidget(
      createTestApp(providerContainer: container, home: const BrowsePage()),
    );
    await tester.pumpAndSettle();

    final songsChip = find.widgetWithText(ActionChip, 'Songs');
    await tester.ensureVisible(songsChip);
    await tester.pumpAndSettle();
    await tester.tap(songsChip);
    await tester.pumpAndSettle();

    expect(find.text('Alpha 0'), findsOneWidget);
    expect(songQueries.length, 1);
    expect(songQueries.last.sort, ItemSort.name);
    expect(songQueries.last.direction, SortDirection.descending);

    await tester.tap(find.byIcon(Icons.sort));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Date Added'));
    await tester.pumpAndSettle();

    final filter = container.read(filterProvider);
    expect(filter.orderBy, EntityFilter.dateCreated);
    expect(filter.desc, isTrue);
    expect(songQueries.length, 2);
    expect(songQueries.last.sort, ItemSort.dateCreated);
    expect(songQueries.last.direction, SortDirection.descending);
    expect(find.text('Bravo 0'), findsOneWidget);

    // Re-tapping the active field flips the direction.
    await tester.tap(find.byIcon(Icons.sort));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Date Added'));
    await tester.pumpAndSettle();

    expect(songQueries.length, 3);
    expect(songQueries.last.sort, ItemSort.dateCreated);
    expect(songQueries.last.direction, SortDirection.ascending);

    // Album Artist and Random also propagate.
    await tester.tap(find.byIcon(Icons.sort));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Album Artist'));
    await tester.pumpAndSettle();
    expect(songQueries.last.sort, ItemSort.albumArtist);

    await tester.tap(find.byIcon(Icons.sort));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Random'));
    await tester.pumpAndSettle();
    expect(songQueries.last.sort, ItemSort.random);
  });
}
