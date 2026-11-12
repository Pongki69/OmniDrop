import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:file_picker/file_picker.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/peer.dart';
import '../services/browser_share_service.dart';
import '../services/local_discovery_service.dart';
import '../services/direct_radio_service.dart';
import '../services/trusted_transfer_protocol.dart';
import '../services/platform_storage_service.dart';

enum _SendTransport { sameWifi, wifiDirect }

class OmniDropApp extends StatefulWidget {
  const OmniDropApp({super.key});

  @override
  State<OmniDropApp> createState() => _OmniDropAppState();
}

class _OmniDropAppState extends State<OmniDropApp> {
  static const _accentChoices = <int, String>{
    0xff59e0b1: 'Mint',
    0xff58a6ff: 'Blue',
    0xffb69cff: 'Violet',
    0xffffb454: 'Amber',
    0xffff7e9d: 'Rose',
    0xff4dd0e1: 'Cyan',
  };

  ThemeMode _themeMode = ThemeMode.dark;
  int _accentSeed = 0xff59e0b1;
  bool _showStartup = true;

  @override
  void initState() {
    super.initState();
    unawaited(_loadAppearance());
    Future<void>.delayed(const Duration(milliseconds: 1550), () {
      if (mounted) setState(() => _showStartup = false);
    });
  }

  Future<void> _loadAppearance() async {
    final preferences = await SharedPreferences.getInstance();
    final mode = switch (preferences.getString('omnidrop_theme_mode')) {
      'light' => ThemeMode.light,
      'system' => ThemeMode.system,
      _ => ThemeMode.dark,
    };
    final savedAccent = preferences.getInt('omnidrop_accent_seed');
    if (!mounted) return;
    setState(() {
      _themeMode = mode;
      if (_accentChoices.containsKey(savedAccent)) _accentSeed = savedAccent!;
    });
  }

  Future<void> _setThemeMode(ThemeMode value) async {
    setState(() => _themeMode = value);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString('omnidrop_theme_mode', value.name);
  }

  Future<void> _setAccentSeed(int value) async {
    setState(() => _accentSeed = value);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setInt('omnidrop_accent_seed', value);
  }

  @override
  Widget build(BuildContext context) {
    ThemeData createTheme(Brightness brightness) => ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: Color(_accentSeed),
            brightness: brightness,
          ),
          useMaterial3: true,
          scaffoldBackgroundColor: brightness == Brightness.dark
              ? const Color(0xff101411)
              : const Color(0xfff6f8f7),
        );
    return MaterialApp(
      title: 'OmniDrop',
      debugShowCheckedModeBanner: false,
      theme: createTheme(Brightness.light),
      darkTheme: createTheme(Brightness.dark),
      themeMode: _themeMode,
      home: AnimatedSwitcher(
        duration: const Duration(milliseconds: 420),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (child, animation) => FadeTransition(
          opacity: animation,
          child: ScaleTransition(
            scale: Tween<double>(begin: .96, end: 1).animate(animation),
            child: child,
          ),
        ),
        child: _showStartup
            ? const _OmniDropSplash(key: ValueKey('startup'))
            : OmniDropHome(
                key: const ValueKey('home'),
                themeMode: _themeMode,
                accentSeed: _accentSeed,
                accentChoices: _accentChoices,
                onThemeModeChanged: _setThemeMode,
                onAccentChanged: _setAccentSeed,
              ),
      ),
    );
  }
}

class _OmniDropSplash extends StatelessWidget {
  const _OmniDropSplash({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: const Color(0xff0a1711),
        body: Center(
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: .86, end: 1),
            duration: const Duration(milliseconds: 900),
            curve: Curves.easeOutBack,
            builder: (context, scale, child) => Opacity(
              opacity: ((scale - .86) / .14).clamp(0, 1).toDouble(),
              child: Transform.scale(scale: scale, child: child),
            ),
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Image.asset(
                'assets/brand/omnidrop_logo.png',
                width: 340,
                height: 340,
                fit: BoxFit.contain,
                semanticLabel: 'OmniDrop',
              ),
            ),
          ),
        ),
      );
}

class OmniDropHome extends StatefulWidget {
  const OmniDropHome({
    super.key,
    required this.themeMode,
    required this.accentSeed,
    required this.accentChoices,
    required this.onThemeModeChanged,
    required this.onAccentChanged,
  });

  final ThemeMode themeMode;
  final int accentSeed;
  final Map<int, String> accentChoices;
  final Future<void> Function(ThemeMode value) onThemeModeChanged;
  final Future<void> Function(int value) onAccentChanged;

  @override
  State<OmniDropHome> createState() => _OmniDropHomeState();
}

