import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';
import 'constants.dart';
import 'services/file_service.dart';
import 'services/settings_service.dart';
import 'providers/editor_provider.dart';
import 'screens/main_screen.dart';
import 'theme/desktop_theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await windowManager.ensureInitialized();

  final settingsService = SettingsService();
  await settingsService.init();

  // Set default save location on first launch
  if (settingsService.defaultSaveLocation.isEmpty) {
    final userProfile = Platform.environment['USERPROFILE'];
    if (userProfile != null) {
      final scribDir = Directory('$userProfile\\Desktop\\Scrib');
      try {
        if (!await scribDir.exists()) {
          await scribDir.create(recursive: true);
        }
        await settingsService.setDefaultSaveLocation(scribDir.path);
      } catch (_) {
        // Silently fail if desktop path doesn't exist
      }
    }
  }

  final fileService = FileService();
  final editorProvider = EditorProvider(fileService, settingsService);

  final windowOptions = WindowOptions(
    size: Size(settingsService.windowWidth, settingsService.windowHeight),
    center: settingsService.windowX == null,
    title: '$appName - $appTagline',
    minimumSize: const Size(480, 360),
    backgroundColor: const Color(0xFF0D0D0D),
    titleBarStyle: TitleBarStyle.normal,
  );

  windowManager.waitUntilReadyToShow(windowOptions, () async {
    if (settingsService.windowX != null && settingsService.windowY != null) {
      await windowManager.setPosition(
        Offset(settingsService.windowX!, settingsService.windowY!),
      );
    }
    await windowManager.show();
    await windowManager.focus();
    if (settingsService.windowMaximized) {
      await windowManager.maximize();
    }
  });

  runApp(ScribDesktopApp(
    settingsService: settingsService,
    editorProvider: editorProvider,
    fileService: fileService,
  ));
}

class ScribDesktopApp extends StatefulWidget {
  final SettingsService settingsService;
  final EditorProvider editorProvider;
  final FileService fileService;

  const ScribDesktopApp({
    super.key,
    required this.settingsService,
    required this.editorProvider,
    required this.fileService,
  });

  @override
  State<ScribDesktopApp> createState() => _ScribDesktopAppState();
}

class _ScribDesktopAppState extends State<ScribDesktopApp> with WindowListener {
  final _navigatorKey = GlobalKey<NavigatorState>();
  Timer? _windowSaveDebounce;
  int _lastEffectiveAccent = -1;
  String _lastWindowTitle = '';

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    windowManager.setPreventClose(true);

    widget.settingsService.addListener(_onSettingsChanged);
    widget.editorProvider.addListener(_onEditorChanged);
  }

  @override
  void dispose() {
    _windowSaveDebounce?.cancel();
    windowManager.removeListener(this);
    widget.settingsService.removeListener(_onSettingsChanged);
    widget.editorProvider.removeListener(_onEditorChanged);
    super.dispose();
  }

  void _onSettingsChanged() {
    setState(() {});
  }

  void _onEditorChanged() {
    final tab = widget.editorProvider.activeTab;
    final title = tab != null
        ? '${tab.fileName}${tab.isDirty ? ' *' : ''} - $appName'
        : '$appName - $appTagline';

    // Skip platform channel call if title hasn't changed
    if (title != _lastWindowTitle) {
      _lastWindowTitle = title;
      windowManager.setTitle(title);
    }

    // Only rebuild theme if effective accent color changed
    final effectiveAccent = tab?.colorIndex
        ?? widget.settingsService.accentColorIndex;
    if (effectiveAccent != _lastEffectiveAccent) {
      _lastEffectiveAccent = effectiveAccent;
      setState(() {});
    }
  }

  @override
  void onWindowClose() async {
    if (widget.editorProvider.hasUnsavedChanges) {
      final context = _navigatorKey.currentContext;
      if (context != null) {
        final result = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Unsaved Changes'),
            content: const Text('You have unsaved changes. Discard and quit?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Discard & Quit'),
              ),
            ],
          ),
        );
        if (result != true) return;
      }
    }

    // Detach all listeners before destroy to prevent cascading
    // rebuilds/title-updates during shutdown
    _windowSaveDebounce?.cancel();
    widget.settingsService.removeListener(_onSettingsChanged);
    widget.editorProvider.removeListener(_onEditorChanged);
    windowManager.removeListener(this);

    await windowManager.destroy();
  }

  void _debouncedSaveWindowState() {
    _windowSaveDebounce?.cancel();
    _windowSaveDebounce = Timer(const Duration(milliseconds: 500), () async {
      final isMaximized = await windowManager.isMaximized();
      if (!isMaximized) {
        final size = await windowManager.getSize();
        final position = await windowManager.getPosition();
        await widget.settingsService.saveWindowState(
          width: size.width,
          height: size.height,
          x: position.dx,
          y: position.dy,
          maximized: false,
        );
      }
    });
  }

  @override
  void onWindowResized() => _debouncedSaveWindowState();

  @override
  void onWindowMoved() => _debouncedSaveWindowState();

  @override
  void onWindowMaximize() async {
    final size = await windowManager.getSize();
    final position = await windowManager.getPosition();
    await widget.settingsService.saveWindowState(
      width: size.width,
      height: size.height,
      x: position.dx,
      y: position.dy,
      maximized: true,
    );
  }

  @override
  void onWindowUnmaximize() => _debouncedSaveWindowState();

  @override
  Widget build(BuildContext context) {
    final settings = widget.settingsService;

    ThemeMode themeMode;
    switch (settings.themeMode) {
      case 1:
        themeMode = ThemeMode.light;
        break;
      case 2:
        themeMode = ThemeMode.dark;
        break;
      default:
        themeMode = ThemeMode.system;
    }

    // Theme accent follows active tab's color, falls back to global setting
    final effectiveAccent = widget.editorProvider.activeTab?.colorIndex
        ?? settings.accentColorIndex;

    return MultiProvider(
      providers: [
        Provider<FileService>.value(value: widget.fileService),
        ChangeNotifierProvider<SettingsService>.value(value: settings),
        ChangeNotifierProvider<EditorProvider>.value(value: widget.editorProvider),
      ],
      child: MaterialApp(
        navigatorKey: _navigatorKey,
        title: appName,
        debugShowCheckedModeBanner: false,
        theme: ScribTheme.lightTheme(accentColorIndex: effectiveAccent),
        darkTheme: ScribTheme.darkTheme(accentColorIndex: effectiveAccent),
        themeMode: themeMode,
        home: const MainScreen(),
      ),
    );
  }
}
