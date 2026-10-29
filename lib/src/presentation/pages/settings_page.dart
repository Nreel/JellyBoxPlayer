import 'package:dropdown_button2/dropdown_button2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:jplayer/main.dart';
import 'package:jplayer/resources/j_player_icons.dart';
import 'package:jplayer/src/config/routes.dart';
import 'package:jplayer/src/core/discord/discord_presence_handler.dart';
import 'package:jplayer/src/core/enums/enums.dart';
import 'package:jplayer/src/data/services/artwork_cache.dart';
import 'package:jplayer/src/domain/providers/cloud_provider.dart';
import 'package:jplayer/src/domain/providers/providers.dart';
import 'package:jplayer/src/presentation/utils/utils.dart';
import 'package:jplayer/src/presentation/widgets/widgets.dart';
import 'package:jplayer/src/providers/accounts_provider.dart';
import 'package:jplayer/src/providers/auth_provider.dart';
import 'package:jplayer/src/providers/network_type_provider.dart';

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  /// Padding for the settings buttons so their hover/highlight state has
  /// breathing room (the global [TextButtonThemeData] uses zero padding).
  static const _buttonPadding = EdgeInsets.symmetric(
    horizontal: 12,
    vertical: 10,
  );

  static const Map<ItemList, String> _browseTabLabels = {
    ItemList.albums: 'Albums',
    ItemList.artists: 'Artists',
    ItemList.songs: 'Songs',
    ItemList.playlists: 'Playlists',
    ItemList.genres: 'Genres',
  };

  static const Map<KeepScreenOn, String> _keepScreenOnLabels = {
    KeepScreenOn.never: 'Never',
    KeepScreenOn.charging: 'While charging',
    KeepScreenOn.always: 'Always',
  };

  static const Map<AnimationSpeed, String> _animationSpeedLabels = {
    AnimationSpeed.none: 'None',
    AnimationSpeed.slow: 'Slow',
    AnimationSpeed.medium: 'Medium',
    AnimationSpeed.fast: 'Fast',
  };

  static const Map<StudioLyricsPlacement, String> _studioLyricsLabels = {
    StudioLyricsPlacement.right: 'Right side',
    StudioLyricsPlacement.left: 'Left side',
    StudioLyricsPlacement.separate: 'Separate page',
  };

  static const Map<LyricsAlignment, String> _lyricsAlignmentLabels = {
    LyricsAlignment.left: 'Left',
    LyricsAlignment.center: 'Middle',
    LyricsAlignment.right: 'Right',
  };

  static const Map<StartPage, String> _startPageLabels = {
    StartPage.home: 'Home',
    StartPage.browse: 'Browse',
  };

  static const Map<ForwardCacheWindow, String> _forwardCacheWindowLabels = {
    ForwardCacheWindow.min10: '10 min',
    ForwardCacheWindow.min15: '15 min',
    ForwardCacheWindow.min30: '30 min',
    ForwardCacheWindow.min45: '45 min',
    ForwardCacheWindow.min60: '60 min',
  };

  static const Map<StreamQuality, String> _streamQualityLabels = {
    StreamQuality.original: 'Original',
    StreamQuality.kbps320: '320 kbps',
    StreamQuality.kbps256: '256 kbps',
    StreamQuality.kbps192: '192 kbps',
    StreamQuality.kbps128: '128 kbps',
    StreamQuality.kbps96: '96 kbps',
    StreamQuality.kbps64: '64 kbps',
  };

  static const Map<ContentUpdateInterval, String> _contentUpdateLabels = {
    ContentUpdateInterval.min1: '1 minute',
    ContentUpdateInterval.min5: '5 minutes',
    ContentUpdateInterval.min15: '15 minutes',
    ContentUpdateInterval.min30: '30 minutes',
    ContentUpdateInterval.never: 'Never',
  };

  /// Preset app accents; the picker dialog covers everything else.
  static const Map<String, Color> _accentPresets = {
    'Red': Color(0xFFFD2F2F),
    'Orange': Color(0xFFFF6B35),
    'Amber': Color(0xFFFFAD44),
    'Green': Color(0xFF3DBF5E),
    'Teal': Color(0xFF2ECDB0),
    'Blue': Color(0xFF3D8BFF),
    'Violet': Color(0xFF8C6BFF),
    'Pink': Color(0xFFFF5C8A),
  };

  static String _accentHex(Color color) =>
      (color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0');

  static const Map<ForwardCacheLimit, String> _forwardCacheLabels = {
    ForwardCacheLimit.off: 'Off',
    ForwardCacheLimit.mb500: '500 MB',
    ForwardCacheLimit.gb1: '1 GB',
    ForwardCacheLimit.gb2: '2 GB',
    ForwardCacheLimit.gb4: '4 GB',
    ForwardCacheLimit.gb8: '8 GB',
  };

  ButtonStyle get _buttonStyle => TextButton.styleFrom(
    padding: _buttonPadding,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
  );

  void _onPaletteSettingsPressed(BuildContext context) =>
      context.pushNamed(Routes.palette.name);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final padding = MediaQuery.paddingOf(context);
    final device = DeviceType.fromScreenSize(MediaQuery.sizeOf(context));
    final contentPadding = EdgeInsets.only(
      left: padding.left + (device.isMobile ? 16 : 30),
      top: padding.top + (device.isMobile ? 16 : 30),
      right: padding.right + (device.isMobile ? 16 : 30),
      bottom: device.isMobile ? 22 : 26,
    );

    return Scaffold(
      body: GradientBackground(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            GradientPanelDecoration(
              child: Padding(
                padding: EdgeInsets.only(
                  left: contentPadding.left,
                  top: contentPadding.top,
                  right: contentPadding.right,
                  bottom: 20,
                ),
                child: Text(
                  'Settings',
                  style: TextStyle(
                    fontSize: device.isMobile ? 24 : 36,
                    fontWeight: FontWeight.w600,
                    height: 1.2,
                  ),
                ),
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: EdgeInsets.only(
                  left: contentPadding.left,
                  right: contentPadding.right,
                  bottom: contentPadding.bottom,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 4,
                  children: [
                    _groupHeader('Connections'),
                    _subsectionHeader('Content servers'),
                    const ServerAccountList(),
                    _subsectionHeader('Connection addresses'),
                    const ServerAddressSettings(),
                    if (ref.watch(cloudAvailableProvider)) ...[
                      _subsectionHeader('Continuity server'),
                      const JellyboxCloudSettings(),
                    ],
                    _subsectionHeader('ListenBrainz'),
                    const ListenBrainzSettings(),
                    _sectionHeader('General'),
                    if (kDebugMode) _settingsButton(context),
                    if (kDebugMode) _queueCacheButton(context),
                    _sectionHeader('Home Page'),
                    _settingCheckbox(
                      ref: ref,
                      setting: AppSetting.generatedPlaylistsDisabled,
                      label: 'Disable auto-generated playlists',
                    ),
                    _settingCheckbox(
                      ref: ref,
                      setting: AppSetting.favouritesHidden,
                      label: 'Hide favourites',
                    ),
                    _settingCheckbox(
                      ref: ref,
                      setting: AppSetting.recentlyPlayedHidden,
                      label: 'Hide recently played',
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _settingDropdown<ContentUpdateInterval>(
                          context: context,
                          label: 'Content update interval',
                          value: ref.watch(contentUpdateIntervalProvider),
                          options: _contentUpdateLabels,
                          onChanged: (value) => ref
                              .read(appSettingsProvider.notifier)
                              .setValue(
                                AppSetting.contentUpdateInterval,
                                value.name,
                              ),
                        ),
                        _refreshContentButton(context, ref),
                      ],
                    ),
                    _settingNote(
                      context,
                      'How often the home page refreshes and downloaded '
                      'playlists check your server for changes.',
                    ),
                    _sectionHeader('UI'),
                    _settingDropdown<StartPage>(
                      context: context,
                      label: 'Default start page',
                      value: ref.watch(defaultStartPageProvider),
                      options: _startPageLabels,
                      onChanged: (value) => ref
                          .read(appSettingsProvider.notifier)
                          .setValue(AppSetting.defaultStartPage, value.name),
                    ),
                    if (!device.isMobile) ...[
                      _settingDropdown<AnimationSpeed>(
                        context: context,
                        label: 'Animation speed',
                        value: ref.watch(animationSpeedProvider),
                        options: _animationSpeedLabels,
                        onChanged: (value) => ref
                            .read(appSettingsProvider.notifier)
                            .setValue(AppSetting.animationSpeed, value.name),
                      ),
                      _settingNote(
                        context,
                        'Affects Studio Mode and Landscape Mode.',
                      ),
                    ],
                    _settingAccentColor(context, ref, isMobile: device.isMobile),
                    _settingNote(
                      context,
                      'Recolours buttons, sliders and panels app-wide. When '
                      '"Match button colours to the current track" is on, '
                      'player buttons follow the cover art instead.',
                    ),
                    _settingDropdown<ItemList>(
                      context: context,
                      label: 'Default browse tab',
                      value: ref.watch(defaultBrowseTabProvider),
                      options: _browseTabLabels,
                      onChanged: (value) => ref
                          .read(appSettingsProvider.notifier)
                          .setValue(AppSetting.defaultBrowseTab, value.name),
                    ),
                    _settingCheckbox(
                      ref: ref,
                      setting: AppSetting.letterRuler,
                      label: 'Show A–Z index on browse lists sorted by name',
                    ),
                    _settingCheckbox(
                      ref: ref,
                      setting: AppSetting.artworkAccent,
                      label: 'Match button colours to the current track',
                    ),
                    _settingCheckbox(
                      ref: ref,
                      setting: AppSetting.nowPlayingHalo,
                      label: 'Enable halo effect for currently playing media',
                    ),
                    if (device.isMobile) ...[
                      _settingCheckbox(
                        ref: ref,
                        setting: AppSetting.albumArtTint,
                        label: 'Tint album pages with cover art colours',
                      ),
                      _settingCheckbox(
                        ref: ref,
                        setting: AppSetting.animatedCovers,
                        label: 'Animated album covers',
                      ),
                      _settingNote(
                        context,
                        'Looks up for animated covers and plays them on '
                        'Wi-Fi only.',
                      ),
                    ],
                    _sectionHeader('Streaming'),
                    _settingDropdown<StreamQuality>(
                      context: context,
                      label: deviceHasCellular ? 'Wi-Fi' : 'Streaming quality',
                      value: ref.watch(streamQualityWifiProvider),
                      options: _streamQualityLabels,
                      onChanged: (value) => ref
                          .read(appSettingsProvider.notifier)
                          .setValue(AppSetting.streamQualityWifi, value.name),
                    ),
                    if (deviceHasCellular)
                      _settingDropdown<StreamQuality>(
                        context: context,
                        label: 'Cellular',
                        value: ref.watch(streamQualityCellularProvider),
                        options: _streamQualityLabels,
                        onChanged: (value) => ref
                            .read(appSettingsProvider.notifier)
                            .setValue(
                              AppSetting.streamQualityCellular,
                              value.name,
                            ),
                      ),
                    _settingNote(
                      context,
                      'Songs above the limit are converted by your server. '
                      'Changes apply from the next song. Downloads always '
                      'keep the original quality.',
                    ),
                    if (deviceHasCellular) ...[
                      _sectionHeader('Downloads'),
                      _settingCheckbox(
                        ref: ref,
                        setting: AppSetting.downloadSyncOnCellular,
                        label: 'Update downloaded playlists on cellular',
                      ),
                      _settingNote(
                        context,
                        'Downloaded playlists follow your server: new songs '
                        'are downloaded and removed songs are deleted. '
                        'Otherwise this only happens on Wi-Fi.',
                      ),
                    ],
                    _sectionHeader('Cache'),
                    _settingDropdown<ForwardCacheLimit>(
                      context: context,
                      label: 'Cache limit',
                      value: ref.watch(forwardCacheLimitProvider),
                      options: _forwardCacheLabels,
                      onChanged: (value) => ref
                          .read(appSettingsProvider.notifier)
                          .setValue(AppSetting.forwardCacheLimit, value.name),
                      trailing: _purgeCacheButton(context, ref),
                    ),
                    if (ref.watch(forwardCacheLimitProvider).isEnabled)
                      _settingDropdown<ForwardCacheWindow>(
                        context: context,
                        label: 'Cache ahead',
                        value: ref.watch(forwardCacheWindowProvider),
                        options: _forwardCacheWindowLabels,
                        onChanged: (value) => ref
                            .read(appSettingsProvider.notifier)
                            .setValue(
                              AppSetting.forwardCacheWindow,
                              value.name,
                            ),
                      ),
                    _clearImageCacheButton(context),
                    if (device.isMobile) ...[
                      _sectionHeader('Landscape player'),
                      _settingDropdown<KeepScreenOn>(
                        context: context,
                        label: 'Keep the screen on',
                        value: ref.watch(keepScreenOnProvider),
                        options: _keepScreenOnLabels,
                        onChanged: (value) => ref
                            .read(appSettingsProvider.notifier)
                            .setValue(AppSetting.keepScreenOn, value.name),
                      ),
                      _settingDropdown<AnimationSpeed>(
                        context: context,
                        label: 'Animation speed',
                        value: ref.watch(animationSpeedProvider),
                        options: _animationSpeedLabels,
                        onChanged: (value) => ref
                            .read(appSettingsProvider.notifier)
                            .setValue(AppSetting.animationSpeed, value.name),
                      ),
                      _settingNote(
                        context,
                        'Affects Studio Mode and Landscape Mode.',
                      ),
                    ],
                    if (!device.isMobile) ...[
                      _sectionHeader('Studio Mode'),
                      if (supportsWindowFullscreen)
                        _settingCheckbox(
                          ref: ref,
                          setting: AppSetting.studioModeFullscreen,
                          label:
                              'Make player full screen when Studio Mode enabled',
                        ),
                      _settingCheckbox(
                        ref: ref,
                        setting: AppSetting.studioModeVideoCovers,
                        label: 'Use video covers when available',
                      ),
                      _settingCheckbox(
                        ref: ref,
                        setting: AppSetting.studioModePinnedControls,
                        label: 'Always show controls',
                      ),
                      _settingCheckbox(
                        ref: ref,
                        setting: AppSetting.studioModeCoverOverVideo,
                        label: 'Show cover art over video background',
                      ),
                      _settingDropdown<StudioLyricsPlacement>(
                        context: context,
                        label: 'Show lyrics',
                        value: ref.watch(studioLyricsPlacementProvider),
                        options: _studioLyricsLabels,
                        onChanged: (value) => ref
                            .read(appSettingsProvider.notifier)
                            .setValue(
                              AppSetting.studioModeLyricsPlacement,
                              value.name,
                            ),
                      ),
                    ],
                    if (supportsDiscordPresence) ...[
                      _sectionHeader('Discord'),
                      _settingCheckbox(
                        ref: ref,
                        setting: AppSetting.discordRichPresence,
                        label: 'Share what I am listening to on Discord',
                      ),
                    ],
                    _sectionHeader('Lyrics'),
                    _settingDropdown<LyricsAlignment>(
                      context: context,
                      label: 'Lyrics text alignment',
                      value: ref.watch(lyricsAlignmentProvider),
                      options: _lyricsAlignmentLabels,
                      onChanged: (value) => ref
                          .read(appSettingsProvider.notifier)
                          .setValue(AppSetting.lyricsAlignment, value.name),
                    ),
                    _settingCheckbox(
                      ref: ref,
                      setting: AppSetting.lrclibLyrics,
                      label: 'Find missing lyrics on LRCLIB',
                    ),
                    _settingNote(
                      context,
                      'When your server has no lyrics for a song, looks '
                      'them up on lrclib.net, a free public lyrics library.',
                    ),
                    if (!device.isDesktop) _logOutButton(ref),
                    _versionLabel(context),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _settingAccentColor(
    BuildContext context,
    WidgetRef ref, {
    required bool isMobile,
  }) {
    final theme = Theme.of(context);
    final current = ref.watch(appAccentColorProvider);
    final muted = theme.colorScheme.onPrimary.withValues(alpha: 0.7);

    final label = Text(
      'Accent colour',
      style: TextStyle(fontSize: 14, height: 1.2, color: muted),
    );

    final swatches = Wrap(
      spacing: 6,
      runSpacing: 4,
      children: [
        for (final entry in _accentPresets.entries)
          IconButton(
            key: Key('accent-${entry.key.toLowerCase()}'),
            tooltip: entry.key,
            onPressed: () => ref
                .read(appSettingsProvider.notifier)
                .setValue(AppSetting.accentColor, _accentHex(entry.value)),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 26, height: 26),
            icon: Padding(
              padding: const EdgeInsets.all(4),
              child: Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: entry.value,
                  border: Border.all(
                    color: entry.value == current
                        ? theme.colorScheme.onPrimary
                        : muted.withValues(alpha: 0.4),
                    width: entry.value == current ? 2 : 1,
                  ),
                ),
              ),
            ),
          ),
        IconButton(
          key: const Key('accent-custom'),
          tooltip: 'Custom colour',
          onPressed: () => _onCustomAccentPressed(context, ref, current),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 26, height: 26),
          icon: Icon(Icons.palette_outlined, size: 18, color: muted),
        ),
      ],
    );

    return Padding(
      padding: const EdgeInsets.only(left: 12, top: 4, bottom: 4),
      child: isMobile
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 4,
              children: [label, swatches],
            )
          : Row(
              children: [
                SizedBox(width: 170, child: label),
                const SizedBox(width: 8),
                swatches,
              ],
            ),
    );
  }

  Future<void> _onCustomAccentPressed(
    BuildContext context,
    WidgetRef ref,
    Color current,
  ) async {
    final picked = await showAppDialog<Color>(
      context,
      builder: (context) => AccentColorDialog(initial: current),
    );
    if (picked != null) {
      ref
          .read(appSettingsProvider.notifier)
          .setValue(AppSetting.accentColor, _accentHex(picked));
    }
  }

  Widget _purgeCacheButton(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return IconButton(
      onPressed: () => _onPurgeCachePressed(context, ref),
      icon: const Icon(Icons.delete_outline, size: 18),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 30, height: 30),
      visualDensity: VisualDensity.compact,
      tooltip: 'Empty cache',
      color: theme.colorScheme.onPrimary.withValues(alpha: 0.7),
    );
  }

  Future<void> _onPurgeCachePressed(BuildContext context, WidgetRef ref) async {
    final confirmed = await showAppDialog<bool>(
      context,
      builder: (context) => AlertDialog.adaptive(
        title: const Text('Empty the cache?', textAlign: TextAlign.center),
        content: const Text(
          'Tracks cached ahead for offline playback will be deleted.',
          textAlign: TextAlign.center,
        ),
        actions: [
          AdaptiveDialogAction(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('No'),
          ),
          AdaptiveDialogAction(
            onPressed: () => Navigator.of(context).pop(true),
            isDestructiveAction: true,
            child: const Text('Yes'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    await ref.read(forwardCacheProvider.notifier).purge();
    messenger.showSnackBar(const SnackBar(content: Text('Cache emptied')));
  }

  Widget _clearImageCacheButton(BuildContext context) => TextButton.icon(
    onPressed: () => _onClearImageCachePressed(context),
    style: _buttonStyle,
    icon: const Icon(Icons.image_not_supported_outlined),
    label: const Text('Clear image cache'),
  );

  Future<void> _onClearImageCachePressed(BuildContext context) async {
    final confirmed = await showAppDialog<bool>(
      context,
      builder: (context) => AlertDialog.adaptive(
        title: const Text(
          'Clear the image cache?',
          textAlign: TextAlign.center,
        ),
        content: const Text(
          'Artwork will be downloaded again from your server as you browse.',
          textAlign: TextAlign.center,
        ),
        actions: [
          AdaptiveDialogAction(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('No'),
          ),
          AdaptiveDialogAction(
            onPressed: () => Navigator.of(context).pop(true),
            isDestructiveAction: true,
            child: const Text('Yes'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    await ArtworkCache.instance.emptyCache();
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    messenger.showSnackBar(
      const SnackBar(content: Text('Image cache cleared')),
    );
  }

  Widget _queueCacheButton(BuildContext context) => TextButton.icon(
    onPressed: () => context.pushNamed(Routes.queueCache.name),
    style: _buttonStyle,
    icon: const Icon(JPlayer.download),
    label: const Text('Queue cache'),
  );

  Widget _settingsButton(BuildContext context) => TextButton.icon(
    onPressed: () => _onPaletteSettingsPressed(context),
    style: _buttonStyle,
    icon: const Icon(JPlayer.music),
    label: const Text('Palette settings'),
  );

  Widget _refreshContentButton(BuildContext context, WidgetRef ref) =>
      IconButton(
        onPressed: () {
          ref.refreshHomeSections();
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(
              const SnackBar(content: Text('Home page refreshed')),
            );
        },
        tooltip: 'Refresh now',
        iconSize: 20,
        color: Theme.of(context).colorScheme.onPrimary.withValues(alpha: 0.7),
        icon: const Icon(Icons.refresh),
      );

  Widget _sectionHeader(String title) => Padding(
    padding: const EdgeInsets.only(left: 12, top: 20, bottom: 4),
    child: Text(
      title,
      style: const TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w600,
        height: 1.2,
      ),
    ),
  );

  /// Top-level menu group, e.g. Connections.
  Widget _groupHeader(String title) => Padding(
    padding: const EdgeInsets.only(left: 12, top: 20, bottom: 6),
    child: Text(
      title,
      style: const TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.w600,
        height: 1.2,
      ),
    ),
  );

  /// Group member, one step below [_sectionHeader].
  Widget _subsectionHeader(String title) => Padding(
    padding: const EdgeInsets.only(left: 12, top: 16, bottom: 4),
    child: Text(
      title,
      style: const TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        height: 1.2,
      ),
    ),
  );

  Widget _settingDropdown<T>({
    required BuildContext context,
    required String label,
    required T value,
    required Map<T, String> options,
    required ValueChanged<T> onChanged,
    Widget? trailing,
  }) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 12, top: 4, bottom: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 170,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 14,
                height: 1.2,
                color: theme.colorScheme.onPrimary.withValues(alpha: 0.7),
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 140,
            child: DropdownButtonHideUnderline(
              child: DropdownButton2<T>(
                isExpanded: true,
                buttonStyleData: ButtonStyleData(
                  height: 30,
                  padding: const EdgeInsets.only(left: 10, right: 6),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: theme.colorScheme.onPrimary.withValues(alpha: 0.2),
                    ),
                  ),
                ),
                iconStyleData: const IconStyleData(iconSize: 20),
                menuItemStyleData: const MenuItemStyleData(
                  height: 34,
                  padding: EdgeInsets.symmetric(horizontal: 8),
                ),
                dropdownStyleData: DropdownStyleData(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  offset: const Offset(0, -6),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
                items: [
                  for (final entry in options.entries)
                    DropdownMenuItem<T>(
                      value: entry.key,
                      child: Text(
                        entry.value,
                        style: TextStyle(
                          fontSize: 13,
                          height: 1.2,
                          color: (entry.key == value)
                              ? theme.colorScheme.primary
                              : theme.colorScheme.onPrimary,
                        ),
                      ),
                    ),
                ],
                value: value,
                onChanged: (selected) {
                  if (selected != null) onChanged(selected);
                },
              ),
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 4),
            trailing,
          ],
        ],
      ),
    );
  }

  Widget _settingCheckbox({
    required WidgetRef ref,
    required AppSetting setting,
    required String label,
  }) {
    final enabled = ref.watch(settingProvider(setting));
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Checkbox(
            value: enabled,
            onChanged: (value) => ref
                .read(appSettingsProvider.notifier)
                .setEnabled(setting, value: value ?? false),
          ),
          Text(label),
        ],
      ),
    );
  }

  Widget _settingNote(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.only(left: 12, top: 2, right: 12),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 12,
        height: 1.3,
        color: Theme.of(context).colorScheme.onPrimary.withValues(alpha: 0.5),
      ),
    ),
  );

  Widget _versionLabel(BuildContext context) {
    final build = appInfo.buildNumber;
    return Padding(
      padding: const EdgeInsets.only(left: 12, top: 20),
      child: Text(
        build.isEmpty
            ? 'Version ${appInfo.version}'
            : 'Version ${appInfo.version} ($build)',
        style: TextStyle(
          fontSize: 12,
          height: 1.2,
          color: Theme.of(context).colorScheme.onPrimary.withValues(alpha: 0.5),
        ),
      ),
    );
  }

  Widget _logOutButton(WidgetRef ref) => TextButton.icon(
    onPressed: ref.read(authProvider.notifier).logout,
    style: _buttonStyle,
    icon: const Icon(JPlayer.log_out),
    label: Text(
      ref.watch(accountsProvider).length > 1
          ? 'Log out of all servers'
          : 'Log out',
    ),
  );
}