class _OmniDropHomeState extends State<OmniDropHome> {
  int _tab = 0;
  _SendTransport _sendTransport = _SendTransport.sameWifi;
  bool _visible = true;
  bool _isDragging = false;
  bool _isDiscovering = false;
  bool _isSending = false;
  bool _cancelRequested = false;
  bool _pauseRequested = false;
  bool _isPaused = false;
  bool _sendFailed = false;
  double _currentFileProgress = 0;
  int _currentFileBytesSent = 0;
  int _currentFileTotalBytes = 0;
  double _currentBytesPerSecond = 0;
  String? _currentTransferFile;
  DateTime _lastProgressUpdate = DateTime.fromMillisecondsSinceEpoch(0);
  int _lastProgressBytes = 0;
  String? _activeOutgoingTransferId;
  String? _retryTransferId;
  String _downloadPath = 'Choose a destination';
  String? _discoveryError;
  String _profileName = 'My device';
  String? _profileImagePath;
  int _desktopTab = 0;
  Future<List<RadioCapability>>? _directCapabilities;
  String _networkBand = 'Checking…';
  bool _directSessionStarting = false;
  bool _directSessionActive = false;
  String _directSessionMessage = '';
  String? _directSessionBand;
  bool _windowsDirectSearchBusy = false;
  final List<DirectDevice> _windowsDirectDevices = [];
  final Set<String> _windowsDirectConnecting = {};
  String? _windowsDirectPeerId;
  int _transferView = 0;
  bool _recordsNewestFirst = true;
  bool _showHiddenFiles = false;
  bool _sortByDate = false;
  bool _sortDescending = false;
  String? _explorerClipboardPath;
  bool _explorerClipboardIsCut = false;
  List<Map<String, dynamic>> _transferRecords = [];
  final List<String> _queue = [];
  final List<int?> _queueSizes = [];
  final List<File> _sharedFiles = [];
  final Map<_SendTransport, _OutgoingQueueSnapshot> _queueSnapshots = {};
  final BrowserShareService _browserShare = BrowserShareService();
  final LocalDiscoveryService _discovery = LocalDiscoveryService();
  final List<Peer> _peers = [];
  String? _selectedPeerId;
  final Set<String> _clipboardTargetIds = <String>{};
  String? _chatPeerId;
  final Map<String, List<_ChatLine>> _chatHistory = {};
  final Map<String, int> _unreadChatCounts = {};
  final TextEditingController _chatController = TextEditingController();
  final TextEditingController _clipboardController = TextEditingController();
  bool _clipboardBusy = false;
  StreamSubscription<List<Peer>>? _peerSubscription;
  StreamSubscription<PairingRequest>? _pairingSubscription;
  StreamSubscription<IncomingTransferOffer>? _incomingTransferSubscription;
  StreamSubscription<IncomingTransferProgress>? _transferProgressSubscription;
  StreamSubscription<IncomingChatMessage>? _chatSubscription;
  final Map<String, _TransferProgressItem> _incomingTransferProgress = {};
  DateTime _lastNotificationUpdate = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    unawaited(_loadSendTransport());
    _peerSubscription = _discovery.peers.listen((peers) {
      if (mounted) {
        setState(() {
          final liveIds = peers
              .where((peer) => peer.trusted)
              .map((peer) => peer.id)
              .toSet();
          _chatHistory
              .removeWhere((deviceId, _) => !liveIds.contains(deviceId));
          _unreadChatCounts
              .removeWhere((deviceId, _) => !liveIds.contains(deviceId));
          if (_chatPeerId != null && !liveIds.contains(_chatPeerId)) {
            _chatPeerId = null;
          }
          _peers
            ..clear()
            ..addAll(peers);
        });
      }
    });
    _pairingSubscription = _discovery.pairingRequests
        .listen((request) => unawaited(_showIncomingPairing(request)));
    _incomingTransferSubscription = _discovery.incomingTransfers
        .listen((offer) => unawaited(_showIncomingTransfer(offer)));
    _transferProgressSubscription =
        _discovery.transferProgress.listen(_updateTransferProgress);
    _chatSubscription = _discovery.chatMessages.listen((message) async {
      if (!mounted || !_peers.any((peer) => peer.id == message.deviceId))
        return;
      if (message.clipboard) {
        await Clipboard.setData(ClipboardData(text: message.text));
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Copied shared text from ${message.deviceName}.')));
        return;
      }
      setState(() {
        _appendIncomingChatLine(_ChatLine(
            peerId: message.deviceId,
            text: message.text,
            sentByMe: false,
            time: DateTime.now()));
      });
    });
    unawaited(_loadProfile());
    unawaited(_loadTransferRecords());
    unawaited(_loadNetworkBand());
    unawaited(_startDiscovery());
  }

  Future<void> _loadSendTransport() async {
    final preferences = await SharedPreferences.getInstance();
    final value = preferences.getString('omnidrop_send_transport');
    if (!mounted) return;
    setState(() {
      _sendTransport = value == 'wifiDirect'
          ? _SendTransport.wifiDirect
          : _SendTransport.sameWifi;
    });
  }

  Future<void> _selectSendTransport(_SendTransport value) async {
    if (_isSending || value == _sendTransport) return;
    _queueSnapshots[_sendTransport] = _OutgoingQueueSnapshot(
      names: List.of(_queue), sizes: List.of(_queueSizes), files: List.of(_sharedFiles),
      selectedPeerId: _selectedPeerId, retryTransferId: _retryTransferId,
      sendFailed: _sendFailed, isPaused: _isPaused,
      currentTransferFile: _currentTransferFile,
      currentFileProgress: _currentFileProgress,
      currentFileBytesSent: _currentFileBytesSent,
      currentFileTotalBytes: _currentFileTotalBytes,
    );
    final snapshot = _queueSnapshots[value];
    setState(() {
      _sendTransport = value;
      _queue..clear()..addAll(snapshot?.names ?? const <String>[]);
      _queueSizes..clear()..addAll(snapshot?.sizes ?? const <int?>[]);
      _sharedFiles..clear()..addAll(snapshot?.files ?? const <File>[]);
      _selectedPeerId = snapshot?.selectedPeerId;
      _clipboardTargetIds.clear();
      _sendFailed = snapshot?.sendFailed ?? false;
      _isPaused = snapshot?.isPaused ?? false;
      _retryTransferId = snapshot?.retryTransferId;
      _currentTransferFile = snapshot?.currentTransferFile;
      _currentFileProgress = snapshot?.currentFileProgress ?? 0;
      _currentFileBytesSent = snapshot?.currentFileBytesSent ?? 0;
      _currentFileTotalBytes = snapshot?.currentFileTotalBytes ?? 0;
    });
    if (value == _SendTransport.sameWifi) {
      if (Platform.isAndroid && _directSessionActive) {
        try {
          await DirectRadioService().stopAndroidDirectGroup();
          _discovery.clearDirectPeers();
          if (mounted) {
            setState(() {
              _directSessionActive = false;
              _directSessionBand = null;
              _directSessionMessage =
                  'Wi-Fi Direct stopped because Same Wi-Fi was selected.';
            });
          }
        } catch (error) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Could not stop Wi-Fi Direct: $error')));
          }
        }
      }
      if (Platform.isWindows && _windowsDirectPeerId != null) {
        await _disconnectWindowsDirectDevice();
      }
    }
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString('omnidrop_send_transport', value.name);
  }

  bool get _usesDirectTransport => _sendTransport == _SendTransport.wifiDirect;

  List<Peer> get _peersForSendTransport => _peers
      .map((peer) => _discovery.peerForTransport(
            peer.id,
            direct: _usesDirectTransport,
          ))
      .whereType<Peer>()
      .toList(growable: false);

  Future<void> _loadNetworkBand() async {
    final band = await DirectRadioService().currentNetworkBand();
    if (mounted) setState(() => _networkBand = band);
  }

  @override
  void dispose() {
    unawaited(_peerSubscription?.cancel() ?? Future<void>.value());
    unawaited(_pairingSubscription?.cancel() ?? Future<void>.value());
    unawaited(_incomingTransferSubscription?.cancel() ?? Future<void>.value());
    unawaited(_transferProgressSubscription?.cancel() ?? Future<void>.value());
    unawaited(_chatSubscription?.cancel() ?? Future<void>.value());
    _chatController.dispose();
    _clipboardController.dispose();
    unawaited(_discovery.dispose());
    unawaited(_browserShare.stop());
    super.dispose();
  }

  Future<void> _startDiscovery() async {
    if (!_visible || _isDiscovering) return;
    setState(() {
      _isDiscovering = true;
      _discoveryError = null;
    });
    try {
      if (Platform.isAndroid) {
        try {
          final permissionsGranted =
              await const MethodChannel('com.omnidrop/direct_radio')
                  .invokeMethod<bool>('requestStartupPermissions');
          if (permissionsGranted != true) {
            if (mounted)
              setState(() => _discoveryError =
                  'Nearby-device permission is needed to discover phones and PCs. Allow it in Android settings, then refresh.');
            return;
          }
        } on PlatformException {
          if (mounted)
            setState(() => _discoveryError =
                'Nearby-device permission was not granted. Allow it in Android settings, then refresh.');
          return;
        }
      }
      await _discovery.start();
    } catch (_) {
      if (mounted) {
        setState(() => _discoveryError =
            'Device discovery is unavailable on this network.');
      }
    } finally {
      if (mounted) setState(() => _isDiscovering = false);
    }
  }

  Future<void> _loadProfile() async {
    final preferences = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _profileName = preferences.getString('omnidrop_profile_name') ??
          Platform.localHostname;
      _profileImagePath = preferences.getString('omnidrop_profile_image');
      _downloadPath = preferences.getString('omnidrop_download_path') ??
          'Downloads/OmniDrop';
    });
    if (preferences.getString('omnidrop_download_path') == null) {
      final defaultFolder =
          await PlatformStorageService().defaultDownloadFolder();
      if (!mounted) return;
      await preferences.setString('omnidrop_download_path', defaultFolder.path);
      setState(() => _downloadPath = defaultFolder.path);
    }
  }

  Future<void> _setVisibility(bool visible) async {
    setState(() => _visible = visible);
    if (Platform.isAndroid) {
      try {
        await const MethodChannel('com.omnidrop/direct_radio')
            .invokeMethod<void>('setVisibility', {'visible': visible});
      } on PlatformException {
        // Discovery visibility still updates in the running app if the native
        // background-service preference cannot be saved.
      }
    }
    if (visible) {
      await _startDiscovery();
    } else {
      await _discovery.stop();
      if (Platform.isAndroid && _directSessionActive) {
        try {
          await DirectRadioService().stopAndroidDirectGroup();
        } catch (_) {}
        _discovery.clearDirectPeers();
        if (mounted)
          setState(() {
            _directSessionActive = false;
            _directSessionBand = null;
            _directSessionMessage =
                'Direct session stopped because device visibility was turned off.';
          });
      }
      if (Platform.isWindows && _windowsDirectPeerId != null) {
        await _disconnectWindowsDirectDevice();
      }
    }
  }

  void _showNearbyDevices() => setState(() {
        _desktopTab = 0;
        _tab = 0;
      });

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        final desktop = box.maxWidth >= 1000;
        return Scaffold(
          body: SafeArea(child: desktop ? _desktop() : _mobile()),
          bottomNavigationBar: desktop
              ? null
              : NavigationBar(
                  selectedIndex: _tab,
                  onDestinationSelected: (i) => setState(() => _tab = i),
                  destinations: [
                      const NavigationDestination(
                          icon: Icon(Icons.radar), label: 'Radar'),
                      const NavigationDestination(
                          icon: Icon(Icons.swap_vert), label: 'Transfers'),
                      const NavigationDestination(
                          icon: Icon(Icons.wifi_tethering), label: 'Direct'),
                      const NavigationDestination(
                          icon: Icon(Icons.content_paste), label: 'Clipboard'),
                      NavigationDestination(
                          icon: Badge(
                            isLabelVisible: _totalUnreadChats > 0,
                            label: Text(_totalUnreadChats > 99
                                ? '99+'
                                : '$_totalUnreadChats'),
                            child: const Icon(Icons.chat_bubble_outline),
                          ),
                          label: 'Chat'),
                      const NavigationDestination(
                          icon: Icon(Icons.settings_outlined),
                          label: 'Settings'),
                    ]),
          floatingActionButton: desktop || _tab == 4
              ? null
              : FloatingActionButton.extended(
                  onPressed: _pickFiles,
                  icon: const Icon(Icons.add),
                  label: const Text('Send files')),
        );
      });

  Widget _desktop() => Row(children: [
        SizedBox(width: 260, child: _sidebar()),
        const VerticalDivider(width: 1),
        Expanded(flex: 5, child: _desktopPage()),
        if (_desktopTab != 1) ...[
          const VerticalDivider(width: 1),
          SizedBox(width: 360, child: _transfers()),
        ],
      ]);

  Widget _desktopPage() {
    final page = switch (_desktopTab) {
      0 => _radar(),
      1 => _transfers(),
      2 => _direct(),
      3 => _clipboard(),
      4 => _chat(),
      _ => _settings(),
    };
    return _pageTransition(_desktopTab, page);
  }

  Widget _mobile() => _pageTransition(
        _tab,
        switch (_tab) {
          0 => _radar(mobile: true),
          1 => _transfers(),
          2 => _direct(),
          3 => _clipboard(),
          4 => _chat(mobile: true),
          _ => _settings()
        },
      );

  Widget _pageTransition(int page, Widget content) => AnimatedSwitcher(
        duration: const Duration(milliseconds: 240),
        reverseDuration: const Duration(milliseconds: 180),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (child, animation) => FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, .018),
              end: Offset.zero,
            ).animate(animation),
            child: child,
          ),
        ),
        child: KeyedSubtree(key: ValueKey(page), child: content),
      );

  Widget _sidebar() => Padding(
      padding: const EdgeInsets.all(24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const _Brand(),
        const SizedBox(height: 36),
        CircleAvatar(
            radius: 26,
            backgroundImage: _profileImagePath == null
                ? null
                : FileImage(File(_profileImagePath!)),
            child: _profileImagePath == null ? const Icon(Icons.person) : null),
        const SizedBox(height: 10),
        Text(_profileName, style: const TextStyle(fontWeight: FontWeight.bold)),
        const Text('This device · Online',
            style: TextStyle(color: Colors.greenAccent)),
        const SizedBox(height: 24),
        ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.folder_outlined),
            title: const Text('Download folder'),
            onTap: _chooseFolder),
        Text(_downloadPath,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 22),
        ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.radar),
            title: const Text('Nearby devices'),
            selected: _desktopTab == 0,
            onTap: _showNearbyDevices),
        ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.swap_vert),
            title: const Text('Transfers'),
            selected: _desktopTab == 1,
            onTap: () => setState(() => _desktopTab = 1)),
        ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.wifi_tethering),
            title: const Text('Direct connections'),
            selected: _desktopTab == 2,
            onTap: () => setState(() => _desktopTab = 2)),
        ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.content_paste),
            title: const Text('Clipboard'),
            selected: _desktopTab == 3,
            onTap: () => setState(() => _desktopTab = 3)),
        ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.chat_bubble_outline),
            title: const Text('Chats'),
            selected: _desktopTab == 4,
            trailing: _totalUnreadChats == 0
                ? null
                : Badge(
                    label: Text(
                        _totalUnreadChats > 99 ? '99+' : '$_totalUnreadChats')),
            onTap: () => setState(() {
                  _desktopTab = 4;
                })),
        ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.settings_outlined),
            title: const Text('Settings'),
            selected: _desktopTab == 5,
            onTap: () => setState(() => _desktopTab = 5)),
        const Text('RECEIVING VISIBILITY',
            style: TextStyle(fontSize: 11, letterSpacing: 1.1)),
        SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Visible to nearby'),
            value: _visible,
            onChanged: _setVisibility),
        const Spacer(),
        _NetworkBadge(
            label: !_visible
                ? 'Hidden from nearby devices'
                : _discoveryError ??
                    (_isDiscovering
                        ? 'Searching local network'
                        : 'Listening for OmniDrop')),
        const SizedBox(height: 12),
      ]));

  Widget _radar({bool mobile = false}) {
    final colorScheme = Theme.of(context).colorScheme;
    final visiblePeers = _peersForSendTransport;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _Brand(),
          const SizedBox(height: 20),
          Row(children: [
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text('Nearby devices',
                      style: Theme.of(context)
                          .textTheme
                          .headlineMedium
                          ?.copyWith(fontWeight: FontWeight.w700)),
                  Text(_discoveryError ??
                      (_isDiscovering
                          ? 'Searching this local network…'
                          : visiblePeers.isEmpty
                              ? _usesDirectTransport
                                  ? 'No Wi-Fi Direct devices connected. Open Direct to start or connect a session.'
                                  : 'No OmniDrop devices found on this Wi-Fi network yet.'
                              : 'Only devices running OmniDrop are shown.'))
                ])),
            OutlinedButton.icon(
                onPressed: _inviteAndroid,
                icon: const Icon(Icons.android),
                label: const Text('Invite Android'))
          ]),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: SegmentedButton<_SendTransport>(
              segments: const [
                ButtonSegment(
                  value: _SendTransport.sameWifi,
                  icon: Icon(Icons.wifi),
                  label: Text('Same Wi-Fi'),
                ),
                ButtonSegment(
                  value: _SendTransport.wifiDirect,
                  icon: Icon(Icons.wifi_tethering),
                  label: Text('Wi-Fi Direct'),
                ),
              ],
              selected: {_sendTransport},
              onSelectionChanged: _isSending
                  ? null
                  : (selection) =>
                      unawaited(_selectSendTransport(selection.first)),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _usesDirectTransport
                ? 'Files will use Wi-Fi Direct, without the shared router.'
                : 'Files will use the same local Wi-Fi network.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints:
                    const BoxConstraints(maxWidth: 760, maxHeight: 760),
                child: AspectRatio(
                  aspectRatio: 1,
                  child: LayoutBuilder(
                    builder: (context, box) {
                      final diameter = box.maxWidth;
                      final bubbleWidth = math.min(126.0, diameter * 0.36);
                      final radius = math.max(
                          0.0,
                          math.min((diameter - bubbleWidth) / 2 - 8,
                              diameter / 2 - 52));
                      return Stack(
                        alignment: Alignment.center,
                        children: [
                          _RadarPulse(
                            diameter: diameter,
                            color: colorScheme.primary,
                          ),
                          Container(
                            width: 92,
                            height: 92,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: colorScheme.surfaceContainerHighest,
                              border: Border.all(
                                  color: colorScheme.primary, width: 2),
                            ),
                            child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  CircleAvatar(
                                      radius: 19,
                                      backgroundColor:
                                          colorScheme.primaryContainer,
                                      child: Icon(Icons.person,
                                          color:
                                              colorScheme.onPrimaryContainer)),
                                  SizedBox(height: 3),
                                  Text('You', style: TextStyle(fontSize: 11))
                                ]),
                          ),
                          for (var i = 0; i < visiblePeers.length; i++)
                            Positioned(
                              top: diameter / 2 +
                                  radius *
                                      math.sin(2 *
                                          math.pi *
                                          i /
                                          math.max(1, visiblePeers.length)) -
                                  48,
                              left: diameter / 2 +
                                  radius *
                                      math.cos(2 *
                                          math.pi *
                                          i /
                                          math.max(1, visiblePeers.length)) -
                                  bubbleWidth / 2,
                              child: _PeerBubble(
                                  peer: visiblePeers[i],
                                  width: bubbleWidth,
                                  selected:
                                      _selectedPeerId == visiblePeers[i].id,
                                  onTap: () => _sendTo(visiblePeers[i])),
                            ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
          if (_selectedPeerId != null)
            Padding(
              padding: EdgeInsets.only(bottom: mobile ? 104 : 0),
              child: _selectedRecipientCard(),
            ),
          if (!mobile) _dropTarget(),
        ],
      ),
    );
  }

  Widget _selectedRecipientCard() {
    final peer = _peersForSendTransport
        .where((item) => item.id == _selectedPeerId)
        .firstOrNull;
    if (peer == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Card(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading:
                Icon(Icons.send, color: Theme.of(context).colorScheme.primary),
            title: Text('Sending to ${peer.name}',
                maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(_sharedFiles.isEmpty
                ? 'Choose files, then send to this device.'
                : _sendFailed
                    ? 'Transfer interrupted. Tap Retry to send again.'
                    : _isSending
                        ? (_currentTransferFile == null
                            ? 'Waiting for ${peer.name} to accept…'
                            : 'Sending $_currentTransferFile · ${_formatBytes(_currentFileBytesSent)} of ${_formatBytes(_currentFileTotalBytes)} · ${_formatSpeed(_currentBytesPerSecond)}')
                        : '${_sharedFiles.length} file${_sharedFiles.length == 1 ? '' : 's'} ready to send.'),
            trailing: _isSending
                ? OutlinedButton.icon(
                    onPressed: _cancelActiveTransfer,
                    icon: const Icon(Icons.close),
                    label: const Text('Cancel'))
                : _sharedFiles.isEmpty
                    ? const Icon(Icons.check_circle_outline)
                    : FilledButton.icon(
                        onPressed: () => _sendSelected(peer),
                        icon: const Icon(Icons.send),
                        label: Text(_sendFailed ? 'Retry' : 'Send')),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                Icon(
                  peer.isDirect ? Icons.wifi_tethering : Icons.wifi,
                  size: 18,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  peer.isDirect
                      ? 'Transfer route · Wi-Fi Direct'
                      : 'Transfer route · Same Wi-Fi',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          if (_isSending)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    LinearProgressIndicator(
                        value: _currentTransferFile == null
                            ? null
                            : _currentFileProgress),
                    const SizedBox(height: 6),
                    Text(_transferEstimateLabel(),
                        style: Theme.of(context).textTheme.bodySmall),
                  ]),
            ),
          if (peer.trusted)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () => _openChat(peer),
                icon: const Icon(Icons.chat_bubble_outline),
                label: const Text('Chat'),
              ),
            ),
        ]),
      ),
    );
  }

  Widget _dropTarget() => DropTarget(
      onDragEntered: (_) => setState(() => _isDragging = true),
      onDragExited: (_) => setState(() => _isDragging = false),
      onDragDone: _onFilesDropped,
      child: InkWell(
          onTap: _pickFiles,
          borderRadius: BorderRadius.circular(20),
          child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 18),
              decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  color: _isDragging
                      ? Theme.of(context).colorScheme.secondaryContainer
                      : Theme.of(context).colorScheme.surfaceContainerHigh,
                  border: Border.all(
                      color: _isDragging
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.outlineVariant,
                      width: _isDragging ? 2 : 1)),
              child: Row(children: [
                Icon(_isDragging ? Icons.file_download_done : Icons.upload_file,
                    color: Theme.of(context).colorScheme.primary, size: 32),
                const SizedBox(width: 14),
                Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      Text(
                          _isDragging
                              ? 'Release to add files'
                              : 'Drop files here or browse',
                          style: const TextStyle(fontWeight: FontWeight.bold)),
                      Text(
                          _isDragging
                              ? 'Files will be added to your transfer queue'
                              : 'Drag files from Explorer, or choose from your device',
                          style: TextStyle(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant))
                    ])),
                IconButton(
                    onPressed: _pickFiles,
                    tooltip: 'Choose files',
                    icon: const Icon(Icons.add_circle_outline))
              ]))));

  void _updateTransferProgress(IncomingTransferProgress progress) {
    if (!mounted) return;
    final key = '${progress.transferId}:${progress.fileName}';
    final now = DateTime.now();
    final item = _incomingTransferProgress.putIfAbsent(
        key,
        () => _TransferProgressItem(
            transferId: progress.transferId,
            deviceId: progress.deviceId,
            deviceName: progress.deviceName,
            fileName: progress.fileName,
            totalBytes: progress.totalBytes));
    item.isDirect = progress.isDirect;
    final elapsed = now.difference(item.lastUpdated).inMicroseconds / 1000000;
    final delta = progress.bytesReceived - item.bytesReceived;
    item.bytesReceived = progress.bytesReceived;
    item.bytesPerSecond = elapsed <= 0 || delta < 0 ? 0 : delta / elapsed;
    item.lastUpdated = now;
    final newlyCompleted = progress.complete && !item.complete;
    item.complete = progress.complete;
    item.failed = progress.failed;
    _publishTransferNotification(
      active: !progress.complete && !progress.failed,
      title: progress.failed
          ? 'Transfer interrupted'
          : progress.complete
              ? 'Transfer complete'
              : 'Receiving ${progress.fileName}',
      text: progress.complete || progress.failed
          ? progress.deviceName
          : '${_formatBytes(progress.bytesReceived)} of ${_formatBytes(progress.totalBytes)} · ${_estimateTime(progress.totalBytes - progress.bytesReceived, item.bytesPerSecond)}',
      progress: progress.totalBytes == 0
          ? (progress.complete ? 100 : 0)
          : (100 * progress.bytesReceived / progress.totalBytes).round(),
    );
    if (newlyCompleted) {
      unawaited(_storeTransferRecord({
        'id': '${now.microsecondsSinceEpoch}-${math.Random().nextInt(1 << 32)}',
        'direction': 'Received',
        'sender': progress.deviceName,
        'receiver': _profileName,
        'transport': 'Connected device',
        'name': progress.fileName,
        'size': progress.totalBytes,
        'location': _downloadPath,
        'duration': _formatDuration(now.difference(item.startedAt)),
        'date': now.toIso8601String(),
      }));
    }
    if (progress.complete ||
        now.difference(item.lastUiUpdate) >=
            const Duration(milliseconds: 500)) {
      item.lastUiUpdate = now;
      setState(() {});
    }
  }

  void _publishTransferNotification({
    required bool active,
    required String title,
    required String text,
    required int progress,
    bool force = false,
  }) {
    if (!Platform.isAndroid) return;
    final now = DateTime.now();
    if (active && !force &&
        now.difference(_lastNotificationUpdate) < const Duration(seconds: 1)) {
      return;
    }
    _lastNotificationUpdate = now;
    unawaited(const MethodChannel('com.omnidrop/direct_radio')
        .invokeMethod<void>('updateTransferNotification', {
      'active': active,
      'title': title,
      'text': text,
      'progress': progress.clamp(0, 100).toInt(),
    }).catchError((_) {}));
  }

  String _estimateTime(int remainingBytes, double bytesPerSecond) {
    if (remainingBytes <= 0) return 'Finishing…';
    if (bytesPerSecond <= 0) return 'Estimating time…';
    final duration = Duration(seconds: (remainingBytes / bytesPerSecond).ceil());
    final finish = DateTime.now().add(duration);
    return 'about ${_formatDuration(duration)} left · ${_formatTime(finish)} finish';
  }

  String _estimateOutgoingQueue() {
    if (!_isSending) return '';
    if (_currentBytesPerSecond <= 0) return 'Estimating remaining transfer time…';
    var remainingBytes = 0;
    final currentIndex = _queue.indexOf(_currentTransferFile ?? '');
    for (var index = 0; index < _queueSizes.length; index++) {
      if (index == currentIndex) {
        remainingBytes += math.max(0, _currentFileTotalBytes - _currentFileBytesSent);
      } else if (index > currentIndex || currentIndex < 0) {
        remainingBytes += _queueSizes[index] ?? 0;
      }
    }
    return _estimateTime(remainingBytes, _currentBytesPerSecond);
  }

  Widget _transfers() => switch (_transferView) {
        1 => _records(),
        2 => _fileExplorer(),
        _ => _queueTransfers(),
      };

  Widget _queueTransfers() {
    final compactLayout = MediaQuery.sizeOf(context).width < 760;
    final incomingItems = _incomingTransferProgress.values
        .where((item) => item.isDirect == _usesDirectTransport)
        .toList(growable: false);
    return Padding(
      padding: EdgeInsets.all(compactLayout ? 16 : 24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const _Brand(),
        SizedBox(height: compactLayout ? 16 : 28),
        Row(children: [
          Expanded(
              child: Text('Transfer queue',
                  style: Theme.of(context)
                      .textTheme
                      .headlineSmall
                      ?.copyWith(fontWeight: FontWeight.bold))),
          IconButton(
              tooltip: 'Transfer records',
              onPressed: () => setState(() => _transferView = 1),
              icon: const Icon(Icons.history)),
          IconButton(
              tooltip: 'File explorer',
              onPressed: () => setState(() => _transferView = 2),
              icon: const Icon(Icons.folder_open)),
          if (_queue.isNotEmpty && !_isSending)
            TextButton.icon(
                onPressed: _clearOutgoingQueue,
                icon: const Icon(Icons.delete_outline),
                label: const Text('Clear')),
        ]),
        const SizedBox(height: 16),
        SegmentedButton<_SendTransport>(
          segments: const [
            ButtonSegment(value: _SendTransport.sameWifi, label: Text('Same Wi-Fi'), icon: Icon(Icons.wifi)),
            ButtonSegment(value: _SendTransport.wifiDirect, label: Text('Wi-Fi Direct'), icon: Icon(Icons.radar)),
          ],
          selected: {_sendTransport},
          onSelectionChanged: (selection) => unawaited(_selectSendTransport(selection.first)),
        ),
        const SizedBox(height: 12),
        if (_isSending)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text('Queue estimate · ${_estimateOutgoingQueue()}',
                maxLines: 2, overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall),
          ),
        if (_queue.isEmpty && incomingItems.isEmpty)
          const Expanded(
              child: Center(
                  child: Text('Your transfers will appear here.',
                      textAlign: TextAlign.center)))
        else
          Expanded(
              child: ListView(children: [
            for (var index = 0; index < _queue.length; index++)
              Builder(builder: (context) {
                final name = _queue[index];
                final active =
                    (_isSending || _sendFailed || _isPaused) && name == _currentTransferFile;
                final retryPeer = _peers
                    .where((item) => item.id == _selectedPeerId)
                    .firstOrNull;
                return Card(
                    child: ListTile(
                        onTap: (_sendFailed || _isPaused) && retryPeer != null
                            ? () => _sendSelected(retryPeer)
                            : null,
                        leading: Icon(active
                            ? _sendFailed
                                ? Icons.error_outline
                                : Icons.sync
                            : Icons.insert_drive_file),
                        title: Text(name,
                            maxLines: 2, overflow: TextOverflow.ellipsis),
                        subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(active
                                  ? _sendFailed || _isPaused
                                      ? '${_isPaused ? 'Paused' : 'Interrupted'} · ${_formatBytes(_currentFileBytesSent)} of ${_formatBytes(_currentFileTotalBytes)} · Tap to resume'
                                      : 'Sending · ${(_currentFileProgress * 100).round()}% · ${_formatBytes(_currentFileTotalBytes)} · ${_formatSpeed(_currentBytesPerSecond)} · ${_estimateTime(_currentFileTotalBytes - _currentFileBytesSent, _currentBytesPerSecond)}'
                                  : _isSending
                                      ? 'Queued · ${_formatBytes(_queueSizes[index] ?? 0)}'
                                      : 'Ready · ${_formatBytes(_queueSizes[index] ?? 0)}'),
                              const SizedBox(height: 5),
                              LinearProgressIndicator(
                                  value: active ? _currentFileProgress : 0,
                                  color:
                                      _sendFailed ? Colors.orangeAccent : null),
                            ]),
                        trailing: PopupMenuButton<String>(
                          tooltip: 'Transfer actions',
                          onSelected: (action) {
                            if (action == 'pause') _pauseActiveTransfer();
                            if (action == 'cancel') _cancelActiveTransfer();
                            if (action == 'resume' && retryPeer != null) {
                              unawaited(_sendSelected(retryPeer));
                            }
                            if (action == 'remove') _removeOutgoingQueueItem(index);
                          },
                          itemBuilder: (context) => [
                            if (_isSending && active)
                              const PopupMenuItem(value: 'pause', child: Text('Pause')),
                            if (_isSending && active)
                              const PopupMenuItem(value: 'cancel', child: Text('Cancel transfer')),
                            if (!_isSending && active && (_isPaused || _sendFailed))
                              PopupMenuItem(value: 'resume', child: Text(_isPaused ? 'Resume' : 'Retry')),
                            if (!_isSending)
                              const PopupMenuItem(value: 'remove', child: Text('Remove from queue')),
                          ],
                        )));
              }),
            for (final item in incomingItems.reversed)
              Card(
                child: ListTile(
                  leading: Icon(item.complete
                      ? Icons.download_done
                      : item.failed
                          ? Icons.error_outline
                          : Icons.downloading),
                  title: Text(item.fileName,
                      maxLines: 2, overflow: TextOverflow.ellipsis),
                  subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(item.complete
                            ? 'Received · ${_formatBytes(item.totalBytes)}'
                            : item.failed
                                ? 'Interrupted · ${_formatBytes(item.bytesReceived)} of ${_formatBytes(item.totalBytes)} · Resume from sender'
                                : 'Receiving from ${item.deviceName} · ${_formatBytes(item.bytesReceived)} of ${_formatBytes(item.totalBytes)} · ${_formatSpeed(item.bytesPerSecond)} · ${_estimateTime(item.totalBytes - item.bytesReceived, item.bytesPerSecond)}'),
                        const SizedBox(height: 5),
                        LinearProgressIndicator(
                            value: item.totalBytes == 0
                                ? 1
                                : item.bytesReceived / item.totalBytes,
                            color: item.failed ? Colors.orangeAccent : null),
                      ]),
                  trailing: PopupMenuButton<String>(
                    tooltip: 'Transfer actions',
                    onSelected: (action) {
                      if (action == 'cancel') _discovery.cancelTransfer(item.transferId);
                      if (action == 'remove') {
                        setState(() => _incomingTransferProgress.removeWhere((_, value) => identical(value, item)));
                      }
                    },
                    itemBuilder: (context) => [
                      if (!item.complete && !item.failed)
                        const PopupMenuItem(value: 'cancel', child: Text('Cancel transfer')),
                      if (item.complete || item.failed)
                        const PopupMenuItem(value: 'remove', child: Text('Remove from queue')),
                    ],
                  ),
                ),
              ),
          ])),
        _NetworkBadge(
            label: !_visible
                ? 'Hidden from nearby devices'
                : _discoveryError ??
                    (_isDiscovering
                        ? 'Searching local network'
                        : 'Listening for OmniDrop'))
      ]));
  }

  void _removeOutgoingQueueItem(int index) {
    if (_isSending || index < 0 || index >= _queue.length) return;
    setState(() {
      _queue.removeAt(index);
      _queueSizes.removeAt(index);
      _sharedFiles.removeAt(index);
      if (_queue.isEmpty) {
        _selectedPeerId = null;
        _retryTransferId = null;
        _isPaused = false;
        _sendFailed = false;
      }
    });
  }

  Widget _records() {
    final sortedRecords = [..._transferRecords]..sort((a, b) =>
        DateTime.parse(a['date'] as String)
            .compareTo(DateTime.parse(b['date'] as String)));
    final records =
        _recordsNewestFirst ? sortedRecords.reversed.toList() : sortedRecords;
    final groups = <String, List<Map<String, dynamic>>>{};
    for (final record in records) {
      final date = DateTime.parse(record['date'] as String);
      final key =
          '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
      groups.putIfAbsent(key, () => []).add(record);
    }
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const _Brand(),
        const SizedBox(height: 24),
        Row(children: [
          IconButton(
              onPressed: () => setState(() => _transferView = 0),
              icon: const Icon(Icons.arrow_back)),
          Expanded(
              child: Text('Transfer records',
                  style: Theme.of(context).textTheme.headlineSmall)),
          TextButton.icon(
              onPressed: () =>
                  setState(() => _recordsNewestFirst = !_recordsNewestFirst),
              icon: const Icon(Icons.sort),
              label: Text(_recordsNewestFirst ? 'Newest' : 'Oldest')),
          if (records.isNotEmpty)
            IconButton(
                tooltip: 'Clear records',
                onPressed: _clearTransferRecords,
                icon: const Icon(Icons.delete_outline)),
        ]),
        Expanded(
            child: records.isEmpty
                ? const Center(
                    child: Text('Completed transfers will be recorded here.'))
                : ListView(children: [
                    for (final entry in groups.entries) ...[
                      Padding(
                          padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
                          child: Text(
                              _dateHeading(DateTime.parse(
                                  entry.value.first['date'] as String)),
                              style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color:
                                      Theme.of(context).colorScheme.primary))),
                      for (final record in entry.value)
                        Card(
                            child: ListTile(
                          leading: Icon(record['direction'] == 'Sent'
                              ? Icons.upload_rounded
                              : Icons.download_done),
                          title: Text(record['name'] as String,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(
                              '${record['direction']} · ${record['sender'] ?? (record['direction'] == 'Sent' ? _profileName : 'Paired device')} → ${record['receiver'] ?? (record['direction'] == 'Sent' ? 'Paired device' : _profileName)} · ${record['transport'] ?? 'Local network'}\n${_formatBytes(record['size'] as int)} · ${record['duration']} · ${record['location']}',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis),
                          trailing: Column(mainAxisSize: MainAxisSize.min, children: [
                            Text(_formatTime(DateTime.parse(record['date'] as String))),
                            IconButton(
                              tooltip: 'Delete transfer record',
                              onPressed: () => _deleteTransferRecord(record),
                              icon: const Icon(Icons.delete_outline, size: 18)),
                          ]),
                        )),
                    ],
                  ])),
      ]),
    );
  }

  String _dateHeading(DateTime date) =>
      '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

  Widget _fileExplorer() => _FileExplorer(
        rootPath:
            _downloadPath == 'Choose a destination' ? null : _downloadPath,
        showHidden: _showHiddenFiles,
        sortByDate: _sortByDate,
        descending: _sortDescending,
        clipboardPath: _explorerClipboardPath,
        clipboardIsCut: _explorerClipboardIsCut,
        onBack: () => setState(() => _transferView = 0),
        onHiddenChanged: (value) => setState(() => _showHiddenFiles = value),
        onSortChanged: (byDate, descending) => setState(() {
          _sortByDate = byDate;
          _sortDescending = descending;
        }),
        onCopy: (path, cut) => setState(() {
          _explorerClipboardPath = path;
          _explorerClipboardIsCut = cut;
        }),
        onPaste: _pasteExplorerItem,
      );

  Future<void> _pasteExplorerItem(Directory directory) async {
    final sourcePath = _explorerClipboardPath;
    if (sourcePath == null) return;
    final source =
        FileSystemEntity.typeSync(sourcePath) == FileSystemEntityType.directory
            ? Directory(sourcePath)
            : File(sourcePath);
    final destination =
        '${directory.path}${Platform.pathSeparator}${source.uri.pathSegments.where((part) => part.isNotEmpty).last}';
    try {
      if (source is File) {
        if (_explorerClipboardIsCut) {
          await source.rename(destination);
        } else {
          await source.copy(destination);
        }
      } else if (source is Directory && !_explorerClipboardIsCut) {
        await _copyDirectory(source, Directory(destination));
      } else {
        throw FileSystemException(
            'Moving a folder is not supported from this view.');
      }
      if (_explorerClipboardIsCut)
        setState(() {
          _explorerClipboardPath = null;
          _explorerClipboardIsCut = false;
        });
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('File operation completed.')));
    } catch (error) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not paste item: $error')));
    }
  }

  Future<void> _copyDirectory(Directory source, Directory destination) async {
    await destination.create(recursive: true);
    await for (final entity in source.list(followLinks: false)) {
      final target =
          '${destination.path}${Platform.pathSeparator}${entity.uri.pathSegments.where((part) => part.isNotEmpty).last}';
      if (entity is Directory)
        await _copyDirectory(entity, Directory(target));
      else if (entity is File) await entity.copy(target);
    }
  }

  Future<void> _loadTransferRecords() async {
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString('omnidrop_transfer_records');
    if (raw == null) return;
    try {
      final decoded = (jsonDecode(raw) as List)
          .whereType<Map>()
          .map((entry) => Map<String, dynamic>.from(entry))
          .toList();
      for (final record in decoded) {
        record.putIfAbsent('id', () => '${DateTime.now().microsecondsSinceEpoch}-${math.Random().nextInt(1 << 32)}');
      }
      if (mounted) setState(() => _transferRecords = decoded);
    } catch (_) {
      await preferences.remove('omnidrop_transfer_records');
    }
  }

  Future<void> _storeTransferRecord(Map<String, dynamic> record) async {
    record.putIfAbsent('id', () => '${DateTime.now().microsecondsSinceEpoch}-${math.Random().nextInt(1 << 32)}');
    _transferRecords.insert(0, record);
    if (mounted) setState(() {});
    if (_transferRecords.length > 500)
      _transferRecords.removeRange(500, _transferRecords.length);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
        'omnidrop_transfer_records', jsonEncode(_transferRecords));
  }

  Future<void> _deleteTransferRecord(Map<String, dynamic> record) async {
    final id = record['id'];
    setState(() => _transferRecords.removeWhere((item) => item['id'] == id));
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString('omnidrop_transfer_records', jsonEncode(_transferRecords));
  }

  Future<void> _clearTransferRecords() async {
    setState(() => _transferRecords.clear());
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove('omnidrop_transfer_records');
  }

  Widget _chat({bool mobile = false}) {
    final peer = _peers.where((item) => item.id == _chatPeerId).firstOrNull;
    if (peer == null) {
      final trustedPeers = _peers.where((item) => item.trusted).toList();
      return ListView(padding: const EdgeInsets.all(24), children: [
        const _Brand(),
        const SizedBox(height: 24),
        Text('Chats', style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 8),
        const Text(
            'Private chats are available while paired devices are connected.'),
        const SizedBox(height: 16),
        if (trustedPeers.isEmpty)
          const Card(child: ListTile(title: Text('No paired devices online')))
        else
          for (final trustedPeer in trustedPeers)
            Card(
              child: ListTile(
                leading: const Icon(Icons.chat_bubble_outline),
                title: Text(trustedPeer.name),
                subtitle: const Text('Connected · End-to-end encrypted'),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  if ((_unreadChatCounts[trustedPeer.id] ?? 0) > 0)
                    Badge(label: Text('${_unreadChatCounts[trustedPeer.id]}')),
                  const SizedBox(width: 8),
                  const Icon(Icons.chevron_right),
                ]),
                onTap: () => _openChat(trustedPeer),
              ),
            ),
      ]);
    }
    final messages = _chatHistory[peer.id] ?? const <_ChatLine>[];
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const _Brand(),
        const SizedBox(height: 16),
        Row(children: [
          IconButton(
              tooltip: 'All chats',
              onPressed: () => setState(() => _chatPeerId = null),
              icon: const Icon(Icons.arrow_back)),
          const CircleAvatar(child: Icon(Icons.person_outline)),
          const SizedBox(width: 12),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(peer.name,
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                Text('Paired · Connected',
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.primary)),
              ])),
        ]),
        const Divider(),
        Expanded(
          child: messages.isEmpty
              ? const Center(
                  child:
                      Text('Messages disappear when this device disconnects.'))
              : ListView.builder(
                  itemCount: messages.length,
                  itemBuilder: (context, index) {
                    final message = messages[index];
                    return Align(
                      alignment: message.sentByMe
                          ? Alignment.centerRight
                          : Alignment.centerLeft,
                      child: Container(
                        constraints: const BoxConstraints(maxWidth: 420),
                        margin: const EdgeInsets.symmetric(vertical: 5),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(
                          color: message.sentByMe
                              ? Theme.of(context).colorScheme.primaryContainer
                              : Theme.of(context)
                                  .colorScheme
                                  .surfaceContainerHigh,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(message.text),
                              const SizedBox(height: 4),
                              Text(_formatTime(message.time),
                                  style: TextStyle(
                                      fontSize: 10,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant)),
                            ]),
                      ),
                    );
                  },
                ),
        ),
        const SizedBox(height: 8),
        Row(children: [
          IconButton(
              tooltip: 'Attach image, GIF, or video',
              onPressed: _isSending ? null : () => _pickChatAttachment(peer),
              icon: const Icon(Icons.attach_file)),
          Expanded(
            child: TextField(
              controller: _chatController,
              minLines: 1,
              maxLines: 4,
              maxLength: 4000,
              decoration: const InputDecoration(
                  hintText: 'Message',
                  counterText: '',
                  border: OutlineInputBorder()),
              onSubmitted: (_) => _sendChatText(peer),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filled(
              tooltip: 'Send message',
              onPressed: () => _sendChatText(peer),
              icon: const Icon(Icons.send)),
        ]),
      ]),
    );
  }

  void _openChat(Peer peer) {
    final transport =
        peer.isDirect ? _SendTransport.wifiDirect : _SendTransport.sameWifi;
    setState(() {
      _sendTransport = transport;
      _chatPeerId = peer.id;
      _unreadChatCounts.remove(peer.id);
      _desktopTab = 4;
      _tab = 4;
    });
    unawaited(SharedPreferences.getInstance().then((preferences) =>
        preferences.setString('omnidrop_send_transport', transport.name)));
  }

  Future<void> _sendChatText(Peer peer) async {
    final text = _chatController.text.trim();
    if (text.isEmpty) return;
    try {
      final routePeer = _discovery.peerForTransport(
        peer.id,
        direct: _usesDirectTransport,
      );
      if (routePeer == null) {
        throw StateError(_usesDirectTransport
            ? 'Connect to this device by Wi-Fi Direct first.'
            : 'This device is not available on the same Wi-Fi network.');
      }
      await _discovery.sendChatMessage(routePeer, text);
      if (!mounted) return;
      setState(() {
        if (_chatController.text.trim() == text) _chatController.clear();
        _appendChatLine(_ChatLine(
            peerId: peer.id, text: text, sentByMe: true, time: DateTime.now()));
      });
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Message not sent: $error')));
    }
  }

  Future<void> _pasteLocalClipboard() async {
    final clipboard = await Clipboard.getData('text/plain');
    if (clipboard?.text == null || !mounted) return;
    setState(() => _clipboardController.text = clipboard!.text!);
  }

  Future<void> _shareClipboard() async {
    var text = _clipboardController.text.trim();
    if (text.isEmpty) {
      text = (await Clipboard.getData('text/plain'))?.text?.trim() ?? '';
    }
    if (text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Copy or enter text to share first.')));
      return;
    }
    final targets = _peersForSendTransport
        .where((peer) => peer.trusted && _clipboardTargetIds.contains(peer.id))
        .toList();
    if (targets.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'Select at least one paired device to receive this clipboard text.')));
      return;
    }
    setState(() => _clipboardBusy = true);
    var sent = 0;
    for (final peer in targets) {
      try {
        await _discovery.sendChatMessage(peer, text, clipboard: true);
        sent++;
      } catch (_) {
        // Continue so one unavailable device does not block other recipients.
      }
    }
    if (!mounted) return;
    setState(() => _clipboardBusy = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(sent == 0
            ? 'Clipboard text could not be sent. Check that paired devices are connected.'
            : 'Clipboard text shared with $sent device${sent == 1 ? '' : 's'}.')));
  }

  Future<void> _pickChatAttachment(Peer peer) async {
    final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const [
          'jpg',
          'jpeg',
          'png',
          'webp',
          'gif',
          'bmp',
          'heic',
          'mp4',
          'mov',
          'm4v',
          'webm',
          'mkv',
          'avi',
          '3gp'
        ]);
    if (result.isEmpty || !mounted) return;
    final selected = result.first.path;
    if (selected == null) return;
    final file = File(selected);
    final name = file.uri.pathSegments.last;
    final size = await file.length();
    if (!mounted) return;
    setState(() {
      _selectedPeerId = peer.id;
      _sharedFiles.add(file);
      _queue.add(name);
      _queueSizes.add(size);
    });
    await _sendSelected(peer, chatAttachment: true);
    if (_sharedFiles.isEmpty && mounted) {
      final text = '📎 Shared file: $name';
      try {
        await _discovery.sendChatMessage(peer, text);
        if (mounted) {
          setState(() => _appendChatLine(_ChatLine(
              peerId: peer.id,
              text: text,
              sentByMe: true,
              time: DateTime.now())));
        }
      } catch (_) {
        // The secure file transfer already completed; the attachment remains
        // available in the receiving device's download folder.
      }
    }
  }

  void _appendChatLine(_ChatLine line) {
    final messages = _chatHistory.putIfAbsent(line.peerId, () => <_ChatLine>[]);
    messages.add(line);
    if (messages.length > 500) messages.removeRange(0, messages.length - 500);
  }

  void _appendIncomingChatLine(_ChatLine line) {
    _appendChatLine(line);
    final chatIsOpen = _chatPeerId == line.peerId &&
        (MediaQuery.sizeOf(context).width >= 1000
            ? _desktopTab == 4
            : _tab == 4);
    if (!chatIsOpen) {
      _unreadChatCounts.update(line.peerId, (count) => count + 1,
          ifAbsent: () => 1);
    }
  }

  int get _totalUnreadChats =>
      _unreadChatCounts.values.fold(0, (total, count) => total + count);

  String _formatTime(DateTime time) =>
      TimeOfDay.fromDateTime(time).format(context);

  String _transferEstimateLabel() {
    if (!_isSending || _currentBytesPerSecond <= 0)
      return 'Calculating remaining time…';
    var remainingBytes =
        (_currentFileTotalBytes - _currentFileBytesSent).clamp(0, 1 << 62);
    final activeIndex = _queue.indexOf(_currentTransferFile ?? '');
    if (activeIndex >= 0) {
      for (var i = activeIndex + 1; i < _queueSizes.length; i++) {
        remainingBytes += _queueSizes[i] ?? 0;
      }
    }
    final seconds = (remainingBytes / _currentBytesPerSecond).ceil();
    final remaining = Duration(seconds: seconds);
    final finishAt = DateTime.now().add(remaining);
    return 'About ${_formatDuration(remaining)} remaining · finishes around ${_formatTime(finishAt)}';
  }

  String _formatDuration(Duration value) {
    if (value.inDays > 0)
      return '${value.inDays}d ${value.inHours.remainder(24)}h';
    if (value.inHours > 0)
      return '${value.inHours}h ${value.inMinutes.remainder(60)}m';
    if (value.inMinutes > 0)
      return '${value.inMinutes}m ${value.inSeconds.remainder(60)}s';
    return '${value.inSeconds}s';
  }

  Future<void> _manageTrustedDevices() async {
    final preferences = await SharedPreferences.getInstance();
    final ids =
        preferences.getStringList('omnidrop_trusted_devices') ?? <String>[];
    final entries = ids
        .map((id) => (
              id: id,
              name: preferences.getString('omnidrop_trusted_device_name_$id') ??
                  _peers.where((peer) => peer.id == id).firstOrNull?.name ??
                  'Device ${id.length > 8 ? id.substring(0, 8) : id}',
            ))
        .toList();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('Trusted devices'),
          content: SizedBox(
            width: 440,
            child: entries.isEmpty
                ? const Text(
                    'No trusted devices yet. Pair with a device to add it here.')
                : ListView(
                    shrinkWrap: true,
                    children: [
                      for (final entry in entries)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.verified_user_outlined),
                          title: Text(entry.name,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(
                              'Device ID · ${entry.id.substring(0, math.min(12, entry.id.length))}'),
                          trailing: IconButton(
                            tooltip: 'Remove trusted device',
                            icon: const Icon(Icons.person_remove_outlined),
                            onPressed: () async {
                              await _discovery.forgetTrustedDevice(entry.id);
                              if (!mounted) return;
                              setState(() {
                                _clipboardTargetIds.remove(entry.id);
                                if (_selectedPeerId == entry.id)
                                  _selectedPeerId = null;
                                if (_chatPeerId == entry.id) _chatPeerId = null;
                              });
                              setDialogState(() => entries
                                  .removeWhere((item) => item.id == entry.id));
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                    content: Text(
                                        '${entry.name} removed from trusted devices.')),
                              );
                            },
                          ),
                        ),
                    ],
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _settings() => ListView(padding: const EdgeInsets.all(24), children: [
        const _Brand(),
        const SizedBox(height: 28),
        Text('Settings', style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 8),
        ListTile(
          leading: const Icon(Icons.brightness_6_outlined),
          title: const Text('App theme'),
          subtitle: const Text('Choose light, dark, or follow your device'),
          trailing: DropdownButtonHideUnderline(
            child: DropdownButton<ThemeMode>(
              value: widget.themeMode,
              items: const [
                DropdownMenuItem(
                    value: ThemeMode.system, child: Text('System')),
                DropdownMenuItem(value: ThemeMode.dark, child: Text('Dark')),
                DropdownMenuItem(value: ThemeMode.light, child: Text('Light')),
              ],
              onChanged: (value) {
                if (value != null) unawaited(widget.onThemeModeChanged(value));
              },
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('App color', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              Text('Change the accent color across OmniDrop.',
                  style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final choice in widget.accentChoices.entries)
                    ChoiceChip(
                      avatar: CircleAvatar(
                        radius: 9,
                        backgroundColor: Color(choice.key),
                      ),
                      label: Text(choice.value),
                      selected: widget.accentSeed == choice.key,
                      onSelected: (_) =>
                          unawaited(widget.onAccentChanged(choice.key)),
                    ),
                ],
              ),
            ],
          ),
        ),
        ListTile(
            leading: CircleAvatar(
                backgroundImage: _profileImagePath == null
                    ? null
                    : FileImage(File(_profileImagePath!)),
                child: _profileImagePath == null
                    ? const Icon(Icons.person)
                    : null),
            title: const Text('Your profile'),
            subtitle: Text('$_profileName · Change name or photo'),
            onTap: _editProfile),
        ListTile(
            leading: const Icon(Icons.folder_outlined),
            title: const Text('Download location'),
            subtitle: Text(_downloadPath),
            onTap: _chooseFolder),
        SwitchListTile(
            title: const Text('Visible to nearby devices'),
            value: _visible,
            onChanged: _setVisibility),
        ListTile(
            leading: Icon(Icons.devices_other),
            title: Text('Trusted devices'),
            subtitle: Text(
                '${_peers.where((peer) => peer.trusted).length} online · View or remove paired devices'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _manageTrustedDevices),
        ListTile(
            leading: const Icon(Icons.android),
            title: const Text('Invite an Android device'),
            subtitle: const Text('Share the app installer with a QR code'),
            onTap: _inviteAndroid),
        ListTile(
            leading: const Icon(Icons.qr_code_2),
            title: const Text('Share with a browser'),
            subtitle: const Text('Temporary link and QR code'),
            onTap: _openBrowserShare)
      ]);

  Widget _clipboard() => ListView(padding: const EdgeInsets.all(24), children: [
        const _Brand(),
        const SizedBox(height: 28),
        Text('Shared clipboard',
            style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 12),
        const Text('Choose which paired devices receive this text.'),
        const SizedBox(height: 8),
        ..._peersForSendTransport
            .where((peer) => peer.trusted)
            .map((peer) => CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _clipboardTargetIds.contains(peer.id),
                  title: Text(peer.name,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: const Text('Paired · online'),
                  controlAffinity: ListTileControlAffinity.leading,
                  onChanged: _clipboardBusy
                      ? null
                      : (selected) => setState(() {
                            if (selected == true) {
                              _clipboardTargetIds.add(peer.id);
                            } else {
                              _clipboardTargetIds.remove(peer.id);
                            }
                          }),
                )),
        if (!_peersForSendTransport.any((peer) => peer.trusted))
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 10),
            child:
                Text('No paired devices are online on this connection mode.'),
          ),
        const SizedBox(height: 20),
        TextField(
          controller: _clipboardController,
          maxLines: 5,
          maxLength: 4000,
          decoration: InputDecoration(
              border: const OutlineInputBorder(),
              hintText: 'Paste text or a link to share',
              suffixIcon: IconButton(
                  tooltip: 'Paste from this device clipboard',
                  onPressed: _pasteLocalClipboard,
                  icon: const Icon(Icons.content_paste))),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
            onPressed: _clipboardBusy ? null : _shareClipboard,
            icon: _clipboardBusy
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.send),
            label: Text(_clipboardBusy
                ? 'Sharing…'
                : 'Share with ${_clipboardTargetIds.where((id) => _peers.any((peer) => peer.id == id && peer.trusted)).length} selected'))
      ]);

  Widget _direct() => FutureBuilder<List<RadioCapability>>(
        future: _directCapabilities ??= DirectRadioService().inspect(),
        builder: (context, snapshot) {
          final capabilities = snapshot.data ?? const <RadioCapability>[];
          return ListView(padding: const EdgeInsets.all(24), children: [
            const _Brand(),
            const SizedBox(height: 28),
            Row(children: [
              if (MediaQuery.sizeOf(context).width >= 1000)
                IconButton(
                    tooltip: 'Back to nearby devices',
                    onPressed: _showNearbyDevices,
                    icon: const Icon(Icons.arrow_back)),
              Expanded(
                  child: Text('Direct connections',
                      style: Theme.of(context).textTheme.headlineMedium)),
              IconButton(
                  tooltip: 'Check this device again',
                  onPressed: () => setState(() =>
                      _directCapabilities = DirectRadioService().inspect()),
                  icon: const Icon(Icons.refresh))
            ]),
            const Text(
                'Router-free discovery uses the radios available on this device. Keep using Nearby devices for transfers over the same Wi-Fi.'),
            const SizedBox(height: 8),
            Card(
                child: ListTile(
              leading: Icon(Icons.network_wifi,
                  color: Theme.of(context).colorScheme.primary),
              title: Text('Current Wi-Fi band: $_networkBand'),
              subtitle: const Text(
                  'Nearby mode follows this Wi-Fi connection. Direct mode uses Wi-Fi Direct; Android requests 5 GHz when hosting.'),
              trailing: IconButton(
                tooltip: 'Refresh Wi-Fi band',
                onPressed: _loadNetworkBand,
                icon: const Icon(Icons.refresh),
              ),
            )),
            const SizedBox(height: 20),
            if (snapshot.connectionState == ConnectionState.waiting)
              const LinearProgressIndicator(),
            if (snapshot.hasError)
              _RadioCard(
                  capability: RadioCapability(
                      name: 'Device check failed',
                      support: RadioSupport.unavailable,
                      message:
                          'Could not inspect this device’s radios. ${snapshot.error}')),
            for (final capability in capabilities)
              _RadioCard(capability: capability),
            if (Platform.isAndroid) ...[
              const SizedBox(height: 14),
              Card(
                  child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Direct transfer session',
                                style: TextStyle(fontWeight: FontWeight.bold)),
                            const SizedBox(height: 6),
                            Text(_directSessionMessage.isEmpty
                                ? 'Start a phone-hosted Wi-Fi Direct group. OmniDrop requests 5 GHz first and falls back to the system-selected band if needed.'
                                : _directSessionMessage),
                            const SizedBox(height: 10),
                            FilledButton.icon(
                              onPressed: _directSessionStarting
                                  ? null
                                  : _toggleDirectSession,
                              icon: _directSessionStarting
                                  ? const SizedBox.square(
                                      dimension: 18,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2))
                                  : Icon(_directSessionActive
                                      ? Icons.stop_circle_outlined
                                      : Icons.wifi_tethering),
                              label: Text(_directSessionStarting
                                  ? 'Starting…'
                                  : _directSessionActive
                                      ? 'Stop direct session'
                                      : 'Start direct session'),
                            ),
                            if (_directSessionActive &&
                                _directSessionBand != null)
                              Padding(
                                  padding: const EdgeInsets.only(top: 8),
                                  child: Text(
                                      'Group preference: $_directSessionBand',
                                      style: TextStyle(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .primary))),
                          ]))),
            ],
            if (Platform.isWindows) ...[
              const SizedBox(height: 14),
              Card(
                  child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Connect to a phone’s direct session',
                                style: TextStyle(fontWeight: FontWeight.bold)),
                            const SizedBox(height: 6),
                            const Text(
                                'Start a Wi-Fi Direct session on Android first, then search here. Windows lets its Wi-Fi driver choose the band; Android requests 5 GHz when it hosts the group.'),
                            const SizedBox(height: 10),
                            FilledButton.icon(
                              onPressed: _windowsDirectSearchBusy
                                  ? null
                                  : _discoverWindowsDirectDevices,
                              icon: _windowsDirectSearchBusy
                                  ? const SizedBox.square(
                                      dimension: 18,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2))
                                  : const Icon(Icons.search),
                              label: Text(_windowsDirectSearchBusy
                                  ? 'Searching…'
                                  : 'Find direct devices'),
                            ),
                            if (_windowsDirectPeerId != null)
                              TextButton.icon(
                                  onPressed: _disconnectWindowsDirectDevice,
                                  icon: const Icon(Icons.link_off),
                                  label:
                                      const Text('Disconnect direct session')),
                            for (final device in _windowsDirectDevices)
                              ListTile(
                                contentPadding: EdgeInsets.zero,
                                leading: const Icon(Icons.phone_android),
                                title: Text(device.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis),
                                trailing: FilledButton.tonal(
                                  onPressed: _windowsDirectConnecting
                                          .contains(device.id)
                                      ? null
                                      : () =>
                                          _connectWindowsDirectDevice(device),
                                  child: Text(_windowsDirectConnecting
                                          .contains(device.id)
                                      ? 'Connecting…'
                                      : 'Connect'),
                                ),
                              ),
                          ]))),
            ],
            if (_peers.any((peer) => peer.isDirect)) ...[
              const SizedBox(height: 16),
              Text('Directly connected',
                  style: Theme.of(context).textTheme.titleMedium),
              for (final peer in _peers.where((peer) => peer.isDirect))
                Card(
                    child: ListTile(
                  leading: Icon(
                      peer.trusted ? Icons.verified_user : Icons.wifi_tethering,
                      color: Theme.of(context).colorScheme.primary),
                  title: Text(peer.name),
                  subtitle: Text(peer.trusted
                      ? 'Paired · Wi-Fi Direct'
                      : 'Wi-Fi Direct · Pair before sending'),
                  trailing:
                      Platform.isWindows && peer.id == _windowsDirectPeerId
                          ? IconButton(
                              tooltip: 'Disconnect',
                              onPressed: _disconnectWindowsDirectDevice,
                              icon: const Icon(Icons.link_off))
                          : peer.trusted
                              ? FilledButton.tonal(
                                  onPressed: () => _sendTo(peer),
                                  child: const Text('Select'))
                              : OutlinedButton(
                                  onPressed: () => _sendTo(peer),
                                  child: const Text('Pair')),
                )),
            ],
            const SizedBox(height: 16),
            const Card(
                child: Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(
                        'Direct sessions use Wi-Fi Direct for the link and OmniDrop’s existing encrypted transfer protocol for file contents. Android requests 5 GHz when hosting; Windows does not expose a band selector, so a Windows-hosted group uses the driver’s choice. Nearby devices remains available over your regular Wi-Fi network.'))),
          ]);
        },
      );

  Future<void> _discoverWindowsDirectDevices() async {
    setState(() => _windowsDirectSearchBusy = true);
    try {
      final devices = await DirectRadioService().discoverWindowsDirectDevices();
      if (!mounted) return;
      setState(() {
        _windowsDirectDevices
          ..clear()
          ..addAll(devices);
      });
      if (devices.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'No Wi-Fi Direct device appeared. Keep the Android session open, enable Wi-Fi on the PC, then search again.')));
      }
    } catch (error) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Direct search failed: $error')));
    } finally {
      if (mounted) setState(() => _windowsDirectSearchBusy = false);
    }
  }

  Future<void> _connectWindowsDirectDevice(DirectDevice device) async {
    setState(() => _windowsDirectConnecting.add(device.id));
    try {
      final address =
          await DirectRadioService().connectWindowsDirectDevice(device.id);
      final peer = await _discovery.connectDirectEndpoint(address);
      if (!mounted) return;
      setState(() => _windowsDirectPeerId = peer.id);
      await _selectSendTransport(_SendTransport.wifiDirect);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              'Connected directly to ${peer.name}. Pair once to send files securely.')));
    } catch (error) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content:
                Text('Could not connect directly to ${device.name}: $error')));
    } finally {
      if (mounted) setState(() => _windowsDirectConnecting.remove(device.id));
    }
  }

  Future<void> _disconnectWindowsDirectDevice() async {
    final deviceId = _windowsDirectPeerId;
    try {
      await DirectRadioService().stopWindowsDirectDevice();
    } catch (_) {
      // The Wi-Fi Direct device may already have disconnected at the OS level.
    }
    if (deviceId != null) _discovery.disconnectDirectPeer(deviceId);
    if (mounted) setState(() => _windowsDirectPeerId = null);
  }

  Future<void> _toggleDirectSession() async {
    setState(() => _directSessionStarting = true);
    try {
      if (_directSessionActive) {
        await DirectRadioService().stopAndroidDirectGroup();
        _discovery.clearDirectPeers();
        if (!mounted) return;
        setState(() {
          _directSessionActive = false;
          _directSessionBand = null;
          _directSessionMessage = 'Direct Wi-Fi group stopped.';
        });
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Direct Wi-Fi session stopped.')));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Starting Wi-Fi Direct…')));
        final result = await DirectRadioService().startAndroidDirectGroup();
        if (!mounted) return;
        setState(() {
          _directSessionActive = result['ok'] == true;
          _directSessionBand = result['band'] as String?;
          _directSessionMessage = (result['message'] ??
              result['reason'] ??
              'Could not start direct session.') as String;
        });
        if (result['ok'] == true) {
          await _selectSendTransport(_SendTransport.wifiDirect);
        }
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(_directSessionMessage),
            duration: const Duration(seconds: 5)));
      }
    } catch (error) {
      if (mounted) {
        setState(() => _directSessionMessage = 'Direct session failed: $error');
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(_directSessionMessage),
            duration: const Duration(seconds: 6)));
      }
    } finally {
      if (mounted) setState(() => _directSessionStarting = false);
    }
  }

  Future<void> _pickFiles() async {
    final files = await FilePicker.pickFiles();
    if (files.isEmpty || !mounted) return;
    _addFiles(files
        .where((file) => file.path != null)
        .map((file) => File(file.path!))
        .toList());
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Choose a nearby device to begin sending.')));
  }

  void _addFiles(List<File> files) {
    if (files.isEmpty || !mounted) return;
    final startIndex = _queueSizes.length;
    setState(() {
      _queue.addAll(files.map((file) => file.uri.pathSegments.last));
      _queueSizes.addAll(List<int?>.filled(files.length, null));
      _sharedFiles.addAll(files);
    });
    unawaited(_populateQueueSizes(startIndex, files));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            '${files.length} file${files.length == 1 ? '' : 's'} added to the queue.')));
  }

  Future<void> _populateQueueSizes(int startIndex, List<File> files) async {
    final sizes = await Future.wait(files.map((file) async {
      try {
        return await file.length();
      } on FileSystemException {
        return 0;
      }
    }));
    if (!mounted) return;
    setState(() {
      for (var i = 0; i < sizes.length; i++) {
        final index = startIndex + i;
        if (index < _queueSizes.length) _queueSizes[index] = sizes[i];
      }
    });
  }

  Future<void> _onFilesDropped(DropDoneDetails details) async {
    setState(() => _isDragging = false);
    final files = <File>[];
    for (final item in details.files) {
      if (item.path.isNotEmpty) {
        files.add(File(item.path));
      } else {
        final directory = await getTemporaryDirectory();
        final safeName = item.name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
        final path =
            '${directory.path}${Platform.pathSeparator}${DateTime.now().microsecondsSinceEpoch}_$safeName';
        await item.saveTo(path);
        files.add(File(path));
      }
    }
    _addFiles(files);
  }

  Future<void> _inviteAndroid() async {
    final pickedFile = await FilePicker.pickFile(
        type: FileType.custom, allowedExtensions: const ['apk']);
    if (pickedFile?.path == null || !mounted) return;
    final apk = File(pickedFile!.path!);
    final link =
        await _browserShare.start([apk], lifetime: const Duration(minutes: 10));
    if (!mounted) return;
    await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
              title: const Text('Install OmniDrop on Android'),
              content: Column(mainAxisSize: MainAxisSize.min, children: [
                QrImageView(
                    data: link.toString(),
                    size: 220,
                    backgroundColor: Colors.white),
                const SizedBox(height: 12),
                const Text(
                    'Scan while connected to the same Wi-Fi, download the APK, then approve installation on the Android device.',
                    textAlign: TextAlign.center),
                const SizedBox(height: 10),
                SelectableText(link.toString(), textAlign: TextAlign.center),
              ]),
              actions: [
                TextButton(
                    onPressed: () async {
                      await _browserShare.stop();
                      if (dialogContext.mounted) Navigator.pop(dialogContext);
                    },
                    child: const Text('Stop sharing'))
              ],
            ));
  }

  Future<void> _openBrowserShare({Peer? peer}) async {
    if (_sharedFiles.isEmpty) {
      await _pickFiles();
      if (_sharedFiles.isEmpty) return;
    }
    final link = await _browserShare.start(List.unmodifiable(_sharedFiles));
    if (!mounted) return;
    await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
              title: Text(peer == null
                  ? 'Browser sharing · 10 minutes'
                  : 'Share with ${peer.name}'),
              content: Column(mainAxisSize: MainAxisSize.min, children: [
                Text(peer == null
                    ? 'Ask the recipient to scan this code while on the same Wi-Fi. The link expires after 10 minutes.'
                    : 'On ${peer.name}, scan this code while connected to the same Wi-Fi. The link expires after 10 minutes.'),
                const SizedBox(height: 12),
                QrImageView(
                    data: link.toString(),
                    size: 220,
                    backgroundColor: Colors.white),
                const SizedBox(height: 12),
                SelectableText(link.toString(), textAlign: TextAlign.center)
              ]),
              actions: [
                TextButton(
                    onPressed: () async {
                      await _browserShare.stop();
                      if (context.mounted) Navigator.pop(context);
                    },
                    child: const Text('Stop sharing'))
              ],
            ));
  }

  Future<void> _chooseFolder() async {
    final path = await FilePicker.getDirectoryPath(
        dialogTitle: 'Choose download folder');
    if (path == null || !mounted) return;
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString('omnidrop_download_path', path);
    if (mounted) setState(() => _downloadPath = path);
  }

  Future<void> _editProfile() async {
    final nameController = TextEditingController(text: _profileName);
    final name = await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
              title: const Text('Edit your profile'),
              content: TextField(
                  controller: nameController,
                  autofocus: true,
                  maxLength: 32,
                  decoration: const InputDecoration(labelText: 'Display name')),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    child: const Text('Cancel')),
                TextButton(
                    onPressed: () => Navigator.pop(
                        dialogContext, nameController.text.trim()),
                    child: const Text('Save'))
              ],
            ));
    nameController.dispose();
    if (name == null || !mounted) return;
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
        'omnidrop_profile_name', name.isEmpty ? Platform.localHostname : name);
    if (mounted) {
      setState(
          () => _profileName = name.isEmpty ? Platform.localHostname : name);
    }
    if (!mounted) return;
    final changePhoto = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
              title: const Text('Profile photo'),
              content: const Text('Would you like to choose a profile photo?'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(dialogContext, false),
                    child: const Text('Later')),
                FilledButton(
                    onPressed: () => Navigator.pop(dialogContext, true),
                    child: const Text('Choose photo'))
              ],
            ));
    if (changePhoto != true) return;
    final image = await FilePicker.pickFile(type: FileType.image);
    if (image?.path == null || !mounted) return;
    await preferences.setString('omnidrop_profile_image', image!.path!);
    if (mounted) setState(() => _profileImagePath = image.path);
  }

  Future<void> _showIncomingPairing(PairingRequest request) async {
    if (!mounted) {
      await _discovery.respondToPairing(request.id, accept: false);
      return;
    }
    final accepted = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
              title: Text('Pair with ${request.deviceName}?'),
              content: Column(mainAxisSize: MainAxisSize.min, children: [
                const Text(
                    'Only approve if this code matches the one shown on the other device.'),
                const SizedBox(height: 18),
                Text(
                    '${request.code.substring(0, 3)} ${request.code.substring(3)}',
                    style: const TextStyle(
                        fontSize: 34,
                        letterSpacing: 4,
                        fontWeight: FontWeight.bold)),
              ]),
              actions: [
                TextButton(
                    onPressed: () =>
                        Navigator.of(dialogContext, rootNavigator: true)
                            .pop(false),
                    child: const Text('Decline')),
                FilledButton(
                    onPressed: () =>
                        Navigator.of(dialogContext, rootNavigator: true)
                            .pop(true),
                    child: const Text('Approve'))
              ],
            ));
    await _discovery.respondToPairing(request.id, accept: accepted == true);
    if (accepted == true && mounted) {
      final paired = await request.completed.future
          .timeout(const Duration(seconds: 95), onTimeout: () => false);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(paired
              ? 'Paired successfully with ${request.deviceName}.'
              : 'Pairing with ${request.deviceName} did not finish.')));
    }
  }

  Future<void> _sendTo(Peer peer) async {
    if (_isSending) return;
    final requestedTransport =
        peer.isDirect ? _SendTransport.wifiDirect : _SendTransport.sameWifi;
    if (_sendTransport != requestedTransport) {
      await _selectSendTransport(requestedTransport);
    }
    final routePeer = _discovery.peerForTransport(
      peer.id,
      direct: _usesDirectTransport,
    );
    if (routePeer == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(_usesDirectTransport
              ? 'Connect to this device from the Direct tab before pairing.'
              : 'This device is not available on the same Wi-Fi network.')));
      return;
    }
    peer = routePeer;
    if (peer.trusted) {
      setState(() {
        _selectedPeerId = peer.id;
        _sendFailed = false;
        _retryTransferId = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content:
              Text('Selected ${peer.name}. Choose files, then tap Send.')));
      return;
    }
    try {
      final session = await _discovery.requestPairing(peer);
      if (!mounted) {
        await session.close();
        return;
      }
      final approved = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) => AlertDialog(
                title: Text('Pair with ${peer.name}?'),
                content: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Text(
                      'Compare this verification code with the other device. Approve only if both screens show the same code.'),
                  const SizedBox(height: 18),
                  Text(
                      '${session.code.substring(0, 3)} ${session.code.substring(3)}',
                      style: const TextStyle(
                          fontSize: 34,
                          letterSpacing: 4,
                          fontWeight: FontWeight.bold)),
                ]),
                actions: [
                  TextButton(
                      onPressed: () =>
                          Navigator.of(dialogContext, rootNavigator: true)
                              .pop(false),
                      child: const Text('Cancel')),
                  FilledButton(
                      onPressed: () =>
                          Navigator.of(dialogContext, rootNavigator: true)
                              .pop(true),
                      child: const Text('Code matches'))
                ],
              ));
      if (approved != true) {
        await session.confirm(false);
        await session.close();
        return;
      }
      if (!mounted) {
        await session.close();
        return;
      }
      final navigator = Navigator.of(context, rootNavigator: true);
      final cancelled = Completer<bool>();
      final route = DialogRoute<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Pairing device'),
          content: Text('Waiting for approval on ${peer.name}…'),
          actions: [
            TextButton(
              onPressed: () {
                if (!cancelled.isCompleted) cancelled.complete(false);
                Navigator.of(dialogContext, rootNavigator: true).pop(false);
              },
              child: const Text('Cancel'),
            ),
          ],
        ),
      );
      final dialogResult = navigator.push<bool>(route);
      final pairingResult = session
          .confirm(true)
          .timeout(const Duration(seconds: 95))
          .then<bool>((accepted) => accepted, onError: (Object _) => false);
      final paired = await Future.any<bool>([pairingResult, cancelled.future]);
      if (cancelled.isCompleted) {
        await session.close();
        await dialogResult;
        return;
      }
      if (navigator.mounted && route.isActive) navigator.pop<bool>(paired);
      final dialogAccepted = await dialogResult;
      await session.close();
      if (dialogAccepted != true || !mounted) return;
      setState(() {
        final index = _peers.indexWhere((item) => item.id == peer.id);
        if (index != -1) {
          _peers[index] = Peer(
              id: peer.id,
              name: peer.name,
              kind: peer.kind,
              address: peer.address,
              port: peer.port,
              trusted: true,
              isDirect: peer.isDirect);
        }
        _selectedPeerId = peer.id;
        _sendFailed = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Successfully paired with ${peer.name}.')));
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not pair: $error')));
      }
    }
  }

  Future<void> _sendSelected(Peer peer, {bool chatAttachment = false}) async {
    final routePeer = _discovery.peerForTransport(
      peer.id,
      direct: _usesDirectTransport,
    );
    if (routePeer == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(_usesDirectTransport
              ? 'This device is not connected by Wi-Fi Direct. Connect it from the Direct tab first.'
              : 'This device is not available on the same Wi-Fi network. Switch mode or reconnect it.')));
      return;
    }
    peer = routePeer;
    if (_sharedFiles.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Choose files to send first.')));
      return;
    }
    final transferId = (_sendFailed || _isPaused) && _retryTransferId != null
        ? _retryTransferId!
        : '${DateTime.now().microsecondsSinceEpoch}-${math.Random().nextInt(1 << 32)}';
    final transferStartedAt = DateTime.now();
    final filesBeingSent = List<File>.unmodifiable(_sharedFiles);
    setState(() {
      _isSending = true;
      _cancelRequested = false;
      _pauseRequested = false;
      _isPaused = false;
      _sendFailed = false;
      _currentFileProgress = 0;
      _currentBytesPerSecond = 0;
      _currentFileBytesSent = 0;
      _currentFileTotalBytes = 0;
      _currentTransferFile = null;
      _lastProgressBytes = 0;
      _activeOutgoingTransferId = transferId;
    });
    _publishTransferNotification(
      active: true,
      title: 'Sending files to ${peer.name}',
      text: '${filesBeingSent.length} file${filesBeingSent.length == 1 ? '' : 's'} · preparing transfer',
      progress: 0,
      force: true,
    );
    try {
      await _discovery.sendTrustedFiles(peer, filesBeingSent,
          transferId: transferId,
          chatAttachment: chatAttachment, onProgress: (fileName, sent, total) {
        final now = DateTime.now();
        final newFile = _currentTransferFile != fileName;
        if (sent < total &&
            !newFile &&
            now.difference(_lastProgressUpdate) <
                const Duration(milliseconds: 400)) {
          return;
        }
        final elapsedSeconds = newFile
            ? 0.0
            : now.difference(_lastProgressUpdate).inMicroseconds / 1000000;
        final bytesDelta = newFile ? sent : sent - _lastProgressBytes;
        _lastProgressUpdate = now;
        _lastProgressBytes = sent;
        if (mounted) {
          setState(() {
            _currentTransferFile = fileName;
            _currentFileProgress = total == 0 ? 1 : sent / total;
            _currentFileBytesSent = sent;
            _currentFileTotalBytes = total;
            _currentBytesPerSecond =
                elapsedSeconds <= 0 ? 0 : bytesDelta / elapsedSeconds;
          });
        }
        _publishTransferNotification(
          active: true,
          title: 'Sending $fileName to ${peer.name}',
          text: '${_formatBytes(sent)} of ${_formatBytes(total)} · ${_formatSpeed(_currentBytesPerSecond)} · ${_estimateTime(total - sent, _currentBytesPerSecond)}',
          progress: total == 0 ? 100 : (sent * 100 / total).round(),
        );
      });
      final completedAt = DateTime.now();
      for (final file in filesBeingSent) {
        final size = await file.length();
        await _storeTransferRecord({
          'id': '${completedAt.microsecondsSinceEpoch}-${math.Random().nextInt(1 << 32)}',
          'direction': 'Sent',
          'sender': _profileName,
          'receiver': peer.name,
          'transport': _usesDirectTransport ? 'Wi-Fi Direct' : 'Same Wi-Fi',
          'name': file.uri.pathSegments.last,
          'size': size,
          'location': file.path,
          'duration':
              _formatDuration(completedAt.difference(transferStartedAt)),
          'date': completedAt.toIso8601String(),
        });
      }
      if (!mounted) return;
      _publishTransferNotification(
        active: false,
        title: 'Transfer complete',
        text: 'Files sent to ${peer.name}.',
        progress: 100,
        force: true,
      );
      setState(() {
        _isSending = false;
        _activeOutgoingTransferId = null;
        _retryTransferId = null;
        _cancelRequested = false;
        _sendFailed = false;
        _isPaused = false;
        _currentTransferFile = null;
        _currentFileProgress = 0;
        _currentBytesPerSecond = 0;
        _currentFileBytesSent = 0;
        _currentFileTotalBytes = 0;
        _queue.clear();
        _queueSizes.clear();
        _sharedFiles.clear();
        _selectedPeerId = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Files sent securely to ${peer.name}.')));
    } catch (error) {
      if (mounted) {
        if (_pauseRequested || error is TransferPausedException) {
          _publishTransferNotification(
            active: false,
            title: 'Transfer paused',
            text: 'Paused at ${_formatBytes(_currentFileBytesSent)}. Resume in OmniDrop.',
            progress: (_currentFileProgress * 100).round(),
            force: true,
          );
          setState(() {
            _isSending = false;
            _pauseRequested = false;
            _isPaused = true;
            _sendFailed = false;
            _activeOutgoingTransferId = null;
            _retryTransferId = transferId;
            _currentBytesPerSecond = 0;
          });
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Transfer paused. Tap Resume to continue.')));
          return;
        }
        if (_cancelRequested || error is TransferCancelledException) {
          _publishTransferNotification(
            active: false,
            title: 'Transfer cancelled',
            text: 'The transfer was stopped.',
            progress: (_currentFileProgress * 100).round(),
            force: true,
          );
          final cancelledByReceiver = error is TransferCancelledException;
          setState(() {
            _isSending = false;
            _cancelRequested = false;
            _sendFailed = false;
            _isPaused = false;
            _activeOutgoingTransferId = null;
            _retryTransferId = null;
            _currentTransferFile = null;
            _currentFileProgress = 0;
            _currentFileBytesSent = 0;
            _currentFileTotalBytes = 0;
            _currentBytesPerSecond = 0;
            _queue.clear();
            _queueSizes.clear();
            _sharedFiles.clear();
          });
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(cancelledByReceiver
                  ? '${peer.name} cancelled the transfer.'
                  : 'Transfer cancelled on both devices.')));
          return;
        }
        setState(() {
          _isSending = false;
          _activeOutgoingTransferId = null;
          _retryTransferId = transferId;
          _sendFailed = true;
          _currentTransferFile ??= _queue.firstOrNull;
          _currentBytesPerSecond = 0;
        });
        _publishTransferNotification(
          active: false,
          title: 'Transfer interrupted',
          text: 'Open OmniDrop to retry sending to ${peer.name}.',
          progress: (_currentFileProgress * 100).round(),
          force: true,
        );
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not send to ${peer.name}: $error')));
    }
  }

  void _cancelActiveTransfer() {
    final transferId = _activeOutgoingTransferId;
    if (transferId == null || !_isSending) return;
    setState(() => _cancelRequested = true);
    _discovery.cancelTransfer(transferId);
  }

  void _pauseActiveTransfer() {
    final transferId = _activeOutgoingTransferId;
    if (transferId == null || !_isSending) return;
    setState(() => _pauseRequested = true);
    _discovery.pauseTransfer(transferId);
  }

  void _clearOutgoingQueue() {
    if (_isSending) return;
    setState(() {
      _queue.clear();
      _queueSizes.clear();
      _sharedFiles.clear();
      _sendFailed = false;
      _isPaused = false;
      _retryTransferId = null;
      _currentTransferFile = null;
      _currentFileProgress = 0;
      _currentFileBytesSent = 0;
      _currentFileTotalBytes = 0;
    });
  }

  Future<void> _showIncomingTransfer(IncomingTransferOffer offer) async {
    if (!mounted) {
      await _discovery.respondToTransfer(offer, accept: false);
      return;
    }
    final totalBytes =
        offer.files.fold<int>(0, (total, file) => total + file.size);
    final accepted = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
              title: Text('Receive from ${offer.deviceName}?'),
              content: SizedBox(
                width: 420,
                child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                          'This paired device is offering these files. They will be encrypted in transit and saved to your download folder.'),
                      const SizedBox(height: 12),
                      for (final file in offer.files.take(8))
                        ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            leading:
                                const Icon(Icons.insert_drive_file_outlined),
                            title: Text(file.name,
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: Text(_formatBytes(file.size))),
                      if (offer.files.length > 8)
                        Text('and ${offer.files.length - 8} more file(s)'),
                      const SizedBox(height: 8),
                      Text(
                          '${offer.files.length} file(s) · ${_formatBytes(totalBytes)} total'),
                    ]),
              ),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(dialogContext, false),
                    child: const Text('Decline')),
                FilledButton(
                    onPressed: () => Navigator.pop(dialogContext, true),
                    child: const Text('Accept')),
              ],
            ));
    await _discovery.respondToTransfer(offer, accept: accepted == true);
    if (accepted == true && mounted) {
      if (offer.isChatAttachment) {
        setState(() {
          for (final file in offer.files) {
            _appendIncomingChatLine(_ChatLine(
                peerId: offer.deviceId,
                text: '📎 Accepted file: ${file.name}',
                sentByMe: false,
                time: DateTime.now()));
          }
        });
      }
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              'Receiving ${offer.files.length} file(s) from ${offer.deviceName}…')));
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024)
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  String _formatSpeed(double bytesPerSecond) {
    final kilobits = bytesPerSecond * 8 / 1000;
    if (kilobits >= 1000) return '${(kilobits / 1000).toStringAsFixed(1)} Mbps';
    return '${kilobits.round()} kbps';
  }
}

