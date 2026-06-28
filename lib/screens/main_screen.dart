import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart' show ChangeSource, QuillController;
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:desktop_drop/desktop_drop.dart';
import '../dialogs/about_dialog.dart';
import '../dialogs/confirm_dialog.dart';
import '../dialogs/password_dialog.dart';
import '../dialogs/shortcuts_dialog.dart';
import '../providers/editor_provider.dart';
import '../services/file_operations.dart';
import '../services/file_service.dart';
import '../services/rtf_service.dart';
import '../services/settings_service.dart';
import '../widgets/tab_bar_widget.dart';
import '../widgets/editor_widget.dart';
import '../widgets/formatting_toolbar_widget.dart';
import '../widgets/status_bar_widget.dart';
import '../widgets/toolbar_widget.dart';
import '../widgets/search_bar_widget.dart';
import '../widgets/global_search_widget.dart';

/// Extensions Scrib can open. Shared by the file picker and drag-and-drop so
/// both accept exactly the same set.
const List<String> kOpenableExtensions = [
  'txt', 'scrb', 'rtf', 'md', 'log', 'csv', 'json', 'xml', 'yaml', 'yml', 'ini', 'cfg',
];

/// Main Scrib Desktop screen. Delegates dialogs to [dialogs/] and the
/// save/save-as decision tree to [FileOperations].
class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  bool _isDragging = false;
  String? _processingMessage; // non-null → show loading overlay
  final _editorKey = GlobalKey<ScribEditorState>();

  /// The active tab's QuillController (null in plain-text mode). Published by
  /// ScribEditor so the formatting toolbar and find bar can react without a
  /// post-frame setState round-trip on the whole screen.
  final ValueNotifier<QuillController?> _activeQuill = ValueNotifier(null);

  @override
  void dispose() {
    _activeQuill.dispose();
    super.dispose();
  }

  FileOperations get _fileOps => FileOperations(
        context.read<FileService>(),
        context.read<SettingsService>(),
      );

  void _setProcessing(String? message) {
    if (!mounted) return;
    setState(() => _processingMessage = message);
  }

  /// Whether [path]'s extension is one Scrib can open (used to filter drops).
  static bool _isSupportedOpenPath(String path) {
    final dot = path.lastIndexOf('.');
    if (dot == -1 || dot == path.length - 1) return false;
    return kOpenableExtensions.contains(path.substring(dot + 1).toLowerCase());
  }

  @override
  Widget build(BuildContext context) {
    final showSearch = context.select<EditorProvider, bool>((e) => e.showSearch);
    final showGlobalSearch = context.select<EditorProvider, bool>((e) => e.showGlobalSearch);
    context.select<EditorProvider, int>((e) => e.activeTabIndex);
    final activeMode = context.select<EditorProvider, EditorMode?>((e) => e.activeTab?.mode);
    context.select<EditorProvider, bool>((e) => e.activeTab?.isEncrypted ?? false);
    final colorScheme = Theme.of(context).colorScheme;

    return CallbackShortcuts(
      bindings: _buildShortcuts(context),
      child: Focus(
        autofocus: true,
        child: DropTarget(
          onDragEntered: (_) => setState(() => _isDragging = true),
          onDragExited: (_) => setState(() => _isDragging = false),
          onDragDone: (details) {
            setState(() => _isDragging = false);
            bool rejectedAny = false;
            for (final file in details.files) {
              final path = file.path;
              if (FileSystemEntity.isDirectorySync(path)) {
                rejectedAny = true;
                continue;
              }
              if (!_isSupportedOpenPath(path)) {
                rejectedAny = true;
                continue;
              }
              _openFilePath(context, path);
            }
            if (rejectedAny && context.mounted) {
              _showSnack(context, 'Some items were skipped (only text files can be opened).');
            }
          },
          child: Scaffold(
            body: Stack(
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildMenuBar(context),
                    ScribToolbar(
                      onOpenFile: () => _openFileDialog(context),
                      onSaveFile: () => _saveFile(context),
                      onSaveFileAs: () => _saveFileAs(context),
                      onToggleMode: () => _confirmToggleEditorMode(context),
                      onToggleEncryption: () => _toggleEncryption(context),
                    ),
                    ScribTabBar(
                      onCloseTab: (index) => _closeTabByIndex(context, index),
                      onRenameTab: (index, newName) => _renameTab(context, index, newName),
                      onCloseOthers: (index) => _closeOtherTabs(context, index),
                      onCloseToRight: (index) => _closeTabsToRight(context, index),
                      onCloseAll: () => _closeAllTabs(context),
                    ),
                    const Divider(height: 1),
                    if (showGlobalSearch) const GlobalSearchPanel(),
                    if (showSearch)
                      ValueListenableBuilder<QuillController?>(
                        valueListenable: _activeQuill,
                        builder: (context, quillCtrl, _) =>
                            ScribSearchBar(quillController: quillCtrl),
                      ),
                    if (activeMode == EditorMode.richText)
                      ValueListenableBuilder<QuillController?>(
                        valueListenable: _activeQuill,
                        builder: (context, quillCtrl, _) => quillCtrl == null
                            ? const SizedBox.shrink()
                            : ScribFormattingToolbar(controller: quillCtrl),
                      ),
                    Expanded(
                      child: ScribEditor(
                        key: _editorKey,
                        activeQuillNotifier: _activeQuill,
                      ),
                    ),
                    const ScribStatusBar(),
                  ],
                ),
                if (_isDragging)
                  Container(
                    color: colorScheme.primary.withValues(alpha: 0.1),
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.file_open, size: 48, color: colorScheme.primary),
                          const SizedBox(height: 12),
                          Text(
                            'Drop file to open',
                            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              color: colorScheme.primary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                if (_processingMessage != null)
                  Container(
                    color: Colors.black54,
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircularProgressIndicator(color: colorScheme.primary),
                          const SizedBox(height: 16),
                          Text(
                            _processingMessage!,
                            style: const TextStyle(color: Colors.white70, fontSize: 14),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Map<ShortcutActivator, VoidCallback> _buildShortcuts(BuildContext context) {
    final editor = context.read<EditorProvider>();
    return {
      const SingleActivator(LogicalKeyboardKey.keyN, control: true): () => editor.addNewTab(),
      const SingleActivator(LogicalKeyboardKey.keyO, control: true): () => _openFileDialog(context),
      const SingleActivator(LogicalKeyboardKey.keyS, control: true): () => _saveFile(context),
      const SingleActivator(LogicalKeyboardKey.keyS, control: true, shift: true): () => _saveFileAs(context),
      const SingleActivator(LogicalKeyboardKey.keyW, control: true): () => _closeCurrentTab(context),
      const SingleActivator(LogicalKeyboardKey.keyF, control: true): () => editor.openFind(),
      const SingleActivator(LogicalKeyboardKey.keyH, control: true): () => editor.openFindReplace(),
      const SingleActivator(LogicalKeyboardKey.keyF, control: true, shift: true): () => editor.toggleGlobalSearch(),
      const SingleActivator(LogicalKeyboardKey.keyY, control: true): () {
        final tab = editor.activeTab;
        if (tab == null) return;
        final quillCtrl = _activeQuill.value;
        if (tab.mode == EditorMode.richText && quillCtrl != null) {
          quillCtrl.redo();
        } else {
          tab.undoController.redo();
        }
      },
      const SingleActivator(LogicalKeyboardKey.keyE, control: true): () => _toggleEncryption(context),
      const SingleActivator(LogicalKeyboardKey.tab, control: true): () => _nextTab(context),
      const SingleActivator(LogicalKeyboardKey.tab, control: true, shift: true): () => _prevTab(context),
      const SingleActivator(LogicalKeyboardKey.keyM, control: true): () { _confirmToggleEditorMode(context); },
      const SingleActivator(LogicalKeyboardKey.equal, control: true): () => _zoomIn(context),
      const SingleActivator(LogicalKeyboardKey.minus, control: true): () => _zoomOut(context),
      const SingleActivator(LogicalKeyboardKey.digit0, control: true): () => _resetZoom(context),
      const SingleActivator(LogicalKeyboardKey.escape): () {
        if (editor.showGlobalSearch) {
          editor.toggleGlobalSearch();
        } else if (editor.showSearch) {
          editor.closeSearch();
        }
      },
      const SingleActivator(LogicalKeyboardKey.f1): () => showShortcutsDialog(context),
    };
  }

  Widget _buildMenuBar(BuildContext context) {
    final editor = context.read<EditorProvider>();
    final themeMode = context.select<SettingsService, int>((s) => s.themeMode);
    final autoSaveOn = context.select<SettingsService, bool>((s) => s.autoSaveInterval > 0);
    final lineNumbersOn = context.select<SettingsService, bool>((s) => s.showLineNumbers);
    final isEncryptedForMenu = context.select<EditorProvider, bool>((e) => e.activeTab?.isEncrypted ?? false);
    final activeMode = context.select<EditorProvider, EditorMode?>((e) => e.activeTab?.mode);
    final settings = context.read<SettingsService>();

    return MenuBar(
      children: [
        SubmenuButton(
          menuChildren: [
            MenuItemButton(
              shortcut: const SingleActivator(LogicalKeyboardKey.keyN, control: true),
              onPressed: () => editor.addNewTab(),
              child: const Text('New'),
            ),
            MenuItemButton(
              shortcut: const SingleActivator(LogicalKeyboardKey.keyO, control: true),
              onPressed: () => _openFileDialog(context),
              child: const Text('Open...'),
            ),
            SubmenuButton(
              menuChildren: [
                ...settings.recentFiles.map((path) => MenuItemButton(
                  onPressed: () => _openFilePath(context, path),
                  child: Text(
                    path.length > 60 ? '...${path.substring(path.length - 57)}' : path,
                    style: const TextStyle(fontSize: 12),
                  ),
                )),
                if (settings.recentFiles.isEmpty)
                  const MenuItemButton(onPressed: null, child: Text('No recent files')),
                if (settings.recentFiles.isNotEmpty) ...[
                  const Divider(),
                  MenuItemButton(
                    onPressed: () => settings.clearRecentFiles(),
                    child: const Text('Clear Recent'),
                  ),
                ],
              ],
              child: const Text('Recent Files'),
            ),
            const Divider(),
            MenuItemButton(
              shortcut: const SingleActivator(LogicalKeyboardKey.keyS, control: true),
              onPressed: () => _saveFile(context),
              child: const Text('Save'),
            ),
            MenuItemButton(
              shortcut: const SingleActivator(LogicalKeyboardKey.keyS, control: true, shift: true),
              onPressed: () => _saveFileAs(context),
              child: const Text('Save As...'),
            ),
            const Divider(),
            MenuItemButton(
              onPressed: () => _showSaveLocationPicker(context),
              child: const Text('Set Save Location...'),
            ),
            const Divider(),
            MenuItemButton(
              shortcut: const SingleActivator(LogicalKeyboardKey.keyW, control: true),
              onPressed: () => _closeCurrentTab(context),
              child: const Text('Close Tab'),
            ),
          ],
          child: const Text('File'),
        ),
        SubmenuButton(
          menuChildren: [
            MenuItemButton(
              shortcut: const SingleActivator(LogicalKeyboardKey.keyZ, control: true),
              onPressed: () {
                final tab = editor.activeTab;
                if (tab == null) return;
                final quillCtrl = _activeQuill.value;
                if (activeMode == EditorMode.richText && quillCtrl != null) {
                  quillCtrl.undo();
                } else {
                  tab.undoController.undo();
                }
              },
              child: const Text('Undo'),
            ),
            MenuItemButton(
              shortcut: const SingleActivator(LogicalKeyboardKey.keyZ, control: true, shift: true),
              onPressed: () {
                final tab = editor.activeTab;
                if (tab == null) return;
                final quillCtrl = _activeQuill.value;
                if (activeMode == EditorMode.richText && quillCtrl != null) {
                  quillCtrl.redo();
                } else {
                  tab.undoController.redo();
                }
              },
              child: const Text('Redo'),
            ),
            const Divider(),
            MenuItemButton(
              shortcut: const SingleActivator(LogicalKeyboardKey.keyX, control: true),
              onPressed: () {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  Actions.maybeInvoke(
                    primaryFocus?.context ?? context,
                    const CopySelectionTextIntent.cut(SelectionChangedCause.keyboard),
                  );
                });
              },
              child: const Text('Cut'),
            ),
            MenuItemButton(
              shortcut: const SingleActivator(LogicalKeyboardKey.keyC, control: true),
              onPressed: () {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  Actions.maybeInvoke(
                    primaryFocus?.context ?? context,
                    CopySelectionTextIntent.copy,
                  );
                });
              },
              child: const Text('Copy'),
            ),
            MenuItemButton(
              shortcut: const SingleActivator(LogicalKeyboardKey.keyV, control: true),
              onPressed: () {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  Actions.maybeInvoke(
                    primaryFocus?.context ?? context,
                    const PasteTextIntent(SelectionChangedCause.keyboard),
                  );
                });
              },
              child: const Text('Paste'),
            ),
            const Divider(),
            MenuItemButton(
              shortcut: const SingleActivator(LogicalKeyboardKey.keyA, control: true),
              onPressed: () {
                final quillCtrl = _activeQuill.value;
                if (activeMode == EditorMode.richText && quillCtrl != null) {
                  quillCtrl.updateSelection(
                    TextSelection(
                      baseOffset: 0,
                      extentOffset: quillCtrl.document.length - 1,
                    ),
                    ChangeSource.local,
                  );
                } else {
                  final ctrl = editor.activeTab?.controller;
                  if (ctrl != null) {
                    ctrl.selection = TextSelection(
                      baseOffset: 0,
                      extentOffset: ctrl.text.length,
                    );
                  }
                }
              },
              child: const Text('Select All'),
            ),
            const Divider(),
            MenuItemButton(
              shortcut: const SingleActivator(LogicalKeyboardKey.keyF, control: true),
              onPressed: () => editor.openFind(),
              child: const Text('Find...'),
            ),
            MenuItemButton(
              shortcut: const SingleActivator(LogicalKeyboardKey.keyH, control: true),
              onPressed: () => editor.openFindReplace(),
              child: const Text('Find & Replace...'),
            ),
            MenuItemButton(
              shortcut: const SingleActivator(LogicalKeyboardKey.keyF, control: true, shift: true),
              onPressed: () => editor.toggleGlobalSearch(),
              child: const Text('Search All Tabs...'),
            ),
          ],
          child: const Text('Edit'),
        ),
        SubmenuButton(
          menuChildren: [
            MenuItemButton(
              shortcut: const SingleActivator(LogicalKeyboardKey.equal, control: true),
              onPressed: activeMode != EditorMode.richText ? () => _zoomIn(context) : null,
              child: const Text('Increase Text Size'),
            ),
            MenuItemButton(
              shortcut: const SingleActivator(LogicalKeyboardKey.minus, control: true),
              onPressed: activeMode != EditorMode.richText ? () => _zoomOut(context) : null,
              child: const Text('Decrease Text Size'),
            ),
            MenuItemButton(
              shortcut: const SingleActivator(LogicalKeyboardKey.digit0, control: true),
              onPressed: activeMode != EditorMode.richText ? () => _resetZoom(context) : null,
              child: const Text('Default Text Size'),
            ),
            const Divider(),
            MenuItemButton(
              onPressed: () => settings.setShowLineNumbers(!lineNumbersOn),
              leadingIcon: lineNumbersOn
                  ? const Icon(Icons.check, size: 16)
                  : const SizedBox(width: 16),
              child: const Text('Line Numbers'),
            ),
            MenuItemButton(
              onPressed: () => settings.setAutoSaveInterval(autoSaveOn ? 0 : 30),
              leadingIcon: autoSaveOn
                  ? const Icon(Icons.check, size: 16)
                  : const SizedBox(width: 16),
              child: const Text('Auto-Save'),
            ),
            const Divider(),
            SubmenuButton(
              menuChildren: [
                MenuItemButton(
                  onPressed: () => settings.setThemeMode(0),
                  leadingIcon: themeMode == 0
                      ? const Icon(Icons.check, size: 16)
                      : const SizedBox(width: 16),
                  child: const Text('System'),
                ),
                MenuItemButton(
                  onPressed: () => settings.setThemeMode(1),
                  leadingIcon: themeMode == 1
                      ? const Icon(Icons.check, size: 16)
                      : const SizedBox(width: 16),
                  child: const Text('Light'),
                ),
                MenuItemButton(
                  onPressed: () => settings.setThemeMode(2),
                  leadingIcon: themeMode == 2
                      ? const Icon(Icons.check, size: 16)
                      : const SizedBox(width: 16),
                  child: const Text('Dark'),
                ),
              ],
              child: const Text('Theme'),
            ),
          ],
          child: const Text('View'),
        ),
        SubmenuButton(
          menuChildren: [
            MenuItemButton(
              shortcut: const SingleActivator(LogicalKeyboardKey.keyE, control: true),
              onPressed: () => _toggleEncryption(context),
              child: Text(isEncryptedForMenu ? 'Decrypt File' : 'Encrypt File'),
            ),
          ],
          child: const Text('Security'),
        ),
        SubmenuButton(
          menuChildren: [
            MenuItemButton(
              shortcut: const SingleActivator(LogicalKeyboardKey.f1),
              onPressed: () => showShortcutsDialog(context),
              child: const Text('Keyboard Shortcuts'),
            ),
            MenuItemButton(
              onPressed: () => showScribAbout(context),
              child: const Text('About Scrib'),
            ),
          ],
          child: const Text('Help'),
        ),
      ],
    );
  }

  // ── File operations ──────────────────────────────────────────────────────

  Future<void> _openFileDialog(BuildContext context) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: kOpenableExtensions,
      allowMultiple: true,
    );
    if (result == null || !context.mounted) return;
    for (final file in result.files) {
      if (file.path != null) await _openFilePath(context, file.path!);
    }
  }

  Future<void> _openFilePath(BuildContext context, String path) async {
    final editor = context.read<EditorProvider>();
    final ext = path.split('.').last.toLowerCase();

    if (ext == 'scrb') {
      final password = await showPasswordPrompt(
        context,
        title: 'Enter Password',
        message: 'This file is encrypted.',
      );
      if (password == null || password.isEmpty) return;
      if (!context.mounted) return;
      _setProcessing('Decrypting...');
      try {
        final success = await editor.openScrbFile(path, password);
        if (!success && context.mounted) {
          _showSnack(context, 'Wrong password or corrupt file');
        }
      } on ScribFileReadException {
        if (context.mounted) _showSnack(context, 'Could not read file');
      } catch (_) {
        if (context.mounted) _showSnack(context, 'Could not open encrypted file');
      } finally {
        _setProcessing(null);
      }
      return;
    }

    if (ext == 'rtf') {
      try {
        final fileService = context.read<FileService>();
        final rtfContent = await fileService.readRtfFile(path);
        final deltaJson = RtfService.rtfToDelta(rtfContent);
        await editor.openRtfFile(path, deltaJson);
      } on ScribFileReadException {
        if (context.mounted) _showSnack(context, 'Could not read RTF file');
      } catch (_) {
        if (context.mounted) _showSnack(context, 'Could not open RTF file');
      }
      return;
    }

    try {
      await editor.openFile(path);
    } on ScribNeedsPasswordException catch (e) {
      if (!context.mounted) return;
      final password = await showPasswordPrompt(
        context,
        title: 'Enter Password',
        message: '${e.fileName} is encrypted.',
      );
      if (password == null || password.isEmpty || !context.mounted) return;
      final success = await editor.openScrbFile(e.path, password);
      if (!success && context.mounted) {
        _showSnack(context, 'Wrong password or corrupt file');
      }
    } on ScribFileReadException {
      if (context.mounted) _showSnack(context, 'Could not read file');
    } catch (_) {
      if (context.mounted) _showSnack(context, 'Could not open file');
    }
  }

  Future<void> _saveFile(BuildContext context) async {
    final editor = context.read<EditorProvider>();
    final tab = editor.activeTab;
    if (tab == null) return;

    if (tab.filePath == null) {
      await _saveFileAs(context);
      return;
    }

    String? password;
    // Pre-flight: if we need a password and the tab doesn't have one, prompt.
    if (tab.isEncrypted && tab.password == null) {
      password = await showSetPasswordDialog(context);
      if (password == null) return;
      if (!context.mounted) return;
    }

    final isEncryptedSave = tab.isEncrypted;
    _setProcessing(isEncryptedSave ? 'Encrypting...' : null);

    try {
      final result = await _fileOps.saveActive(
        editor,
        passwordForNewEncryption: password,
      );
      if (!result.ok) {
        if (context.mounted) _showSnack(context, 'Could not save file');
        return;
      }
      if (result.extensionChanged && context.mounted && result.newPath != null) {
        final newName = result.newPath!.split(Platform.pathSeparator).last;
        _showSnack(context, 'Saved as $newName');
      }
      if (result.warning != null && context.mounted) {
        _showSnack(context, result.warning!);
      }
    } finally {
      _setProcessing(null);
    }
  }

  Future<void> _saveFileAs(BuildContext context) async {
    final editor = context.read<EditorProvider>();
    final tab = editor.activeTab;
    if (tab == null) return;

    bool processing = false;
    try {
      final result = await _fileOps.saveAs(
        editor,
        resolvePassword: () async {
          if (!context.mounted) return null;
          return showSetPasswordDialog(context);
        },
      );
      if (!result.ok) {
        if (result.error != null && result.error != 'Cancelled' && context.mounted) {
          _showSnack(context, 'Could not save file');
        }
        return;
      }
      // Surface encryption progress indicator only for actual .scrb writes.
      if (tab.isEncrypted) processing = true;
    } finally {
      if (processing) _setProcessing(null);
    }
  }

  Future<void> _renameTab(BuildContext context, int index, String newName) async {
    final editor = context.read<EditorProvider>();
    final settings = context.read<SettingsService>();
    if (index < 0 || index >= editor.tabs.length) return;
    final tab = editor.tabs[index];

    if (tab.filePath != null) {
      final oldPath = tab.filePath!;
      final sep = oldPath.lastIndexOf(Platform.pathSeparator);
      final dir = sep > 0 ? oldPath.substring(0, sep) : '.';
      final ext = oldPath.split('.').last;
      final newPath = '$dir${Platform.pathSeparator}$newName.$ext';

      // Check for overwrite — never silently clobber another file.
      if (await File(newPath).exists() && newPath != oldPath) {
        if (!context.mounted) return;
        final overwrite = await showScribConfirm(
          context,
          title: 'Replace File?',
          message: 'A file named "$newName.$ext" already exists in this folder. Replace it?',
          confirmLabel: 'Replace',
        );
        if (!overwrite) return;
      }

      try {
        await File(oldPath).rename(newPath);
        // Re-lookup by identity in case any other op shifted tabs during the await.
        final currentIndex = editor.tabs.indexOf(tab);
        if (currentIndex != -1) editor.updateTabFile(currentIndex, newPath);
      } catch (_) {
        if (context.mounted) _showSnack(context, 'Could not rename file');
      }
    } else {
      final defaultDir = settings.defaultSaveLocation;
      if (defaultDir.isNotEmpty) {
        final dir = Directory(defaultDir);
        if (!await dir.exists()) await dir.create(recursive: true);

        final ext = tab.isEncrypted ? 'scrb' : 'txt';
        final path = '$defaultDir${Platform.pathSeparator}$newName.$ext';

        if (tab.isEncrypted && tab.password == null) {
          if (!context.mounted) return;
          final password = await showSetPasswordDialog(context);
          if (password == null) {
            editor.renameTab(index, newName);
            return;
          }
          tab.password = password;
        }

        final currentIndex = editor.tabs.indexOf(tab);
        if (currentIndex == -1) return;
        editor.setActiveTab(currentIndex);
        try {
          await editor.saveActiveTabAs(path, encrypted: tab.isEncrypted, password: tab.password);
        } catch (_) {
          if (context.mounted) _showSnack(context, 'Could not save file');
        }
      } else {
        editor.renameTab(index, newName);
      }
    }
  }

  Future<void> _showSaveLocationPicker(BuildContext context) async {
    final settings = context.read<SettingsService>();
    final path = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Choose Default Save Location',
      initialDirectory: settings.defaultSaveLocation.isNotEmpty
          ? settings.defaultSaveLocation
          : null,
    );
    if (path == null || !context.mounted) return;
    await settings.setDefaultSaveLocation(path);
    if (!context.mounted) return;
    _showSnack(context, 'Default save location: $path');
  }

  Future<void> _closeCurrentTab(BuildContext context) async {
    final editor = context.read<EditorProvider>();
    if (editor.activeTab == null) return;
    await _closeTabByIndex(context, editor.activeTabIndex);
  }

  Future<void> _closeTabByIndex(BuildContext context, int index) async {
    final editor = context.read<EditorProvider>();
    if (index < 0 || index >= editor.tabs.length) return;
    final tab = editor.tabs[index];

    if (!tab.isDirty) {
      editor.closeTab(index);
      return;
    }

    // A dirty tab — including an untitled one the user has typed into — must
    // not be dropped silently. Offer Save / Discard / Cancel; the Save branch
    // below routes untitled tabs through Save As.
    final choice = await showUnsavedChangesDialog(context, fileName: tab.fileName);
    if (!mounted || choice == UnsavedChangesChoice.cancel) return;

    if (choice == UnsavedChangesChoice.save) {
      final currentIndex = editor.tabs.indexOf(tab);
      if (currentIndex == -1) return;
      editor.setActiveTab(currentIndex);
      if (tab.filePath != null) {
        try {
          await editor.saveActiveTab();
        } catch (_) {
          if (context.mounted) _showSnack(context, 'Could not save file');
          return;
        }
      } else {
        if (!context.mounted) return;
        await _saveFileAs(context);
        if (tab.isDirty) return;
      }
    }

    // Re-lookup — save/dialog may have shifted tab indices.
    final currentIndex = editor.tabs.indexOf(tab);
    if (currentIndex != -1) editor.closeTab(currentIndex);
  }

  /// Close a set of tabs: clean ones are removed in one pass, dirty ones are
  /// routed through the unsaved-changes prompt one at a time.
  Future<void> _closeTabSet(BuildContext context, List<EditorTab> targets) async {
    final editor = context.read<EditorProvider>();
    final dirty = editor.closeTabs(targets);
    for (final tab in dirty) {
      if (!mounted) return;
      final idx = editor.tabs.indexOf(tab);
      if (idx == -1) continue;
      await _closeTabByIndex(context, idx);
    }
  }

  Future<void> _closeOtherTabs(BuildContext context, int index) async {
    final editor = context.read<EditorProvider>();
    if (index < 0 || index >= editor.tabs.length) return;
    final keep = editor.tabs[index];
    await _closeTabSet(context, editor.tabs.where((t) => t != keep).toList());
  }

  Future<void> _closeTabsToRight(BuildContext context, int index) async {
    final editor = context.read<EditorProvider>();
    if (index < 0 || index >= editor.tabs.length) return;
    await _closeTabSet(context, editor.tabs.sublist(index + 1).toList());
  }

  Future<void> _closeAllTabs(BuildContext context) async {
    final editor = context.read<EditorProvider>();
    await _closeTabSet(context, editor.tabs.toList());
  }

  Future<void> _toggleEncryption(BuildContext context) async {
    final editor = context.read<EditorProvider>();
    final tab = editor.activeTab;
    if (tab == null) return;

    if (!tab.isEncrypted) {
      editor.toggleEncryption();
      final password = await showSetPasswordDialog(context);
      if (password == null || !context.mounted) {
        editor.toggleEncryption(); // revert
        return;
      }
      tab.password = password;
      await _saveFile(context);
    } else {
      editor.toggleEncryption();
    }
  }

  void _nextTab(BuildContext context) {
    final editor = context.read<EditorProvider>();
    if (editor.tabs.length > 1) {
      editor.setActiveTab((editor.activeTabIndex + 1) % editor.tabs.length);
    }
  }

  void _prevTab(BuildContext context) {
    final editor = context.read<EditorProvider>();
    if (editor.tabs.length > 1) {
      editor.setActiveTab((editor.activeTabIndex - 1 + editor.tabs.length) % editor.tabs.length);
    }
  }

  void _zoomIn(BuildContext context) {
    final editor = context.read<EditorProvider>();
    if (editor.activeTab?.mode == EditorMode.richText) return;
    editor.setTabFontSize((editor.activeTab?.tabFontSize ?? 14.0) + 1);
  }

  void _zoomOut(BuildContext context) {
    final editor = context.read<EditorProvider>();
    if (editor.activeTab?.mode == EditorMode.richText) return;
    editor.setTabFontSize((editor.activeTab?.tabFontSize ?? 14.0) - 1);
  }

  void _resetZoom(BuildContext context) {
    final editor = context.read<EditorProvider>();
    if (editor.activeTab?.mode == EditorMode.richText) return;
    editor.setTabFontSize(14.0);
  }

  Future<void> _confirmToggleEditorMode(BuildContext context) async {
    final editor = context.read<EditorProvider>();
    final tab = editor.activeTab;
    if (tab == null) return;

    if (tab.mode == EditorMode.richText) {
      final confirmed = await showScribConfirm(
        context,
        title: 'Switch to Plain Text?',
        message:
            'Switching to Plain Text will remove all formatting '
            '(bold, italic, colors, fonts, etc.). You can revert within this session.',
        confirmLabel: 'Switch to Plain Text',
      );
      if (!confirmed) return;
    }

    editor.toggleEditorMode();

    // Offer a one-step revert via a SnackBar action.
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(tab.mode == EditorMode.richText
            ? 'Switched to Rich Text'
            : 'Switched to Plain Text'),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 6),
        action: SnackBarAction(
          label: 'Revert',
          onPressed: () => editor.revertModeToggle(),
        ),
      ),
    );
  }

  void _showSnack(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}
