/// Limit for building a mobile or tablet UI
const int kTabletBreakpoint = 600;

/// True for the direct-download (Developer ID / notarized DMG) build, set via
/// `--dart-define=JELLYBOX_DIRECT_DOWNLOAD=true` in the macOS DMG workflow.
/// Those builds are not sandboxed; the App Store build leaves this false.
const bool kDirectDownloadBuild = bool.fromEnvironment(
  'JELLYBOX_DIRECT_DOWNLOAD',
);

const bool kSideloadBuild = bool.fromEnvironment('JELLYBOX_SIDELOAD');

const String discordApplicationId = '1547587702344388712';

/// Default continuity server. Override at build time with
/// `--dart-define=CONTINUITY_URL=http://192.168.1.10:8000`; users can also
/// change it at runtime from the connect form.
const String jellyboxCloudUrl = String.fromEnvironment(
  'CONTINUITY_URL',
  defaultValue: 'http://localhost:8000',
);
const String jellyfinRelayPluginUrl =
    'https://github.com/JellyBoxPlayer/jellyfin-relay';

const String jellyboxTunnelDomain = 'tunnel.jellybox.app';

const int connectionsPerHost = 6;