class _Brand extends StatelessWidget {
  const _Brand();
  @override
  Widget build(BuildContext context) => Row(children: [
        Icon(Icons.bolt, color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: 6),
        const Text('OmniDrop',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18))
      ]);
}

class _RadarPulse extends StatefulWidget {
  const _RadarPulse({required this.diameter, required this.color});

  final double diameter;
  final Color color;

  @override
  State<_RadarPulse> createState() => _RadarPulseState();
}

class _RadarPulseState extends State<_RadarPulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2200),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, child) => Stack(
            alignment: Alignment.center,
            children: [
              for (var index = 0; index < 3; index++) _pulse(index),
            ],
          ),
        ),
      );

  Widget _pulse(int index) {
    final progress = (_controller.value + index / 3) % 1;
    final maxDiameter = math.max(150.0, widget.diameter * .78);
    final diameter = 100 + (maxDiameter - 100) * progress;
    final opacity = (1 - progress) * .20;
    return Container(
      width: diameter,
      height: diameter,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: widget.color.withValues(alpha: opacity),
          width: 1.5,
        ),
      ),
    );
  }
}

class _NetworkBadge extends StatelessWidget {
  const _NetworkBadge({required this.label});
  final String label;
  @override
  Widget build(BuildContext context) => Row(children: [
        Icon(Icons.wifi, color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: 8),
        Flexible(
            child: Text(label,
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
                overflow: TextOverflow.ellipsis))
      ]);
}

