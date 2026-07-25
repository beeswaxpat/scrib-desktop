import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';
import 'constants.dart';
import 'services/atomic_write.dart';
import 'services/file_service.dart';
import 'services/settings_service.dart';
import 'providers/editor_provider.dart';
import 'screens/main_screen.dart';
import 'theme/desktop_theme.dart';

/// User's choice in the quit-with-unsaved-changes dialog.
enum _QuitChoice { cancel, discard, save }

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await windowManager.ensureInitialized();

  final settingsService = SettingsService();
  try {
    await settingsService.init();
  } catch (e) {
    // Hive holds an exclusive lock on the settings box, so a second copy of
    // Scrib fails here. Throwing before runApp left a process with no window
    // and no message, which reads as "the app is broken". Tell the user, then
    // exit cleanly instead of lingering invisibly.
    await windowManager.show();
    runApp(_StartupFailureApp(
      message: 'Scrib is already running.\n\n'
          'Only one copy can be open at a time, because they would overwrite '
          "each other's settings. Switch to the open window instead.",
      detail: '$e',
    ));
    return;
  }

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

  // Best-effort recovery of any stranded Scrib-namespaced .scrib-tmp /
  // .scrib-bak files from a prior crash. Safe no-op on clean startup. Beyond
  // the default save location, sweep the directory of every session-restore
  // and recent file: a crash mid-fallback-rename strands the user's content
  // at <path>.scrib-bak wherever that file lives, not only in the save dir.
  final recoverDirs = <String>{};
  if (settingsService.defaultSaveLocation.isNotEmpty) {
    recoverDirs.add(settingsService.defaultSaveLocation);
  }
  String? parentDir(String path) {
    final sep = path.lastIndexOf(Platform.pathSeparator);
    return sep > 0 ? path.substring(0, sep) : null;
  }
  for (final entry in settingsService.sessionTabs) {
    final p = entry['path'];
    if (p is String && p.isNotEmpty) {
      final dir = parentDir(p);
      if (dir != null) recoverDirs.add(dir);
    }
  }
  for (final p in settingsService.recentFiles) {
    final dir = parentDir(p);
    if (dir != null) recoverDirs.add(dir);
  }
  for (final dir in recoverDirs) {
    unawaited(AtomicWrite.recoverIfNeeded(dir));
  }

  final fileService = FileService();
  final editorProvider = EditorProvider(fileService, settingsService);

  // Reopen the previous session's tabs (best-effort, in the background so the
  // window shows immediately). Encrypted files come back as LOCKED tabs —
  // launch never prompts for a password and never decrypts unasked.
  if (settingsService.restoreSession) {
    unawaited(editorProvider.restorePreviousSession());
  }

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
        final result = await showDialog<_QuitChoice>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Unsaved Changes'),
            content: const Text(
              'You have unsaved changes. Save them before quitting?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, _QuitChoice.cancel),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, _QuitChoice.discard),
                child: const Text('Discard & Quit'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, _QuitChoice.save),
                child: const Text('Save & Quit'),
              ),
            ],
          ),
        );
        if (result == null || result == _QuitChoice.cancel) return;
        if (result == _QuitChoice.save) {
          // Save everything we safely can. If anything remains unsaved (an
          // untitled tab, or an encrypted tab with no password), don't quit —
          // surface it so the user can finish rather than lose work.
          final allSaved = await widget.editorProvider.saveAllSaveable();
          if (!allSaved) {
            final c = _navigatorKey.currentContext;
            if (c != null && c.mounted) {
              ScaffoldMessenger.of(c).showSnackBar(
                const SnackBar(
                  content: Text(
                    'Some tabs could not be saved automatically '
                    '(missing filename or password, or a pending format '
                    'change). Save them with Ctrl+S, then quit.',
                  ),
                  behavior: SnackBarBehavior.floating,
                ),
              );
            }
            return;
          }
        }
      }
    }

    // Record the open tabs (paths only — never content or passwords) so the
    // next launch can restore them. With restore off, clear any stored
    // session instead so no record of the workspace persists.
    // Everything from here is shutdown housekeeping. setPreventClose(true) is
    // still in force, so a throw in this tail escapes an `async void` handler
    // and leaves a window that can never be closed: the user's only way out is
    // Task Manager, which loses the very session this block is saving. None of
    // it is worth blocking the quit, so failures are swallowed and the destroy
    // always runs.
    try {
      if (widget.settingsService.restoreSession) {
        await widget.settingsService.saveSession(
          widget.editorProvider.sessionSnapshot(),
          widget.editorProvider.sessionActiveIndex,
        );
      } else {
        await widget.settingsService.clearSession();
      }
    } catch (e) {
      if (kDebugMode) debugPrint('Session save on quit failed: $e');
    }

    // Dispose timers/listeners before destroy so the process exits cleanly.
    try {
      _windowSaveDebounce?.cancel();
      widget.settingsService.removeListener(_onSettingsChanged);
      widget.editorProvider.removeListener(_onEditorChanged);
      windowManager.removeListener(this);
      widget.editorProvider.dispose();
    } catch (e) {
      if (kDebugMode) debugPrint('Teardown on quit failed: $e');
    }

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

/// Minimal window shown when startup fails before the editor can be built.
///
/// A failure in main() before runApp leaves a process with no window at all,
/// which the user experiences as the app silently refusing to open. This gives
/// the failure a face and an OK button.
class _StartupFailureApp extends StatelessWidget {
  final String message;
  final String detail;

  const _StartupFailureApp({required this.message, required this.detail});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: Scaffold(
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Scrib could not start',
                      style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 16),
                  Text(message),
                  const SizedBox(height: 16),
                  if (kDebugMode)
                    Text(detail,
                        style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: 24),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton(
                      onPressed: () => windowManager.destroy(),
                      child: const Text('Close'),
                    ),
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
