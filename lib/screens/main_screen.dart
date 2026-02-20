import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart' show ChangeSource;
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:desktop_drop/desktop_drop.dart';
import '../providers/editor_provider.dart';
import '../services/file_service.dart';
import '../services/rtf_service.dart';
import '../services/settings_service.dart';
import '../widgets/tab_bar_widget.dart';
import '../widgets/editor_widget.dart';
import '../widgets/formatting_toolbar_widget.dart';
import '../widgets/status_bar_widget.dart';
import '../widgets/toolbar_widget.dart';
import '../widgets/search_bar_widget.dart';
import '../constants.dart';

/// Main Scrib Desktop screen - the whole app in one window
class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  bool _isDragging = false;
  String? _processingMessage; // non-null → show loading overlay
  final _editorKey = GlobalKey<ScribEditorState>();

  @override
  Widget build(BuildContext context) {
    // Select only the specific fields MainScreen needs — avoids rebuilding
    // the entire screen (menu bar, toolbar, etc.) on every content debounce.
    final showSearch = context.select<EditorProvider, bool>((e) => e.showSearch);
    // activeTabIndex: triggers rebuild when tabs open/close (needed for editor rerender)
    context.select<EditorProvider, int>((e) => e.activeTabIndex);
    final activeMode = context.select<EditorProvider, EditorMode?>((e) => e.activeTab?.mode);
    // isEncrypted: triggers rebuild so the toolbar's lock icon stays in sync
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
            for (final file in details.files) {
              _openFilePath(context, file.path);
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
                    ),
                    const Divider(height: 1),
                    if (showSearch)
                      ScribSearchBar(
                        quillController: _editorKey.currentState?.quillController,
                      ),
                    if (activeMode == EditorMode.richText)
                      Builder(builder: (context) {
                        final quillCtrl = _editorKey.currentState?.quillController;
                        if (quillCtrl == null) {
                          // Controller not ready yet — schedule a rebuild after the editor creates it
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (mounted) setState(() {});
                          });
                          return const SizedBox.shrink();
                        }
                        return ScribFormattingToolbar(controller: quillCtrl);
                      }),
                    Expanded(
                      child: ScribEditor(key: _editorKey),
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
                // Encryption/decryption progress overlay
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
      const SingleActivator(LogicalKeyboardKey.keyF, control: true): () => editor.toggleSearch(),
      const SingleActivator(LogicalKeyboardKey.keyH, control: true): () => editor.showSearchBar(),
      const SingleActivator(LogicalKeyboardKey.keyE, control: true): () => _toggleEncryption(context),
      const SingleActivator(LogicalKeyboardKey.tab, control: true): () => _nextTab(context),
      const SingleActivator(LogicalKeyboardKey.tab, control: true, shift: true): () => _prevTab(context),
      const SingleActivator(LogicalKeyboardKey.keyM, control: true): () { _confirmToggleEditorMode(context); },
      const SingleActivator(LogicalKeyboardKey.equal, control: true): () => _zoomIn(context),
      const SingleActivator(LogicalKeyboardKey.minus, control: true): () => _zoomOut(context),
      const SingleActivator(LogicalKeyboardKey.digit0, control: true): () => _resetZoom(context),
      const SingleActivator(LogicalKeyboardKey.escape): () {
        if (editor.showSearch) editor.toggleSearch();
      },
    };
  }

  Widget _buildMenuBar(BuildContext context) {
    final editor = context.read<EditorProvider>();
    final themeMode = context.select<SettingsService, int>((s) => s.themeMode);
    final autoSaveOn = context.select<SettingsService, bool>((s) => s.autoSaveInterval > 0);
    // isEncrypted select keeps the Security submenu label ("Encrypt/Decrypt File") in sync
    final isEncryptedForMenu = context.select<EditorProvider, bool>((e) => e.activeTab?.isEncrypted ?? false);
    // activeMode triggers menu rebuild on mode changes (needed for Edit menu behavior)
    final activeMode = context.select<EditorProvider, EditorMode?>((e) => e.activeTab?.mode);
    final settings = context.read<SettingsService>();
    final quillCtrl = _editorKey.currentState?.quillController;

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
                    const CopySelectionTextIntent(SelectionChangedCause.keyboard, collapseSelection: true),
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
                    const CopySelectionTextIntent(SelectionChangedCause.keyboard, collapseSelection: false),
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
              onPressed: () => editor.toggleSearch(),
              child: const Text('Find & Replace'),
            ),
          ],
          child: const Text('Edit'),
        ),
        SubmenuButton(
          menuChildren: [
            MenuItemButton(
              shortcut: const SingleActivator(LogicalKeyboardKey.equal, control: true),
              onPressed: () => _zoomIn(context),
              child: const Text('Increase Text Size'),
            ),
            MenuItemButton(
              shortcut: const SingleActivator(LogicalKeyboardKey.minus, control: true),
              onPressed: () => _zoomOut(context),
              child: const Text('Decrease Text Size'),
            ),
            MenuItemButton(
              shortcut: const SingleActivator(LogicalKeyboardKey.digit0, control: true),
              onPressed: () => _resetZoom(context),
              child: const Text('Default Text Size'),
            ),
            const Divider(),
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
              onPressed: () => _showAbout(context),
              child: const Text('About Scrib'),
            ),
          ],
          child: const Text('Help'),
        ),
      ],
    );
  }

  Future<void> _openFileDialog(BuildContext context) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['txt', 'scrb', 'rtf', 'md', 'log', 'csv', 'json', 'xml', 'yaml', 'yml', 'ini', 'cfg'],
      allowMultiple: true,
    );
    if (result != null && context.mounted) {
      for (final file in result.files) {
        if (file.path != null) await _openFilePath(context, file.path!);
      }
    }
  }

  Future<void> _openFilePath(BuildContext context, String path) async {
    final editor = context.read<EditorProvider>();
    final ext = path.split('.').last.toLowerCase();

    if (ext == 'scrb') {
      final password = await _showPasswordDialog(context, 'Enter Password', 'This file is encrypted.');
      if (password != null && password.isNotEmpty && context.mounted) {
        setState(() => _processingMessage = 'Decrypting...');
        try {
          final success = await editor.openScrbFile(path, password);
          if (!success && context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Wrong password or corrupt file'), behavior: SnackBarBehavior.floating),
            );
          }
        } catch (e) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Could not open encrypted file: $e'), behavior: SnackBarBehavior.floating),
            );
          }
        } finally {
          setState(() => _processingMessage = null);
        }
      }
    } else if (ext == 'rtf') {
      try {
        final fileService = context.read<FileService>();
        final rtfService = RtfService();
        final rtfContent = await fileService.readRtfFile(path);
        final deltaJson = rtfService.rtfToDelta(rtfContent);
        editor.openRtfFile(path, deltaJson);
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not open RTF file: $e'), behavior: SnackBarBehavior.floating),
          );
        }
      }
    } else {
      try {
        await editor.openFile(path);
      } on ScribNeedsPasswordException catch (e) {
        if (!context.mounted) return;
        final password = await _showPasswordDialog(context, 'Enter Password', '${e.fileName} is encrypted.');
        if (password != null && password.isNotEmpty && context.mounted) {
          final success = await editor.openScrbFile(e.path, password);
          if (!success && context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Wrong password or corrupt file'), behavior: SnackBarBehavior.floating),
            );
          }
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not open file: $e'), behavior: SnackBarBehavior.floating),
          );
        }
      }
    }
  }

  Future<void> _saveFile(BuildContext context) async {
    final editor = context.read<EditorProvider>();
    final fileService = context.read<FileService>();
    final tab = editor.activeTab;
    if (tab == null) return;

    if (tab.filePath == null) {
      await _saveFileAs(context);
      return;
    }

    // ── Extension mismatch: encryption state changed since last save ──
    final currentPath = tab.filePath!;
    if (tab.isEncrypted && !currentPath.endsWith('.scrb')) {
      // Was plain/rtf, now encrypted → save to .scrb path
      final newPath = _swapExtension(currentPath, '.scrb');
      if (tab.password == null) {
        final password = await _showSetPasswordDialog(context);
        if (password == null) return;
        tab.password = password;
      }
      setState(() => _processingMessage = 'Encrypting...');
      try {
        await editor.saveActiveTabAs(newPath, encrypted: true, password: tab.password);
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not save file: $e'), behavior: SnackBarBehavior.floating),
          );
        }
      } finally {
        setState(() => _processingMessage = null);
      }
      return;
    }
    if (!tab.isEncrypted && currentPath.endsWith('.scrb')) {
      // Was encrypted, now decrypted → save to .txt (or .rtf)
      final ext = tab.mode == EditorMode.richText ? '.rtf' : '.txt';
      final newPath = _swapExtension(currentPath, ext);
      try {
        if (ext == '.rtf' && tab.deltaJson.isNotEmpty) {
          final rtfService = RtfService();
          final rtfContent = rtfService.deltaToRtf(tab.deltaJson);
          await fileService.writeRtfFile(newPath, rtfContent);
          editor.markTabSavedAs(newPath);
        } else {
          await editor.saveActiveTabAs(newPath);
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not save file: $e'), behavior: SnackBarBehavior.floating),
          );
        }
      }
      return;
    }

    // ── Normal save (extension matches encryption state) ──
    if (tab.isEncrypted && tab.password == null) {
      final password = await _showSetPasswordDialog(context);
      if (password == null) return;
      tab.password = password;
    }

    if (tab.isEncrypted) {
      setState(() => _processingMessage = 'Encrypting...');
    }

    try {
      // RTF files need special conversion
      if (tab.filePath!.endsWith('.rtf') && tab.mode == EditorMode.richText && tab.deltaJson.isNotEmpty) {
        final rtfService = RtfService();
        final rtfContent = rtfService.deltaToRtf(tab.deltaJson);
        await fileService.writeRtfFile(tab.filePath!, rtfContent);
        tab.markSaved();
        editor.onContentChanged();
      } else {
        await editor.saveActiveTab();
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not save file: $e'), behavior: SnackBarBehavior.floating),
        );
      }
    } finally {
      if (_processingMessage != null) {
        setState(() => _processingMessage = null);
      }
    }
  }

  /// Swap the file extension, handling files with or without an existing extension.
  String _swapExtension(String path, String newExt) {
    final dot = path.lastIndexOf('.');
    final sep = path.lastIndexOf(Platform.pathSeparator);
    // Only strip if the dot is after the last separator (i.e. it's a real extension)
    if (dot > sep && dot > 0) {
      return '${path.substring(0, dot)}$newExt';
    }
    return '$path$newExt';
  }

  Future<void> _saveFileAs(BuildContext context) async {
    final editor = context.read<EditorProvider>();
    final settings = context.read<SettingsService>();
    final fileService = context.read<FileService>();
    final tab = editor.activeTab;
    if (tab == null) return;

    String extension;
    if (tab.isEncrypted) {
      extension = 'scrb';
    } else if (tab.mode == EditorMode.richText) {
      extension = 'rtf';
    } else {
      extension = 'txt';
    }
    final defaultName = tab.fileName.endsWith('.$extension')
        ? tab.fileName
        : '${tab.fileName.replaceAll(RegExp(r'\.[^.]+$'), '')}.$extension';

    String? initialDir;
    if (tab.filePath != null) {
      final sep = tab.filePath!.lastIndexOf(Platform.pathSeparator);
      if (sep > 0) initialDir = tab.filePath!.substring(0, sep);
    } else {
      final defaultLoc = settings.defaultSaveLocation;
      if (defaultLoc.isNotEmpty) initialDir = defaultLoc;
    }

    final path = await FilePicker.platform.saveFile(
      dialogTitle: 'Save As',
      fileName: defaultName,
      initialDirectory: initialDir,
      type: FileType.custom,
      allowedExtensions: ['txt', 'scrb', 'rtf'],
    );

    if (path != null && context.mounted) {
      // If the tab is already marked encrypted (e.g. user clicked Encrypt before
      // Save As was called), honour that even if they typed a name without .scrb.
      // Silently append the extension so the file is properly encrypted on disk.
      final effectivePath = (tab.isEncrypted && !path.endsWith('.scrb'))
          ? _swapExtension(path, '.scrb')
          : path;

      final isEncrypted = effectivePath.endsWith('.scrb');
      final isRtf = effectivePath.endsWith('.rtf');
      String? password;
      if (isEncrypted) {
        password = tab.password ?? await _showSetPasswordDialog(context);
        if (password == null) return;
      }

      if (isEncrypted) {
        setState(() => _processingMessage = 'Encrypting...');
      }

      try {
        if (isRtf && tab.mode == EditorMode.richText && tab.deltaJson.isNotEmpty) {
          final rtfService = RtfService();
          final rtfContent = rtfService.deltaToRtf(tab.deltaJson);
          await fileService.writeRtfFile(effectivePath, rtfContent);
          editor.markTabSavedAs(effectivePath);
        } else {
          await editor.saveActiveTabAs(effectivePath, encrypted: isEncrypted, password: password);
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not save file: $e'), behavior: SnackBarBehavior.floating),
          );
        }
      } finally {
        if (_processingMessage != null) {
          setState(() => _processingMessage = null);
        }
      }
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

      try {
        await File(oldPath).rename(newPath);
        editor.updateTabFile(index, newPath);
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not rename: $e'), behavior: SnackBarBehavior.floating),
          );
        }
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
          final password = await _showSetPasswordDialog(context);
          if (password == null) {
            editor.renameTab(index, newName);
            return;
          }
          tab.password = password;
        }

        editor.setActiveTab(index);
        try {
          await editor.saveActiveTabAs(path, encrypted: tab.isEncrypted, password: tab.password);
        } catch (e) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Could not save: $e'), behavior: SnackBarBehavior.floating),
            );
          }
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
    if (path != null) {
      await settings.setDefaultSaveLocation(path);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Default save location: $path'), behavior: SnackBarBehavior.floating),
        );
      }
    }
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
      // Fast path: clean — close immediately
      editor.closeTab(index);
      return;
    }

    if (tab.filePath == null) {
      // Fast path: dirty but never saved to disk — nothing to lose, discard silently
      editor.closeTab(index);
      return;
    }

    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Save Changes?'),
        content: Text('${tab.fileName} has unsaved changes.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, 'discard'), child: const Text('Discard')),
          TextButton(onPressed: () => Navigator.pop(ctx, 'cancel'), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, 'save'), child: const Text('Save')),
        ],
      ),
    );

    if (!mounted || result == 'cancel' || result == null) return;

    if (result == 'save') {
      editor.setActiveTab(index);
      if (tab.filePath != null) {
        try {
          await editor.saveActiveTab();
        } catch (e) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Could not save: $e'), behavior: SnackBarBehavior.floating),
            );
          }
          return;
        }
      } else {
        if (!context.mounted) return;
        await _saveFileAs(context);
        if (tab.isDirty) return;
      }
    }

    // Re-lookup index since save/dialog may have shifted tabs
    final currentIndex = editor.tabs.indexOf(tab);
    if (currentIndex != -1) editor.closeTab(currentIndex);
  }

  Future<void> _toggleEncryption(BuildContext context) async {
    final editor = context.read<EditorProvider>();
    final tab = editor.activeTab;
    if (tab == null) return;

    if (!tab.isEncrypted) {
      // Encrypting: toggle flag, prompt for password, then save immediately
      editor.toggleEncryption(); // sets isEncrypted = true
      final password = await _showSetPasswordDialog(context);
      if (password == null || !context.mounted) {
        // User cancelled → revert
        editor.toggleEncryption();
        return;
      }
      tab.password = password;
      await _saveFile(context);
    } else {
      // Decrypting: toggle flag, save will handle extension swap on next save
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
    editor.setTabFontSize((editor.activeTab?.tabFontSize ?? 14.0) + 1);
  }

  void _zoomOut(BuildContext context) {
    final editor = context.read<EditorProvider>();
    editor.setTabFontSize((editor.activeTab?.tabFontSize ?? 14.0) - 1);
  }

  void _resetZoom(BuildContext context) {
    context.read<EditorProvider>().setTabFontSize(14.0);
  }

  Future<String?> _showPasswordDialog(BuildContext context, String title, String message) async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              obscureText: true,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Password',
                border: OutlineInputBorder(),
                enabledBorder: OutlineInputBorder(),
                focusedBorder: OutlineInputBorder(),
              ),
              onSubmitted: (value) {
                if (value.isNotEmpty) Navigator.pop(ctx, value);
              },
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              if (controller.text.isNotEmpty) Navigator.pop(ctx, controller.text);
            },
            child: const Text('Open'),
          ),
        ],
      ),
    );
    controller.dispose();
    return result;
  }

  Future<String?> _showSetPasswordDialog(BuildContext context) async {
    final controller1 = TextEditingController();
    final controller2 = TextEditingController();
    String? error;

    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Set Encryption Password'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('This password will be required to open the file.'),
              const SizedBox(height: 16),
              TextField(
                controller: controller1,
                obscureText: true,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Password',
                  border: OutlineInputBorder(),
                  enabledBorder: OutlineInputBorder(),
                  focusedBorder: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: controller2,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Confirm Password',
                  border: OutlineInputBorder(),
                  enabledBorder: OutlineInputBorder(),
                  focusedBorder: OutlineInputBorder(),
                ),
                onSubmitted: (_) {
                  if (controller1.text == controller2.text && controller1.text.length >= 4) {
                    Navigator.pop(ctx, controller1.text);
                  }
                },
              ),
              if (error != null) ...[
                const SizedBox(height: 8),
                Text(error!, style: TextStyle(color: Theme.of(ctx).colorScheme.error, fontSize: 12)),
              ],
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                if (controller1.text.isEmpty) {
                  setDialogState(() => error = 'Password cannot be empty');
                  return;
                }
                if (controller1.text.length < 4) {
                  setDialogState(() => error = 'Password must be at least 4 characters');
                  return;
                }
                if (controller1.text != controller2.text) {
                  setDialogState(() => error = 'Passwords do not match');
                  return;
                }
                Navigator.pop(ctx, controller1.text);
              },
              child: const Text('Encrypt'),
            ),
          ],
        ),
      ),
    );
    controller1.dispose();
    controller2.dispose();
    return result;
  }

  Future<void> _confirmToggleEditorMode(BuildContext context) async {
    final editor = context.read<EditorProvider>();
    final tab = editor.activeTab;
    if (tab == null) return;

    if (tab.mode == EditorMode.richText) {
      // Rich → Plain: warn user about formatting loss
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Switch to Plain Text?'),
          content: const Text(
            'Switching to Plain Text will remove all formatting '
            '(bold, italic, colors, fonts, etc.). This cannot be undone.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Switch to Plain Text'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }

    editor.toggleEditorMode();
  }

  void _showAbout(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colorScheme = Theme.of(context).colorScheme;
    final muted = isDark ? const Color(0xFF707070) : const Color(0xFF999999);
    final body = isDark ? const Color(0xFF909090) : const Color(0xFF666666);
    final dividerColor = isDark ? const Color(0xFF2A2A2A) : const Color(0xFFE0E0E0);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        titlePadding: EdgeInsets.zero,
        contentPadding: const EdgeInsets.fromLTRB(28, 20, 28, 8),
        actionsPadding: const EdgeInsets.fromLTRB(28, 0, 28, 16),
        content: SizedBox(
          width: 300,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Logo + name + version
              Row(
                children: [
                  Image.asset('assets/scrib_icon.png', width: 36, height: 36),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Scrib Desktop', style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.3,
                        color: isDark ? const Color(0xFFE0E0E0) : const Color(0xFF1A1A1A),
                      )),
                      const SizedBox(height: 1),
                      Text('v$appVersion', style: TextStyle(
                        fontSize: 11,
                        color: muted,
                        letterSpacing: 0.2,
                      )),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Divider(height: 1, thickness: 0.5, color: dividerColor),
              const SizedBox(height: 14),
              // Tagline
              Align(
                alignment: Alignment.centerLeft,
                child: Text('The encrypted editor.', style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: colorScheme.primary,
                  letterSpacing: 0.2,
                )),
              ),
              const SizedBox(height: 3),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(appTagline, style: TextStyle(
                  fontSize: 11.5,
                  color: muted,
                  letterSpacing: 0.1,
                )),
              ),
              const SizedBox(height: 14),
              // Features
              _aboutRow(Icons.shield_outlined, 'AES-256 encryption + tamper protection', body),
              const SizedBox(height: 5),
              _aboutRow(Icons.description_outlined, 'Plain text, rich text, and .scrb', body),
              const SizedBox(height: 5),
              _aboutRow(Icons.lock_outlined, 'Your files. Your keys. Always.', body),
              const SizedBox(height: 14),
              Divider(height: 1, thickness: 0.5, color: dividerColor),
              const SizedBox(height: 10),
              // Attribution
              Text('Built by Beeswax Pat', style: TextStyle(
                fontSize: 10.5,
                fontStyle: FontStyle.italic,
                color: muted,
                letterSpacing: 0.2,
              )),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget _aboutRow(IconData icon, String text, Color color) {
    return Row(
      children: [
        Icon(icon, size: 13, color: color.withValues(alpha: 0.6)),
        const SizedBox(width: 8),
        Text(text, style: TextStyle(
          fontSize: 11.5,
          color: color,
          letterSpacing: 0.1,
        )),
      ],
    );
  }
}