class _PeerBubble extends StatelessWidget {
  const _PeerBubble(
      {required this.peer,
      required this.width,
      required this.onTap,
      required this.selected});
  final Peer peer;
  final double width;
  final VoidCallback onTap;
  final bool selected;
  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Tooltip(
        message: peer.isDirect
            ? '${peer.name} · Connected through Wi-Fi Direct.'
            : peer.rssi == null
                ? '${peer.name} · Available on local Wi-Fi; signal strength is not exposed.'
                : '${peer.name} · ${peer.rssi} dBm',
        child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(18),
            child: Container(
                width: width,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                        color: selected || peer.trusted
                            ? colorScheme.primary
                            : colorScheme.outlineVariant)),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(
                      switch (peer.kind) {
                        DeviceKind.phone => Icons.phone_iphone,
                        DeviceKind.tablet => Icons.tablet_mac,
                        DeviceKind.browser => Icons.language,
                        DeviceKind.desktop => Icons.laptop_mac
                      },
                      color: colorScheme.primary),
                  Text(peer.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.wifi,
                        size: 12,
                        color: peer.rssi == null
                            ? colorScheme.onSurfaceVariant
                            : peer.rssi! >= -65
                                ? colorScheme.primary
                                : peer.rssi! >= -80
                                    ? Colors.amberAccent
                                    : Colors.orangeAccent),
                    const SizedBox(width: 3),
                    Text(
                        peer.isDirect
                            ? 'Wi-Fi Direct'
                            : peer.rssi == null
                                ? 'Same Wi-Fi'
                                : '${peer.rssi} dBm',
                        style: TextStyle(
                            color: colorScheme.onSurfaceVariant, fontSize: 10)),
                  ]),
                  Text(
                      selected
                          ? 'Selected'
                          : peer.trusted
                              ? 'Tap to select'
                              : 'Tap to pair',
                      style: TextStyle(
                          color: colorScheme.onSurfaceVariant, fontSize: 11))
                ]))));
  }
}

class _ChatLine {
  const _ChatLine({
    required this.peerId,
    required this.text,
    required this.sentByMe,
    required this.time,
  });

  final String peerId;
  final String text;
  final bool sentByMe;
  final DateTime time;
}

class _TransferProgressItem {
  _TransferProgressItem({
    required this.transferId,
    required this.deviceId,
    required this.deviceName,
    required this.fileName,
    required this.totalBytes,
  });

  final String transferId;
  final String deviceId;
  final String deviceName;
  final String fileName;
  final int totalBytes;
  int bytesReceived = 0;
  double bytesPerSecond = 0;
  final DateTime startedAt = DateTime.now();
  DateTime lastUpdated = DateTime.now();
  DateTime lastUiUpdate = DateTime.fromMillisecondsSinceEpoch(0);
  bool complete = false;
  bool failed = false;
  bool isDirect = false;
}

class _OutgoingQueueSnapshot {
  const _OutgoingQueueSnapshot({
    required this.names,
    required this.sizes,
    required this.files,
    required this.selectedPeerId,
    required this.retryTransferId,
    required this.sendFailed,
    required this.isPaused,
    required this.currentTransferFile,
    required this.currentFileProgress,
    required this.currentFileBytesSent,
    required this.currentFileTotalBytes,
  });

  final List<String> names;
  final List<int?> sizes;
  final List<File> files;
  final String? selectedPeerId;
  final String? retryTransferId;
  final bool sendFailed;
  final bool isPaused;
  final String? currentTransferFile;
  final double currentFileProgress;
  final int currentFileBytesSent;
  final int currentFileTotalBytes;
}

class _FileExplorer extends StatefulWidget {
  const _FileExplorer(
      {required this.rootPath,
      required this.showHidden,
      required this.sortByDate,
      required this.descending,
      required this.clipboardPath,
      required this.clipboardIsCut,
      required this.onBack,
      required this.onHiddenChanged,
      required this.onSortChanged,
      required this.onCopy,
      required this.onPaste});
  final String? rootPath;
  final bool showHidden;
  final bool sortByDate;
  final bool descending;
  final String? clipboardPath;
  final bool clipboardIsCut;
  final VoidCallback onBack;
  final ValueChanged<bool> onHiddenChanged;
  final void Function(bool byDate, bool descending) onSortChanged;
  final void Function(String path, bool cut) onCopy;
  final Future<void> Function(Directory directory) onPaste;
  @override
  State<_FileExplorer> createState() => _FileExplorerState();
}

class _FileExplorerState extends State<_FileExplorer> {
  late Directory? _root;
  late Directory? _current;
  late Future<List<FileSystemEntity>> _listing;
  String? _androidTreeUri;
  final List<String?> _androidDocumentStack = <String?>[null];
  final List<String> _androidPathLabels = <String>['Selected storage'];
  late Future<List<Map<String, dynamic>>> _androidListing;

  @override
  void initState() {
    super.initState();
    _root = widget.rootPath == null ? null : Directory(widget.rootPath!);
    _current = _root;
    _listing = _readListing();
    _androidListing = Future.value(const <Map<String, dynamic>>[]);
  }

  @override
  void didUpdateWidget(covariant _FileExplorer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.showHidden != widget.showHidden ||
        oldWidget.sortByDate != widget.sortByDate ||
        oldWidget.descending != widget.descending) _listing = _readListing();
  }

  Future<List<FileSystemEntity>> _readListing() async {
    final directory = _current;
    if (directory == null) return const [];
    final entries = <FileSystemEntity>[];
    await for (final entity in directory.list(followLinks: false)) {
      final name =
          entity.uri.pathSegments.where((part) => part.isNotEmpty).last;
      if (!widget.showHidden && name.startsWith('.')) continue;
      if (FileSystemEntity.typeSync(entity.path, followLinks: false) ==
          FileSystemEntityType.link) continue;
      entries.add(entity);
    }
    entries.sort((a, b) {
      final typeA = FileSystemEntity.typeSync(a.path, followLinks: false) ==
          FileSystemEntityType.directory;
      final typeB = FileSystemEntity.typeSync(b.path, followLinks: false) ==
          FileSystemEntityType.directory;
      if (typeA != typeB) return typeA ? -1 : 1;
      var order = widget.sortByDate
          ? a.statSync().modified.compareTo(b.statSync().modified)
          : a.uri.pathSegments.last
              .toLowerCase()
              .compareTo(b.uri.pathSegments.last.toLowerCase());
      if (widget.descending) order = -order;
      return order;
    });
    return entries;
  }

  void _refresh() => setState(() {
        _listing = _readListing();
        if (_androidTreeUri != null) _androidListing = _readAndroidListing();
      });

  Future<void> _chooseAnotherFolder() async {
    if (Platform.isAndroid) {
      try {
        final uri = await const MethodChannel('com.omnidrop/direct_radio')
            .invokeMethod<String>('pickStorageDirectory');
        if (uri == null || !mounted) return;
        setState(() {
          _androidTreeUri = uri;
          _androidDocumentStack
            ..clear()
            ..add(null);
          _androidPathLabels
            ..clear()
            ..add('Selected storage');
          _androidListing = _readAndroidListing();
        });
      } on PlatformException catch (error) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(error.message ?? 'Could not open storage picker.')));
        }
      }
      return;
    }
    try {
      final path = await FilePicker.getDirectoryPath(
          dialogTitle: 'Choose a folder to browse');
      if (path != null && mounted) {
        setState(() {
          _root = Directory(path);
          _current = _root;
          _listing = _readListing();
        });
      }
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not open this folder: $error')));
      }
    }
  }

  Future<List<Map<String, dynamic>>> _readAndroidListing() async {
    final treeUri = _androidTreeUri;
    if (treeUri == null) return const [];
    final entries = await const MethodChannel('com.omnidrop/direct_radio')
        .invokeListMethod<Map<dynamic, dynamic>>('listStorageDirectory', {
      'treeUri': treeUri,
      if (_androidDocumentStack.last != null)
        'documentId': _androidDocumentStack.last,
    });
    final result = (entries ?? const <Map<dynamic, dynamic>>[])
        .map((entry) => Map<String, dynamic>.from(entry))
        .where((entry) => widget.showHidden ||
            !(entry['name'] as String).startsWith('.'))
        .toList();
    result.sort((a, b) {
      final aDirectory = a['isDirectory'] == true;
      final bDirectory = b['isDirectory'] == true;
      if (aDirectory != bDirectory) return aDirectory ? -1 : 1;
      final order = widget.sortByDate
          ? (a['modified'] as int).compareTo(b['modified'] as int)
          : (a['name'] as String)
              .toLowerCase()
              .compareTo((b['name'] as String).toLowerCase());
      return widget.descending ? -order : order;
    });
    return result;
  }

  Future<void> _deleteAndroidEntry(Map<String, dynamic> entry) async {
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
              title: const Text('Delete this item?'),
              content: Text('“${entry['name']}” will be deleted from this device.'),
              actions: [
                TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
              ],
            ));
    if (confirmed != true) return;
    try {
      await const MethodChannel('com.omnidrop/direct_radio').invokeMethod<bool>(
          'deleteStorageDocument', {'uri': entry['uri']});
      _refresh();
    } on PlatformException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(error.message ?? 'Could not delete this item.')));
      }
    }
  }

  Future<void> _openAndroidEntry(Map<String, dynamic> entry) async {
    if (entry['isDirectory'] == true) {
      setState(() {
        _androidDocumentStack.add(entry['id'] as String);
        _androidPathLabels.add(entry['name'] as String);
        _androidListing = _readAndroidListing();
      });
      return;
    }
    try {
      await const MethodChannel('com.omnidrop/direct_radio').invokeMethod<void>(
          'openStorageDocument', {'uri': entry['uri']});
    } on PlatformException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(error.message ?? 'Could not open this file.')));
      }
    }
  }

  Widget _androidStorageContents() => FutureBuilder<List<Map<String, dynamic>>>(
        future: _androidListing,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
                child: Text('Cannot open this folder. Access may have changed.\n${snapshot.error}',
                    textAlign: TextAlign.center));
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final entries = snapshot.data!;
          if (entries.isEmpty) return const Center(child: Text('This folder is empty.'));
          return ListView.builder(
            itemCount: entries.length,
            itemBuilder: (context, index) {
              final entry = entries[index];
              final isDirectory = entry['isDirectory'] == true;
              final size = entry['size'] as int? ?? 0;
              return ListTile(
                leading: Icon(isDirectory ? Icons.folder : Icons.insert_drive_file),
                title: Text(entry['name'] as String,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(isDirectory ? 'Folder' : _formatFileSize(size)),
                onTap: () => _openAndroidEntry(entry),
                trailing: PopupMenuButton<String>(
                  tooltip: 'File actions',
                  onSelected: (action) {
                    if (action == 'delete') _deleteAndroidEntry(entry);
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem(value: 'delete', child: Text('Delete')),
                  ],
                ),
              );
            },
          );
        },
      );

  Future<void> _delete(FileSystemEntity entity) async {
    final name = entity.uri.pathSegments.where((part) => part.isNotEmpty).last;
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
              title: const Text('Delete this item?'),
              content: Text('“$name” will be deleted from this device.'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Cancel')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Delete'))
              ],
            ));
    if (confirmed != true) return;
    try {
      await entity.delete(recursive: entity is Directory);
      _refresh();
    } catch (error) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not delete item: $error')));
    }
  }

  Future<void> _openFile(File file) async {
    try {
      final size = await file.length();
      if (size > 1024 * 1024) {
        if (mounted)
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('Preview is limited to text files under 1 MB.')));
        return;
      }
      final content = await file.readAsString();
      if (!mounted) return;
      await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
                title: Text(file.uri.pathSegments.last,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                content: SizedBox(
                    width: 600,
                    child:
                        SingleChildScrollView(child: SelectableText(content))),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Close'))
                ],
              ));
    } on Object {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('This file cannot be previewed as text.')));
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const _Brand(),
          const SizedBox(height: 24),
          Row(children: [
            IconButton(
                onPressed: widget.onBack, icon: const Icon(Icons.arrow_back)),
            Expanded(
                child: Text('File explorer',
                    style: Theme.of(context).textTheme.headlineSmall)),
            IconButton(
                tooltip: Platform.isAndroid
                    ? 'Choose internal or external storage'
                    : 'Choose another folder',
                onPressed: _chooseAnotherFolder,
                icon: const Icon(Icons.folder_open)),
            IconButton(
                tooltip: 'Refresh',
                onPressed: _refresh,
                icon: const Icon(Icons.refresh))
          ]),
          if (_androidTreeUri != null || _current != null)
            Text(_androidTreeUri != null
                    ? (_androidDocumentStack.length == 1
                        ? 'Selected internal or external storage'
                        : _androidPathLabels.last)
                    : _current!.path,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall),
          Wrap(spacing: 6, children: [
            if (_androidTreeUri != null && _androidDocumentStack.length > 1)
              TextButton.icon(
                  onPressed: () => setState(() {
                        _androidDocumentStack.removeLast();
                        _androidPathLabels.removeLast();
                        _androidListing = _readAndroidListing();
                      }),
                  icon: const Icon(Icons.arrow_upward),
                  label: const Text('Up')),
            if (_androidTreeUri == null && _current != null &&
                _root != null &&
                _current!.path != _root!.path)
              TextButton.icon(
                  onPressed: () {
                    final parent = _current!.parent;
                    if (parent.path.length >= _root!.path.length) {
                      _current = parent;
                      _refresh();
                    }
                  },
                  icon: const Icon(Icons.arrow_upward),
                  label: const Text('Up')),
            FilterChip(
                label: const Text('Show hidden'),
                selected: widget.showHidden,
                onSelected: widget.onHiddenChanged),
            TextButton.icon(
                onPressed: () =>
                    widget.onSortChanged(false, !widget.descending),
                icon: const Icon(Icons.sort_by_alpha),
                label: const Text('Name')),
            TextButton.icon(
                onPressed: () => widget.onSortChanged(true, !widget.descending),
                icon: const Icon(Icons.schedule),
                label: const Text('Date')),
            if (widget.clipboardPath != null && _current != null)
              TextButton.icon(
                  onPressed: () => widget.onPaste(_current!),
                  icon: const Icon(Icons.content_paste),
                  label: Text(widget.clipboardIsCut ? 'Move here' : 'Paste')),
          ]),
          Expanded(
              child: _androidTreeUri != null
                  ? _androidStorageContents()
                  : _current == null
                  ? Center(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                      const Text(
                          'Choose a download folder to browse its files.'),
                      const SizedBox(height: 8),
                      FilledButton.icon(
                          onPressed: _chooseAnotherFolder,
                          icon: const Icon(Icons.folder_open),
                          label: const Text('Choose folder'))
                    ]))
                  : FutureBuilder<List<FileSystemEntity>>(
                      future: _listing,
                      builder: (context, snapshot) {
                        if (snapshot.hasError)
                          return Center(
                              child: Text(
                                  'Cannot open this folder. Check folder access.\n${snapshot.error}',
                                  textAlign: TextAlign.center));
                        if (!snapshot.hasData)
                          return const Center(
                              child: CircularProgressIndicator());
                        final entries = snapshot.data!;
                        if (entries.isEmpty)
                          return const Center(
                              child: Text('This folder is empty.'));
                        return ListView.builder(
                            itemCount: entries.length,
                            itemBuilder: (context, index) {
                              final entity = entries[index];
                              final isDirectory = entity is Directory;
                              final name = entity.uri.pathSegments
                                  .where((part) => part.isNotEmpty)
                                  .last;
                              return ListTile(
                                leading: Icon(isDirectory
                                    ? Icons.folder
                                    : Icons.insert_drive_file),
                                title: Text(name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis),
                                subtitle: isDirectory
                                    ? const Text('Folder')
                                    : FutureBuilder<int>(
                                        future: (entity as File).length(),
                                        builder: (context, size) => Text(
                                            size.hasData
                                                ? _formatFileSize(size.data!)
                                                : 'File')),
                                onTap: isDirectory
                                    ? () {
                                        setState(() {
                                          _current = Directory(entity.path);
                                          _listing = _readListing();
                                        });
                                      }
                                    : () => _openFile(entity as File),
                                trailing: PopupMenuButton<String>(
                                    tooltip: 'File actions',
                                    onSelected: (action) {
                                      if (action == 'copy')
                                        widget.onCopy(entity.path, false);
                                      if (action == 'cut')
                                        widget.onCopy(entity.path, true);
                                      if (action == 'delete') _delete(entity);
                                    },
                                    itemBuilder: (context) => [
                                          const PopupMenuItem(
                                              value: 'copy',
                                              child: Text('Copy')),
                                          if (!isDirectory)
                                            const PopupMenuItem(
                                                value: 'cut',
                                                child: Text('Cut')),
                                          const PopupMenuItem(
                                              value: 'delete',
                                              child: Text('Delete'))
                                        ]),
                              );
                            });
                      })),
        ]),
      );
}

String _formatFileSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024)
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

class _RadioCard extends StatelessWidget {
  const _RadioCard({required this.capability});
  final RadioCapability capability;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final (icon, color, label) = switch (capability.support) {
      RadioSupport.supported => (
          Icons.check_circle_outline,
          primary,
          'Supported'
        ),
      RadioSupport.unsupported => (
          Icons.block_outlined,
          Colors.orangeAccent,
          'Not supported'
        ),
      RadioSupport.unavailable => (
          Icons.warning_amber_rounded,
          Colors.orangeAccent,
          'Unavailable'
        ),
      RadioSupport.unknown => (
          Icons.help_outline,
          Theme.of(context).colorScheme.onSurfaceVariant,
          'Not checked'
        ),
    };
    return Card(
      child: ListTile(
        minVerticalPadding: 14,
        leading: Icon(icon, color: color, size: 28),
        title: Text(capability.name),
        subtitle: Padding(
            padding: const EdgeInsets.only(top: 5),
            child: Text(capability.message)),
        trailing: Text(label, style: TextStyle(color: color, fontSize: 12)),
      ),
    );
  }
}
