import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_markdown_plus_latex/flutter_markdown_plus_latex.dart';
import 'package:intl/intl.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import 'app_controller.dart';
import 'domain/entities.dart';
import 'services/attachment_service.dart';
import 'services/api_client.dart';
import 'services/content_repository.dart';
import 'services/context_budget.dart';
import 'services/settings_service.dart';
import 'services/tool_service.dart';
import 'services/voice_service.dart';
import 'services/workspace_project_service.dart';
import 'widgets/code_block.dart';
import 'widgets/markdown_extensions.dart';

const _accent = Color(0xFFC96F47);
const _lightBackground = Color(0xFFF9F9F7);
const _lightSurface = Color(0xFFFFFFFF);
const _lightSurfaceSoft = Color(0xFFF4F2EF);
const _lightSurface86OnBackground = Color(0xFFFEFEFE);
const _lightText = Color(0xFF101010);
const _lightMuted = Color(0xFF77716B);
const _lightLine = Color(0xFFE5E0DB);
const _lightLineStrong = Color(0xFFD7D0CA);
const _lightDanger = Color(0xFFBD3E3E);
const _lightDangerLine = Color(0xFFD39996);
const _darkBackground = Color(0xFF1D1D1C);
const _darkSurface = Color(0xFF2A2A28);
const _darkText = Color(0xFFC3C2B8);
const _darkMuted = Color(0xFF96948B);
const _darkLine = Color(0xFF343431);
const _darkLineStrong = Color(0xFF4B4A45);
const _darkUserBubble = Color(0xFF101010);
const _darkSurface86OnBackground = Color(0xFF282826);
const _shellMaxWidth = 480.0;
const _drawerMaxWidth = 360.0;
const _drawerScreenMaxShift = 348.0;
// The legacy compact preset scales the inherited chat body to 13px. Store the
// inverse-scaled value so the rendered message size remains exact.
const _legacyChatBodyFontSize = 130 / 9;
const _messageActionExtent = 30.0;
const _messageActionGap = 1.0;
const _uuid = Uuid();

final md.ExtensionSet _legacyMarkdownExtensionSet =
    createClaudeMarkdownExtensionSet();
final md.ExtensionSet _workspaceMarkdownExtensionSet =
    createClaudeMarkdownExtensionSet();

String? _selectedFontFamily(Map<String, Object?> settings) =>
    switch ('${settings['fontFamily'] ?? 'claude'}') {
      'system' => null,
      'claude' || 'dm' || 'DMSans' => 'DMSans',
      'jakarta' || 'PlusJakartaSans' => 'PlusJakartaSans',
      'lora' || 'Lora' => 'Lora',
      'newsreader' || 'Newsreader' => 'Newsreader',
      'sourceSerif' || 'SourceSerif4' => 'SourceSerif4',
      'custom' =>
        '${settings['customFontFamily'] ?? ''}'.trim().isEmpty
            ? null
            : '${settings['customFontFamily']}',
      final custom when custom.isNotEmpty => custom,
      _ => null,
    };

String? _bodyFontFamily(Map<String, Object?> settings) =>
    '${settings['fontFamily'] ?? 'claude'}' == 'claude'
    ? 'Lora'
    : _selectedFontFamily(settings);

String? _displayFontFamily(Map<String, Object?> settings) =>
    '${settings['fontFamily'] ?? 'claude'}' == 'claude'
    ? 'Newsreader'
    : _selectedFontFamily(settings);

List<String>? _bodyFontFallback(Map<String, Object?> settings) =>
    '${settings['fontFamily'] ?? 'claude'}' == 'claude'
    ? const <String>['Georgia', 'Times New Roman', 'serif']
    : null;

List<String>? _displayFontFallback(Map<String, Object?> settings) =>
    '${settings['fontFamily'] ?? 'claude'}' == 'claude'
    ? const <String>['SourceSerif4', 'Georgia', 'Times New Roman', 'serif']
    : null;

class ClaudeChatApp extends StatefulWidget {
  const ClaudeChatApp({
    required this.controller,
    this.skipSplash = false,
    super.key,
  });

  final AppController controller;
  final bool skipSplash;

  @override
  State<ClaudeChatApp> createState() => _ClaudeChatAppState();
}

class _ClaudeChatAppState extends State<ClaudeChatApp> {
  late bool showingSplash;

  AppController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    showingSplash = !widget.skipSplash;
    if (!showingSplash) return;
    Future<void>.delayed(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => showingSplash = false);
    });
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final mode = switch (controller.settings['themeMode']) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };
      return MaterialApp(
        title: '${controller.settings['appName'] ?? 'ClaudeChat'}',
        debugShowCheckedModeBanner: false,
        themeMode: mode,
        themeAnimationDuration: Duration.zero,
        theme: _theme(Brightness.light),
        darkTheme: _theme(Brightness.dark),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(_textScale())),
          child: child!,
        ),
        home: showingSplash
            ? _SplashScreen(controller: controller, phrase: _splashPhrase())
            : AppShell(controller: controller),
      );
    },
  );

  double _textScale() {
    final explicit = (controller.settings['fontScale'] as num?)?.toDouble();
    if (explicit != null && explicit != 1) return explicit.clamp(.8, 1.4);
    return switch ('${controller.settings['fontSize'] ?? 'compact'}') {
      'tiny' => .84,
      'regular' => 1.0,
      'large' => 1.08,
      _ => .9,
    };
  }

  String _splashPhrase() {
    final phrases = '${controller.settings['splashPhrases'] ?? ''}'
        .split(RegExp(r'[\r\n]+'))
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toList();
    if (phrases.isEmpty) return '很高兴见到你';
    if (controller.settings['splashRandom'] != true) return phrases.first;
    return phrases[DateTime.now().millisecondsSinceEpoch % phrases.length];
  }

  ThemeData _theme(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final family = _selectedFontFamily(controller.settings);
    final scheme =
        ColorScheme.fromSeed(
          seedColor: _accent,
          brightness: brightness,
          surface: dark ? const Color(0xFF2A2A28) : _lightSurface,
        ).copyWith(
          primary: dark ? const Color(0xFFDD8358) : _accent,
          onPrimary: Colors.white,
          surface: dark ? const Color(0xFF2A2A28) : _lightSurface,
          surfaceContainerHighest: dark
              ? const Color(0xFF2A2A28)
              : _lightSurfaceSoft,
          onSurface: dark ? const Color(0xFFC3C2B8) : _lightText,
          onSurfaceVariant: dark ? const Color(0xFF96948B) : _lightMuted,
          outline: dark ? const Color(0xFF343431) : _lightLine,
          error: dark ? const Color(0xFFFF8178) : _lightDanger,
        );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: dark ? _darkBackground : _lightBackground,
      fontFamily: family,
      textTheme: ThemeData(
        brightness: brightness,
      ).textTheme.apply(fontFamily: family),
      dividerColor: dark ? Colors.white12 : _lightLine,
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        filled: true,
        fillColor: dark ? const Color(0xFF2A2A28) : Colors.white,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 12,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: dark ? Colors.white12 : _lightLine),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: _accent, width: 1.3),
        ),
      ),
      cardTheme: CardThemeData(
        color: dark ? const Color(0xFF2A2A28) : _lightSurface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: dark ? Colors.white10 : _lightLine),
        ),
      ),
      listTileTheme: const ListTileThemeData(
        dense: true,
        minVerticalPadding: 8,
        contentPadding: EdgeInsets.symmetric(horizontal: 14),
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}

class _SplashScreen extends StatelessWidget {
  const _SplashScreen({required this.controller, required this.phrase});

  final AppController controller;
  final String phrase;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Theme.of(context).brightness == Brightness.dark
        ? Colors.black
        : _lightBackground,
    body: LayoutBuilder(
      builder: (context, constraints) {
        final framed = constraints.maxWidth >= 740;
        return Center(
          child: Container(
            width: math.min(constraints.maxWidth, _shellMaxWidth),
            height: framed ? constraints.maxHeight - 36 : constraints.maxHeight,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(framed ? 34 : 0),
              boxShadow: framed
                  ? const <BoxShadow>[
                      BoxShadow(
                        color: Color(0x38000000),
                        blurRadius: 80,
                        offset: Offset(0, 20),
                      ),
                    ]
                  : null,
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(framed ? 34 : 0),
              child: ColoredBox(
                color: Theme.of(context).scaffoldBackgroundColor,
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(28, 80, 28, 28),
                    child: Stack(
                      alignment: Alignment.center,
                      children: <Widget>[
                        Semantics(
                          label: '应用图标和名称',
                          container: true,
                          child: Row(
                            key: const ValueKey<String>('app-splash-brand'),
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              const _ClaudeMark(size: 46),
                              const SizedBox(width: 12),
                              Flexible(
                                child: Text(
                                  '${controller.settings['appName'] ?? 'ClaudeChat'}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontFamily: _displayFontFamily(
                                      controller.settings,
                                    ),
                                    fontFamilyFallback: _displayFontFallback(
                                      controller.settings,
                                    ),
                                    fontSize: 38,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Align(
                          alignment: Alignment.bottomCenter,
                          child: Text(
                            phrase,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    ),
  );
}

class AppShell extends StatefulWidget {
  const AppShell({required this.controller, super.key});
  final AppController controller;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  final composer = TextEditingController();
  final memoryPageKey = GlobalKey<_MemoriesPageState>();
  final diaryPageKey = GlobalKey<_DiaryPageState>();
  final filesPageKey = GlobalKey<_FilesPageState>();
  final workspacePageKey = GlobalKey<_WorkspacesPageState>();
  String? approvalShowing;
  int? noticeNavigationHandling;
  bool drawerOpen = false;

  @override
  void initState() {
    super.initState();
    widget.controller.chatActivity.addListener(_onChatActivity);
  }

  void _onChatActivity() {
    if (!mounted || widget.controller.section != AppSection.chat) return;
    setState(() {});
  }

  @override
  void didUpdateWidget(covariant AppShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;
    oldWidget.controller.chatActivity.removeListener(_onChatActivity);
    widget.controller.chatActivity.addListener(_onChatActivity);
  }

  @override
  void dispose() {
    widget.controller.chatActivity.removeListener(_onChatActivity);
    composer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    if (controller.notice != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || controller.notice == null) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(controller.notice!)));
        controller.notice = null;
      });
    }
    final approval = controller.pendingToolApproval;
    if (approval != null &&
        controller.approvalDialogRequested &&
        approvalShowing != approval.callId) {
      approvalShowing = approval.callId;
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _showToolApproval(approval),
      );
    }
    final noticeNavigation = controller.pendingNoticeNavigation;
    if (noticeNavigation != null &&
        noticeNavigationHandling != noticeNavigation.serial) {
      noticeNavigationHandling = noticeNavigation.serial;
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _openNoticeTarget(noticeNavigation),
      );
    }
    final appBackground = Theme.of(context).scaffoldBackgroundColor;
    final handlesBack =
        drawerOpen ||
        controller.canReturnFromNotice ||
        controller.activeWorkspace != null ||
        controller.section != AppSection.chat;
    return PopScope(
      canPop: !handlesBack,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleSystemBack();
      },
      child: Scaffold(
        backgroundColor: Theme.of(context).brightness == Brightness.dark
            ? Colors.black
            : _lightBackground,
        body: LayoutBuilder(
          builder: (context, constraints) {
            final framed = constraints.maxWidth >= 740;
            final shellHeight = framed
                ? constraints.maxHeight - 36
                : constraints.maxHeight;
            return Center(
              child: Container(
                width: math.min(constraints.maxWidth, _shellMaxWidth),
                height: math.max(0, shellHeight),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(framed ? 34 : 0),
                  border: framed
                      ? Border.all(color: Colors.black.withValues(alpha: .08))
                      : null,
                  boxShadow: framed
                      ? const <BoxShadow>[
                          BoxShadow(
                            color: Color(0x38000000),
                            blurRadius: 80,
                            offset: Offset(0, 20),
                          ),
                        ]
                      : const <BoxShadow>[],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(framed ? 34 : 0),
                  child: ColoredBox(
                    color: appBackground,
                    child: LayoutBuilder(
                      builder: (context, shellConstraints) {
                        final drawerWidth = math.min(
                          _drawerMaxWidth,
                          shellConstraints.maxWidth * .78,
                        );
                        final screenShift = math.min(
                          _drawerScreenMaxShift,
                          shellConstraints.maxWidth * .74,
                        );
                        return Stack(
                          children: <Widget>[
                            Positioned.fill(
                              child: AnimatedSlide(
                                offset: Offset(
                                  drawerOpen
                                      ? screenShift / shellConstraints.maxWidth
                                      : 0,
                                  0,
                                ),
                                duration: const Duration(milliseconds: 220),
                                curve: Curves.easeOutCubic,
                                child: _WorkspaceTaskBallLayer(
                                  controller: controller,
                                  child: RepaintBoundary(
                                    child: ColoredBox(
                                      color: appBackground,
                                      child: Column(
                                        children: <Widget>[
                                          _WebTopBar(
                                            controller: controller,
                                            drawerOpen: drawerOpen,
                                            onOpenDrawer: _openDrawer,
                                            onCloseDrawer: _closeDrawer,
                                            onAddMemory: _addMemory,
                                            onToggleDiaryView: _toggleDiaryView,
                                            onAddWorkspace: _addWorkspace,
                                            onWorkspaceBack: _workspaceBack,
                                            onOpenWorkspaceSettings:
                                                _openWorkspaceSettings,
                                            onOpenWorkspaceConversations:
                                                _openWorkspaceConversations,
                                          ),
                                          Expanded(child: _page(controller)),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            if (drawerOpen)
                              Positioned.fill(
                                child: GestureDetector(
                                  onTap: _closeDrawer,
                                  onHorizontalDragEnd: (details) {
                                    if (details.primaryVelocity != null &&
                                        details.primaryVelocity! < -180) {
                                      _closeDrawer();
                                    }
                                  },
                                  child: ColoredBox(
                                    color: Colors.black.withValues(alpha: .08),
                                  ),
                                ),
                              ),
                            AnimatedPositioned(
                              duration: const Duration(milliseconds: 220),
                              curve: Curves.easeOutCubic,
                              left: drawerOpen ? 0 : -drawerWidth,
                              top: 0,
                              bottom: 0,
                              width: drawerWidth,
                              child: GestureDetector(
                                behavior: HitTestBehavior.translucent,
                                onHorizontalDragEnd: (details) {
                                  if (details.primaryVelocity != null &&
                                      details.primaryVelocity! < -180) {
                                    _closeDrawer();
                                  }
                                },
                                child: RepaintBoundary(
                                  child: _Sidebar(
                                    controller: controller,
                                    onNavigate: _closeDrawer,
                                  ),
                                ),
                              ),
                            ),
                            if (!drawerOpen)
                              Positioned(
                                left: 0,
                                top: 0,
                                bottom: 0,
                                width: 22,
                                child: GestureDetector(
                                  behavior: HitTestBehavior.translucent,
                                  onHorizontalDragEnd: (details) {
                                    if (details.primaryVelocity != null &&
                                        details.primaryVelocity! > 220) {
                                      _openDrawer();
                                    }
                                  },
                                ),
                              ),
                          ],
                        );
                      },
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  void _openDrawer() {
    FocusManager.instance.primaryFocus?.unfocus();
    if (!drawerOpen) setState(() => drawerOpen = true);
  }

  void _closeDrawer() {
    if (drawerOpen) setState(() => drawerOpen = false);
  }

  void _handleSystemBack() {
    final controller = widget.controller;
    FocusManager.instance.primaryFocus?.unfocus();
    if (drawerOpen) {
      _closeDrawer();
    } else if (controller.canReturnFromNotice) {
      controller.returnFromNoticeNavigation();
    } else if (controller.section == AppSection.workspaces &&
        controller.activeWorkspace != null) {
      _workspaceBack();
    } else if (controller.section != AppSection.chat) {
      controller.open(AppSection.chat);
    }
  }

  Future<void> _addMemory() async => memoryPageKey.currentState?.startEditor();

  void _workspaceBack() {
    if (workspacePageKey.currentState?.handleBack() == true) return;
    widget.controller.closeWorkspace();
  }

  void _openWorkspaceSettings() {
    FocusManager.instance.primaryFocus?.unfocus();
    workspacePageKey.currentState?.openSettings();
  }

  void _openWorkspaceConversations() {
    FocusManager.instance.primaryFocus?.unfocus();
    workspacePageKey.currentState?.openConversationMenu();
  }

  Future<void> _openNoticeTarget(AppNoticeNavigation navigation) async {
    if (!mounted) return;
    _closeDrawer();
    FocusManager.instance.primaryFocus?.unfocus();
    widget.controller.completeNoticeNavigation(navigation.serial);
    switch (navigation.target) {
      case AppSection.memories:
        memoryPageKey.currentState?.highlightEntry(navigation.entryId);
        break;
      case AppSection.diary:
        await diaryPageKey.currentState?.openNotificationEntry(
          navigation.entryId,
        );
        if (mounted) {
          _closeDrawer();
          widget.controller.returnFromNoticeNavigation(navigation.serial);
        }
        break;
      case AppSection.files:
        await filesPageKey.currentState?.openNotificationEntry(
          navigation.entryId,
        );
        if (mounted) {
          _closeDrawer();
          widget.controller.returnFromNoticeNavigation(navigation.serial);
        }
        break;
      case AppSection.chat ||
          AppSection.voices ||
          AppSection.workspaces ||
          AppSection.settings:
        break;
    }
  }

  void _toggleDiaryView() {
    widget.controller.saveSetting(
      'diaryViewMode',
      widget.controller.settings['diaryViewMode'] == 'list' ? 'grid' : 'list',
    );
  }

  Future<void> _addWorkspace() async {
    final textController = TextEditingController();
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('新建工作区'),
        content: TextField(
          controller: textController,
          autofocus: true,
          decoration: const InputDecoration(hintText: '工作区名称'),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    final value = textController.text.trim();
    textController.dispose();
    if (saved != true || value.isEmpty) return;
    await widget.controller.content.createWorkspace(value);
    await widget.controller.reload();
  }

  Widget _page(AppController controller) => switch (controller.section) {
    AppSection.chat => _ChatPage(controller: controller, composer: composer),
    AppSection.memories => _MemoriesPage(
      key: memoryPageKey,
      controller: controller,
    ),
    AppSection.diary => _DiaryPage(key: diaryPageKey, controller: controller),
    AppSection.files => _FilesPage(key: filesPageKey, controller: controller),
    AppSection.voices => _VoicesPage(controller: controller),
    AppSection.workspaces => _WorkspacesPage(
      key: workspacePageKey,
      controller: controller,
    ),
    AppSection.settings => _SettingsPage(controller: controller),
  };

  Future<void> _showToolApproval(ToolRequest request) async {
    if (!mounted) return;
    final definition = widget.controller.tools.definition(request.name);
    final approved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('工具审批'),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  const _LegacyIcon(
                    _LegacyIconKind.tool,
                    size: 20,
                    color: _lightText,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    definition?.label ?? request.name,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(definition?.approvalText ?? 'AI 想执行一个需要你确认的本地工具。'),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                constraints: const BoxConstraints(maxHeight: 220),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(
                    const JsonEncoder.withIndent(
                      '  ',
                    ).convert(request.arguments),
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('拒绝'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('允许'),
          ),
        ],
      ),
    );
    approvalShowing = null;
    unawaited(widget.controller.resolveToolApproval(approved == true));
  }
}

class _WebTopBar extends StatelessWidget {
  const _WebTopBar({
    required this.controller,
    required this.drawerOpen,
    required this.onOpenDrawer,
    required this.onCloseDrawer,
    required this.onAddMemory,
    required this.onToggleDiaryView,
    required this.onAddWorkspace,
    required this.onWorkspaceBack,
    required this.onOpenWorkspaceSettings,
    required this.onOpenWorkspaceConversations,
  });

  final AppController controller;
  final bool drawerOpen;
  final VoidCallback onOpenDrawer;
  final VoidCallback onCloseDrawer;
  final VoidCallback onAddMemory;
  final VoidCallback onToggleDiaryView;
  final VoidCallback onAddWorkspace;
  final VoidCallback onWorkspaceBack;
  final VoidCallback onOpenWorkspaceSettings;
  final VoidCallback onOpenWorkspaceConversations;

  @override
  Widget build(BuildContext context) => SafeArea(
    bottom: false,
    child: SizedBox(
      height: controller.section == AppSection.settings ? 62 : 58,
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 64,
            child: Padding(
              padding: const EdgeInsets.only(left: 12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: SizedBox.square(
                  dimension: 36,
                  child: IconButton(
                    onPressed: controller.canReturnFromNotice
                        ? () {
                            onCloseDrawer();
                            controller.returnFromNoticeNavigation();
                          }
                        : controller.section == AppSection.workspaces &&
                              controller.activeWorkspace != null
                        ? onWorkspaceBack
                        : controller.section == AppSection.settings
                        ? () => controller.open(AppSection.chat)
                        : drawerOpen
                        ? onCloseDrawer
                        : onOpenDrawer,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: 36,
                      height: 36,
                    ),
                    icon: DecoratedBox(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border:
                            drawerOpen &&
                                controller.section != AppSection.settings
                            ? Border.all(
                                color: const Color(0xFF101010),
                                width: 1,
                              )
                            : null,
                      ),
                      child: SizedBox.square(
                        dimension: 36,
                        child: Center(
                          child: controller.canReturnFromNotice
                              ? Transform.rotate(
                                  angle: math.pi,
                                  child: const _LegacyIcon(
                                    _LegacyIconKind.chevronRight,
                                    size: 22,
                                    color: Color(0xFF101010),
                                  ),
                                )
                              : controller.section == AppSection.workspaces &&
                                    controller.activeWorkspace != null
                              ? Transform.rotate(
                                  angle: math.pi,
                                  child: const _LegacyIcon(
                                    _LegacyIconKind.chevronRight,
                                    size: 22,
                                    color: Color(0xFF101010),
                                  ),
                                )
                              : controller.section == AppSection.settings
                              ? const _LegacyIcon(
                                  _LegacyIconKind.close,
                                  size: 18,
                                  color: Color(0xFF101010),
                                )
                              : const _LegacyIcon(
                                  _LegacyIconKind.menu,
                                  size: 18,
                                  color: Color(0xFF101010),
                                ),
                        ),
                      ),
                    ),
                    tooltip: controller.canReturnFromNotice
                        ? '返回对话'
                        : controller.section == AppSection.workspaces &&
                              controller.activeWorkspace != null
                        ? '返回工作区列表'
                        : controller.section == AppSection.settings
                        ? '关闭设置'
                        : drawerOpen
                        ? '关闭侧边栏'
                        : '打开侧边栏',
                  ),
                ),
              ),
            ),
          ),
          Expanded(child: _center(context)),
          SizedBox(width: 64, child: _trailing(context)),
        ],
      ),
    ),
  );

  Widget _center(BuildContext context) {
    if (controller.section != AppSection.chat) {
      final heading = Text(
        controller.section == AppSection.workspaces &&
                controller.activeWorkspace != null
            ? controller.activeWorkspace!.name
            : _sectionTitle(controller),
        textAlign: TextAlign.center,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: controller.section == AppSection.settings
            ? const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                height: 1.317,
              )
            : const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                height: 1.05,
              ),
      );
      return controller.section == AppSection.settings
          ? Transform.translate(offset: const Offset(0, -1.5), child: heading)
          : heading;
    }
    return Center(
      child: SizedBox(
        height: 46,
        width: double.infinity,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => _showModelPicker(context, controller),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const SizedBox(width: 18),
                  const SizedBox(width: 3),
                  Flexible(
                    child: Text(
                      controller.activeModelLabel.isEmpty
                          ? '选择模型'
                          : controller.activeModelLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        height: 1.05,
                      ),
                    ),
                  ),
                  const SizedBox(width: 3),
                  const _LegacyIcon(_LegacyIconKind.chevron, size: 20),
                ],
              ),
              Text(
                controller.privateMode ? '私密对话' : 'Adaptive',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 14,
                  height: 1.15,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _trailing(BuildContext context) {
    if (controller.section == AppSection.chat) {
      return Align(
        alignment: Alignment.centerLeft,
        child: SizedBox.square(
          dimension: 36,
          child: IconButton(
            onPressed: () => controller.setPrivateMode(!controller.privateMode),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 36, height: 36),
            icon: controller.privateMode
                ? Icon(
                    Icons.close_rounded,
                    size: 20,
                    color: Theme.of(context).colorScheme.error,
                  )
                : const _LegacyIcon(
                    _LegacyIconKind.ghost,
                    size: 18,
                    color: Color(0xFF101010),
                  ),
            tooltip: controller.privateMode ? '退出私密对话' : '进入私密对话',
          ),
        ),
      );
    }
    if (controller.section == AppSection.settings) {
      return Align(
        alignment: Alignment.centerLeft,
        child: SizedBox.square(
          dimension: 36,
          child: IconButton(
            onPressed: () => showAboutDialog(
              context: context,
              applicationName: 'ClaudeChat',
              applicationVersion: 'Flutter 单框架迁移版',
              children: const <Widget>[
                Text('Android 与 iOS 共用 UI、业务模型和无损合并备份格式。'),
              ],
            ),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 36, height: 36),
            icon: const _LegacyIcon(
              _LegacyIconKind.shield,
              size: 18,
              color: Color(0xFF101010),
            ),
            tooltip: '关于',
          ),
        ),
      );
    }
    if (controller.section == AppSection.memories) {
      return Align(
        alignment: Alignment.centerLeft,
        child: SizedBox.square(
          dimension: 36,
          child: IconButton(
            onPressed: onAddMemory,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 36, height: 36),
            icon: const _LegacyIcon(
              _LegacyIconKind.plus,
              size: 18,
              color: Color(0xFF101010),
            ),
            tooltip: '新增记忆',
          ),
        ),
      );
    }
    if (controller.section == AppSection.diary) {
      final listMode = controller.settings['diaryViewMode'] == 'list';
      return Align(
        alignment: Alignment.centerLeft,
        child: SizedBox.square(
          dimension: 36,
          child: IconButton(
            onPressed: onToggleDiaryView,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 36, height: 36),
            icon: _LegacyIcon(
              listMode ? _LegacyIconKind.grid : _LegacyIconKind.list,
              size: 18,
              color: const Color(0xFF101010),
            ),
            tooltip: listMode ? '切换卡片' : '切换列表',
          ),
        ),
      );
    }
    if (controller.section == AppSection.workspaces &&
        controller.activeWorkspace == null) {
      return Align(
        alignment: Alignment.centerLeft,
        child: SizedBox.square(
          dimension: 36,
          child: IconButton(
            onPressed: onAddWorkspace,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 36, height: 36),
            icon: const _LegacyIcon(
              _LegacyIconKind.plus,
              size: 18,
              color: Color(0xFF101010),
            ),
            tooltip: '新建工作区',
          ),
        ),
      );
    }
    if (controller.section == AppSection.workspaces &&
        controller.activeWorkspace != null) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            SizedBox.square(
              dimension: 30,
              child: IconButton(
                onPressed: onOpenWorkspaceConversations,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(
                  width: 30,
                  height: 30,
                ),
                icon: const Icon(Icons.add_rounded, size: 20),
                tooltip: '工作区对话',
              ),
            ),
            SizedBox.square(
              dimension: 30,
              child: IconButton(
                onPressed: onOpenWorkspaceSettings,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(
                  width: 30,
                  height: 30,
                ),
                icon: const Icon(Icons.settings_outlined, size: 18),
                tooltip: '工作区设置',
              ),
            ),
          ],
        ),
      );
    }
    return const SizedBox.shrink();
  }
}

Future<void> _confirmDeleteWorkspace(
  BuildContext context,
  AppController controller,
) async {
  final workspace = controller.activeWorkspace;
  if (workspace == null) return;
  final first = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      content: const Text('删除这个工作区？它会从应用中隐藏，但数据仍会保留在迁移包中。'),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('确定'),
        ),
      ],
    ),
  );
  if (first != true || !context.mounted) return;
  final second = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      content: const Text('再次确认删除这个工作区。'),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('确定'),
        ),
      ],
    ),
  );
  if (second == true) await controller.deleteWorkspace(workspace);
}

Future<void> _showModelPicker(
  BuildContext context,
  AppController controller,
) async {
  final slots = controller.modelSlots;
  if (slots.isEmpty) {
    controller.open(AppSection.settings);
    _snack(context, '请先在设置的“模型”中添加一个模型槽位');
    return;
  }
  final target = context.findRenderObject() as RenderBox?;
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
  if (target == null || overlay == null) return;
  final targetOrigin = target.localToGlobal(Offset.zero, ancestor: overlay);
  final targetRect = targetOrigin & target.size;
  final menuWidth = math.min(292.0, overlay.size.width - 32);
  final menuLeft = (targetRect.center.dx - menuWidth / 2).clamp(
    16.0,
    overlay.size.width - menuWidth - 16,
  );
  final selected = await showGeneralDialog<String>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭模型选择',
    barrierColor: const Color(0x14000000),
    transitionDuration: const Duration(milliseconds: 160),
    pageBuilder: (dialogContext, _, _) => Stack(
      children: <Widget>[
        Positioned(
          left: targetRect.left + 64,
          top: targetRect.top + 5.75,
          width: targetRect.width - 128,
          height: 46.4896,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(
                  color: const Color(0xFF101010),
                  width: .6667,
                ),
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
        ),
        Positioned(
          left: menuLeft,
          top: targetRect.bottom,
          width: menuWidth,
          child: _ModelPickerPanel(controller: controller, slots: slots),
        ),
      ],
    ),
  );
  if (selected == '__settings__') {
    controller.open(AppSection.settings);
  } else if (selected != null) {
    await controller.selectModelSlot(selected);
  }
}

class _ModelPickerPanel extends StatelessWidget {
  const _ModelPickerPanel({required this.controller, required this.slots});

  final AppController controller;
  final List<Map<String, Object?>> slots;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    explicitChildNodes: true,
    label: '模型选择',
    child: Material(
      color: Colors.transparent,
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: const Color(0xEBFFFFFF),
          border: const Border(
            left: BorderSide(color: Color(0xFFE5E0DB), width: .6667),
            right: BorderSide(color: Color(0xFFE5E0DB), width: .6667),
            bottom: BorderSide(color: Color(0xFFE5E0DB), width: .6667),
          ),
          borderRadius: const BorderRadius.only(
            bottomLeft: Radius.circular(18),
            bottomRight: Radius.circular(18),
          ),
          boxShadow: const <BoxShadow>[
            BoxShadow(
              color: Color(0x241F1912),
              blurRadius: 48,
              offset: Offset(0, 16),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ...slots.indexed.map((entry) {
              final index = entry.$1;
              final slot = entry.$2;
              final title = '${slot['label'] ?? slot['apiName'] ?? ''}';
              final subtitle =
                  '${slot['description'] ?? slot['apiName'] ?? '未填写描述'}';
              return _ModelPickerOption(
                height: index == 0 ? 50.6667 : 47.3333,
                semanticsLabel: '$title $subtitle',
                onTap: () => Navigator.pop(context, '${slot['id']}'),
                trailing: slot['id'] == controller.settings['activeModelSlotId']
                    ? const _LegacyIcon(_LegacyIconKind.check, size: 22)
                    : null,
                child: Row(
                  children: <Widget>[
                    Flexible(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFF77716B),
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }),
            Container(
              height: 10,
              decoration: const BoxDecoration(
                color: Color(0xFFF4F2EF),
                border: Border(
                  bottom: BorderSide(color: Color(0xFFE5E0DB), width: .6667),
                ),
              ),
            ),
            _ModelPickerOption(
              height: 63.3333,
              semanticsLabel: 'More models 编辑显示名和真实 API 模型名',
              drawBottomBorder: false,
              onTap: () => Navigator.pop(context, '__settings__'),
              trailing: const _LegacyIcon(
                _LegacyIconKind.chevronRight,
                size: 22,
              ),
              child: const Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'More models',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                  SizedBox(height: 4),
                  Text(
                    '编辑显示名和真实 API 模型名',
                    style: TextStyle(color: Color(0xFF77716B), fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _ModelPickerOption extends StatelessWidget {
  const _ModelPickerOption({
    required this.height,
    required this.semanticsLabel,
    required this.onTap,
    required this.child,
    this.trailing,
    this.drawBottomBorder = true,
  });

  final double height;
  final String semanticsLabel;
  final VoidCallback onTap;
  final Widget child;
  final Widget? trailing;
  final bool drawBottomBorder;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: semanticsLabel,
    child: ExcludeSemantics(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: Container(
            height: height,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              border: drawBottomBorder
                  ? const Border(
                      bottom: BorderSide(
                        color: Color(0xFFE5E0DB),
                        width: .6667,
                      ),
                    )
                  : null,
            ),
            child: Row(
              children: <Widget>[
                Expanded(child: child),
                SizedBox(width: 32, child: Center(child: trailing)),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({required this.controller, required this.onNavigate});
  final AppController controller;
  final VoidCallback onNavigate;

  @override
  Widget build(BuildContext context) {
    final starred = controller.conversations.where((item) => item.starred);
    final recent = controller.conversations.where((item) => !item.starred);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        border: Border(
          right: BorderSide(color: Theme.of(context).dividerColor),
        ),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 22, 18.67, 18),
          child: Column(
            children: <Widget>[
              Row(
                children: <Widget>[
                  const _ClaudeMark(size: 30),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '${controller.settings['appName'] ?? 'ClaudeChat'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: _displayFontFamily(controller.settings),
                        fontFamilyFallback: _displayFontFallback(
                          controller.settings,
                        ),
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                        height: 1,
                      ),
                    ),
                  ),
                  IconButton.filled(
                    onPressed: () {
                      _navigateAfterDrawer(() => controller.newConversation());
                    },
                    style: IconButton.styleFrom(
                      backgroundColor: _accent,
                      foregroundColor: Colors.white,
                      fixedSize: const Size.square(34),
                      minimumSize: const Size.square(34),
                      maximumSize: const Size.square(34),
                      padding: EdgeInsets.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    icon: const _LegacyIcon(
                      _LegacyIconKind.plus,
                      size: 18,
                      color: Colors.white,
                    ),
                    tooltip: '新建对话',
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: SingleChildScrollView(
                  child: Padding(
                    padding: const EdgeInsets.only(right: 2),
                    child: Column(
                      children: <Widget>[
                        const SizedBox(height: 9),
                        _NavTile(
                          icon: _LegacyIconKind.chat,
                          label: 'Chats',
                          selected: controller.section == AppSection.chat,
                          onTap: () => _open(AppSection.chat),
                        ),
                        _NavTile(
                          icon: _LegacyIconKind.diary,
                          label: 'Ta 的心事',
                          selected: controller.section == AppSection.diary,
                          onTap: () => _open(AppSection.diary),
                        ),
                        _NavTile(
                          icon: _LegacyIconKind.pin,
                          label: 'Ta 的记忆',
                          selected: controller.section == AppSection.memories,
                          onTap: () => _open(AppSection.memories),
                        ),
                        _NavTile(
                          icon: _LegacyIconKind.folder,
                          label: 'Ta的文件',
                          selected: controller.section == AppSection.files,
                          onTap: () => _open(AppSection.files),
                        ),
                        _NavTile(
                          icon: _LegacyIconKind.waveform,
                          label: 'Ta的声音',
                          selected: controller.section == AppSection.voices,
                          onTap: () => _open(AppSection.voices),
                        ),
                        _NavTile(
                          icon: _LegacyIconKind.workspace,
                          label: 'Ta的工作室',
                          selected: controller.section == AppSection.workspaces,
                          onTap: () => _open(AppSection.workspaces),
                        ),
                        const _DrawerSectionTitle('Starred'),
                        ..._conversationRows(context, starred.toList(), true),
                        const _DrawerSectionTitle('Recents', compactTop: true),
                        ..._conversationRows(context, recent.toList(), false),
                      ],
                    ),
                  ),
                ),
              ),
              Container(
                height: 65,
                padding: const EdgeInsets.only(top: 12),
                decoration: BoxDecoration(
                  border: Border(
                    top: BorderSide(color: Theme.of(context).dividerColor),
                  ),
                ),
                child: _ProfileTile(
                  label: '${controller.settings['profileName'] ?? '用户'}',
                  selected: controller.section == AppSection.settings,
                  onTap: () => _open(AppSection.settings),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _conversationRows(
    BuildContext context,
    List<Conversation> items,
    bool starred,
  ) {
    if (items.isEmpty) {
      return <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 4.67, 8, 7),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              starred ? '还没有置顶对话' : '还没有历史对话',
              style: TextStyle(
                fontSize: 12,
                height: 1.3,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ];
    }
    return items.map((item) {
      return _ConversationRow(
        label: item.title,
        starred: item.starred,
        selected:
            controller.section == AppSection.chat &&
            controller.activeConversation?.id == item.id,
        onTap: () {
          _navigateAfterDrawer(() => controller.selectConversation(item));
        },
        onToggleStar: () => _conversationAction(context, item, 'star'),
        onArchive: () => _conversationAction(context, item, 'archive'),
        onDelete: () => _conversationAction(context, item, 'delete'),
      );
    }).toList();
  }

  Future<void> _conversationAction(
    BuildContext context,
    Conversation item,
    String action,
  ) async {
    if (action == 'star') {
      await controller.toggleConversationStar(item);
    } else if (action == 'archive') {
      await controller.archiveConversation(item);
    } else if (action == 'export') {
      await controller.exportConversation(item);
    } else if (action == 'delete' && context.mounted) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('删除对话？'),
          content: Text('“${item.title}”将进入删除记录，并在合并导入时同步。'),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('删除'),
            ),
          ],
        ),
      );
      if (confirmed == true) await controller.deleteConversation(item);
    }
  }

  void _open(AppSection section) {
    _navigateAfterDrawer(() => controller.open(section));
  }

  void _navigateAfterDrawer(FutureOr<void> Function() navigate) {
    onNavigate();
    Future<void>.delayed(const Duration(milliseconds: 230), () async {
      await navigate();
    });
  }
}

class _DrawerSectionTitle extends StatelessWidget {
  const _DrawerSectionTitle(this.label, {this.compactTop = false});
  final String label;
  final bool compactTop;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(8, compactTop ? 3 : 13, 8, 3),
    child: Align(
      alignment: Alignment.centerLeft,
      child: Text(
        label,
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          fontSize: 13,
          fontWeight: FontWeight.w600,
          height: 1.25,
        ),
      ),
    ),
  );
}

class _NavTile extends StatelessWidget {
  const _NavTile({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final _LegacyIconKind icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 1),
    child: Material(
      color: selected
          ? Theme.of(context).colorScheme.surfaceContainerHighest
          : Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
          height: 32,
          child: Row(
            children: <Widget>[
              const SizedBox(width: 7),
              SizedBox(
                width: 28,
                child: Center(child: _LegacyIcon(icon, size: 18)),
              ),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14),
                ),
              ),
              const SizedBox(width: 3),
            ],
          ),
        ),
      ),
    ),
  );
}

class _ConversationRow extends StatelessWidget {
  const _ConversationRow({
    required this.label,
    required this.starred,
    required this.selected,
    required this.onTap,
    required this.onToggleStar,
    required this.onArchive,
    required this.onDelete,
  });

  final String label;
  final bool starred;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onToggleStar;
  final VoidCallback onArchive;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) => Material(
    color: selected
        ? Theme.of(context).colorScheme.surfaceContainerHighest
        : Colors.transparent,
    borderRadius: BorderRadius.circular(10),
    child: SizedBox(
      height: 32,
      child: Row(
        children: <Widget>[
          const SizedBox(width: 7),
          Expanded(
            child: InkWell(
              onTap: onTap,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14),
                ),
              ),
            ),
          ),
          IconButton(
            onPressed: onToggleStar,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 26, height: 26),
            icon: const _LegacyIcon(_LegacyIconKind.star, size: 18),
            tooltip: starred ? '取消置顶' : '置顶',
          ),
          IconButton(
            onPressed: onArchive,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 26, height: 26),
            icon: const Icon(Icons.archive_outlined, size: 18),
            tooltip: '归档对话',
          ),
          IconButton(
            onPressed: onDelete,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 26, height: 26),
            icon: const _LegacyIcon(_LegacyIconKind.trash, size: 18),
            tooltip: '删除对话',
          ),
          const SizedBox(width: 7),
        ],
      ),
    ),
  );
}

class _ProfileTile extends StatelessWidget {
  const _ProfileTile({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: selected
        ? Theme.of(context).colorScheme.surfaceContainerHighest
        : Colors.transparent,
    borderRadius: BorderRadius.circular(12),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        height: 52,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Row(
            children: <Widget>[
              Container(
                width: 36,
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  shape: BoxShape.circle,
                ),
                child: Text(
                  label.characters.firstOrNull ?? '',
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    height: 1,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(fontSize: _legacyChatBodyFontSize),
                ),
              ),
              const Icon(Icons.settings_outlined, size: 19),
            ],
          ),
        ),
      ),
    ),
  );
}

class _ChatPage extends StatelessWidget {
  const _ChatPage({required this.controller, required this.composer});
  final AppController controller;
  final TextEditingController composer;

  @override
  Widget build(BuildContext context) {
    final content = Column(
      children: <Widget>[
        _ApiNoticeBar(controller: controller),
        Expanded(
          child: _ScrollEdgeFade(
            child: GestureDetector(
              key: const Key('chat-reading-surface'),
              behavior: HitTestBehavior.translucent,
              onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
              child:
                  controller.messages.isEmpty &&
                      controller.streamingText.isEmpty
                  ? controller.privateMode
                        ? _PrivateWelcome(controller: controller)
                        : _Welcome(controller: controller)
                  : _MessageList(
                      key: ValueKey<String>(
                        'chat-${controller.activeConversation?.id ?? 'none'}',
                      ),
                      controller: controller,
                    ),
            ),
          ),
        ),
        if (controller.messages.isNotEmpty) _ContextBar(controller: controller),
        _Composer(controller: controller, textController: composer),
      ],
    );
    return content;
  }
}

class _ScrollEdgeFade extends StatelessWidget {
  const _ScrollEdgeFade({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final glass = Color.lerp(
      theme.scaffoldBackgroundColor,
      theme.colorScheme.surface,
      .5,
    )!;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        child,
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          height: 9,
          child: IgnorePointer(
            child: ClipRect(
              child: BackdropFilter(
                filter: ui.ImageFilter.blur(sigmaX: 5.5, sigmaY: 5.5),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: <Color>[
                        glass.withValues(alpha: .48),
                        glass.withValues(alpha: .06),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: 11,
          child: IgnorePointer(
            child: ClipRect(
              child: BackdropFilter(
                filter: ui.ImageFilter.blur(sigmaX: 5.5, sigmaY: 5.5),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: <Color>[
                        glass.withValues(alpha: .06),
                        glass.withValues(alpha: .48),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ApiNoticeBar extends StatelessWidget {
  const _ApiNoticeBar({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    if (controller.actionableNotifications.isNotEmpty) {
      return _ActionableNoticeBar(controller: controller);
    }
    final text = controller.privateMode
        ? '私密对话不会保存到历史记录'
        : controller.localDemoMode
        ? '当前为本地演示回复'
        : 'API 已配置，聊天记录只保存在本机';
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 0),
      child: Container(
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface.withValues(alpha: .74),
          border: Border.all(
            color: Theme.of(context).colorScheme.outline,
            width: 0.6667,
          ),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.3,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(width: 12),
            TextButton(
              onPressed: () => controller.open(AppSection.settings),
              style: TextButton.styleFrom(
                minimumSize: Size.zero,
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                foregroundColor: const Color(0xFF2F76C2),
                textStyle: const TextStyle(fontSize: 12, height: 1.3),
              ),
              child: Text(controller.localDemoMode ? '配置' : '设置'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionableNoticeBar extends StatelessWidget {
  const _ActionableNoticeBar({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final items = controller.actionableNotifications;
    final expandedItems = controller.expandedActionableNotifications;
    final latest = items.first;
    final expanded = controller.notificationsOpen;
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final line = dark ? const Color(0xFF343431) : _lightLine;
    final accent = dark ? const Color(0xFFDD8358) : _accent;
    final surfaceSoft = dark ? const Color(0xFF2A2A28) : _lightSurfaceSoft;
    final blue = dark ? const Color(0xFF82B9F2) : const Color(0xFF2F76C2);
    final accentBorder = Color.lerp(line, accent, .4)!;
    final alertBackground = Color.lerp(surfaceSoft, accent, .06)!;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Container(
        clipBehavior: expanded ? Clip.none : Clip.antiAlias,
        decoration: BoxDecoration(
          color: alertBackground,
          border: Border.all(color: accentBorder, width: 0.6667),
          borderRadius: BorderRadius.circular(expanded ? 16 : 20),
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: expanded ? 4 : 0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              InkWell(
                onTap: controller.toggleNotifications,
                splashColor: Colors.transparent,
                highlightColor: Colors.transparent,
                hoverColor: Colors.transparent,
                child: SizedBox(
                  height: 34,
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: expanded ? 12 : 0,
                    ),
                    child: Row(
                      children: <Widget>[
                        _NoticeDot(type: latest.type),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            latest.text,
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: blue,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              height: 1.2963,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          items.length > 1 ? '+${items.length - 1}' : '',
                          style: TextStyle(
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (expanded)
                Padding(
                  padding: const EdgeInsets.fromLTRB(6, 0, 6, 4),
                  child: Container(
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surface,
                      border: Border.all(color: line, width: 0.6667),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        for (
                          var index = 0;
                          index < math.min(3, expandedItems.length);
                          index++
                        ) ...<Widget>[
                          _NoticeRow(
                            item: expandedItems[index],
                            onTap: () => controller.activateNotification(
                              expandedItems[index],
                            ),
                          ),
                          if (index < math.min(3, expandedItems.length) - 1)
                            Divider(
                              height: 0.6667,
                              thickness: 0.6667,
                              color: line,
                            ),
                        ],
                        if (expandedItems.length > 3) ...<Widget>[
                          Divider(
                            height: 0.6667,
                            thickness: 0.6667,
                            color: line,
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Text(
                              '还有 ${expandedItems.length - 3} 条待办',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                                fontSize: 11,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NoticeRow extends StatelessWidget {
  const _NoticeRow({required this.item, required this.onTap});

  final AppNotice item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final blue = dark ? const Color(0xFF82B9F2) : const Color(0xFF2F76C2);
    final danger = dark ? const Color(0xFFFF8178) : _lightDanger;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: <Widget>[
          _NoticeDot(type: item.type),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              item.text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 12,
                height: 1.2963,
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            height: 28,
            child: TextButton(
              onPressed: onTap,
              style: TextButton.styleFrom(
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                overlayColor: Colors.transparent,
                backgroundColor:
                    (item.type == AppNoticeType.danger ? danger : blue)
                        .withValues(alpha: .1),
                foregroundColor: item.type == AppNoticeType.danger
                    ? danger
                    : blue,
                textStyle: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
                shape: const StadiumBorder(),
              ),
              child: Text(item.isApproval ? '处理' : '查看'),
            ),
          ),
        ],
      ),
    );
  }
}

class _NoticeDot extends StatelessWidget {
  const _NoticeDot({required this.type});

  final AppNoticeType type;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 12,
    height: 8,
    child: Align(
      alignment: Alignment.centerLeft,
      child: Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          color: switch (type) {
            AppNoticeType.danger => const Color(0xFFBD3E3E),
            AppNoticeType.notice => const Color(0xFFC96F47),
            AppNoticeType.info => const Color(0xFF2F76C2),
          },
          shape: BoxShape.circle,
        ),
      ),
    ),
  );
}

class _ContextBar extends StatelessWidget {
  const _ContextBar({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final used = controller.estimatedInputTokens;
    final output = controller.estimatedOutputTokens;
    final budget = controller.contextTokenBudget;
    final folds = controller.activeConversation?.summaryFoldCount ?? 0;
    final warning = folds > 0 || (budget != null && used >= budget * .78);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 820),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 2),
        child: Align(
          alignment: Alignment.centerRight,
          child: Text(
            '输入 ~${_usageNumber(used)}${budget == null ? '' : ' / ${_usageNumber(budget)}'} · 输出 ~${_usageNumber(output)}${folds == 0 ? '' : ' · 已折叠 $folds 次'}',
            style: TextStyle(
              fontSize: 11.1111,
              color: warning
                  ? Colors.orange.withValues(alpha: .8)
                  : Theme.of(context).hintColor.withValues(alpha: .6),
            ),
          ),
        ),
      ),
    );
  }
}

class _Welcome extends StatelessWidget {
  const _Welcome({required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.only(bottom: 86),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: Column(
            children: <Widget>[
              const _ClaudeMark(size: 42),
              const SizedBox(height: 18),
              Text(
                _greetingText(controller),
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: _displayFontFamily(controller.settings),
                  fontFamilyFallback: _displayFontFallback(controller.settings),
                  fontSize: 32,
                  fontWeight: FontWeight.w500,
                  height: 1.05,
                  color: Color(0xFF3E3833),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _PrivateWelcome extends StatelessWidget {
  const _PrivateWelcome({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.only(bottom: 90),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const _LegacyIcon(
            _LegacyIconKind.ghost,
            size: 42,
            color: Color(0xFF101010),
          ),
          const SizedBox(height: 14),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 340),
            child: const Text(
              '私密对话不会写入历史，也不会参与本地记忆。关闭后，本轮内容会从页面里消失。',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                height: 1.28,
                color: Color(0xFF101010),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Semantics(
            link: true,
            label: '查看本地数据设置',
            excludeSemantics: true,
            child: GestureDetector(
              onTap: () => controller.open(AppSection.settings),
              child: const Text(
                '查看本地数据设置',
                style: TextStyle(
                  fontSize: _legacyChatBodyFontSize,
                  height: 1.2,
                  decoration: TextDecoration.underline,
                  decorationThickness: 1,
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _ClaudeMark extends StatelessWidget {
  const _ClaudeMark({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: Size.square(size),
    painter: const _ClaudeMarkPainter(_accent),
  );
}

class _ClaudeMarkPainter extends CustomPainter {
  const _ClaudeMarkPainter(this.color);

  final Color color;

  static const _ends = <Offset>[
    Offset(12.1, 3.9),
    Offset(8.9, 4.5),
    Offset(6.2, 6.6),
    Offset(4, 10.7),
    Offset(4, 13.7),
    Offset(6.4, 17.5),
    Offset(9.8, 20.2),
    Offset(13.7, 20.1),
    Offset(17.4, 18.1),
    Offset(20.1, 14.1),
    Offset(20, 10.3),
    Offset(17.5, 5.9),
    Offset(15.1, 4.4),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.shortestSide / 24;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8 * scale
      ..strokeCap = StrokeCap.round;
    final center = Offset(12 * scale, 12 * scale);
    for (final point in _ends) {
      canvas.drawLine(center, point * scale, paint);
    }
    canvas.drawCircle(
      center,
      2.1 * scale,
      Paint()
        ..color = color
        ..style = PaintingStyle.fill,
    );
  }

  @override
  bool shouldRepaint(covariant _ClaudeMarkPainter oldDelegate) =>
      oldDelegate.color != color;
}

enum _LegacyIconKind {
  menu,
  close,
  check,
  copy,
  refresh,
  send,
  stop,
  warning,
  thumbsUp,
  thumbsDown,
  branch,
  chevron,
  chevronRight,
  chat,
  star,
  ghost,
  plus,
  globe,
  shield,
  upload,
  download,
  database,
  microphone,
  waveform,
  tool,
  link,
  clock,
  search,
  brain,
  moon,
  user,
  trash,
  book,
  edit,
  file,
  pin,
  list,
  grid,
  diary,
  folder,
  workspace,
}

class _LegacyIcon extends StatelessWidget {
  const _LegacyIcon(this.kind, {required this.size, this.color});

  final _LegacyIconKind kind;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: CustomPaint(
      painter: _LegacyIconPainter(
        kind,
        color ?? IconTheme.of(context).color ?? const Color(0xFF101010),
      ),
    ),
  );
}

class _LegacyIconPainter extends CustomPainter {
  const _LegacyIconPainter(this.kind, this.color);

  final _LegacyIconKind kind;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.shortestSide / 24;
    canvas.save();
    canvas.scale(scale, scale);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.9
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    switch (kind) {
      case _LegacyIconKind.menu:
        canvas
          ..drawLine(const Offset(4, 6), const Offset(20, 6), paint)
          ..drawLine(const Offset(4, 12), const Offset(20, 12), paint)
          ..drawLine(const Offset(4, 18), const Offset(12, 18), paint);
      case _LegacyIconKind.close:
        canvas
          ..drawLine(const Offset(18, 6), const Offset(6, 18), paint)
          ..drawLine(const Offset(6, 6), const Offset(18, 18), paint);
      case _LegacyIconKind.check:
        canvas.drawPath(
          Path()
            ..moveTo(20, 6)
            ..lineTo(9, 17)
            ..lineTo(4, 12),
          paint,
        );
      case _LegacyIconKind.copy:
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(9, 9, 11, 11),
            const Radius.circular(2),
          ),
          paint,
        );
        canvas.drawPath(
          Path()
            ..moveTo(5, 15)
            ..lineTo(4, 15)
            ..cubicTo(2.9, 15, 2, 14.1, 2, 13)
            ..lineTo(2, 4)
            ..cubicTo(2, 2.9, 2.9, 2, 4, 2)
            ..lineTo(13, 2)
            ..cubicTo(14.1, 2, 15, 2.9, 15, 4)
            ..lineTo(15, 5),
          paint,
        );
      case _LegacyIconKind.refresh:
        canvas.drawPath(
          Path()
            ..moveTo(21, 12)
            ..arcToPoint(
              const Offset(5.5, 18.2),
              radius: const Radius.circular(9),
            ),
          paint,
        );
        canvas.drawPath(
          Path()
            ..moveTo(3, 12)
            ..arcToPoint(
              const Offset(18.5, 5.8),
              radius: const Radius.circular(9),
            ),
          paint,
        );
        canvas
          ..drawPath(
            Path()
              ..moveTo(18, 2)
              ..lineTo(18, 6)
              ..lineTo(22, 6),
            paint,
          )
          ..drawPath(
            Path()
              ..moveTo(6, 22)
              ..lineTo(6, 18)
              ..lineTo(2, 18),
            paint,
          );
      case _LegacyIconKind.send:
        canvas
          ..drawPath(
            Path()
              ..moveTo(22, 2)
              ..lineTo(15, 22)
              ..lineTo(11, 13)
              ..lineTo(2, 9)
              ..close(),
            paint,
          )
          ..drawLine(const Offset(22, 2), const Offset(11, 13), paint);
      case _LegacyIconKind.stop:
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(7, 7, 10, 10),
            const Radius.circular(2),
          ),
          paint,
        );
      case _LegacyIconKind.warning:
        canvas
          ..drawPath(
            Path()
              ..moveTo(12, 4)
              ..lineTo(21, 20)
              ..lineTo(3, 20)
              ..close(),
            paint,
          )
          ..drawLine(const Offset(12, 10), const Offset(12, 13), paint)
          ..drawCircle(const Offset(12, 17), 1, paint);
      case _LegacyIconKind.thumbsUp:
        canvas
          ..drawLine(const Offset(7, 10), const Offset(7, 21), paint)
          ..drawPath(
            Path()
              ..moveTo(15, 5.9)
              ..lineTo(14, 10)
              ..lineTo(19.8, 10)
              ..cubicTo(21.05, 10, 22, 11.15, 21.8, 12.3)
              ..lineTo(20.4, 19.3)
              ..cubicTo(20.2, 20.3, 19.4, 21, 18.4, 21)
              ..lineTo(7, 21)
              ..cubicTo(5.34, 21, 4, 19.66, 4, 18)
              ..lineTo(4, 13)
              ..cubicTo(4, 11.34, 5.34, 10, 7, 10)
              ..lineTo(8.3, 10)
              ..lineTo(12, 4)
              ..cubicTo(12.9, 2.55, 15.25, 3.45, 15, 5.9)
              ..close(),
            paint,
          );
      case _LegacyIconKind.thumbsDown:
        canvas
          ..drawLine(const Offset(17, 14), const Offset(17, 3), paint)
          ..drawPath(
            Path()
              ..moveTo(9, 18.1)
              ..lineTo(10, 14)
              ..lineTo(4.2, 14)
              ..cubicTo(2.95, 14, 2, 12.85, 2.2, 11.7)
              ..lineTo(3.6, 4.7)
              ..cubicTo(3.8, 3.7, 4.6, 3, 5.6, 3)
              ..lineTo(17, 3)
              ..cubicTo(18.66, 3, 20, 4.34, 20, 6)
              ..lineTo(20, 11)
              ..cubicTo(20, 12.66, 18.66, 14, 17, 14)
              ..lineTo(15.7, 14)
              ..lineTo(12, 20)
              ..cubicTo(11.1, 21.45, 8.75, 20.55, 9, 18.1)
              ..close(),
            paint,
          );
      case _LegacyIconKind.branch:
        canvas.drawPath(
          Path()
            ..moveTo(6, 3)
            ..lineTo(6, 9)
            ..cubicTo(6, 10.66, 7.34, 12, 9, 12)
            ..lineTo(18, 12),
          paint,
        );
        canvas
          ..drawPath(
            Path()
              ..moveTo(15, 9)
              ..lineTo(18, 12)
              ..lineTo(15, 15),
            paint,
          )
          ..drawLine(const Offset(6, 21), const Offset(6, 15), paint);
      case _LegacyIconKind.chevron:
        canvas.drawPath(
          Path()
            ..moveTo(6, 9)
            ..lineTo(12, 15)
            ..lineTo(18, 9),
          paint,
        );
      case _LegacyIconKind.chevronRight:
        canvas.drawPath(
          Path()
            ..moveTo(9, 18)
            ..lineTo(15, 12)
            ..lineTo(9, 6),
          paint,
        );
      case _LegacyIconKind.chat:
        canvas.drawPath(
          Path()
            ..moveTo(21, 15)
            ..cubicTo(21, 17.2, 19.2, 19, 17, 19)
            ..lineTo(7, 19)
            ..lineTo(3, 23)
            ..lineTo(3, 7)
            ..cubicTo(3, 4.8, 4.8, 3, 7, 3)
            ..lineTo(17, 3)
            ..cubicTo(19.2, 3, 21, 4.8, 21, 7)
            ..close(),
          paint,
        );
      case _LegacyIconKind.star:
        canvas.drawPath(
          Path()
            ..moveTo(12, 2)
            ..lineTo(15.1, 8.3)
            ..lineTo(22, 9.3)
            ..lineTo(17, 14.2)
            ..lineTo(18.2, 21)
            ..lineTo(12, 17.8)
            ..lineTo(5.8, 21)
            ..lineTo(7, 14.2)
            ..lineTo(2, 9.3)
            ..lineTo(8.9, 8.3)
            ..close(),
          paint,
        );
      case _LegacyIconKind.plus:
        canvas
          ..drawLine(const Offset(12, 5), const Offset(12, 19), paint)
          ..drawLine(const Offset(5, 12), const Offset(19, 12), paint);
      case _LegacyIconKind.waveform:
        canvas
          ..drawLine(const Offset(4, 12), const Offset(4.01, 12), paint)
          ..drawLine(const Offset(8, 8), const Offset(8, 16), paint)
          ..drawLine(const Offset(12, 5), const Offset(12, 19), paint)
          ..drawLine(const Offset(16, 8), const Offset(16, 16), paint)
          ..drawLine(const Offset(20, 12), const Offset(20.01, 12), paint);
      case _LegacyIconKind.tool:
        canvas.drawPath(
          Path()
            ..moveTo(14.7, 6.3)
            ..cubicTo(12.75, 4.35, 9.65, 4.75, 8.2, 7.1)
            ..cubicTo(7.35, 8.5, 7.35, 10.15, 8.15, 11.45)
            ..lineTo(3, 18)
            ..lineTo(6, 21)
            ..lineTo(12.7, 14.3)
            ..cubicTo(14.35, 15.25, 16.5, 14.95, 17.9, 13.55)
            ..cubicTo(19.05, 12.4, 19.45, 10.7, 18.95, 9.2)
            ..lineTo(15.1, 12.9)
            ..lineTo(12.1, 9.9)
            ..close(),
          paint,
        );
      case _LegacyIconKind.link:
        canvas.drawPath(
          Path()
            ..moveTo(10, 13)
            ..cubicTo(11.95, 14.95, 15.15, 14.95, 17.1, 13)
            ..lineTo(19.1, 11)
            ..cubicTo(21.85, 8.25, 19.9, 3.5, 16, 3.5)
            ..cubicTo(14.7, 3.5, 13.45, 4, 12.5, 4.9)
            ..lineTo(10.9, 6.5),
          paint,
        );
        canvas.drawPath(
          Path()
            ..moveTo(14, 11)
            ..cubicTo(12.05, 9.05, 8.85, 9.05, 6.9, 11)
            ..lineTo(4.9, 13)
            ..cubicTo(2.15, 15.75, 4.1, 20.5, 8, 20.5)
            ..cubicTo(9.3, 20.5, 10.55, 20, 11.5, 19.1)
            ..lineTo(13.1, 17.5),
          paint,
        );
      case _LegacyIconKind.clock:
        canvas
          ..drawCircle(const Offset(12, 12), 9, paint)
          ..drawLine(const Offset(12, 7), const Offset(12, 12), paint)
          ..drawLine(const Offset(12, 12), const Offset(15, 14), paint);
      case _LegacyIconKind.search:
        canvas
          ..drawCircle(const Offset(11, 11), 7, paint)
          ..drawLine(const Offset(16.5, 16.5), const Offset(20, 20), paint);
      case _LegacyIconKind.brain:
        canvas.drawPath(
          Path()
            ..moveTo(12, 2)
            ..cubicTo(14.76, 2, 17, 4.24, 17, 7)
            ..cubicTo(17, 12, 12, 18, 12, 18)
            ..cubicTo(12, 18, 7, 12, 7, 7)
            ..cubicTo(7, 4.24, 9.24, 2, 12, 2)
            ..close(),
          paint,
        );
        canvas
          ..drawLine(const Offset(12, 20), const Offset(12, 17), paint)
          ..drawPath(
            Path()
              ..moveTo(7, 8)
              ..cubicTo(8.7, 3.8, 15.3, 3.8, 17, 8),
            paint,
          );
      case _LegacyIconKind.moon:
        canvas.drawPath(
          Path()
            ..moveTo(12, 3)
            ..cubicTo(11.2, 7.6, 15.5, 11.8, 21, 12)
            ..cubicTo(20, 17.1, 15.5, 20.7, 10.3, 20)
            ..cubicTo(5.5, 19.4, 2.1, 15, 3.1, 10.2)
            ..cubicTo(3.9, 6.3, 7.6, 3.4, 12, 3)
            ..close(),
          paint,
        );
      case _LegacyIconKind.user:
        canvas.drawPath(
          Path()
            ..moveTo(20, 21)
            ..cubicTo(19.3, 16.8, 16.1, 14, 12, 14)
            ..cubicTo(7.9, 14, 4.7, 16.8, 4, 21),
          paint,
        );
        canvas.drawCircle(const Offset(12, 7), 4, paint);
      case _LegacyIconKind.trash:
        canvas
          ..drawLine(const Offset(3, 6), const Offset(21, 6), paint)
          ..drawPath(
            Path()
              ..moveTo(8, 6)
              ..lineTo(8, 4)
              ..lineTo(16, 4)
              ..lineTo(16, 6),
            paint,
          )
          ..drawPath(
            Path()
              ..moveTo(19, 6)
              ..lineTo(18, 21)
              ..lineTo(6, 21)
              ..lineTo(5, 6),
            paint,
          )
          ..drawLine(const Offset(10, 11), const Offset(10, 17), paint)
          ..drawLine(const Offset(14, 11), const Offset(14, 17), paint);
      case _LegacyIconKind.book:
        canvas.drawPath(
          Path()
            ..moveTo(4, 19.5)
            ..cubicTo(4, 18.1, 5.1, 17, 6.5, 17)
            ..lineTo(21, 17),
          paint,
        );
        canvas.drawPath(
          Path()
            ..moveTo(4, 4.5)
            ..cubicTo(4, 3.1, 5.1, 2, 6.5, 2)
            ..lineTo(21, 2)
            ..lineTo(21, 22)
            ..lineTo(6.5, 22)
            ..cubicTo(5.1, 22, 4, 20.9, 4, 19.5)
            ..close(),
          paint,
        );
      case _LegacyIconKind.edit:
        canvas.drawLine(const Offset(12, 20), const Offset(21, 20), paint);
        canvas.drawPath(
          Path()
            ..moveTo(16.5, 3.5)
            ..cubicTo(17.3, 2.7, 18.7, 2.7, 19.5, 3.5)
            ..cubicTo(20.3, 4.3, 20.3, 5.7, 19.5, 6.5)
            ..lineTo(7, 19)
            ..lineTo(3, 20)
            ..lineTo(4, 16)
            ..close(),
          paint,
        );
      case _LegacyIconKind.file:
        canvas.drawPath(
          Path()
            ..moveTo(14, 2)
            ..lineTo(6, 2)
            ..cubicTo(4.9, 2, 4, 2.9, 4, 4)
            ..lineTo(4, 20)
            ..cubicTo(4, 21.1, 4.9, 22, 6, 22)
            ..lineTo(18, 22)
            ..cubicTo(19.1, 22, 20, 21.1, 20, 20)
            ..lineTo(20, 8)
            ..close(),
          paint,
        );
        canvas
          ..drawPath(
            Path()
              ..moveTo(14, 2)
              ..lineTo(14, 8)
              ..lineTo(20, 8),
            paint,
          )
          ..drawLine(const Offset(8, 13), const Offset(16, 13), paint)
          ..drawLine(const Offset(8, 17), const Offset(13, 17), paint);
      case _LegacyIconKind.globe:
        canvas
          ..drawCircle(const Offset(12, 12), 10, paint)
          ..drawLine(const Offset(2, 12), const Offset(22, 12), paint);
        canvas.drawPath(
          Path()
            ..moveTo(12, 2)
            ..cubicTo(19, 6, 19, 18, 12, 22),
          paint,
        );
        canvas.drawPath(
          Path()
            ..moveTo(12, 2)
            ..cubicTo(5, 6, 5, 18, 12, 22),
          paint,
        );
      case _LegacyIconKind.shield:
        canvas.drawPath(
          Path()
            ..moveTo(12, 22)
            ..cubicTo(12, 22, 20, 18, 20, 12)
            ..lineTo(20, 5)
            ..lineTo(12, 2)
            ..lineTo(4, 5)
            ..lineTo(4, 12)
            ..cubicTo(4, 18, 12, 22, 12, 22)
            ..close(),
          paint,
        );
        canvas
          ..drawLine(const Offset(9, 12), const Offset(15, 12), paint)
          ..drawLine(const Offset(12, 9), const Offset(12, 15), paint);
      case _LegacyIconKind.upload:
        canvas.drawPath(
          Path()
            ..moveTo(21, 15)
            ..lineTo(21, 19)
            ..cubicTo(21, 20.1, 20.1, 21, 19, 21)
            ..lineTo(5, 21)
            ..cubicTo(3.9, 21, 3, 20.1, 3, 19)
            ..lineTo(3, 15),
          paint,
        );
        canvas.drawPath(
          Path()
            ..moveTo(17, 8)
            ..lineTo(12, 3)
            ..lineTo(7, 8),
          paint,
        );
        canvas.drawLine(const Offset(12, 3), const Offset(12, 15), paint);
      case _LegacyIconKind.download:
        canvas.drawPath(
          Path()
            ..moveTo(21, 15)
            ..lineTo(21, 19)
            ..cubicTo(21, 20.1, 20.1, 21, 19, 21)
            ..lineTo(5, 21)
            ..cubicTo(3.9, 21, 3, 20.1, 3, 19)
            ..lineTo(3, 15),
          paint,
        );
        canvas.drawPath(
          Path()
            ..moveTo(7, 10)
            ..lineTo(12, 15)
            ..lineTo(17, 10),
          paint,
        );
        canvas.drawLine(const Offset(12, 15), const Offset(12, 3), paint);
      case _LegacyIconKind.database:
        canvas.drawOval(const Rect.fromLTWH(3, 2, 18, 6), paint);
        canvas.drawPath(
          Path()
            ..moveTo(3, 5)
            ..lineTo(3, 19)
            ..cubicTo(3, 20.7, 7, 22, 12, 22)
            ..cubicTo(17, 22, 21, 20.7, 21, 19)
            ..lineTo(21, 5),
          paint,
        );
        canvas.drawPath(
          Path()
            ..moveTo(3, 12)
            ..cubicTo(3, 13.7, 7, 15, 12, 15)
            ..cubicTo(17, 15, 21, 13.7, 21, 12),
          paint,
        );
      case _LegacyIconKind.microphone:
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(9, 2, 6, 13),
            const Radius.circular(3),
          ),
          paint,
        );
        canvas.drawPath(
          Path()
            ..moveTo(19, 10)
            ..lineTo(19, 12)
            ..cubicTo(19, 15.87, 15.87, 19, 12, 19)
            ..cubicTo(8.13, 19, 5, 15.87, 5, 12)
            ..lineTo(5, 10),
          paint,
        );
        canvas.drawLine(const Offset(12, 19), const Offset(12, 22), paint);
      case _LegacyIconKind.ghost:
        canvas
          ..drawLine(const Offset(9, 10), const Offset(9.01, 10), paint)
          ..drawLine(const Offset(15, 10), const Offset(15.01, 10), paint);
        canvas.drawPath(
          Path()
            ..moveTo(12, 2)
            ..cubicTo(7.58, 2, 4, 5.58, 4, 10)
            ..lineTo(4, 20)
            ..lineTo(6.6, 18.2)
            ..lineTo(9.2, 20)
            ..lineTo(12, 18.2)
            ..lineTo(14.8, 20)
            ..lineTo(17.4, 18.2)
            ..lineTo(20, 20)
            ..lineTo(20, 10)
            ..cubicTo(20, 5.58, 16.42, 2, 12, 2)
            ..close(),
          paint,
        );
      case _LegacyIconKind.pin:
        canvas.drawPath(
          Path()
            ..moveTo(12, 2)
            ..cubicTo(9.24, 2, 7, 4.24, 7, 7)
            ..cubicTo(7, 10.5, 4, 12, 4, 12)
            ..lineTo(20, 12)
            ..cubicTo(20, 12, 17, 10.5, 17, 7)
            ..cubicTo(17, 4.24, 14.76, 2, 12, 2)
            ..close(),
          paint,
        );
        canvas
          ..drawLine(const Offset(7, 8), const Offset(17, 8), paint)
          ..drawLine(const Offset(12, 12), const Offset(12, 20), paint)
          ..drawLine(const Offset(12, 20), const Offset(12, 17), paint);
      case _LegacyIconKind.list:
        canvas
          ..drawLine(const Offset(9, 6), const Offset(20, 6), paint)
          ..drawLine(const Offset(9, 12), const Offset(20, 12), paint)
          ..drawLine(const Offset(9, 18), const Offset(20, 18), paint)
          ..drawLine(const Offset(4, 6), const Offset(4.01, 6), paint)
          ..drawLine(const Offset(4, 12), const Offset(4.01, 12), paint)
          ..drawLine(const Offset(4, 18), const Offset(4.01, 18), paint);
      case _LegacyIconKind.grid:
        canvas
          ..drawRect(const Rect.fromLTWH(3, 3, 7, 7), paint)
          ..drawRect(const Rect.fromLTWH(14, 3, 7, 7), paint)
          ..drawRect(const Rect.fromLTWH(3, 14, 7, 7), paint)
          ..drawRect(const Rect.fromLTWH(14, 14, 7, 7), paint);
      case _LegacyIconKind.diary:
        canvas.drawPath(
          Path()
            ..moveTo(5, 4)
            ..lineTo(17, 4)
            ..cubicTo(18.1, 4, 19, 4.9, 19, 6)
            ..lineTo(19, 20)
            ..lineTo(7, 20)
            ..cubicTo(5.9, 20, 5, 19.1, 5, 18)
            ..close(),
          paint,
        );
        canvas
          ..drawLine(const Offset(5, 17), const Offset(19, 17), paint)
          ..drawLine(const Offset(8, 4), const Offset(8, 17), paint);
      case _LegacyIconKind.folder:
        canvas.drawPath(
          Path()
            ..moveTo(3, 6)
            ..lineTo(9, 6)
            ..lineTo(11, 9)
            ..lineTo(21, 9)
            ..lineTo(21, 19)
            ..cubicTo(21, 20.1, 20.1, 21, 19, 21)
            ..lineTo(5, 21)
            ..cubicTo(3.9, 21, 3, 20.1, 3, 19)
            ..close(),
          paint,
        );
      case _LegacyIconKind.workspace:
        canvas
          ..drawRect(const Rect.fromLTWH(3, 3, 7, 7), paint)
          ..drawRect(const Rect.fromLTWH(14, 3, 7, 7), paint)
          ..drawRect(const Rect.fromLTWH(3, 14, 7, 7), paint);
        canvas.drawPath(
          Path()
            ..moveTo(17.5, 13)
            ..lineTo(22, 17.5)
            ..lineTo(17.5, 22)
            ..lineTo(13, 17.5)
            ..close(),
          paint,
        );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _LegacyIconPainter oldDelegate) =>
      oldDelegate.kind != kind || oldDelegate.color != color;
}

class _MessageList extends StatefulWidget {
  const _MessageList({required this.controller, super.key});
  final AppController controller;

  @override
  State<_MessageList> createState() => _MessageListState();
}

class _MessageListState extends State<_MessageList> {
  late final ScrollController _scroll;
  late final String _conversationId;
  bool _stickToBottom = true;
  bool _bottomSettleScheduled = false;
  bool _reserveLegacyScrollbar = false;
  bool _revealed = false;

  AppController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _conversationId = controller.activeConversation?.id ?? '';
    final viewport = controller.takeChatViewportRequest(_conversationId);
    final restoring = viewport?.disposition == ChatViewportDisposition.restore;
    _scroll = ScrollController(
      initialScrollOffset: restoring ? viewport?.offset ?? 0 : 0,
    );
    _stickToBottom = !restoring;
    _revealed = restoring;
    _reserveLegacyScrollbar =
        restoring && (viewport?.reserveLegacyScrollbar ?? false);
    _scroll.addListener(_trackPosition);
    WidgetsBinding.instance.addPostFrameCallback((_) => _recordPosition());
  }

  void _trackPosition() {
    if (!_scroll.hasClients) return;
    _stickToBottom = _scroll.position.extentAfter < 140;
    _recordPosition();
  }

  void _recordPosition() {
    if (!_scroll.hasClients || _conversationId.isEmpty) return;
    controller.recordChatViewport(
      _conversationId,
      _scroll.position.pixels,
      scrollable: _scroll.position.maxScrollExtent > .5,
    );
  }

  @override
  void dispose() {
    _recordPosition();
    _scroll
      ..removeListener(_trackPosition)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final items = <ChatMessage>[...controller.messages];
    if (controller.busy ||
        controller.streamingText.isNotEmpty ||
        controller.streamingReasoning.isNotEmpty ||
        controller.streamingParts.isNotEmpty) {
      items.add(
        ChatMessage(
          id: 'stream',
          conversationId: controller.activeConversation?.id ?? '',
          sequence: items.length + 1,
          role: 'assistant',
          content: controller.streamingText,
          metadataJson: jsonEncode(<String, Object?>{
            if (controller.streamingReasoning.isNotEmpty)
              'reasoning': controller.streamingReasoning,
          }),
          createdAt: DateTime.now(),
        ),
      );
    }
    if (_stickToBottom) _scheduleBottomSettle();
    final list = NotificationListener<ScrollStartNotification>(
      onNotification: (notification) {
        // Stop automatic bottom settling as soon as the user's drag begins.
        // Waiting for the first changed scroll offset lets a streaming rebuild
        // jump the list back under the finger and makes the page feel locked.
        if (notification.dragDetails != null) {
          _stickToBottom = false;
          FocusManager.instance.primaryFocus?.unfocus();
        }
        return false;
      },
      child: Listener(
        onPointerMove: (_) => FocusManager.instance.primaryFocus?.unfocus(),
        child: ListView.builder(
          key: const Key('chat-message-list'),
          controller: _scroll,
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: EdgeInsets.fromLTRB(
            18,
            8,
            18 + (_reserveLegacyScrollbar ? 15.333333 : 0),
            // Legacy `.messages` contributes 12px and its nested `.thread`
            // contributes another 10px. The Flutter list flattens those nodes.
            22,
          ),
          itemCount: items.length,
          itemBuilder: (context, index) => Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 820),
              child: _MessageBubble(
                controller: controller,
                message: items[index],
                streaming: items[index].id == 'stream',
                bottomSpacing: index == items.length - 1 ? 0 : 12,
              ),
            ),
          ),
        ),
      ),
    );
    return AnimatedOpacity(
      opacity: _revealed ? 1 : 0,
      duration: const Duration(milliseconds: 80),
      curve: Curves.easeOut,
      child: RepaintBoundary(child: list),
    );
  }

  void _scheduleBottomSettle() {
    if (_bottomSettleScheduled) return;
    _bottomSettleScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _settleAtBottom(0);
    });
  }

  void _settleAtBottom(int pass) {
    if (!mounted || !_scroll.hasClients || !_stickToBottom) {
      _bottomSettleScheduled = false;
      if (mounted && !_revealed) setState(() => _revealed = true);
      return;
    }
    final reserveScrollbar = _scroll.position.maxScrollExtent > .5;
    if (reserveScrollbar != _reserveLegacyScrollbar) {
      _bottomSettleScheduled = false;
      setState(() => _reserveLegacyScrollbar = reserveScrollbar);
      return;
    }
    _scroll.jumpTo(_scroll.position.maxScrollExtent);
    _recordPosition();
    if (pass < 2) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _settleAtBottom(pass + 1);
      });
      WidgetsBinding.instance.scheduleFrame();
      return;
    }
    _bottomSettleScheduled = false;
    if (!_revealed) setState(() => _revealed = true);
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.controller,
    required this.message,
    required this.streaming,
    required this.bottomSpacing,
  });
  final AppController controller;
  final ChatMessage message;
  final bool streaming;
  final double bottomSpacing;

  @override
  Widget build(BuildContext context) {
    final user = message.role == 'user';
    final reasoning = _reasoning(message.metadataJson);
    final messageParts = streaming
        ? _streamingParts()
        : controller.partsForMessage(message.id);
    final showAvatar = user
        ? controller.settings['showUserAvatar'] == true
        : controller.settings['showAssistantAvatar'] == true;
    final feedback = _metadataValue(message.metadataJson, 'feedback');
    return Padding(
      // CSS grid `gap` exists only between legacy message articles; it does
      // not add trailing space after the final message.
      padding: EdgeInsets.only(bottom: bottomSpacing),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: user
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        children: <Widget>[
          if (showAvatar) ...<Widget>[
            CircleAvatar(
              radius: 16,
              backgroundColor: _accent.withValues(alpha: .14),
              child: Icon(
                user ? Icons.person_outline : Icons.auto_awesome,
                size: 17,
                color: _accent,
              ),
            ),
            const SizedBox(width: 11),
          ],
          Flexible(
            child: Column(
              crossAxisAlignment: user
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.start,
              children: <Widget>[
                if (!user) const SizedBox(height: 2),
                if (user)
                  _LegacyUserMessage(
                    controller: controller,
                    message: message,
                    streaming: streaming,
                  )
                else
                  ..._assistantPartWidgets(
                    context,
                    messageParts,
                    fallbackReasoning: reasoning,
                  ),
                if (!streaming)
                  FutureBuilder<List<PendingAttachment>>(
                    future: message.id.startsWith('private-')
                        ? Future.value(const <PendingAttachment>[])
                        : controller.attachments.forMessage(message.id),
                    builder: (context, snapshot) {
                      final items =
                          snapshot.data ?? const <PendingAttachment>[];
                      if (items.isEmpty) return const SizedBox.shrink();
                      return Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: _AttachmentGallery(
                          controller: controller,
                          items: items,
                        ),
                      );
                    },
                  ),
                if (!streaming && !user)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Theme(
                        data: Theme.of(context).copyWith(
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              IconButton(
                                onPressed: () {
                                  Clipboard.setData(
                                    ClipboardData(text: message.content),
                                  );
                                  _snack(context, '消息已复制');
                                },
                                icon: const _LegacyIcon(
                                  _LegacyIconKind.copy,
                                  size: 16,
                                  color: _lightMuted,
                                ),
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints.tightFor(
                                  width: 30,
                                  height: 30,
                                ),
                                tooltip: '复制',
                              ),
                              const SizedBox(width: 1),
                              IconButton(
                                onPressed: () =>
                                    controller.retryAssistantMessage(message),
                                icon: const _LegacyIcon(
                                  _LegacyIconKind.refresh,
                                  size: 16,
                                  color: _lightMuted,
                                ),
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints.tightFor(
                                  width: 30,
                                  height: 30,
                                ),
                                tooltip: '重新回答',
                              ),
                              const SizedBox(width: 1),
                              IconButton(
                                onPressed: () =>
                                    controller.exportMessage(message),
                                icon: const _LegacyIcon(
                                  _LegacyIconKind.download,
                                  size: 16,
                                  color: _lightMuted,
                                ),
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints.tightFor(
                                  width: 30,
                                  height: 30,
                                ),
                                tooltip: '导出',
                              ),
                              const SizedBox(width: 1),
                              IconButton(
                                onPressed: () =>
                                    controller.rateMessage(message, 'positive'),
                                icon: _LegacyIcon(
                                  _LegacyIconKind.thumbsUp,
                                  size: 16,
                                  color: feedback == 'positive'
                                      ? _lightText
                                      : _lightMuted,
                                ),
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints.tightFor(
                                  width: 30,
                                  height: 30,
                                ),
                                tooltip: '赞',
                              ),
                              const SizedBox(width: 1),
                              IconButton(
                                onPressed: () =>
                                    controller.rateMessage(message, 'negative'),
                                icon: _LegacyIcon(
                                  _LegacyIconKind.thumbsDown,
                                  size: 16,
                                  color: feedback == 'negative'
                                      ? _lightText
                                      : _lightMuted,
                                ),
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints.tightFor(
                                  width: 30,
                                  height: 30,
                                ),
                                tooltip: '踩',
                              ),
                              const SizedBox(width: 1),
                              if (!controller.privateMode)
                                IconButton(
                                  onPressed: () =>
                                      controller.branchFromMessage(message),
                                  icon: const _LegacyIcon(
                                    _LegacyIconKind.branch,
                                    size: 16,
                                    color: _lightMuted,
                                  ),
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints.tightFor(
                                    width: 30,
                                    height: 30,
                                  ),
                                  tooltip: '分支',
                                ),
                              if (!controller.privateMode) ...<Widget>[
                                const SizedBox(width: 1),
                                IconButton(
                                  onPressed:
                                      controller.voiceBusyMessageIds.contains(
                                        message.id,
                                      )
                                      ? () => controller.stopVoiceGeneration(
                                          message.id,
                                        )
                                      : () => controller.playMessageVoice(
                                          message,
                                        ),
                                  icon:
                                      controller.voiceBusyMessageIds.contains(
                                        message.id,
                                      )
                                      ? const Icon(
                                          Icons.stop_rounded,
                                          size: 15,
                                          color: _lightMuted,
                                        )
                                      : Icon(
                                          controller.playingVoiceId != null &&
                                                  controller.playingVoiceId ==
                                                      controller
                                                          .voiceForMessage(
                                                            message.id,
                                                          )
                                                          ?.id
                                              ? Icons.stop_circle_outlined
                                              : Icons.play_arrow_rounded,
                                          size: 17,
                                          color: _lightMuted,
                                        ),
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints.tightFor(
                                    width: 30,
                                    height: 30,
                                  ),
                                  tooltip:
                                      controller.voiceBusyMessageIds.contains(
                                        message.id,
                                      )
                                      ? '停止生成语音'
                                      : '播放语音',
                                ),
                                const SizedBox(width: 1),
                                IconButton(
                                  onPressed:
                                      controller.voiceBusyMessageIds.contains(
                                        message.id,
                                      )
                                      ? null
                                      : () => controller.toggleVoiceFavorite(
                                          message,
                                        ),
                                  icon: Icon(
                                    controller
                                                .voiceForMessage(message.id)
                                                ?.favorite ==
                                            true
                                        ? Icons.favorite
                                        : Icons.favorite_border,
                                    size: 17,
                                    color:
                                        controller
                                                .voiceForMessage(message.id)
                                                ?.favorite ==
                                            true
                                        ? _accent
                                        : _lightMuted,
                                  ),
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints.tightFor(
                                    width: 30,
                                    height: 30,
                                  ),
                                  tooltip: '收藏语音',
                                ),
                                const SizedBox(width: 1),
                                IconButton(
                                  onPressed: () => _showMessageVoices(context),
                                  icon: const Icon(
                                    Icons.library_music_outlined,
                                    size: 17,
                                    color: _lightMuted,
                                  ),
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints.tightFor(
                                    width: 30,
                                    height: 30,
                                  ),
                                  tooltip: '选择绑定的声音',
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showMessageVoices(BuildContext context) =>
      showGeneralDialog<void>(
        context: context,
        barrierDismissible: false,
        transitionDuration: const Duration(milliseconds: 180),
        transitionBuilder: (context, animation, _, child) => SlideTransition(
          position: Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero)
              .animate(
                CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
              ),
          child: child,
        ),
        pageBuilder: (dialogContext, _, _) => _MessageVoicesPage(
          controller: controller,
          message: message,
          onBack: () => Navigator.pop(dialogContext),
        ),
      );

  List<String> _reasoning(String metadata) {
    try {
      final decoded = jsonDecode(metadata);
      if (decoded is! Map) return const <String>[];
      final values = decoded.cast<String, Object?>();
      for (final key in const <String>[
        'reasoning',
        'reasoning_content',
        'reasoningContent',
        'reasoning_text',
        'reasoningText',
        'analysis_content',
        'analysisContent',
        'analysis',
        'thinking',
        'thought',
        'thoughts',
      ]) {
        final restored = _reasoningValues(values[key]);
        if (restored.isNotEmpty) return restored;
      }
      final restoredParts = _reasoningParts(values['parts']);
      if (restoredParts.isNotEmpty) return restoredParts;
      final legacy = values['legacy'];
      if (legacy is Map) {
        final legacyValues = legacy.cast<String, Object?>();
        for (final key in const <String>[
          'reasoning',
          'reasoning_content',
          'reasoningContent',
          'reasoning_text',
          'reasoningText',
          'analysis_content',
          'analysisContent',
          'analysis',
          'thinking',
          'thought',
          'thoughts',
        ]) {
          final restored = _reasoningValues(legacyValues[key]);
          if (restored.isNotEmpty) return restored;
        }
        return _reasoningParts(legacyValues['parts']);
      }
    } on Object {
      // A malformed optional metadata field must not hide the message.
    }
    return const <String>[];
  }

  List<String> _reasoningValues(Object? raw) {
    if (raw is String) {
      return raw.trim().isEmpty ? const <String>[] : <String>[raw];
    }
    if (raw is! List) return const <String>[];
    return raw
        .map((item) {
          if (item is String) return item;
          if (item is Map) {
            return '${item['content'] ?? item['text'] ?? item['reasoning'] ?? item['analysis'] ?? item['thinking'] ?? ''}';
          }
          return '';
        })
        .where((value) => value.trim().isNotEmpty)
        .toList();
  }

  List<String> _reasoningParts(Object? raw) {
    if (raw is! List) return const <String>[];
    return raw
        .whereType<Map>()
        .where((part) {
          final type = '${part['type'] ?? ''}'.toLowerCase();
          return const <String>{
            'thought',
            'thinking',
            'reasoning',
          }.contains(type);
        })
        .map((part) {
          return '${part['content'] ?? part['text'] ?? part['reasoning'] ?? ''}';
        })
        .where((value) => value.trim().isNotEmpty)
        .toList();
  }

  List<MessagePart> _streamingParts() {
    final now = DateTime.now();
    final output = <MessagePart>[
      MessagePart(
        id: 'stream-replying-status',
        messageId: 'stream',
        sequence: 0,
        type: 'status',
        metadataJson: canonicalJson(<String, Object?>{'status': 'replying'}),
        createdAt: now,
      ),
    ];
    for (final entry in controller.streamingParts.indexed) {
      if (entry.$2.type == 'status') continue;
      final status = '${entry.$2.metadata['status'] ?? ''}';
      if (entry.$2.type == 'tool' &&
          (status == 'preparing' || status == 'running')) {
        continue;
      }
      output.add(
        MessagePart(
          id: 'stream-part-${entry.$1}',
          messageId: 'stream',
          sequence: output.length,
          type: entry.$2.type,
          content: entry.$2.content,
          metadataJson: canonicalJson(entry.$2.metadata),
          createdAt: now,
        ),
      );
    }
    final committedReasoning = output
        .where((part) => part.type == 'thought')
        .map((part) => part.content ?? '')
        .join();
    final pendingReasoning =
        controller.streamingReasoning.startsWith(committedReasoning)
        ? controller.streamingReasoning.substring(committedReasoning.length)
        : controller.streamingReasoning;
    if (pendingReasoning.isNotEmpty) {
      output.add(
        MessagePart(
          id: 'stream-thought',
          messageId: 'stream',
          sequence: output.length,
          type: 'thought',
          content: pendingReasoning,
          createdAt: now,
        ),
      );
    }
    final committedText = output
        .where((part) => part.type == 'content')
        .map((part) => part.content ?? '')
        .join();
    final pendingText = controller.streamingText.startsWith(committedText)
        ? controller.streamingText.substring(committedText.length)
        : controller.streamingText;
    if (pendingText.isNotEmpty) {
      output.add(
        MessagePart(
          id: 'stream-content',
          messageId: 'stream',
          sequence: output.length,
          type: 'content',
          content: pendingText,
          createdAt: now,
        ),
      );
    }
    final progress = controller.streamingToolProgress;
    final completedTools = output.where((part) => part.type == 'tool').length;
    output.add(
      MessagePart(
        id: 'stream-response-status',
        messageId: 'stream',
        sequence: output.length,
        type: 'status',
        metadataJson: canonicalJson(<String, Object?>{
          'status': 'response_progress',
          'label': progress == null ? '小机子正在组织回复' : _toolProcessLabel(progress),
          if (completedTools > 0) 'detail': '已完成 $completedTools 次工具调用，正在继续处理。',
        }),
        createdAt: now,
      ),
    );
    return output;
  }

  List<Widget> _assistantPartWidgets(
    BuildContext context,
    List<MessagePart> parts, {
    required List<String> fallbackReasoning,
  }) {
    final hasContent = parts.any(
      (part) => part.type == 'content' && (part.content ?? '').isNotEmpty,
    );
    bool isThoughtPart(MessagePart part) =>
        const <String>{
          'thought',
          'thinking',
          'reasoning',
        }.contains(part.type.toLowerCase()) &&
        (part.content ?? '').isNotEmpty;

    final hasThought = parts.any(isThoughtPart);
    MessagePart statusPart(String status, int sequence) =>
        parts
            .where(
              (part) =>
                  part.type == 'status' &&
                  '${part.metadata['status'] ?? ''}' == status,
            )
            .firstOrNull ??
        MessagePart(
          id: '${message.id}-$status-status',
          messageId: message.id,
          sequence: sequence,
          type: 'status',
          metadataJson: canonicalJson(<String, Object?>{'status': status}),
          createdAt: message.createdAt,
        );

    bool isHeadStatus(MessagePart part) =>
        part.type == 'status' &&
        const <String>{
          'sent',
          'replying',
        }.contains('${part.metadata['status'] ?? ''}');

    bool isTailStatus(MessagePart part) =>
        part.type == 'status' &&
        const <String>{
          'success',
          'receive_failed',
          'return_failed',
        }.contains('${part.metadata['status'] ?? ''}');

    final middle = parts
        .where((part) => !isHeadStatus(part) && !isTailStatus(part))
        .toList();
    final tail = parts.where(isTailStatus).toList();
    final orderedMiddle = hasThought
        ? middle
        : _mergeLegacyFallbackReasoning(
            middle,
            fallbackReasoning,
            messageId: message.id,
            createdAt: message.createdAt,
          );
    final effective = <MessagePart>[
      statusPart('sent', -2),
      statusPart('replying', -1),
      ...orderedMiddle,
      if (!hasContent && message.content.isNotEmpty)
        MessagePart(
          id: '${message.id}-fallback-content',
          messageId: message.id,
          sequence: orderedMiddle.length,
          type: 'content',
          content: message.content,
          createdAt: message.createdAt,
        ),
      ...tail,
    ];
    return effective.map<Widget>((part) {
      return switch (part.type) {
        'status' => _StatusCapsule(part: part),
        'tool' => _ToolCapsule(part: part),
        'thought' ||
        'thinking' ||
        'reasoning' when (part.content ?? '').isNotEmpty => _ThoughtBlock(
          key: ValueKey(part.id),
          controller: controller,
          content: part.content!,
        ),
        'content' when (part.content ?? '').isNotEmpty => Padding(
          padding: const EdgeInsets.only(bottom: 5),
          child: _LegacyMarkdownContent(
            data: part.content!,
            streaming: streaming,
            controller: controller,
            styleSheet: _legacyMarkdownStyle(context),
          ),
        ),
        _ => const SizedBox.shrink(),
      };
    }).toList();
  }

  List<MessagePart> _mergeLegacyFallbackReasoning(
    List<MessagePart> middle,
    List<String> fallbackReasoning, {
    required String messageId,
    required DateTime createdAt,
  }) {
    final thoughts = fallbackReasoning
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toList(growable: false);
    if (thoughts.isEmpty) return middle;

    MessagePart thought(int index) => MessagePart(
      id: '$messageId-fallback-thought-$index',
      messageId: messageId,
      sequence: -1000 + index,
      type: 'thought',
      content: thoughts[index],
      createdAt: createdAt,
    );

    // Ordered message_parts are authoritative. This path only handles old
    // rows where reasoning survived in metadata but its exact boundaries did
    // not. Pair each surviving thought with the next content segment instead
    // of collecting every thought after all content/tool receipts.
    final output = <MessagePart>[];
    var thoughtIndex = 0;
    for (final part in middle) {
      if (part.type == 'content' && thoughtIndex < thoughts.length) {
        output.add(thought(thoughtIndex++));
      }
      output.add(part);
    }
    if (output.every((part) => part.type != 'content')) {
      final remaining = <MessagePart>[];
      while (thoughtIndex < thoughts.length) {
        remaining.add(thought(thoughtIndex++));
      }
      output.insertAll(0, remaining);
      return output;
    }
    while (thoughtIndex < thoughts.length) {
      output.add(thought(thoughtIndex++));
    }
    return output;
  }

  MarkdownStyleSheet _legacyMarkdownStyle(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final text = dark ? const Color(0xFFC3C2B8) : _lightText;
    final muted = dark ? const Color(0xFF96948B) : _lightMuted;
    final line = dark ? const Color(0xFF343431) : _lightLine;
    final soft = dark ? const Color(0xFF2A2A28) : _lightSurfaceSoft;
    final body = TextStyle(
      fontFamily: _bodyFontFamily(controller.settings),
      fontFamilyFallback: _bodyFontFallback(controller.settings),
      fontSize: _legacyChatBodyFontSize,
      height: 1.52,
    );
    final heading = TextStyle(
      fontFamily: _bodyFontFamily(controller.settings),
      fontFamilyFallback: _bodyFontFallback(controller.settings),
      fontWeight: FontWeight.w800,
      height: 1.22,
    );
    return MarkdownStyleSheet.fromTheme(theme).copyWith(
      p: body.copyWith(color: text),
      blockSpacing: 8.3542,
      listIndent: 16.25,
      listBullet: body.copyWith(color: text),
      listBulletPadding: const EdgeInsets.only(right: 4),
      strong: const TextStyle(fontWeight: FontWeight.w800),
      em: const TextStyle(fontStyle: FontStyle.italic),
      h1: heading.copyWith(fontSize: 18, color: text),
      h2: heading.copyWith(fontSize: 17, color: text),
      h3: heading.copyWith(fontSize: 16, color: text),
      h4: heading.copyWith(fontSize: 16, color: text),
      h1Padding: const EdgeInsets.only(top: 12.64, bottom: 5.18),
      h2Padding: const EdgeInsets.only(top: 11.93, bottom: 4.90),
      h3Padding: const EdgeInsets.only(top: 11.23, bottom: 4.61),
      h4Padding: const EdgeInsets.only(top: 11.23, bottom: 4.61),
      code: TextStyle(
        color: text,
        fontFamily: 'monospace',
        fontSize: 13,
        backgroundColor: soft,
      ),
      codeblockPadding: EdgeInsets.zero,
      codeblockDecoration: const BoxDecoration(color: Colors.transparent),
      horizontalRuleDecoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: line.withValues(alpha: .72), width: .666667),
        ),
      ),
      blockquote: body.copyWith(color: muted),
      blockquotePadding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      blockquoteDecoration: BoxDecoration(
        color: soft,
        border: Border(left: BorderSide(color: line, width: 3)),
        borderRadius: BorderRadius.circular(3),
      ),
      tableHead: body.copyWith(color: text, fontWeight: FontWeight.w700),
      tableBody: body.copyWith(color: text),
      tableBorder: TableBorder.all(color: line, width: 1),
      tableCellsPadding: const EdgeInsets.fromLTRB(10, 7, 10, 7),
      tableHeadCellsPadding: const EdgeInsets.fromLTRB(10, 7, 10, 7),
      tableHeadCellsDecoration: BoxDecoration(color: soft),
    );
  }

  Object? _metadataValue(String metadata, String key) {
    try {
      final decoded = jsonDecode(metadata);
      return decoded is Map ? decoded[key] : null;
    } on FormatException {
      return null;
    }
  }
}

class _LegacyUserMessage extends StatefulWidget {
  const _LegacyUserMessage({
    required this.controller,
    required this.message,
    required this.streaming,
  });

  final AppController controller;
  final ChatMessage message;
  final bool streaming;

  @override
  State<_LegacyUserMessage> createState() => _LegacyUserMessageState();
}

class _LegacyUserMessageState extends State<_LegacyUserMessage> {
  bool showActions = false;
  Timer? _longPressTimer;

  @override
  void dispose() {
    _longPressTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.end,
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      GestureDetector(
        child: Listener(
          onPointerDown: widget.streaming
              ? null
              : (_) {
                  _longPressTimer?.cancel();
                  _longPressTimer = Timer(
                    const Duration(milliseconds: 450),
                    () {
                      if (mounted) {
                        setState(() => showActions = !showActions);
                      }
                    },
                  );
                },
          onPointerUp: (_) => _longPressTimer?.cancel(),
          onPointerCancel: (_) => _longPressTimer?.cancel(),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: Theme.of(context).brightness == Brightness.dark
                  ? const Color(0xFF101010)
                  : const Color(0xFFF0EFEC),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(22),
                topRight: Radius.circular(22),
                bottomLeft: Radius.circular(22),
                bottomRight: Radius.circular(8),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                SelectableText(
                  widget.message.content,
                  style: TextStyle(
                    fontFamily: _bodyFontFamily(widget.controller.settings),
                    fontFamilyFallback: _bodyFontFallback(
                      widget.controller.settings,
                    ),
                    fontSize: _legacyChatBodyFontSize,
                    height: 1.5,
                  ),
                ),
                if (!widget.streaming &&
                    widget.message.content.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 2),
                  _MessageTokenLabel(
                    controller: widget.controller,
                    message: widget.message,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      if (showActions)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              _action(
                tooltip: '复制',
                icon: _LegacyIconKind.copy,
                onPressed: () async {
                  await Clipboard.setData(
                    ClipboardData(text: widget.message.content),
                  );
                  if (context.mounted) {
                    setState(() => showActions = false);
                    _snack(context, '消息已复制');
                  }
                },
              ),
              const SizedBox(width: _messageActionGap),
              _action(
                tooltip: '重编',
                icon: _LegacyIconKind.edit,
                onPressed: () => _edit(resend: false),
              ),
              const SizedBox(width: _messageActionGap),
              _action(
                tooltip: '编辑并重发',
                icon: _LegacyIconKind.refresh,
                onPressed: () => _edit(resend: true),
              ),
            ],
          ),
        ),
    ],
  );

  Widget _action({
    required String tooltip,
    required _LegacyIconKind icon,
    required VoidCallback onPressed,
  }) => IconButton(
    onPressed: onPressed,
    tooltip: tooltip,
    padding: EdgeInsets.zero,
    constraints: const BoxConstraints.tightFor(
      width: _messageActionExtent,
      height: _messageActionExtent,
    ),
    icon: _LegacyIcon(icon, size: 16, color: _lightMuted),
  );

  void _edit({required bool resend}) {
    widget.controller.beginUserMessageEdit(widget.message, resend: resend);
    if (mounted) setState(() => showActions = false);
  }
}

class _LegacyMarkdownContent extends StatelessWidget {
  const _LegacyMarkdownContent({
    required this.data,
    required this.streaming,
    required this.controller,
    required this.styleSheet,
    this.extensionSet,
  });

  final String data;
  final bool streaming;
  final AppController controller;
  final MarkdownStyleSheet styleSheet;
  final md.ExtensionSet? extensionSet;

  @override
  Widget build(BuildContext context) {
    final segments = _segments(data);
    final inlineSurface =
        styleSheet.code?.backgroundColor ??
        (Theme.of(context).brightness == Brightness.dark
            ? _darkSurface
            : _lightSurfaceSoft);
    final inlineBuilders = createClaudeInlineBuilders(
      highlightColor: Color.alphaBlend(
        _accent.withValues(alpha: .18),
        inlineSurface,
      ),
      inlineCodeColor: inlineSurface,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: segments.indexed.map((entry) {
        final index = entry.$1;
        final segment = entry.$2;
        if (segment.code) {
          final language = segment.language.isEmpty ? '' : segment.language;
          return MarkdownBody(
            data: '```$language\n${segment.content}\n```',
            selectable: true,
            extensionSet: extensionSet ?? _legacyMarkdownExtensionSet,
            builders: <String, MarkdownElementBuilder>{
              'pre': ClaudeCodeBlockBuilder(
                foldLines:
                    (controller.settings['codeFoldLines'] as num?)?.toInt() ??
                    5,
                onRun: (code, _) => controller.platform.previewHtml(
                  code,
                  fallbackTitle: 'HTML 预览',
                ),
                margin: EdgeInsets.only(
                  // Browser block margins collapse. MarkdownBody already
                  // contributes 8.3542px after the preceding block, so only
                  // the remainder of the legacy 10px code margin is added.
                  top: index > 0 ? 1.6458 : 10,
                  bottom: 10,
                ),
              ),
            },
            styleSheet: styleSheet,
          );
        }
        final cursor = streaming && index == segments.length - 1 ? ' ▍' : '';
        final content = '${segment.content}$cursor'.trim();
        if (content.isEmpty) return const SizedBox.shrink();
        return MarkdownBody(
          data: content,
          selectable: true,
          extensionSet: extensionSet ?? _legacyMarkdownExtensionSet,
          builders: <String, MarkdownElementBuilder>{
            ...inlineBuilders,
            'latex': LatexElementBuilder(textStyle: styleSheet.p),
          },
          onTapLink: (_, href, _) {
            if (href != null) _showLinkActions(context, controller, href);
          },
          styleSheet: styleSheet,
        );
      }).toList(),
    );
  }

  List<_LegacyMarkdownSegment> _segments(String source) {
    final cleaned = source
        .replaceFirst(RegExp(r'^(?:[ \t]*\r?\n)+'), '')
        .replaceFirst(RegExp(r'(?:\r?\n[ \t]*)+$'), '');
    final pattern = RegExp(r'```([^\n`]*)\n([\s\S]*?)```');
    final output = <_LegacyMarkdownSegment>[];
    var cursor = 0;
    for (final match in pattern.allMatches(cleaned)) {
      if (match.start > cursor) {
        output.add(
          _LegacyMarkdownSegment.text(cleaned.substring(cursor, match.start)),
        );
      }
      output.add(
        _LegacyMarkdownSegment.code(
          match.group(2)?.replaceFirst(RegExp(r'\n$'), '') ?? '',
          (match.group(1) ?? '').trim(),
        ),
      );
      cursor = match.end;
    }
    if (cursor < cleaned.length) {
      output.add(_LegacyMarkdownSegment.text(cleaned.substring(cursor)));
    }
    if (output.isEmpty) output.add(_LegacyMarkdownSegment.text(cleaned));
    return output;
  }
}

class _LegacyMarkdownSegment {
  const _LegacyMarkdownSegment.text(this.content) : code = false, language = '';

  const _LegacyMarkdownSegment.code(this.content, this.language) : code = true;

  final bool code;
  final String content;
  final String language;
}

enum _LinkOpenAction { safePreview, externalBrowser }

Future<void> _showLinkActions(
  BuildContext context,
  AppController controller,
  String rawUrl,
) async {
  final uri = Uri.tryParse(rawUrl.trim());
  if (uri == null ||
      !uri.hasAuthority ||
      (uri.scheme != 'http' && uri.scheme != 'https')) {
    _snack(context, '只能打开有效的 HTTP 或 HTTPS 链接');
    return;
  }
  final action = await showDialog<_LinkOpenAction>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: .18),
    builder: (dialogContext) {
      final dark = Theme.of(dialogContext).brightness == Brightness.dark;
      final muted = dark ? _darkMuted : _lightMuted;
      return Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 36),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text(
                  '打开链接',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 6),
                Text(
                  uri.toString(),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: muted, fontSize: 11.5, height: 1.35),
                ),
                const SizedBox(height: 12),
                _LinkActionTile(
                  icon: Icons.shield_outlined,
                  title: '安全预览',
                  subtitle: '在隔离阅读器中查看公开文本，不运行网页脚本',
                  onTap: () =>
                      Navigator.pop(dialogContext, _LinkOpenAction.safePreview),
                ),
                const SizedBox(height: 6),
                _LinkActionTile(
                  icon: Icons.open_in_browser_rounded,
                  title: '使用浏览器打开',
                  subtitle: '离开应用，并交给手机默认浏览器',
                  onTap: () => Navigator.pop(
                    dialogContext,
                    _LinkOpenAction.externalBrowser,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
  if (!context.mounted || action == null) return;
  if (action == _LinkOpenAction.safePreview) {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => _SafeLinkPreviewPage(controller: controller, url: uri),
      ),
    );
    return;
  }
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('使用系统浏览器打开？'),
      content: const Text(
        '此操作会离开 ClaudeChat，并使用手机默认浏览器访问该网址。请先确认链接可信；不要在可疑页面输入账号、密码、验证码或支付信息。建议不确定时先使用“安全预览”。',
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('确认前往'),
        ),
      ],
    ),
  );
  if (confirmed != true) return;
  try {
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!opened && context.mounted) _snack(context, '未找到可打开此链接的浏览器');
  } on Object catch (error) {
    if (context.mounted) _snack(context, '打开失败：$error');
  }
}

class _LinkActionTile extends StatelessWidget {
  const _LinkActionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.surfaceContainerHighest,
    borderRadius: BorderRadius.circular(12),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: <Widget>[
            Icon(icon, size: 20, color: _accent),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontSize: 10.5,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded, size: 19),
          ],
        ),
      ),
    ),
  );
}

class _SafeLinkPreviewPage extends StatefulWidget {
  const _SafeLinkPreviewPage({required this.controller, required this.url});

  final AppController controller;
  final Uri url;

  @override
  State<_SafeLinkPreviewPage> createState() => _SafeLinkPreviewPageState();
}

class _SafeLinkPreviewPageState extends State<_SafeLinkPreviewPage> {
  late final Future<Map<String, String>> preview = widget.controller.tools.web
      .fetch(widget.url.toString());

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      leading: const BackButton(),
      title: const Text('安全预览'),
      centerTitle: true,
    ),
    body: SafeArea(
      child: FutureBuilder<Map<String, String>>(
        future: preview,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(
              child: SizedBox.square(
                dimension: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            );
          }
          if (snapshot.hasError) {
            return Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  const Icon(Icons.shield_outlined, size: 36, color: _accent),
                  const SizedBox(height: 12),
                  const Text(
                    '无法安全预览这个链接',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${snapshot.error}',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            );
          }
          final value = snapshot.data!;
          return SelectionArea(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 28),
              children: <Widget>[
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 9,
                  ),
                  decoration: BoxDecoration(
                    color: _accent.withValues(alpha: .08),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Icon(Icons.shield_outlined, size: 18, color: _accent),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '隔离阅读模式：仅展示服务器返回的公开文本，不执行 JavaScript，不加载登录态，也不向网页提供应用数据。',
                          style: TextStyle(fontSize: 11.5, height: 1.4),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  value['title']?.trim().isNotEmpty == true
                      ? value['title']!
                      : widget.url.host,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    height: 1.25,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  value['url'] ?? widget.url.toString(),
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 11,
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  value['content']?.trim().isNotEmpty == true
                      ? value['content']!
                      : '网页没有可显示的文本内容。',
                  style: const TextStyle(fontSize: 14, height: 1.55),
                ),
              ],
            ),
          );
        },
      ),
    ),
  );
}

class _MessageTokenLabel extends StatelessWidget {
  const _MessageTokenLabel({required this.controller, required this.message});

  final AppController controller;
  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final ratio =
        (controller.settings['tokenEstimateRatio'] as num?)?.toDouble() ?? 1;
    final value = (ContextBudget.estimateText(message.content) * ratio).ceil();
    return Text(
      _usageNumber(value),
      style: TextStyle(
        fontSize: 10,
        height: 1.5,
        color: Theme.of(
          context,
        ).colorScheme.onSurfaceVariant.withValues(alpha: .35),
      ),
    );
  }
}

class _AttachmentGallery extends StatelessWidget {
  const _AttachmentGallery({required this.controller, required this.items});

  final AppController controller;
  final List<PendingAttachment> items;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 7,
    runSpacing: 7,
    children: items.map((item) {
      final path = controller.attachments.absolutePath(item);
      if (!item.isImage) {
        return ActionChip(
          avatar: const Icon(Icons.attach_file, size: 16),
          label: Text(item.name),
          tooltip: '${item.mediaType} · ${item.byteSize} 字节',
          onPressed: () => _share(path, item.name),
        );
      }
      return Semantics(
        button: true,
        label: '查看图片 ${item.name}',
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => showDialog<void>(
            context: context,
            builder: (dialogContext) => Dialog.fullscreen(
              backgroundColor: Colors.black,
              child: Stack(
                children: <Widget>[
                  Positioned.fill(
                    child: InteractiveViewer(
                      minScale: .5,
                      maxScale: 5,
                      child: Center(
                        child: Image.file(
                          File(path),
                          fit: BoxFit.contain,
                          errorBuilder: (_, _, _) => const Icon(
                            Icons.broken_image_outlined,
                            color: Colors.white54,
                            size: 54,
                          ),
                        ),
                      ),
                    ),
                  ),
                  SafeArea(
                    child: Row(
                      children: <Widget>[
                        IconButton(
                          onPressed: () => Navigator.pop(dialogContext),
                          color: Colors.white,
                          icon: const Icon(Icons.close_rounded),
                          tooltip: '关闭',
                        ),
                        Expanded(
                          child: Text(
                            item.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white),
                          ),
                        ),
                        IconButton(
                          onPressed: () => _share(path, item.name),
                          color: Colors.white,
                          icon: const Icon(Icons.ios_share_outlined),
                          tooltip: '分享',
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          onLongPress: () => _share(path, item.name),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Image.file(
              File(path),
              width: 180,
              height: 132,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => Container(
                width: 180,
                height: 80,
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                alignment: Alignment.center,
                child: const Icon(Icons.broken_image_outlined),
              ),
            ),
          ),
        ),
      );
    }).toList(),
  );

  void _share(String path, String name) => SharePlus.instance.share(
    ShareParams(files: <XFile>[XFile(path)], title: name),
  );
}

class _ThoughtBlock extends StatefulWidget {
  const _ThoughtBlock({
    required this.controller,
    required this.content,
    super.key,
  });

  final AppController controller;

  final String content;

  @override
  State<_ThoughtBlock> createState() => _ThoughtBlockState();
}

class _ThoughtBlockState extends State<_ThoughtBlock> {
  bool open = false;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    margin: const EdgeInsets.only(bottom: 5),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        InkWell(
          onTap: () => setState(() => open = !open),
          splashColor: Colors.transparent,
          highlightColor: Colors.transparent,
          hoverColor: Colors.transparent,
          child: Container(
            height: 28,
            padding: const EdgeInsets.fromLTRB(4, 1, 0, 1),
            child: Row(
              children: <Widget>[
                const _LegacyIcon(
                  _LegacyIconKind.clock,
                  size: 15,
                  color: Color(0xFF7B7873),
                ),
                const SizedBox(width: 6),
                const Expanded(
                  child: Text(
                    '思维链',
                    style: TextStyle(
                      color: Color(0xFF7B7873),
                      fontSize: 12,
                      height: 1.28,
                    ),
                  ),
                ),
                AnimatedRotation(
                  turns: open ? .25 : 0,
                  duration: const Duration(milliseconds: 160),
                  curve: Curves.ease,
                  child: const _LegacyIcon(
                    _LegacyIconKind.chevronRight,
                    size: 15,
                    color: Color(0xFF7B7873),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (open)
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 20.15625),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 1, 0, 2),
              child: Text(
                widget.content,
                style: TextStyle(
                  color: Color(0xFF7B7873),
                  fontFamily: _bodyFontFamily(widget.controller.settings),
                  fontFamilyFallback: _bodyFontFallback(
                    widget.controller.settings,
                  ),
                  fontSize: _legacyChatBodyFontSize,
                  height: 1.32,
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

class _StatusCapsule extends StatelessWidget {
  const _StatusCapsule({required this.part});

  final MessagePart part;

  @override
  Widget build(BuildContext context) {
    final metadata = part.metadata;
    final status = '${metadata['status'] ?? ''}';
    final detail = '${metadata['detail'] ?? ''}';
    final customLabel = '${metadata['label'] ?? ''}'.trim();
    if (status.startsWith('tool_')) {
      return const SizedBox.shrink();
    }
    final dark = Theme.of(context).brightness == Brightness.dark;
    final muted = dark ? const Color(0xFF96948B) : _lightMuted;
    final danger = dark ? const Color(0xFFFF8178) : _lightDanger;
    final definition = switch (status) {
      'sent' => (_LegacyIconKind.check, '消息已发送', muted),
      'replying' => (
        _LegacyIconKind.send,
        customLabel.isEmpty ? '小机子正在回复' : customLabel,
        muted,
      ),
      'response_progress' => (
        _LegacyIconKind.send,
        customLabel.isEmpty ? '小机子正在组织回复' : customLabel,
        muted,
      ),
      'success' => (_LegacyIconKind.check, '消息返回成功', muted),
      'tool_completed' => (
        _LegacyIconKind.check,
        '小机子已完成${_toolLifecycleNoun('${metadata['name'] ?? ''}')}',
        muted,
      ),
      'tool_waiting_approval' => (
        _LegacyIconKind.tool,
        '小机子正在等待${_toolLifecycleNoun('${metadata['name'] ?? ''}')}审批',
        muted,
      ),
      'tool_denied' => (
        _LegacyIconKind.close,
        '小机子的${_toolLifecycleNoun('${metadata['name'] ?? ''}')}未获批准',
        danger,
      ),
      'tool_failed' => (
        _LegacyIconKind.warning,
        '小机子未能完成${_toolLifecycleNoun('${metadata['name'] ?? ''}')}',
        danger,
      ),
      'tools_unavailable' => (_LegacyIconKind.warning, '工具接口不可用', danger),
      'receive_failed' => (_LegacyIconKind.warning, '消息接收失败', danger),
      'return_failed' => (_LegacyIconKind.close, '消息返回失败', danger),
      _ => (_LegacyIconKind.check, status, muted),
    };
    if (definition.$2.isEmpty) return const SizedBox.shrink();
    return _ExpandableCapsule(
      icon: definition.$1,
      label: definition.$2,
      color: definition.$3,
      detail: detail,
      iconGap: 5,
      spinning: status == 'response_progress',
      dangerBorder:
          status == 'tools_unavailable' ||
          status == 'tool_denied' ||
          status == 'tool_failed' ||
          status == 'receive_failed' ||
          status == 'return_failed',
    );
  }
}

class _ToolCapsule extends StatelessWidget {
  const _ToolCapsule({required this.part});

  final MessagePart part;

  @override
  Widget build(BuildContext context) {
    final metadata = part.metadata;
    final name = '${metadata['name'] ?? 'tool'}';
    final arguments = metadata['arguments'];
    final status = '${metadata['status'] ?? 'success'}';
    final dark = Theme.of(context).brightness == Brightness.dark;
    final textColor = dark ? const Color(0xFFC3C2B8) : const Color(0xFF101010);
    final danger = dark ? const Color(0xFFFF8178) : _lightDanger;
    final result = _decodeToolResult(part.content);
    if (status == 'preparing' || status == 'running') {
      return _ToolProgressCapsule(
        name: name,
        arguments: arguments,
        running: status == 'running',
      );
    }
    final rawDetail = const JsonEncoder.withIndent(
      '  ',
    ).convert(<String, Object?>{'arguments': arguments, 'result': result});
    final detail = rawDetail.length <= 6000
        ? rawDetail
        : '${rawDetail.substring(0, 6000)}\n…';
    final label = switch (status) {
      'success' => '小机子${_toolAction(name, arguments, result)}',
      'pending_approval' => '小机子请求审批${_toolLabel(name)}',
      'denied' => '小机子被拒绝了${_toolLabel(name)}',
      _ => '小机子出错了${_toolLabel(name)}',
    };
    return _ExpandableCapsule(
      icon: _toolIcon(name),
      label: label,
      color: status == 'success' || status == 'pending_approval'
          ? textColor
          : danger,
      detail: detail,
      iconGap: 4,
      strongBorder: status == 'success' || status == 'pending_approval',
      dangerBorder: status != 'success' && status != 'pending_approval',
    );
  }

  String _toolAction(String name, Object? rawArguments, Object? rawResult) {
    final arguments = rawArguments is Map ? rawArguments : const {};
    final result = rawResult is Map ? rawResult : const {};
    String suffix(Object? value, [int limit = 28]) {
      final item = '${value ?? ''}'.trim();
      return item.isEmpty ? '' : '「${_truncate(item, limit)}」';
    }

    String quoted(Object? value, [int limit = 28]) =>
        '「${_truncate('${value ?? ''}'.trim(), limit)}」';

    return switch (name) {
      'web_search' when suffix(arguments['query'], 30).isNotEmpty =>
        '搜索了${suffix(arguments['query'], 30)}',
      'fetch_url' when suffix(arguments['url'], 30).isNotEmpty =>
        '读取了${suffix(arguments['url'], 30)}',
      'create_file' || 'create_workspace_file' =>
        '创建了文件${quoted(arguments['name'] ?? result['name'])}',
      'read_file' => '读取了文件${quoted(arguments['name'] ?? result['name'])}',
      'edit_file' || 'edit_workspace_file' =>
        '编辑了文件${quoted(arguments['name'] ?? result['name'])}',
      'delete_file' => '删除了文件${quoted(arguments['name'] ?? result['name'])}',
      'set_greeting' => '修改了欢迎语${quoted(result['greeting'])}',
      'set_splash_phrases' => '修改了开屏语${quoted(result['phrases'])}',
      'create_memory' => '创建了记忆${quoted(arguments['content'])}',
      'update_memory' => '编辑了记忆${quoted(arguments['content'])}',
      'delete_memory' => '删除了记忆${quoted(arguments['content'])}',
      'create_diary_entry' => '写了日记${quoted(arguments['title'])}',
      'revise_diary_entry' => '修订了日记${quoted(arguments['title'])}',
      'request_delete_diary_entry' ||
      'delete_diary_entry' => '删除了日记${quoted(arguments['title'])}',
      _ => '完成了${_toolLabel(name)}',
    };
  }

  _LegacyIconKind _toolIcon(String name) {
    if (name.contains('search')) return _LegacyIconKind.search;
    if (name.contains('memory')) return _LegacyIconKind.brain;
    if (name.contains('diary')) return _LegacyIconKind.book;
    if (name.contains('file') || name.contains('workspace')) {
      return _LegacyIconKind.file;
    }
    if (name == 'get_time') return _LegacyIconKind.clock;
    if (name == 'fetch_url') return _LegacyIconKind.link;
    return _LegacyIconKind.tool;
  }

  Object? _decodeToolResult(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      return jsonDecode(raw);
    } on FormatException {
      return raw;
    }
  }

  String _truncate(String value, int limit) =>
      value.length <= limit ? value : '${value.substring(0, limit)}…';
}

class _ToolProgressCapsule extends StatelessWidget {
  const _ToolProgressCapsule({
    required this.name,
    required this.arguments,
    required this.running,
  });

  final String name;
  final Object? arguments;
  final bool running;

  @override
  Widget build(BuildContext context) {
    final values = arguments is Map ? arguments! as Map : const {};
    final rawName = '${values['name'] ?? ''}'.trim();
    final suffix = rawName.isEmpty ? '' : '「${_compact(rawName)}」';
    final label = switch ((name, running)) {
      ('get_time', false) => '小机子准备读取当前时间',
      ('get_time', true) => '小机子正在读取当前时间',
      ('search_memory', false) => '小机子准备搜索记忆',
      ('search_memory', true) => '小机子正在搜索记忆',
      ('create_memory', false) => '小机子准备创建记忆',
      ('create_memory', true) => '小机子正在创建记忆',
      ('update_memory', false) => '小机子准备更新记忆',
      ('update_memory', true) => '小机子正在更新记忆',
      ('delete_memory', false) => '小机子准备删除记忆',
      ('delete_memory', true) => '小机子正在处理记忆删除',
      ('create_diary_entry', false) => '小机子准备写日记',
      ('create_diary_entry', true) => '小机子正在写日记',
      ('revise_diary_entry', false) => '小机子准备修订日记',
      ('revise_diary_entry', true) => '小机子正在修订日记',
      ('request_delete_diary_entry' || 'delete_diary_entry', false) =>
        '小机子准备删除日记',
      ('request_delete_diary_entry' || 'delete_diary_entry', true) =>
        '小机子正在处理日记删除',
      ('search_diary_entries', false) => '小机子准备搜索日记',
      ('search_diary_entries', true) => '小机子正在搜索日记',
      ('read_diary_entry', false) => '小机子准备读取日记',
      ('read_diary_entry', true) => '小机子正在读取日记',
      ('search_files', false) => '小机子准备搜索文件',
      ('search_files', true) => '小机子正在搜索文件',
      ('read_file', false) => '小机子准备读取文件',
      ('read_file', true) => '小机子正在读取文件',
      ('create_file', false) => '小机子准备创建文件',
      ('create_file', true) => '小机子正在写入文件$suffix',
      ('edit_file', false) => '小机子准备编辑文件',
      ('edit_file', true) => '小机子正在写入文件$suffix',
      ('delete_file', false) => '小机子准备删除文件',
      ('delete_file', true) => '小机子正在处理文件删除',
      ('web_search', false) => '小机子准备搜索网络',
      ('web_search', true) => '小机子正在搜索网络',
      ('fetch_url', false) => '小机子准备读取网页',
      ('fetch_url', true) => '小机子正在读取网页',
      ('set_greeting', false) => '小机子准备修改欢迎语',
      ('set_greeting', true) => '小机子正在修改欢迎语',
      ('set_splash_phrases', false) => '小机子准备修改开屏语',
      ('set_splash_phrases', true) => '小机子正在修改开屏语',
      ('create_calendar_event', false) => '小机子准备创建日历日程',
      ('create_calendar_event', true) => '小机子正在写入系统日历',
      ('schedule_notification', false) => '小机子准备创建通知',
      ('schedule_notification', true) => '小机子正在安排系统通知',
      ('create_system_reminder', false) => '小机子准备创建提醒事项',
      ('create_system_reminder', true) => '小机子正在写入系统提醒事项',
      ('update_home_widget', false) => '小机子准备更新小组件',
      ('update_home_widget', true) => '小机子正在更新桌面小组件',
      ('list_workspace_files', false) => '小机子准备检查工作区文件',
      ('list_workspace_files', true) => '小机子正在检查工作区文件',
      ('read_workspace_file', false) => '小机子准备读取工作区文件',
      ('read_workspace_file', true) => '小机子正在读取工作区文件$suffix',
      ('list_workspace_file_versions', false) => '小机子准备检查工作区文件版本',
      ('list_workspace_file_versions', true) => '小机子正在检查工作区文件版本',
      ('read_workspace_file_version', false) => '小机子准备读取工作区文件版本',
      ('read_workspace_file_version', true) => '小机子正在读取工作区文件版本',
      ('restore_workspace_file_version', false) => '小机子准备恢复工作区文件版本',
      ('restore_workspace_file_version', true) => '小机子正在恢复工作区文件版本',
      ('create_workspace_file', false) => '小机子准备创建工作区文件',
      ('create_workspace_file', true) => '小机子正在写入工作区文件$suffix',
      ('edit_workspace_file', false) => '小机子准备编辑工作区文件',
      ('edit_workspace_file', true) => '小机子正在写入工作区文件$suffix',
      (_, false) => '小机子准备使用${_toolLabel(name)}',
      (_, true) => '小机子正在执行${_toolLabel(name)}',
    };
    final dark = Theme.of(context).brightness == Brightness.dark;
    final color = dark ? const Color(0xFFC3C2B8) : const Color(0xFF101010);
    final line = dark ? const Color(0xFF4C4A45) : _lightLineStrong;
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(minHeight: 28),
      margin: const EdgeInsets.only(bottom: 5),
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border.all(color: line, width: 0.6667),
        borderRadius: BorderRadius.circular(15),
      ),
      child: Row(
        children: <Widget>[
          SizedBox.square(
            dimension: 14,
            child: CircularProgressIndicator(strokeWidth: 1.6, color: color),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: color, fontSize: 12, height: 1.25),
            ),
          ),
        ],
      ),
    );
  }

  static String _compact(String value) =>
      value.length <= 26 ? value : '${value.substring(0, 26)}…';
}

class _ExpandableCapsule extends StatefulWidget {
  const _ExpandableCapsule({
    required this.icon,
    required this.label,
    required this.color,
    required this.detail,
    required this.iconGap,
    this.strongBorder = false,
    this.dangerBorder = false,
    this.spinning = false,
  });

  final _LegacyIconKind icon;
  final String label;
  final Color color;
  final String detail;
  final double iconGap;
  final bool strongBorder;
  final bool dangerBorder;
  final bool spinning;

  @override
  State<_ExpandableCapsule> createState() => _ExpandableCapsuleState();
}

class _ExpandableCapsuleState extends State<_ExpandableCapsule> {
  bool open = false;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final surfaceSoft = dark ? const Color(0xFF2A2A28) : _lightSurfaceSoft;
    final line = dark ? const Color(0xFF343431) : _lightLine;
    final lineStrong = dark ? const Color(0xFF4B4A45) : _lightLineStrong;
    final muted = dark ? const Color(0xFF96948B) : _lightMuted;
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Semantics(
        container: true,
        button: widget.detail.isNotEmpty,
        expanded: widget.detail.isNotEmpty ? open : null,
        label: open ? '${widget.label} ${widget.detail}' : widget.label,
        onTap: widget.detail.isEmpty
            ? null
            : () => setState(() => open = !open),
        excludeSemantics: true,
        child: InkWell(
          borderRadius: BorderRadius.circular(open ? 8 : 18),
          splashColor: Colors.transparent,
          highlightColor: Colors.transparent,
          hoverColor: Colors.transparent,
          onTap: widget.detail.isEmpty
              ? null
              : () => setState(() => open = !open),
          child: Container(
            // The legacy capsule sits inside a stretching CSS grid item.
            // Its collapsed and expanded states therefore share the full
            // message-column width.
            width: double.infinity,
            constraints: const BoxConstraints(maxWidth: 444),
            padding: EdgeInsets.symmetric(
              horizontal: 10,
              vertical: open ? 6 : 3,
            ),
            decoration: BoxDecoration(
              color: surfaceSoft,
              border: Border.all(
                color: widget.dangerBorder
                    ? widget.color
                    : widget.strongBorder
                    ? lineStrong
                    : line,
                width: 1,
              ),
              borderRadius: BorderRadius.circular(open ? 8 : 999),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    if (widget.spinning)
                      SizedBox.square(
                        dimension: 14,
                        child: CircularProgressIndicator(
                          key: const Key('response-status-spinner'),
                          strokeWidth: 1.6,
                          color: widget.color,
                        ),
                      )
                    else
                      _LegacyIcon(widget.icon, size: 14, color: widget.color),
                    SizedBox(width: widget.iconGap),
                    Flexible(
                      child: Text(
                        widget.label,
                        style: TextStyle(
                          color: widget.color,
                          fontSize: 11,
                          fontWeight: FontWeight.w400,
                          height: 1.212,
                        ),
                      ),
                    ),
                  ],
                ),
                if (open) ...<Widget>[
                  // The legacy CSS declares margin-top: 4px, while its actual
                  // grid line box adds another ~5.7px. Nine logical pixels
                  // reproduces the measured 63px expanded bounding box.
                  const SizedBox(height: 9),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 180),
                    child: SingleChildScrollView(
                      child: Text(
                        widget.detail,
                        style: TextStyle(
                          color: muted,
                          fontSize: 11,
                          height: 1.212,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Composer extends StatefulWidget {
  const _Composer({required this.controller, required this.textController});
  final AppController controller;
  final TextEditingController textController;

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  OverlayEntry? _actionsEntry;
  final FocusNode _inputFocus = FocusNode(debugLabel: 'chat-composer');
  int _syncedEditRequestSerial = -1;

  AppController get controller => widget.controller;
  TextEditingController get textController => widget.textController;

  @override
  void dispose() {
    _actionsEntry?.remove();
    _inputFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _syncEditState();
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 10, 18, 14),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 444),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 104),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(24),
                      boxShadow: Theme.of(context).brightness == Brightness.dark
                          ? const <BoxShadow>[]
                          : const <BoxShadow>[
                              BoxShadow(
                                color: Color(0x12000000),
                                offset: Offset(0, 8),
                                blurRadius: 24,
                              ),
                            ],
                    ),
                    child: Material(
                      color: Theme.of(context).colorScheme.surface,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(24),
                        side: const BorderSide(color: _lightLineStrong),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(
                          12.67,
                          13,
                          12.67,
                          13,
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            if (controller.editingUserMessage != null)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 4),
                                child: SizedBox(
                                  height: 24,
                                  child: Row(
                                    children: <Widget>[
                                      Expanded(
                                        child: Text(
                                          controller.editingUserMessageResend
                                              ? '编辑并重发'
                                              : '重编，不重新发送',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w700,
                                            color: _lightMuted,
                                          ),
                                        ),
                                      ),
                                      TextButton(
                                        onPressed: _cancelEdit,
                                        style: TextButton.styleFrom(
                                          minimumSize: Size.zero,
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 6,
                                          ),
                                          tapTargetSize:
                                              MaterialTapTargetSize.shrinkWrap,
                                          visualDensity: VisualDensity.compact,
                                        ),
                                        child: const Text(
                                          '取消',
                                          style: TextStyle(fontSize: 12),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            if (controller.pendingAttachments.isNotEmpty)
                              SizedBox(
                                height: 46,
                                child: ListView.separated(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 5,
                                  ),
                                  scrollDirection: Axis.horizontal,
                                  itemCount:
                                      controller.pendingAttachments.length,
                                  separatorBuilder: (_, _) =>
                                      const SizedBox(width: 6),
                                  itemBuilder: (context, index) {
                                    final item =
                                        controller.pendingAttachments[index];
                                    return InputChip(
                                      avatar: Icon(
                                        item.isImage
                                            ? Icons.image_outlined
                                            : Icons.description_outlined,
                                        size: 17,
                                      ),
                                      label: Text(
                                        item.name,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      onDeleted: () =>
                                          controller.removeAttachment(item),
                                    );
                                  },
                                ),
                              ),
                            TextField(
                              key: const Key('chat-composer-input'),
                              controller: textController,
                              focusNode: _inputFocus,
                              minLines: 2,
                              maxLines: 8,
                              style: TextStyle(
                                fontFamily: _selectedFontFamily(
                                  controller.settings,
                                ),
                                fontSize: 14,
                                height: 1.18,
                              ),
                              textInputAction: TextInputAction.newline,
                              onChanged: (_) => setState(() {}),
                              onTapOutside: (_) => _dismissKeyboard(),
                              decoration: InputDecoration(
                                hintText: controller.privateMode
                                    ? '在私密对话里输入'
                                    : 'Reply to ${controller.settings['appName'] ?? 'ClaudeChat'}',
                                filled: false,
                                border: InputBorder.none,
                                enabledBorder: InputBorder.none,
                                focusedBorder: InputBorder.none,
                                contentPadding: EdgeInsets.zero,
                              ),
                            ),
                            const SizedBox(height: 12),
                            SizedBox(
                              height: 36,
                              child: Row(
                                children: <Widget>[
                                  IconButton(
                                    onPressed: () => _showMoreActions(context),
                                    hoverColor: Colors.transparent,
                                    focusColor: Colors.transparent,
                                    highlightColor: Colors.transparent,
                                    splashColor: Colors.transparent,
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints.tightFor(
                                      width: 30,
                                      height: 30,
                                    ),
                                    style: IconButton.styleFrom(
                                      shape: const CircleBorder(),
                                      tapTargetSize:
                                          MaterialTapTargetSize.shrinkWrap,
                                      visualDensity: VisualDensity.compact,
                                      side: _actionsEntry == null
                                          ? BorderSide.none
                                          : const BorderSide(
                                              color: Color(0xFF101010),
                                              width: 0.666667,
                                            ),
                                    ),
                                    icon: const _LegacyIcon(
                                      _LegacyIconKind.plus,
                                      size: 18,
                                      color: Color(0xFF101010),
                                    ),
                                    tooltip: '更多操作',
                                  ),
                                  const SizedBox.shrink(),
                                  IconButton(
                                    onPressed: () => controller.saveSetting(
                                      'webSearchEnabled',
                                      controller.settings['webSearchEnabled'] !=
                                          true,
                                    ),
                                    icon: _LegacyIcon(
                                      _LegacyIconKind.globe,
                                      size: 18,
                                      color:
                                          controller
                                                  .settings['webSearchEnabled'] ==
                                              true
                                          ? const Color(0xFF2F76C2)
                                          : null,
                                    ),
                                    tooltip:
                                        controller
                                                .settings['webSearchEnabled'] ==
                                            true
                                        ? '关闭联网搜索'
                                        : '网络搜索',
                                    style: IconButton.styleFrom(
                                      backgroundColor:
                                          controller
                                                  .settings['webSearchEnabled'] ==
                                              true
                                          ? const Color(0xFFF4F2EF)
                                          : Colors.transparent,
                                      shape: const CircleBorder(),
                                      tapTargetSize:
                                          MaterialTapTargetSize.shrinkWrap,
                                      visualDensity: VisualDensity.compact,
                                    ),
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints.tightFor(
                                      width: 30,
                                      height: 30,
                                    ),
                                  ),
                                  const Spacer(),
                                  IconButton(
                                    onPressed: () async {
                                      try {
                                        final value = await controller.platform
                                            .recognizeSpeech(
                                              locale:
                                                  '${controller.settings['language'] ?? 'zh-CN'}',
                                            );
                                        if (value == null) return;
                                        final old = textController.text
                                            .trimRight();
                                        textController.text = old.isEmpty
                                            ? value
                                            : '$old $value';
                                        textController.selection =
                                            TextSelection.collapsed(
                                              offset:
                                                  textController.text.length,
                                            );
                                      } on Object catch (error) {
                                        if (context.mounted) {
                                          _snack(context, '语音识别不可用：$error');
                                        }
                                      }
                                    },
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints.tightFor(
                                      width: 30,
                                      height: 30,
                                    ),
                                    icon: const _LegacyIcon(
                                      _LegacyIconKind.microphone,
                                      size: 18,
                                      color: Color(0xFF101010),
                                    ),
                                    tooltip: '语音输入',
                                  ),
                                  const SizedBox(width: 4),
                                  IconButton(
                                    onPressed: controller.busy
                                        ? controller.stopGeneration
                                        : _send,
                                    style: IconButton.styleFrom(
                                      backgroundColor: controller.busy
                                          ? Theme.of(context).colorScheme.error
                                          : Theme.of(
                                              context,
                                            ).colorScheme.onSurface,
                                      foregroundColor: Theme.of(
                                        context,
                                      ).colorScheme.surface,
                                      fixedSize: const Size.square(36),
                                      minimumSize: const Size.square(36),
                                      maximumSize: const Size.square(36),
                                      padding: EdgeInsets.zero,
                                      tapTargetSize:
                                          MaterialTapTargetSize.shrinkWrap,
                                    ),
                                    icon: controller.busy
                                        ? const _LegacyIcon(
                                            _LegacyIconKind.stop,
                                            size: 16,
                                          )
                                        : textController.text.trim().isEmpty &&
                                              controller
                                                  .pendingAttachments
                                                  .isEmpty
                                        ? const _LegacyIcon(
                                            _LegacyIconKind.waveform,
                                            size: 18,
                                          )
                                        : const _LegacyIcon(
                                            _LegacyIconKind.send,
                                            size: 18,
                                          ),
                                    tooltip: controller.busy ? '停止生成' : '发送',
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
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

  void _syncEditState() {
    if (_syncedEditRequestSerial == controller.editRequestSerial) return;
    _syncedEditRequestSerial = controller.editRequestSerial;
    final message = controller.editingUserMessage;
    if (message == null) return;
    textController.value = TextEditingValue(
      text: message.content,
      selection: TextSelection.collapsed(offset: message.content.length),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || controller.editingUserMessage == null) return;
      _inputFocus.requestFocus();
      textController.selection = TextSelection.collapsed(
        offset: textController.text.length,
      );
    });
  }

  void _cancelEdit() {
    textController.clear();
    controller.cancelUserMessageEdit();
    _inputFocus.requestFocus();
  }

  void _dismissKeyboard() {
    _inputFocus.unfocus();
    FocusManager.instance.primaryFocus?.unfocus();
  }

  void _send() {
    final value = textController.text;
    if (value.trim().isEmpty && controller.pendingAttachments.isEmpty) return;
    textController.clear();
    _dismissKeyboard();
    if (controller.editingUserMessage != null) {
      controller.submitUserMessageEdit(value);
    } else {
      controller.send(value);
    }
  }

  void _showMoreActions(BuildContext context) {
    if (_actionsEntry != null) return;
    _dismissKeyboard();
    final overlay = Overlay.of(context);
    late final OverlayEntry entry;
    void close() {
      if (entry.mounted) entry.remove();
      if (mounted) {
        setState(() => _actionsEntry = null);
      }
    }

    entry = OverlayEntry(
      builder: (overlayContext) => Stack(
        children: <Widget>[
          Positioned.fill(
            child: Semantics(
              button: true,
              label: '关闭',
              excludeSemantics: true,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: close,
              ),
            ),
          ),
          Positioned(
            left: 18,
            bottom: MediaQuery.viewPaddingOf(overlayContext).bottom + 70,
            width: 226,
            height: 340,
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                boxShadow: const <BoxShadow>[
                  BoxShadow(
                    color: Color(0x291F1912),
                    offset: Offset(0, 8),
                    blurRadius: 32,
                  ),
                ],
              ),
              child: Material(
                color: Theme.of(context).colorScheme.surface,
                elevation: 0,
                clipBehavior: Clip.antiAlias,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: BorderSide(
                    color: Theme.of(context).colorScheme.outline,
                    width: 0.666667,
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    0.666667,
                    6.666667,
                    0.666667,
                    6.666667,
                  ),
                  child: Column(
                    children: <Widget>[
                      _MoreActionRow(
                        icon: Icons.camera_alt_outlined,
                        label: '相机',
                        onTap: () async {
                          close();
                          await controller.captureAttachment(
                            confirmLargeSelection: _confirmLargeAttachments,
                          );
                        },
                      ),
                      _MoreActionRow(
                        icon: Icons.photo_library_outlined,
                        label: '照片',
                        showTopBorder: true,
                        onTap: () async {
                          close();
                          await controller.pickPhotoAttachments(
                            confirmLargeSelection: _confirmLargeAttachments,
                          );
                        },
                      ),
                      _MoreActionRow(
                        icon: Icons.attach_file_rounded,
                        label: '文件',
                        showTopBorder: true,
                        onTap: () async {
                          close();
                          await controller.pickAttachments(
                            confirmLargeSelection: _confirmLargeAttachments,
                          );
                        },
                      ),
                      _MoreActionRow(
                        icon: Icons.build_outlined,
                        label: '工具箱',
                        showTopBorder: true,
                        onTap: () {
                          close();
                          unawaited(_showToolbox());
                        },
                      ),
                      _MoreActionRow(
                        icon: Icons.extension_outlined,
                        label: '插件',
                        showTopBorder: true,
                        onTap: () {
                          close();
                          unawaited(_showPluginsPlaceholder());
                        },
                      ),
                      _MoreActionRow(
                        icon: Icons.download_outlined,
                        label: '导出当前对话',
                        showTopBorder: true,
                        onTap: () {
                          close();
                          final conversation = controller.activeConversation;
                          if (conversation != null) {
                            controller.exportConversation(conversation);
                          }
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
    setState(() => _actionsEntry = entry);
    overlay.insert(entry);
  }

  Future<void> _showToolbox() async {
    await Future<void>.delayed(Duration.zero);
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => FractionallySizedBox(
        heightFactor: .82,
        child: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 8, 8),
              child: Row(
                children: <Widget>[
                  const Expanded(
                    child: Text(
                      '工具箱',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(sheetContext),
                    icon: const Icon(Icons.close_rounded),
                    tooltip: '关闭',
                  ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.only(bottom: 24),
                child: _LegacyToolboxSettingsPanel(controller: controller),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showPluginsPlaceholder() async {
    await Future<void>.delayed(Duration.zero);
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheetContext) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 2, 24, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Row(
              children: <Widget>[
                Icon(Icons.extension_outlined, size: 22),
                SizedBox(width: 10),
                Text(
                  '插件',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              '已预留插件入口。后续可在这里安装工具、MCP 服务、界面扩展，或带有独立指令与工作流的 Agent 插件。',
              style: TextStyle(
                height: 1.55,
                color: Theme.of(sheetContext).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<bool> _confirmLargeAttachments(
    LargeAttachmentSelection selection,
  ) async {
    if (!mounted) return false;
    final largeNames = selection.largeFileNames.isEmpty
        ? '本次选择的附件总量超过 50 MB。'
        : '超过 50 MB 的文件：${selection.largeFileNames.join('、')}';
    final approved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('确认添加大附件？'),
        content: Text(
          '$largeNames\n\n'
          '最大文件：${_byteSizeLabel(selection.largestFileBytes)}\n'
          '本次合计：${_byteSizeLabel(selection.totalBytes)}\n\n'
          '继续可能消耗较多内存、流量和 API 费用，也可能被模型供应商拒绝。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('仍然添加'),
          ),
        ],
      ),
    );
    return approved == true;
  }
}

class _MoreActionRow extends StatelessWidget {
  const _MoreActionRow({
    required this.icon,
    required this.label,
    required this.onTap,
    this.showTopBorder = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool showTopBorder;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      border: showTopBorder
          ? const Border(top: BorderSide(color: _lightLine, width: 0.666667))
          : null,
    ),
    child: Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: 54,
          child: Row(
            children: <Widget>[
              const SizedBox(width: 13),
              Icon(icon, size: 23, color: const Color(0xFF101010)),
              const SizedBox(width: 17),
              Text(
                label,
                style: const TextStyle(
                  fontSize: _legacyChatBodyFontSize,
                  height: 1.15,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _MemoriesPage extends StatefulWidget {
  const _MemoriesPage({required this.controller, super.key});
  final AppController controller;

  @override
  State<_MemoriesPage> createState() => _MemoriesPageState();
}

class _MemoriesPageState extends State<_MemoriesPage> {
  final search = TextEditingController();
  TextEditingController? editorContent;
  TextEditingController? editorTags;
  String? editingId;
  String editorLevel = 'important';
  String level = 'all';
  String? highlightedEntryId;
  Timer? _highlightTimer;

  AppController get controller => widget.controller;

  @override
  void dispose() {
    _highlightTimer?.cancel();
    search.dispose();
    editorContent?.dispose();
    editorTags?.dispose();
    super.dispose();
  }

  void highlightEntry(String entryId) {
    _highlightTimer?.cancel();
    setState(() => highlightedEntryId = entryId);
    _highlightTimer = Timer(const Duration(milliseconds: 2800), () {
      if (!mounted || highlightedEntryId != entryId) return;
      setState(() => highlightedEntryId = null);
    });
  }

  void startEditor([MemoryEntry? entry]) {
    editorContent?.dispose();
    editorTags?.dispose();
    setState(() {
      editingId = entry?.id;
      editorContent = TextEditingController(text: entry?.content ?? '');
      editorTags = TextEditingController(text: entry?.tags.join(' ') ?? '');
      editorLevel = entry?.level ?? 'important';
    });
  }

  void _cancelEditor() {
    editorContent?.dispose();
    editorTags?.dispose();
    setState(() {
      editingId = null;
      editorContent = null;
      editorTags = null;
      editorLevel = 'important';
    });
  }

  Future<void> _saveEditor() async {
    final content = editorContent?.text.trim() ?? '';
    if (content.isEmpty) {
      _snack(context, '先写一点记忆内容');
      return;
    }
    await controller.content.saveMemory(
      id: editingId,
      content: content,
      level: editorLevel,
      tags: (editorTags?.text ?? '')
          .split(RegExp(r'[,，#\s]+'))
          .map((item) => item.trim())
          .where((item) => item.isNotEmpty)
          .toSet()
          .take(12)
          .toList(),
    );
    _cancelEditor();
    await controller.reload();
    if (mounted) _snack(context, '记忆已保存');
  }

  Future<void> _deleteMemory(MemoryEntry item) async {
    final first = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: const Text('删除这条记忆？它会从默认搜索结果里隐藏，但导出数据仍可保留。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (first != true || !mounted) return;
    final second = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: const Text('再次确认：真的要删除吗？'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认删除'),
          ),
        ],
      ),
    );
    if (second != true) return;
    await controller.deleteMemoryFromUi(item.id);
    if (mounted) _snack(context, '记忆已删除');
  }

  @override
  Widget build(BuildContext context) {
    final query = search.text.trim().toLowerCase();
    final filtered = controller.memories
        .where(
          (item) =>
              (level == 'all'
                  ? item.deletedAt == null
                  : level == 'deleted'
                  ? item.deletedAt != null
                  : item.deletedAt == null && item.level == level) &&
              (query.isEmpty ||
                  item.content.toLowerCase().contains(query) ||
                  item.tags.any((tag) => tag.toLowerCase().contains(query))),
        )
        .take(80)
        .toList();
    return _StandardPage(
      title: 'Ta 的记忆',
      subtitle: '',
      child: Column(
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: search,
                  onChanged: (_) => setState(() {}),
                  style: const TextStyle(fontSize: 14, height: 1.2),
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search, size: 18),
                    prefixIconConstraints: BoxConstraints(
                      minWidth: 44,
                      minHeight: 42,
                    ),
                    hintText: '搜索内容或标签',
                    contentPadding: EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              _MemoryFilterPill(
                label:
                    '${controller.memories.where((item) => item.deletedAt == null).length} 条可用',
                selected: level == 'all',
                onTap: () => setState(() => level = 'all'),
              ),
              const SizedBox(width: 8),
              _MemoryFilterPill(
                label:
                    '${controller.memories.where((item) => item.deletedAt == null && item.level == 'critical').length} 条关键',
                selected: level == 'critical',
                onTap: () => setState(() => level = 'critical'),
              ),
              const SizedBox(width: 8),
              _MemoryFilterPill(
                label:
                    '${controller.memories.where((item) => item.deletedAt != null).length} 条已删',
                selected: level == 'deleted',
                onTap: () => setState(() => level = 'deleted'),
              ),
            ],
          ),
          const SizedBox(height: 22),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '关键记忆会自动注入上下文；其他等级默认留在本地库里，AI 需要时会自己搜索。',
              style: TextStyle(
                fontSize: 9.9,
                height: 1.25,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          if (editorContent != null) ...<Widget>[
            const SizedBox(height: 12),
            _LegacyMemoryEditor(
              content: editorContent!,
              tags: editorTags!,
              level: editorLevel,
              onLevelChanged: (value) => setState(() => editorLevel = value),
              onCancel: _cancelEditor,
              onSave: _saveEditor,
            ),
          ],
          const SizedBox(height: 12),
          Expanded(
            child: filtered.isEmpty
                ? const _EmptyState(
                    icon: Icons.push_pin_outlined,
                    legacyIcon: _LegacyIconKind.pin,
                    offsetY: -1,
                    title: '还没有匹配的记忆。',
                    message: '换一个关键词，或者等 AI 创建一些记忆。',
                  )
                : LayoutBuilder(
                    builder: (context, constraints) => ListView.separated(
                      padding: EdgeInsets.zero,
                      itemCount: filtered.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (context, index) {
                        final item = filtered[index];
                        return ConstrainedBox(
                          constraints: BoxConstraints(
                            minHeight: filtered.length == 1
                                ? constraints.maxHeight
                                : 0,
                          ),
                          child: _LegacyMemoryCard(
                            item: item,
                            highlighted: item.id == highlightedEntryId,
                            onEdit: () => startEditor(item),
                            onDelete: () => _deleteMemory(item),
                            onRestore: () async {
                              await controller.restoreEntity(
                                'memories',
                                item.id,
                              );
                              if (mounted) _snack(this.context, '记忆已恢复');
                            },
                          ),
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _LegacyMemoryEditor extends StatelessWidget {
  const _LegacyMemoryEditor({
    required this.content,
    required this.tags,
    required this.level,
    required this.onLevelChanged,
    required this.onCancel,
    required this.onSave,
  });

  final TextEditingController content;
  final TextEditingController tags;
  final String level;
  final ValueChanged<String> onLevelChanged;
  final VoidCallback onCancel;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: dark ? _darkSurface : _lightSurfaceSoft,
        border: Border.all(color: dark ? _darkLine : _lightLine),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const Text('记忆内容', style: TextStyle(fontSize: 12)),
          const SizedBox(height: 6),
          TextField(
            controller: content,
            autofocus: true,
            minLines: 3,
            maxLines: 6,
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    const Text('等级', style: TextStyle(fontSize: 12)),
                    const SizedBox(height: 6),
                    _LegacySelect(
                      value: level,
                      items: const <(String, String)>[
                        ('critical', '关键'),
                        ('important', '重要'),
                        ('daily', '日常'),
                        ('trivial', '琐事'),
                        ('archived', '归档'),
                      ],
                      onChanged: onLevelChanged,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    const Text('标签', style: TextStyle(fontSize: 12)),
                    const SizedBox(height: 6),
                    TextField(
                      controller: tags,
                      decoration: const InputDecoration(hintText: '用空格或逗号分隔'),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Expanded(
                child: OutlinedButton(
                  onPressed: onCancel,
                  child: const Text('取消'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.icon(
                  onPressed: onSave,
                  icon: const _LegacyIcon(_LegacyIconKind.check, size: 18),
                  label: const Text('保存'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _LegacyMemoryCard extends StatelessWidget {
  const _LegacyMemoryCard({
    required this.item,
    required this.highlighted,
    required this.onEdit,
    required this.onDelete,
    required this.onRestore,
  });

  final MemoryEntry item;
  final bool highlighted;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onRestore;

  @override
  Widget build(BuildContext context) {
    final deleted = item.deletedAt != null;
    final sourceLabel = switch (item.source) {
      'ai' => 'AI 创建',
      'user_explicit' => '用户创建',
      _ => '手动',
    };
    final dark = Theme.of(context).brightness == Brightness.dark;
    final surface = dark ? _darkSurface : _lightSurface;
    final muted = dark ? _darkMuted : _lightMuted;
    final line = dark ? _darkLine : _lightLine;
    final soft = dark ? _darkBackground : _lightSurfaceSoft;
    final accentStrong = dark
        ? const Color(0xFFF1A077)
        : const Color(0xFFAD5938);
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: highlighted ? 1 : 0),
      duration: highlighted
          ? const Duration(milliseconds: 2500)
          : Duration.zero,
      builder: (context, progress, child) {
        final amount = _entryFlashAmount(progress);
        return Semantics(
          container: true,
          explicitChildNodes: true,
          child: Opacity(
            opacity: deleted ? .78 : 1,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(12, 14, 12, 12),
              decoration: BoxDecoration(
                color: Color.lerp(
                  surface,
                  Theme.of(context).colorScheme.primary,
                  .12 * amount,
                ),
                border: Border.all(color: line),
                borderRadius: BorderRadius.circular(12),
                boxShadow: amount == 0
                    ? const <BoxShadow>[]
                    : <BoxShadow>[
                        BoxShadow(
                          color: Theme.of(
                            context,
                          ).colorScheme.primary.withValues(alpha: .6 * amount),
                          spreadRadius: 4 * amount,
                        ),
                      ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      _MemoryTag(
                        label: deleted ? '已删除' : _levelName(item.level),
                        foreground: muted,
                        background: soft,
                      ),
                      const Spacer(),
                      Text(
                        DateFormat(
                          'MM/dd HH:mm',
                        ).format(item.updatedAt.toLocal()),
                        style: TextStyle(
                          color: muted,
                          fontSize: 11,
                          height: 1.212,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 7),
                  Text(
                    item.content,
                    style: TextStyle(color: muted, fontSize: 12, height: 1.3),
                  ),
                  const SizedBox(height: 9),
                  Wrap(
                    spacing: 6,
                    runSpacing: 5,
                    children: item.tags
                        .map(
                          (tag) => _MemoryTag(
                            label: tag,
                            foreground: accentStrong,
                            background: Color.alphaBlend(
                              _accent.withValues(alpha: .12),
                              surface,
                            ),
                          ),
                        )
                        .toList(),
                  ),
                  if (item.deleteReason != null &&
                      item.deleteReason!.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 8),
                    Text(
                      '删除原因：${item.deleteReason}',
                      style: TextStyle(
                        color: muted,
                        fontSize: 11,
                        height: 1.25,
                      ),
                    ),
                  ],
                  const SizedBox(height: 11),
                  Row(
                    children: <Widget>[
                      Text(
                        sourceLabel,
                        style: TextStyle(
                          color: muted,
                          fontSize: 11,
                          height: 1.212,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        '调用 ${item.useFrequency} 次',
                        style: TextStyle(
                          color: muted,
                          fontSize: 11,
                          height: 1.212,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 11),
                  Row(
                    children: <Widget>[
                      if (deleted)
                        _MemoryActionButton(
                          icon: _LegacyIconKind.refresh,
                          label: '恢复',
                          onPressed: onRestore,
                        )
                      else ...<Widget>[
                        _MemoryActionButton(
                          icon: _LegacyIconKind.edit,
                          label: '编辑',
                          onPressed: onEdit,
                        ),
                        const SizedBox(width: 8),
                        _MemoryActionButton(
                          icon: _LegacyIconKind.trash,
                          label: '删除',
                          onPressed: onDelete,
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

double _entryFlashAmount(double progress) {
  final percent = progress * 100;
  if (percent >= 90) return 0;
  final segment = (percent / 15).floor();
  final offset = (percent % 15) / 15;
  return segment.isEven ? offset : 1 - offset;
}

class _MemoryTag extends StatelessWidget {
  const _MemoryTag({
    required this.label,
    required this.foreground,
    required this.background,
  });

  final String label;
  final Color foreground;
  final Color background;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3.5),
    decoration: BoxDecoration(
      color: background,
      borderRadius: BorderRadius.circular(999),
    ),
    child: Text(
      label,
      style: TextStyle(color: foreground, fontSize: 11, height: 1.212),
    ),
  );
}

class _MemoryActionButton extends StatelessWidget {
  const _MemoryActionButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final _LegacyIconKind icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final text = dark ? _darkText : _lightText;
    final line = dark ? _darkLine : _lightLine;
    return SizedBox(
      height: 32,
      child: OutlinedButton.icon(
        onPressed: onPressed,
        icon: _LegacyIcon(icon, size: 16, color: text),
        label: Text(label),
        style: OutlinedButton.styleFrom(
          foregroundColor: text,
          side: BorderSide(color: line),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          visualDensity: VisualDensity.compact,
          shape: const StadiumBorder(),
          textStyle: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            height: 1.1,
          ),
        ),
      ),
    );
  }
}

class _MemoryFilterPill extends StatelessWidget {
  const _MemoryFilterPill({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Expanded(
      child: SizedBox(
        height: 34,
        child: OutlinedButton(
          onPressed: onTap,
          style: OutlinedButton.styleFrom(
            backgroundColor: selected
                ? (dark ? _darkSurface : _lightSurfaceSoft)
                : (dark ? _darkSurface : _lightSurface),
            side: BorderSide(
              color: selected ? _accent : (dark ? _darkLine : _lightLine),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 4),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
            foregroundColor: selected
                ? (dark ? const Color(0xFFF1A077) : const Color(0xFFAD5938))
                : (dark ? _darkMuted : _lightMuted),
            textStyle: const TextStyle(fontSize: 11.5, height: 1.2),
          ),
          child: Text(label, maxLines: 1),
        ),
      ),
    );
  }
}

class _DiaryPage extends StatefulWidget {
  const _DiaryPage({required this.controller, super.key});
  final AppController controller;

  @override
  State<_DiaryPage> createState() => _DiaryPageState();
}

class _DiaryPageState extends State<_DiaryPage> {
  final search = TextEditingController();
  final Map<String, String> _contents = <String, String>{};
  final Map<String, String> _searchHaystacks = <String, String>{};
  final Map<String, int> _versionCounts = <String, int>{};
  String _indexSignature = '';

  AppController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _ensureSearchIndex();
  }

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  Future<void> openNotificationEntry(String entryId) async {
    final entry = controller.diaries
        .where((item) => item.id == entryId)
        .firstOrNull;
    if (entry != null && mounted) {
      await _showDiaryDetail(context, entry);
    }
  }

  @override
  Widget build(BuildContext context) {
    _ensureSearchIndex();
    final query = search.text.trim().toLowerCase();
    final filtered =
        controller.diaries
            .where((item) => query.isEmpty || _diaryScore(item, query) > 0)
            .toList()
          ..sort((left, right) {
            final byUpdated = right.updatedAt.compareTo(left.updatedAt);
            return byUpdated != 0 ? byUpdated : right.id.compareTo(left.id);
          });
    if (filtered.length > 80) filtered.removeRange(80, filtered.length);
    return _StandardPage(
      title: 'Ta的心事',
      subtitle: '',
      rightPadding: filtered.isEmpty ? 30 : 14,
      legacyScrollbar: filtered.isEmpty,
      child: Column(
        children: <Widget>[
          TextField(
            controller: search,
            onChanged: (_) => setState(() {}),
            style: const TextStyle(fontSize: 14, height: 1.2),
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search_rounded, size: 18),
              prefixIconConstraints: BoxConstraints(
                minWidth: 44,
                minHeight: 42,
              ),
              hintText: '搜索关键词、标签、理由',
              contentPadding: EdgeInsets.symmetric(vertical: 12),
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: controller.diaries.isEmpty
                ? const _EmptyState(
                    icon: Icons.auto_stories_outlined,
                    legacyIcon: _LegacyIconKind.diary,
                    offsetY: 26,
                    title: '还没有找到心事',
                    message: '等 AI 写下第一篇，或者换个关键词试试。',
                  )
                : filtered.isEmpty
                ? const _EmptyState(
                    icon: Icons.search_off_rounded,
                    title: '还没有找到心事',
                    message: '换一个关键词试试。',
                  )
                : GridView.builder(
                    padding: const EdgeInsets.only(bottom: 24),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount:
                          controller.settings['diaryViewMode'] == 'list'
                          ? 1
                          : 2,
                      mainAxisExtent:
                          controller.settings['diaryViewMode'] == 'list'
                          ? 98
                          : 148.2,
                      crossAxisSpacing: 10,
                      mainAxisSpacing: 10,
                    ),
                    itemCount: filtered.length,
                    itemBuilder: (context, index) {
                      final item = filtered[index];
                      return _LegacyDiaryCard(
                        entry: item,
                        content: _contents[item.id] ?? '',
                        versionCount: _versionCounts[item.id] ?? 0,
                        listMode:
                            controller.settings['diaryViewMode'] == 'list',
                        onTap: () => _showDiaryDetail(context, item),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Future<List<DiaryVersion>> _versionsFor(DiaryEntry entry) async {
    final audit = controller.visualAuditDiaryVersions
        .where((version) => version.diaryId == entry.id)
        .toList();
    if (audit.isNotEmpty) {
      audit.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return audit;
    }
    return controller.content.diaryVersions(entry.id);
  }

  DiaryVersion? _latestVersion(DiaryEntry entry, List<DiaryVersion> versions) =>
      versions
          .where((version) => version.id == entry.latestVersionId)
          .firstOrNull ??
      versions.firstOrNull;

  int _diaryScore(DiaryEntry entry, String query) {
    if (query.isEmpty) return entry.updatedAt.millisecondsSinceEpoch;
    final haystack =
        _searchHaystacks[entry.id] ??
        <String>[
          entry.title,
          entry.mood ?? '',
          entry.deleteReason ?? '',
          entry.tags.join(' '),
          _contents[entry.id] ?? '',
        ].join(' ').toLowerCase();
    var score = haystack.contains(query) ? 10 : 0;
    for (final word
        in query.split(RegExp(r'\s+')).where((word) => word.isNotEmpty)) {
      if (haystack.contains(word)) score += 2;
    }
    if (entry.status == 'active') score += 1;
    return score;
  }

  Future<void> _showDiaryDetail(BuildContext context, DiaryEntry entry) async {
    final versions = await _versionsFor(entry);
    if (!context.mounted) return;
    final latest = _latestVersion(entry, versions);
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: false,
      transitionDuration: Duration.zero,
      pageBuilder: (dialogContext, _, _) => _LegacyDiaryDetail(
        controller: controller,
        entry: entry,
        content: latest?.content ?? '',
        versionCount: versions.length,
        onBack: () => Navigator.pop(dialogContext),
        onCopy: () =>
            Clipboard.setData(ClipboardData(text: latest?.content ?? '')),
        onExport: () => _exportDiary(entry, versions),
        onHistory: () => _diaryHistory(dialogContext, entry),
      ),
    );
  }

  Future<void> _diaryHistory(BuildContext context, DiaryEntry entry) async {
    final versions = await _versionsFor(entry);
    if (!context.mounted) return;
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: false,
      transitionDuration: Duration.zero,
      pageBuilder: (historyContext, _, _) => _LegacyDiaryHistory(
        entry: entry,
        versions: versions,
        onBack: () => Navigator.pop(historyContext),
        onOpenVersion: (version) => _showDiaryVersion(historyContext, version),
      ),
    );
  }

  Future<void> _showDiaryVersion(
    BuildContext context,
    DiaryVersion version,
  ) async {
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: false,
      transitionDuration: Duration.zero,
      pageBuilder: (versionContext, _, _) => _LegacyDiaryVersionDetail(
        controller: controller,
        version: version,
        onBack: () => Navigator.pop(versionContext),
      ),
    );
  }

  Future<void> _exportDiary(
    DiaryEntry entry,
    List<DiaryVersion> versions,
  ) async {
    final timestamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
    final payload = <String, Object?>{
      'version': 1,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'entry': <String, Object?>{
        'id': entry.id,
        'title': entry.title,
        'status': entry.status,
        'mood': entry.mood ?? '',
        'tags': entry.tags,
        'latestVersionId': entry.latestVersionId ?? '',
        'sourceConversationId': entry.sourceConversationId ?? '',
        'createdAt': entry.createdAt.toUtc().toIso8601String(),
        'updatedAt': entry.updatedAt.toUtc().toIso8601String(),
        'deletedAt': entry.deletedAt?.toUtc().toIso8601String() ?? '',
        'deleteReason': entry.deleteReason ?? '',
      },
      'versions': versions
          .map(
            (version) => <String, Object?>{
              'id': version.id,
              'diaryId': version.diaryId,
              'title': version.title,
              'content': version.content,
              'operation': version.operation,
              'reason': version.reason ?? '',
              'mood': version.mood ?? '',
              'tags': version.tags,
              'sourceConversationId': version.sourceConversationId ?? '',
              'createdAt': version.createdAt.toUtc().toIso8601String(),
            },
          )
          .toList(),
    };
    await controller.shareTextContent(
      name: 'Chat_$timestamp.json',
      content: const JsonEncoder.withIndent('  ').convert(payload),
    );
  }

  void _ensureSearchIndex() {
    final signature = controller.diaries
        .map((item) => '${item.id}:${item.updatedAt.microsecondsSinceEpoch}')
        .join('|');
    if (signature == _indexSignature) return;
    _indexSignature = signature;
    Future<void>(() async {
      final next = <String, String>{};
      final counts = <String, int>{};
      for (final item in controller.diaries) {
        final auditVersions = controller.visualAuditDiaryVersions
            .where((version) => version.diaryId == item.id)
            .toList();
        if (auditVersions.isNotEmpty) {
          auditVersions.sort((a, b) => b.createdAt.compareTo(a.createdAt));
          next[item.id] = _latestVersion(item, auditVersions)?.content ?? '';
          counts[item.id] = auditVersions.length;
          _searchHaystacks[item.id] = _diaryHaystack(item, auditVersions);
        } else {
          final versions = await controller.content.diaryVersions(item.id);
          next[item.id] = _latestVersion(item, versions)?.content ?? '';
          counts[item.id] = versions.length;
          _searchHaystacks[item.id] = _diaryHaystack(item, versions);
        }
      }
      if (!mounted || signature != _indexSignature) return;
      setState(() {
        _contents
          ..clear()
          ..addAll(next);
        _versionCounts
          ..clear()
          ..addAll(counts);
      });
    });
  }

  String _diaryHaystack(DiaryEntry entry, List<DiaryVersion> versions) =>
      <String>[
        entry.title,
        entry.mood ?? '',
        entry.deleteReason ?? '',
        entry.tags.join(' '),
        ...versions.map(
          (version) =>
              '${version.title} ${version.content} ${version.reason ?? ''}',
        ),
      ].join(' ').toLowerCase();
}

class _LegacyDetailHeader extends StatelessWidget {
  const _LegacyDetailHeader({
    required this.title,
    required this.onBack,
    this.backTooltip = '返回',
    this.actions = const <Widget>[],
    this.titleSuffix,
    this.fontSize = 18,
  });

  final String title;
  final VoidCallback onBack;
  final String backTooltip;
  final List<Widget> actions;
  final Widget? titleSuffix;
  final double fontSize;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 58,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
      child: Row(
        children: <Widget>[
          SizedBox.square(
            dimension: 36,
            child: IconButton(
              onPressed: onBack,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 36, height: 36),
              icon: const Icon(Icons.chevron_left, size: 22),
              tooltip: backTooltip,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Row(
              children: <Widget>[
                Flexible(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.left,
                    style: TextStyle(
                      fontSize: fontSize,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (titleSuffix != null) ...<Widget>[
                  const SizedBox(width: 8),
                  titleSuffix!,
                ],
              ],
            ),
          ),
          if (actions.isNotEmpty) ...<Widget>[
            const SizedBox(width: 6),
            Row(mainAxisSize: MainAxisSize.min, children: actions),
          ],
        ],
      ),
    ),
  );
}

class _LegacyEmptyContent extends StatelessWidget {
  const _LegacyEmptyContent({this.label = '小机子没有写下任何内容'});

  final String label;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).brightness == Brightness.dark
        ? _darkMuted
        : _lightMuted;
    return Align(
      alignment: Alignment.topLeft,
      child: Text(
        label,
        style: TextStyle(
          color: muted.withValues(alpha: .52),
          fontSize: 12,
          fontStyle: FontStyle.italic,
          height: 1.45,
        ),
      ),
    );
  }
}

class _LegacyDiaryDetail extends StatelessWidget {
  const _LegacyDiaryDetail({
    required this.controller,
    required this.entry,
    required this.content,
    required this.versionCount,
    required this.onBack,
    required this.onCopy,
    required this.onExport,
    required this.onHistory,
  });

  final AppController controller;
  final DiaryEntry entry;
  final String content;
  final int versionCount;
  final VoidCallback onBack;
  final VoidCallback onCopy;
  final VoidCallback onExport;
  final VoidCallback onHistory;

  @override
  Widget build(BuildContext context) {
    final deleted = entry.deletedAt != null || entry.status == 'deleted';
    final time = DateFormat('MM/dd HH:mm').format(entry.updatedAt.toLocal());
    return Semantics(
      scopesRoute: true,
      namesRoute: true,
      explicitChildNodes: true,
      label: '日记详情',
      child: Material(
        color: Theme.of(context).scaffoldBackgroundColor,
        child: SafeArea(
          child: Column(
            children: <Widget>[
              _LegacyDetailHeader(
                title: entry.title,
                onBack: onBack,
                actions: <Widget>[
                  _LegacyFileAction(
                    icon: _LegacyIconKind.copy,
                    tooltip: '复制',
                    onPressed: onCopy,
                  ),
                  _LegacyFileAction(
                    icon: _LegacyIconKind.download,
                    tooltip: '导出',
                    onPressed: onExport,
                  ),
                  if (versionCount > 0)
                    _LegacyFileAction(
                      icon: _LegacyIconKind.clock,
                      tooltip: '历史版本',
                      onPressed: onHistory,
                    ),
                ],
              ),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: Theme.of(context).brightness == Brightness.dark
                          ? _darkLine
                          : _lightLine,
                      width: 2 / 3,
                    ),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    SizedBox(
                      height: 24,
                      child: Row(
                        children: <Widget>[
                          _LegacyDiaryState(
                            label: deleted
                                ? '已删除'
                                : (entry.mood?.isNotEmpty == true
                                      ? entry.mood!
                                      : '有效'),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            time,
                            style: _legacyDiaryMetaStyle(
                              context,
                            ).copyWith(fontWeight: FontWeight.w400),
                          ),
                        ],
                      ),
                    ),
                    if (entry.tags.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 9),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: entry.tags
                            .map((tag) => _LegacyDiaryTag(label: tag))
                            .toList(),
                      ),
                    ],
                    if (deleted) ...<Widget>[
                      const SizedBox(height: 10),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: const Color(0xFFBD3E3E).withValues(alpha: .10),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          '这篇日记已被 AI 标记为已删除：${entry.deleteReason ?? '没有留下原因。'}',
                          style: const TextStyle(
                            color: Color(0xFFBD3E3E),
                            fontSize: 12,
                            height: 1.35,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              Expanded(
                child: deleted
                    ? Center(
                        child: Text(
                          '日记内容请在历史版本中查看',
                          style: TextStyle(
                            color:
                                Theme.of(context).brightness == Brightness.dark
                                ? _darkMuted
                                : _lightMuted,
                            fontSize: 11,
                          ),
                        ),
                      )
                    : SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(16, 26.333, 16, 18),
                        child: content.trim().isEmpty
                            ? const _LegacyEmptyContent()
                            : _LegacyMarkdownContent(
                                data: content,
                                streaming: false,
                                controller: controller,
                                styleSheet: _legacyContentMarkdownStyle(
                                  context,
                                  controller,
                                ),
                              ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LegacyDiaryTag extends StatelessWidget {
  const _LegacyDiaryTag({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      constraints: const BoxConstraints(minHeight: 22),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Color.alphaBlend(
          _accent.withValues(alpha: .12),
          dark ? _darkSurface : _lightSurface,
        ),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: dark ? const Color(0xFFF1A077) : const Color(0xFFAD5938),
          fontSize: 11,
          fontWeight: FontWeight.w700,
          height: 1.35,
        ),
      ),
    );
  }
}

class _LegacyDiaryHistory extends StatelessWidget {
  const _LegacyDiaryHistory({
    required this.entry,
    required this.versions,
    required this.onBack,
    required this.onOpenVersion,
  });

  final DiaryEntry entry;
  final List<DiaryVersion> versions;
  final VoidCallback onBack;
  final ValueChanged<DiaryVersion> onOpenVersion;

  @override
  Widget build(BuildContext context) => Semantics(
    scopesRoute: true,
    namesRoute: true,
    explicitChildNodes: true,
    label: '日记历史',
    child: Material(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: SafeArea(
        child: Column(
          children: <Widget>[
            _LegacyDetailHeader(
              title: '${entry.title} · 历史版本',
              onBack: onBack,
              backTooltip: '返回详情',
            ),
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.all(12),
                itemCount: versions.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final version = versions[index];
                  final operation = switch (version.operation) {
                    'create' => '创建',
                    'delete' => '删除',
                    _ => '修订',
                  };
                  final time = DateFormat(
                    'MM/dd HH:mm',
                  ).format(version.createdAt.toLocal());
                  return Semantics(
                    button: true,
                    label: '$operation\n$time',
                    child: ExcludeSemantics(
                      child: Material(
                        color: Theme.of(context).brightness == Brightness.dark
                            ? _darkSurface
                            : _lightSurface,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: BorderSide(
                            color:
                                Theme.of(context).brightness == Brightness.dark
                                ? _darkLine
                                : _lightLine,
                            width: 2 / 3,
                          ),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          onTap: () => onOpenVersion(version),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 12,
                            ),
                            child: Row(
                              children: <Widget>[
                                _LegacyDiaryState(label: operation),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    time,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: _legacyDiaryMetaStyle(
                                      context,
                                    ).copyWith(fontWeight: FontWeight.w400),
                                  ),
                                ),
                                _LegacyIcon(
                                  _LegacyIconKind.chevronRight,
                                  size: 16,
                                  color:
                                      Theme.of(context).brightness ==
                                          Brightness.dark
                                      ? _darkMuted
                                      : _lightMuted,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _LegacyDiaryVersionDetail extends StatelessWidget {
  const _LegacyDiaryVersionDetail({
    required this.controller,
    required this.version,
    required this.onBack,
  });

  final AppController controller;
  final DiaryVersion version;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final operation = switch (version.operation) {
      'create' => '创建',
      'delete' => '删除',
      _ => '修订',
    };
    final time = DateFormat('MM/dd HH:mm').format(version.createdAt.toLocal());
    return Semantics(
      scopesRoute: true,
      namesRoute: true,
      explicitChildNodes: true,
      label: '日记版本详情',
      child: Material(
        color: Theme.of(context).scaffoldBackgroundColor,
        child: SafeArea(
          child: Column(
            children: <Widget>[
              _LegacyDetailHeader(
                title: time,
                onBack: onBack,
                backTooltip: '返回历史列表',
                actions: <Widget>[
                  _LegacyFileAction(
                    icon: _LegacyIconKind.copy,
                    tooltip: '复制',
                    onPressed: () =>
                        Clipboard.setData(ClipboardData(text: version.content)),
                  ),
                  _LegacyFileAction(
                    icon: _LegacyIconKind.download,
                    tooltip: '导出',
                    onPressed: () => controller.shareTextContent(
                      name:
                          'Diary_${DateFormat('yyyyMMdd_HHmmss').format(version.createdAt.toLocal())}.md',
                      content: version.content,
                    ),
                  ),
                ],
              ),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: Theme.of(context).brightness == Brightness.dark
                          ? _darkLine
                          : _lightLine,
                      width: 2 / 3,
                    ),
                  ),
                ),
                child: SizedBox(
                  height: 24,
                  child: Row(
                    children: <Widget>[
                      _LegacyDiaryState(label: operation),
                      if ((version.reason ?? '').isNotEmpty) ...<Widget>[
                        const SizedBox(width: 8),
                        Text(
                          version.reason!,
                          style: _legacyDiaryMetaStyle(
                            context,
                          ).copyWith(fontWeight: FontWeight.w400, height: 1.25),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 30.333, 16, 18),
                  child: version.content.trim().isEmpty
                      ? const _LegacyEmptyContent()
                      : _LegacyMarkdownContent(
                          data: version.content,
                          streaming: false,
                          controller: controller,
                          styleSheet: _legacyContentMarkdownStyle(
                            context,
                            controller,
                          ),
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LegacyDiaryCard extends StatelessWidget {
  const _LegacyDiaryCard({
    required this.entry,
    required this.content,
    required this.versionCount,
    required this.listMode,
    required this.onTap,
  });

  final DiaryEntry entry;
  final String content;
  final int versionCount;
  final bool listMode;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final deleted = entry.deletedAt != null || entry.status == 'deleted';
    final status = deleted ? '已删除' : '有效';
    final summary = content.trim();
    final time = DateFormat('MM/dd HH:mm').format(entry.updatedAt.toLocal());
    final mood = entry.mood?.trim() ?? '';
    final semantics = <String>[
      status,
      time,
      entry.title,
      if (!listMode) summary,
      if (mood.isNotEmpty) mood,
      '$versionCount 个版本',
    ].join('\n');
    return Semantics(
      button: true,
      label: semantics,
      child: ExcludeSemantics(
        child: Material(
          color: deleted
              ? (Theme.of(context).brightness == Brightness.dark
                    ? _darkBackground
                    : _lightSurfaceSoft)
              : (Theme.of(context).brightness == Brightness.dark
                    ? _darkSurface
                    : _lightSurface),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(
              color: Theme.of(context).brightness == Brightness.dark
                  ? _darkLine
                  : _lightLine,
              width: 2 / 3,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: listMode
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        SizedBox(
                          height: 24,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: <Widget>[
                              _LegacyDiaryState(label: status),
                              Text(time, style: _legacyDiaryMetaStyle(context)),
                            ],
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          entry.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            height: 1.2,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: <Widget>[
                            if (mood.isNotEmpty) ...<Widget>[
                              Text(mood, style: _legacyDiaryMetaStyle(context)),
                              const SizedBox(width: 6),
                            ],
                            Text(
                              '$versionCount 个版本',
                              style: _legacyDiaryMetaStyle(context),
                            ),
                          ],
                        ),
                      ],
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        SizedBox(
                          height: 24,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: <Widget>[
                              _LegacyDiaryState(label: status),
                              Text(time, style: _legacyDiaryMetaStyle(context)),
                            ],
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          entry.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            height: 1.2,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          summary,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color:
                                Theme.of(context).brightness == Brightness.dark
                                ? _darkMuted
                                : _lightMuted,
                            fontSize: 11.6,
                            fontWeight: FontWeight.w400,
                            height: 1.45,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: <Widget>[
                            if (mood.isNotEmpty) ...<Widget>[
                              Text(mood, style: _legacyDiaryMetaStyle(context)),
                              const SizedBox(width: 6),
                            ],
                            Text(
                              '$versionCount 个版本',
                              style: _legacyDiaryMetaStyle(context),
                            ),
                          ],
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

TextStyle _legacyDiaryMetaStyle(BuildContext context) => TextStyle(
  color: Theme.of(context).brightness == Brightness.dark
      ? _darkMuted
      : _lightMuted,
  fontSize: 11,
  fontWeight: FontWeight.w700,
  height: 1.35,
);

class _LegacyDiaryState extends StatelessWidget {
  const _LegacyDiaryState({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) => Container(
    constraints: const BoxConstraints(minHeight: 24),
    alignment: Alignment.center,
    padding: const EdgeInsets.symmetric(horizontal: 9),
    decoration: BoxDecoration(
      color: Theme.of(context).brightness == Brightness.dark
          ? _darkBackground
          : _lightSurfaceSoft,
      borderRadius: BorderRadius.circular(999),
    ),
    child: Text(label, style: _legacyDiaryMetaStyle(context)),
  );
}

class _FilesPage extends StatefulWidget {
  const _FilesPage({required this.controller, super.key});
  final AppController controller;

  @override
  State<_FilesPage> createState() => _FilesPageState();
}

class _FilesPageState extends State<_FilesPage> {
  final search = TextEditingController();
  final Map<String, String> _contents = <String, String>{};
  String _indexSignature = '';

  AppController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _ensureSearchIndex();
  }

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  Future<void> openNotificationEntry(String entryId) async {
    final file = controller.files
        .where((item) => item.id == entryId)
        .firstOrNull;
    if (file != null && mounted) {
      await _showFileDetail(context, file, _contents[file.id] ?? '');
    }
  }

  @override
  Widget build(BuildContext context) {
    _ensureSearchIndex();
    final query = search.text.trim().toLowerCase();
    final filtered = controller.files.where((item) {
      if (query.isEmpty) return true;
      final content = _contents[item.id] ?? '';
      final prefix = content.length <= 2000
          ? content
          : content.substring(0, 2000);
      return '${item.name} $prefix'.toLowerCase().contains(query);
    }).toList();
    filtered.sort((left, right) {
      final byUpdated = right.updatedAt.compareTo(left.updatedAt);
      return byUpdated != 0 ? byUpdated : right.id.compareTo(left.id);
    });
    return _StandardPage(
      title: 'Ta的文件',
      subtitle: '',
      rightPadding: 14,
      child: Column(
        children: <Widget>[
          TextField(
            controller: search,
            onChanged: (_) => setState(() {}),
            style: const TextStyle(fontSize: 14, height: 1.2),
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search_rounded, size: 18),
              prefixIconConstraints: BoxConstraints(
                minWidth: 44,
                minHeight: 42,
              ),
              hintText: '搜索文件名或内容',
              contentPadding: EdgeInsets.symmetric(vertical: 12),
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: controller.files.isEmpty
                ? const _EmptyState(
                    icon: Icons.folder_open_outlined,
                    legacyIcon: _LegacyIconKind.folder,
                    offsetY: 0,
                    messageGap: 6,
                    title: '这里是 Ta 的作品集',
                    message: 'AI 还没有制作过任何文件，和它聊天时它会自动保存到这里。',
                  )
                : filtered.isEmpty
                ? const _EmptyState(
                    icon: Icons.search_off_rounded,
                    title: '没有匹配的文件',
                    message: '换一个关键词试试。',
                  )
                : GridView.builder(
                    padding: const EdgeInsets.only(bottom: 24),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          mainAxisExtent: 148.2,
                          crossAxisSpacing: 10,
                          mainAxisSpacing: 10,
                        ),
                    itemCount: filtered.length,
                    itemBuilder: (context, index) {
                      final item = filtered[index];
                      final deleted =
                          item.deletedAt != null || item.status == 'deleted';
                      final content = _contents[item.id] ?? '';
                      return _LegacyFileCard(
                        file: item,
                        content: content,
                        deleted: deleted,
                        onTap: () => _showFileDetail(context, item, content),
                        onRun: !deleted && _canPreview(item.name, item.type)
                            ? () => _previewFile(item, content)
                            : null,
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _previewFile(UserFileRecord item, String content) async {
    if (utf8.encode(content).length > AttachmentService.warningThresholdBytes) {
      final approved = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('预览超大文件？'),
          content: Text('“${item.name}”超过 50 MB，预览可能占用较多内存并导致应用短暂无响应。是否继续？'),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('继续预览'),
            ),
          ],
        ),
      );
      if (approved != true) return;
    }
    await controller.platform.previewHtml(
      content,
      runtimeScope: 'file-${item.id}',
      fallbackTitle: item.name,
    );
  }

  Future<void> _showFileDetail(
    BuildContext context,
    UserFileRecord file,
    String cachedContent,
  ) async {
    final content = cachedContent.isNotEmpty
        ? cachedContent
        : controller.visualAuditFileContents[file.id] ??
              await controller.content.readFile(file.id);
    if (!context.mounted) return;
    final deleted = file.deletedAt != null || file.status == 'deleted';
    final dark = Theme.of(context).brightness == Brightness.dark;
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: false,
      transitionDuration: Duration.zero,
      pageBuilder: (dialogContext, _, _) => Material(
        color: Theme.of(context).scaffoldBackgroundColor,
        child: SafeArea(
          child: Column(
            children: <Widget>[
              _LegacyDetailHeader(
                title: file.name,
                fontSize: 14,
                onBack: () => Navigator.pop(dialogContext),
                backTooltip: '返回列表',
                titleSuffix: _MemoryTag(
                  label: deleted ? '已删除' : '有效',
                  foreground: dark ? _darkMuted : _lightMuted,
                  background: dark ? _darkSurface : _lightSurfaceSoft,
                ),
                actions: <Widget>[
                  _LegacyFileAction(
                    icon: _LegacyIconKind.copy,
                    tooltip: '复制',
                    onPressed: () =>
                        Clipboard.setData(ClipboardData(text: content)),
                  ),
                  _LegacyFileAction(
                    icon: _LegacyIconKind.download,
                    tooltip: '导出',
                    onPressed: () => controller.shareTextContent(
                      name: file.name,
                      content: content,
                    ),
                  ),
                  _LegacyFileAction(
                    icon: _LegacyIconKind.clock,
                    tooltip: '历史版本',
                    onPressed: () => _fileHistory(dialogContext, file),
                  ),
                  if (!deleted)
                    _LegacyFileAction(
                      icon: _LegacyIconKind.trash,
                      tooltip: '删除',
                      danger: true,
                      onPressed: () async {
                        final approved = await showDialog<bool>(
                          context: dialogContext,
                          builder: (confirmContext) => AlertDialog(
                            content: const Text('删除这个文件？'),
                            actions: <Widget>[
                              TextButton(
                                onPressed: () =>
                                    Navigator.pop(confirmContext, false),
                                child: const Text('取消'),
                              ),
                              FilledButton(
                                onPressed: () =>
                                    Navigator.pop(confirmContext, true),
                                child: const Text('删除'),
                              ),
                            ],
                          ),
                        );
                        if (approved != true) return;
                        await controller.deleteFileFromUi(file.id);
                        if (dialogContext.mounted) {
                          Navigator.pop(dialogContext);
                          _snack(context, '文件已删除');
                        }
                      },
                    ),
                ],
              ),
              if (deleted)
                Expanded(
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Text(
                            '该文件已被 AI 删除：${file.deleteReason ?? '没有留下原因。'}',
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontSize: 12, height: 1.35),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '文件内容请在历史版本中查看',
                            style: TextStyle(
                              color: dark ? _darkMuted : _lightMuted,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                )
              else
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(14),
                    child: SizedBox(
                      width: double.infinity,
                      child: content.trim().isEmpty
                          ? const _LegacyEmptyContent(label: '小机子没有写入任何内容')
                          : SelectableText(
                              content,
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 12,
                                height: 1.35,
                              ),
                            ),
                    ),
                  ),
                ),
              Container(
                height: 44,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                  border: Border(
                    top: BorderSide(color: dark ? _darkLine : _lightLine),
                  ),
                ),
                child: Row(
                  children: <Widget>[
                    Text(
                      _fileSizeLabel(content),
                      style: TextStyle(
                        color: dark ? _darkMuted : _lightMuted,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      DateFormat(
                        'MM/dd HH:mm',
                      ).format(file.updatedAt.toLocal()),
                      style: TextStyle(
                        color: dark ? _darkMuted : _lightMuted,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _fileHistory(BuildContext context, UserFileRecord file) async {
    final versions = await controller.content.fileVersions(file.id);
    if (!context.mounted) return;
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: false,
      transitionDuration: Duration.zero,
      pageBuilder: (dialogContext, _, _) => _LegacyFileHistoryPage(
        controller: controller,
        file: file,
        versions: versions,
        readContent: controller.content.readFileVersion,
        onClose: () => Navigator.pop(dialogContext),
      ),
    );
  }

  void _ensureSearchIndex() {
    final signature = controller.files
        .map((item) => '${item.id}:${item.updatedAt.microsecondsSinceEpoch}')
        .join('|');
    if (signature == _indexSignature) return;
    _indexSignature = signature;
    Future<void>(() async {
      final next = <String, String>{};
      for (final item in controller.files) {
        try {
          next[item.id] =
              controller.visualAuditFileContents[item.id] ??
              await controller.content.readFile(item.id);
        } on FileSystemException {
          next[item.id] = '';
        }
      }
      if (!mounted || signature != _indexSignature) return;
      setState(() {
        _contents
          ..clear()
          ..addAll(next);
      });
    });
  }
}

class _LegacyFileHistoryPage extends StatefulWidget {
  const _LegacyFileHistoryPage({
    required this.controller,
    required this.file,
    required this.versions,
    required this.readContent,
    required this.onClose,
  });

  final AppController controller;
  final UserFileRecord file;
  final List<UserFileVersionRecord> versions;
  final Future<String> Function(UserFileVersionRecord version) readContent;
  final VoidCallback onClose;

  @override
  State<_LegacyFileHistoryPage> createState() => _LegacyFileHistoryPageState();
}

class _LegacyFileHistoryPageState extends State<_LegacyFileHistoryPage> {
  UserFileVersionRecord? selected;
  final Map<String, Future<String>> _contentLoads = <String, Future<String>>{};

  Future<String> _content(UserFileVersionRecord version) =>
      _contentLoads.putIfAbsent(version.id, () => widget.readContent(version));

  @override
  Widget build(BuildContext context) {
    final version = selected;
    return Material(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: SafeArea(
        child: Column(
          children: <Widget>[
            _LegacyDetailHeader(
              title: version == null
                  ? '${widget.file.name} · 历史版本'
                  : DateFormat(
                      'MM/dd HH:mm',
                    ).format(version.createdAt.toLocal()),
              fontSize: 14,
              onBack: version == null
                  ? widget.onClose
                  : () => setState(() => selected = null),
              backTooltip: version == null ? '返回详情' : '返回历史列表',
              actions: version == null
                  ? const <Widget>[]
                  : <Widget>[
                      _LegacyFileAction(
                        icon: _LegacyIconKind.copy,
                        tooltip: '复制',
                        onPressed: () async {
                          final body = await _content(version);
                          await Clipboard.setData(ClipboardData(text: body));
                        },
                      ),
                      _LegacyFileAction(
                        icon: _LegacyIconKind.download,
                        tooltip: '导出',
                        onPressed: () async {
                          final body = await _content(version);
                          await widget.controller.shareTextContent(
                            name: widget.file.name,
                            content: body,
                          );
                        },
                      ),
                    ],
            ),
            if (version == null)
              Expanded(child: _historyList())
            else
              Expanded(child: _versionDetail(version)),
          ],
        ),
      ),
    );
  }

  Widget _historyList() {
    if (widget.versions.isEmpty) {
      return Center(
        child: Text(
          '暂无历史版本',
          style: TextStyle(
            color: Theme.of(context).brightness == Brightness.dark
                ? _darkMuted
                : _lightMuted,
            fontSize: 12,
          ),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(14),
      itemCount: widget.versions.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final version = widget.versions[index];
        final operation = version.reason.contains('删除')
            ? '删除'
            : version.reason.contains('创建')
            ? '创建'
            : '修订';
        final time = DateFormat(
          'MM/dd HH:mm',
        ).format(version.createdAt.toLocal());
        return Semantics(
          button: true,
          label: '$operation\n$time',
          child: ExcludeSemantics(
            child: Material(
              color: Theme.of(context).brightness == Brightness.dark
                  ? _darkSurface
                  : _lightSurface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(
                  color: Theme.of(context).brightness == Brightness.dark
                      ? _darkLine
                      : _lightLine,
                  width: 2 / 3,
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () => setState(() => selected = version),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  child: Row(
                    children: <Widget>[
                      _LegacyDiaryState(label: operation),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          time,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: _legacyDiaryMetaStyle(
                            context,
                          ).copyWith(fontWeight: FontWeight.w400),
                        ),
                      ),
                      _LegacyIcon(
                        _LegacyIconKind.chevronRight,
                        size: 16,
                        color: Theme.of(context).brightness == Brightness.dark
                            ? _darkMuted
                            : _lightMuted,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _versionDetail(UserFileVersionRecord version) => FutureBuilder<String>(
    future: _content(version),
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return Center(
          child: Text(
            '无法读取该版本',
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        );
      }
      if (!snapshot.hasData) {
        return const Center(child: CircularProgressIndicator(strokeWidth: 2));
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (version.reason.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
              child: Text(
                version.reason,
                style: TextStyle(
                  color: Theme.of(context).brightness == Brightness.dark
                      ? _darkMuted
                      : _lightMuted,
                  fontSize: 11,
                  height: 1.25,
                ),
              ),
            ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(14),
              child: snapshot.data!.trim().isEmpty
                  ? const _LegacyEmptyContent(label: '小机子没有写入任何内容')
                  : SelectableText(
                      snapshot.data!,
                      style: TextStyle(
                        color: Theme.of(context).brightness == Brightness.dark
                            ? _darkText
                            : _lightText,
                        fontFamily: 'monospace',
                        fontSize: 12,
                        height: 1.4,
                      ),
                    ),
            ),
          ),
        ],
      );
    },
  );
}

class _LegacyFileCard extends StatelessWidget {
  const _LegacyFileCard({
    required this.file,
    required this.content,
    required this.deleted,
    required this.onTap,
    required this.onRun,
  });

  final UserFileRecord file;
  final String content;
  final bool deleted;
  final VoidCallback onTap;
  final VoidCallback? onRun;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final surface = dark ? _darkSurface : _lightSurface;
    final soft = dark ? _darkBackground : _lightSurfaceSoft;
    final text = dark ? _darkText : _lightText;
    final muted = dark ? _darkMuted : _lightMuted;
    final line = dark ? _darkLine : _lightLine;
    final compact = _cleanBoundaryText(content);
    final preview = deleted
        ? '已删除，原因为：${file.deleteReason ?? 'AI 请求删除'}'
        : compact.length <= 80
        ? compact
        : compact.substring(0, 80);
    return Opacity(
      opacity: deleted ? .78 : 1,
      child: Material(
        color: surface,
        shape: RoundedRectangleBorder(
          side: BorderSide(color: line),
          borderRadius: BorderRadius.circular(12),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  alignment: WrapAlignment.spaceBetween,
                  children: <Widget>[
                    _MemoryTag(
                      label: deleted
                          ? '已删除'
                          : (file.type.trim().isEmpty ? '文件' : file.type),
                      foreground: muted,
                      background: soft,
                    ),
                    Text(
                      DateFormat(
                        'MM/dd HH:mm',
                      ).format(file.updatedAt.toLocal()),
                      style: TextStyle(
                        color: muted,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  file.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: text,
                    fontSize: 15,
                    height: 1.2,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: Text(
                    preview,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: muted, fontSize: 12, height: 1.4),
                  ),
                ),
                Row(
                  children: <Widget>[
                    Text(
                      deleted ? '已删除' : _fileSizeLabel(content),
                      style: TextStyle(
                        color: muted,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Spacer(),
                    if (onRun != null)
                      SizedBox.square(
                        dimension: 28,
                        child: OutlinedButton(
                          onPressed: onRun,
                          style: OutlinedButton.styleFrom(
                            padding: EdgeInsets.zero,
                            shape: const CircleBorder(),
                            side: BorderSide(color: line),
                            backgroundColor: soft,
                          ),
                          child: _LegacyIcon(
                            _LegacyIconKind.send,
                            size: 12,
                            color: dark
                                ? const Color(0xFFF1A077)
                                : const Color(0xFFAD5938),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LegacyFileAction extends StatelessWidget {
  const _LegacyFileAction({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.danger = false,
  });

  final _LegacyIconKind icon;
  final String tooltip;
  final VoidCallback onPressed;
  final bool danger;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: 36,
    child: IconButton(
      onPressed: onPressed,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 36, height: 36),
      tooltip: tooltip,
      icon: _LegacyIcon(
        icon,
        size: 16,
        color: danger
            ? (Theme.of(context).brightness == Brightness.dark
                  ? const Color(0xFFFF8178)
                  : _lightDanger)
            : (Theme.of(context).brightness == Brightness.dark
                  ? _darkText
                  : _lightText),
      ),
    ),
  );
}

class _LegacyWorkspaceSegmented extends StatelessWidget {
  const _LegacyWorkspaceSegmented({
    required this.fileCount,
    required this.selected,
    required this.onSelected,
  });

  final int fileCount;
  final int selected;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      height: 44,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: dark ? _darkSurface : _lightSurfaceSoft,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: _LegacyWorkspaceSegmentButton(
              label: '文件 ($fileCount)',
              selected: selected == 0,
              onTap: () => onSelected(0),
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: _LegacyWorkspaceSegmentButton(
              label: '对话',
              selected: selected == 1,
              onTap: () => onSelected(1),
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: _LegacyWorkspaceSegmentButton(
              label: '计划',
              selected: selected == 2,
              onTap: () => onSelected(2),
            ),
          ),
        ],
      ),
    );
  }
}

class _LegacyWorkspaceSegmentButton extends StatelessWidget {
  const _LegacyWorkspaceSegmentButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Material(
      color: selected
          ? (dark ? _darkSurface : _lightSurface)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      shadowColor: selected ? const Color(0x14000000) : Colors.transparent,
      elevation: selected ? 1 : 0,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              color: selected
                  ? (dark ? _darkText : _lightText)
                  : (dark ? _darkMuted : _lightMuted),
              fontSize: 12,
              height: 1.2,
            ),
          ),
        ),
      ),
    );
  }
}

class _LegacyWorkspaceCard extends StatelessWidget {
  const _LegacyWorkspaceCard({
    required this.workspace,
    required this.fileCount,
    required this.onTap,
  });

  final WorkspaceRecord workspace;
  final int fileCount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final text = dark ? _darkText : _lightText;
    final muted = dark ? _darkMuted : _lightMuted;
    return Material(
      color: dark ? _darkSurface : _lightSurface,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: dark ? _darkLine : _lightLine),
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  _LegacyWorkspacePill(label: '$fileCount 个文件'),
                  const Spacer(),
                  Text(
                    DateFormat(
                      'MM/dd HH:mm',
                    ).format(workspace.updatedAt.toLocal()),
                    style: TextStyle(
                      color: muted,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      height: 1.2,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                workspace.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: text,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  height: 1.2,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '点击进入工作区',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: muted, fontSize: 12, height: 1.4),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LegacyWorkspacePill extends StatelessWidget {
  const _LegacyWorkspacePill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      constraints: const BoxConstraints(minHeight: 24),
      padding: const EdgeInsets.symmetric(horizontal: 9),
      decoration: BoxDecoration(
        color: dark ? _darkSurface : _lightSurfaceSoft,
        borderRadius: BorderRadius.circular(999),
      ),
      alignment: Alignment.center,
      child: Text(
        label,
        maxLines: 1,
        style: TextStyle(
          color: dark ? _darkMuted : _lightMuted,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          height: 1.2,
        ),
      ),
    );
  }
}

class _ArchivedWorkspaceRow extends StatelessWidget {
  const _ArchivedWorkspaceRow({
    required this.workspace,
    required this.onRestore,
  });

  final WorkspaceRecord workspace;
  final VoidCallback onRestore;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      constraints: const BoxConstraints(minHeight: 54),
      margin: const EdgeInsets.only(bottom: 7),
      padding: const EdgeInsets.fromLTRB(14, 7, 8, 7),
      decoration: BoxDecoration(
        color: dark ? _darkSurface : _lightSurface,
        border: Border.all(color: dark ? _darkLine : _lightLine),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Text(
                  workspace.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: dark ? _darkText : _lightText,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  DateFormat(
                    'yyyy/MM/dd HH:mm',
                  ).format(workspace.updatedAt.toLocal()),
                  style: TextStyle(
                    color: dark ? _darkMuted : _lightMuted,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          TextButton(onPressed: onRestore, child: const Text('恢复')),
        ],
      ),
    );
  }
}

class _WorkspacesPage extends StatefulWidget {
  const _WorkspacesPage({required this.controller, super.key});
  final AppController controller;

  @override
  State<_WorkspacesPage> createState() => _WorkspacesPageState();
}

class _WorkspacesPageState extends State<_WorkspacesPage> {
  final workspaceComposer = TextEditingController();
  final workspaceSearch = TextEditingController();
  final workspaceFocus = FocusNode(debugLabel: 'workspace-composer');
  final Set<String> collapsedWorkspaceFolders = <String>{};
  final Set<String> expandedWorkspaceSettings = <String>{};
  String? activeWorkspaceId;
  bool showWorkspaceSettings = false;
  int tab = 1;
  int workspaceChatEpoch = 0;

  AppController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    controller.workspaceActivity.addListener(_onWorkspaceActivity);
  }

  void _onWorkspaceActivity() {
    if (mounted) setState(() {});
  }

  void openSettings() {
    if (controller.activeWorkspace == null) return;
    setState(() {
      showWorkspaceSettings = true;
    });
  }

  Future<void> openConversationMenu() async {
    if (controller.activeWorkspace == null) return;
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ListTile(
                leading: const Icon(Icons.add_comment_outlined),
                title: const Text('新建对话'),
                onTap: () => Navigator.pop(sheetContext, 'new'),
              ),
              ListTile(
                leading: const Icon(Icons.forum_outlined),
                title: const Text('对话列表'),
                onTap: () => Navigator.pop(sheetContext, 'list'),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'new') {
      await controller.createWorkspaceConversation();
      if (!mounted) return;
      setState(() {
        tab = 1;
        workspaceChatEpoch++;
      });
      return;
    }
    await _openWorkspaceConversationList();
  }

  Future<void> _openWorkspaceConversationList() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (pageContext) => Scaffold(
          body: SafeArea(
            child: Column(
              children: <Widget>[
                SizedBox(
                  height: 54,
                  child: Row(
                    children: <Widget>[
                      IconButton(
                        onPressed: () => Navigator.pop(pageContext),
                        icon: const Icon(
                          Icons.arrow_back_ios_new_rounded,
                          size: 18,
                        ),
                      ),
                      const Expanded(
                        child: Text(
                          '对话列表',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      const SizedBox(width: 48),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 24),
                    itemCount: controller.workspaceConversations.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 7),
                    itemBuilder: (context, index) {
                      final item = controller.workspaceConversations[index];
                      final selected =
                          controller.activeWorkspaceConversation?.id == item.id;
                      return ListTile(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: BorderSide(
                            color: selected
                                ? _accent.withValues(alpha: .55)
                                : Theme.of(context).dividerColor,
                          ),
                        ),
                        leading: Icon(
                          selected
                              ? Icons.chat_bubble_rounded
                              : Icons.chat_bubble_outline_rounded,
                          color: selected ? _accent : null,
                        ),
                        title: Text(
                          item.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          DateFormat(
                            'MM/dd HH:mm',
                          ).format(item.updatedAt.toLocal()),
                        ),
                        onTap: () async {
                          await controller.openWorkspaceConversation(item);
                          if (pageContext.mounted) {
                            Navigator.pop(pageContext);
                          }
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (!mounted) return;
    setState(() {
      tab = 1;
      workspaceChatEpoch++;
    });
  }

  bool handleBack() {
    if (showWorkspaceSettings) {
      setState(() => showWorkspaceSettings = false);
      return true;
    }
    return false;
  }

  Future<void> _enterWorkspace(WorkspaceRecord workspace) async {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      tab = 1;
      showWorkspaceSettings = false;
      expandedWorkspaceSettings.clear();
      activeWorkspaceId = null;
      workspaceChatEpoch++;
    });
    await controller.openWorkspace(workspace);
  }

  @override
  void dispose() {
    controller.workspaceActivity.removeListener(_onWorkspaceActivity);
    workspaceComposer.dispose();
    workspaceSearch.dispose();
    workspaceFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final active = controller.activeWorkspace;
    if (active == null) {
      activeWorkspaceId = null;
      final query = workspaceSearch.text.trim().toLowerCase();
      final visible = controller.workspaces
          .where(
            (item) => query.isEmpty || item.name.toLowerCase().contains(query),
          )
          .toList();
      final archived = controller.archivedWorkspaces
          .where(
            (item) => query.isEmpty || item.name.toLowerCase().contains(query),
          )
          .toList();
      return _StandardPage(
        title: 'Ta的工作室',
        subtitle: '',
        rightPadding: visible.isEmpty && archived.isEmpty ? 30 : 14,
        legacyScrollbar: visible.isEmpty && archived.isEmpty,
        child: Column(
          children: <Widget>[
            TextField(
              controller: workspaceSearch,
              onChanged: (_) => setState(() {}),
              style: const TextStyle(fontSize: 14, height: 1.2),
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search_rounded, size: 18),
                prefixIconConstraints: BoxConstraints(
                  minWidth: 44,
                  minHeight: 42,
                ),
                hintText: '搜索工作区名称',
                contentPadding: EdgeInsets.symmetric(vertical: 12),
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: visible.isEmpty && archived.isEmpty
                  ? const _EmptyState(
                      icon: Icons.widgets_outlined,
                      legacyIcon: _LegacyIconKind.workspace,
                      offsetY: 25.5,
                      messageGap: 7,
                      title: '还没有工作区',
                      message: '创建一个工作区，AI 可以在里面编写多个文件。工作区是独立的，不会影响其他对话。',
                    )
                  : ListView(
                      padding: const EdgeInsets.only(bottom: 24),
                      children: <Widget>[
                        if (visible.isNotEmpty)
                          GridView.builder(
                            padding: EdgeInsets.zero,
                            primary: false,
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            gridDelegate:
                                const SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: 2,
                                  mainAxisExtent: 101,
                                  crossAxisSpacing: 10,
                                  mainAxisSpacing: 10,
                                ),
                            itemCount: visible.length,
                            itemBuilder: (context, index) {
                              final item = visible[index];
                              return _LegacyWorkspaceCard(
                                workspace: item,
                                fileCount:
                                    controller.workspaceFileCounts[item.id] ??
                                    0,
                                onTap: () => _enterWorkspace(item),
                              );
                            },
                          ),
                        if (archived.isNotEmpty) ...<Widget>[
                          const SizedBox(height: 18),
                          Text(
                            'Archive',
                            style: TextStyle(
                              color:
                                  Theme.of(context).brightness ==
                                      Brightness.dark
                                  ? _darkMuted
                                  : _lightMuted,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 8),
                          ...archived.map(
                            (item) => _ArchivedWorkspaceRow(
                              workspace: item,
                              onRestore: () =>
                                  controller.restoreArchivedWorkspace(item),
                            ),
                          ),
                        ],
                      ],
                    ),
            ),
          ],
        ),
      );
    }
    if (activeWorkspaceId != active.id) {
      activeWorkspaceId = active.id;
      tab = 1;
      showWorkspaceSettings = false;
      expandedWorkspaceSettings.clear();
    }
    if (showWorkspaceSettings) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 0),
        child: _workspaceSettings(context),
      );
    }
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18),
          child: _LegacyWorkspaceSegmented(
            fileCount: controller.workspaceFiles.length,
            selected: tab,
            onSelected: (value) {
              FocusManager.instance.primaryFocus?.unfocus();
              setState(() => tab = value);
            },
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 0),
            child: switch (tab) {
              0 => _workspaceFiles(context),
              1 => _workspaceChat(context),
              _ => _workspacePlan(context),
            },
          ),
        ),
      ],
    );
  }

  Widget _workspaceFiles(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final muted = dark ? _darkMuted : _lightMuted;
    final workspace = controller.activeWorkspace!;
    final persistedNames = controller.workspaceFiles
        .map((item) => item.name)
        .toSet();
    final liveOnlyFiles = controller
        .workspaceLiveFileEditsFor(workspace.id)
        .where((item) => !persistedNames.contains(item.name))
        .map(
          (item) => WorkspaceFileRecord(
            id: 'live:${item.name}',
            workspaceId: workspace.id,
            name: item.name,
            type: item.name.contains('.')
                ? item.name.split('.').last.toLowerCase()
                : 'text',
            relativePath: '',
            updatedAt: item.updatedAt,
          ),
        )
        .toList(growable: false);
    final files = <WorkspaceFileRecord>[
      ...controller.workspaceFiles,
      ...liveOnlyFiles,
    ];
    final entries = _workspaceTreeEntries(files);
    final type = _workspaceProjectLabel(
      controller.effectiveWorkspaceProjectType,
    );
    return Column(
      children: <Widget>[
        Row(
          children: <Widget>[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: dark ? _darkSurface : _lightSurfaceSoft,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: dark ? _darkLine : _lightLine),
              ),
              child: Text(
                type,
                style: TextStyle(
                  color: muted,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const Spacer(),
            FilledButton.icon(
              onPressed: controller.workspaceBusy
                  ? null
                  : () => _runWorkspace(context),
              icon: const Icon(Icons.play_arrow_rounded, size: 18),
              label: const Text('运行'),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Expanded(
          child: files.isEmpty
              ? const _EmptyState(
                  icon: Icons.folder_open_outlined,
                  legacyIcon: _LegacyIconKind.folder,
                  title: '还没有文件',
                  message: '在对话 tab 中和 AI 协作，AI 可以把文件存到这里。',
                )
              : ListView.separated(
                  padding: const EdgeInsets.only(bottom: 18),
                  itemCount: entries.length,
                  separatorBuilder: (context, index) => Divider(
                    height: 1,
                    indent: 42,
                    color: dark ? _darkLine : _lightLine,
                  ),
                  itemBuilder: (context, index) {
                    final entry = entries[index];
                    final file = entry.file;
                    return Material(
                      color: Colors.transparent,
                      child: ListTile(
                        dense: true,
                        minTileHeight: 48,
                        contentPadding: EdgeInsets.only(
                          left: 6 + entry.depth * 18.0,
                          right: 6,
                        ),
                        leading: Icon(
                          entry.isFolder
                              ? (collapsedWorkspaceFolders.contains(entry.path)
                                    ? Icons.folder_outlined
                                    : Icons.folder_open_outlined)
                              : _workspaceFileIcon(file!.name),
                          size: 20,
                          color: entry.isFolder ? _accent : muted,
                        ),
                        title: Text(
                          entry.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        subtitle: file == null
                            ? null
                            : Text(
                                file.id.startsWith('live:')
                                    ? '正在写入 · 只读预览'
                                    : '${file.type} · ${utf8.encode(controller.workspaceFileContents[file.id] ?? '').length} B',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: muted, fontSize: 10.5),
                              ),
                        trailing: entry.isFolder
                            ? Icon(
                                collapsedWorkspaceFolders.contains(entry.path)
                                    ? Icons.chevron_right_rounded
                                    : Icons.expand_more_rounded,
                                size: 19,
                                color: muted,
                              )
                            : const Icon(Icons.chevron_right_rounded, size: 18),
                        onTap: entry.isFolder
                            ? () => setState(() {
                                if (!collapsedWorkspaceFolders.add(
                                  entry.path,
                                )) {
                                  collapsedWorkspaceFolders.remove(entry.path);
                                }
                              })
                            : () => _openWorkspaceSourcePage(context, file!),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _workspaceChat(BuildContext context) {
    final messages = <WorkspaceMessageRecord>[...controller.workspaceMessages];
    final dark = Theme.of(context).brightness == Brightness.dark;
    final textColor = dark ? _darkText : _lightText;
    final mutedColor = dark ? _darkMuted : _lightMuted;
    final surfaceColor = dark ? _darkSurface : _lightSurface;
    final sendBackground = dark ? _lightBackground : _lightText;
    final sendForeground = dark ? _lightText : _lightSurface;
    return Column(
      children: <Widget>[
        if (controller.workspaceTaskVisible &&
            controller.workspaceTaskDisplayStyle == 'top') ...<Widget>[
          _WorkspaceTaskIndicator(
            label: controller.visibleWorkspaceTaskSummary,
            dark: dark,
            busy: controller.workspaceBusy,
            onTap: () => _showWorkspaceTaskDetails(context),
          ),
          const SizedBox(height: 6),
        ],
        Expanded(
          child: _ScrollEdgeFade(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
              child: messages.isEmpty && !controller.workspaceConversationBusy
                  ? const _EmptyState(
                      icon: Icons.forum_outlined,
                      legacyIcon: _LegacyIconKind.chat,
                      title: '',
                      message: '在下方输入，和 AI 一起编辑工作区文件。',
                    )
                  : _WorkspaceMessageList(
                      key: ValueKey<String>(
                        'workspace-chat-${controller.activeWorkspace!.id}-$workspaceChatEpoch',
                      ),
                      activitySerial: Object.hash(
                        messages.length,
                        controller.workspaceBusy,
                        controller.workspaceStreamingText.length,
                        controller.workspaceStreamingReasoning.length,
                        controller.workspaceStreamingParts.length,
                        controller.workspaceStreamingToolProgress?.metadata,
                      ),
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemCount:
                          messages.length +
                          (controller.workspaceConversationBusy ? 1 : 0),
                      itemBuilder: (context, index) {
                        final streaming = index == messages.length;
                        final role = streaming
                            ? 'assistant'
                            : messages[index].role;
                        final message = streaming ? null : messages[index];
                        final text = streaming
                            ? controller.workspaceStreamingText
                            : message!.content;
                        final user = role == 'user';
                        return Align(
                          alignment: user
                              ? Alignment.centerRight
                              : Alignment.centerLeft,
                          child: Container(
                            constraints: const BoxConstraints(
                              maxWidth: 360,
                              minWidth: 0,
                            ),
                            margin: const EdgeInsets.only(bottom: 4),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 12,
                            ),
                            decoration: BoxDecoration(
                              color: user
                                  ? (dark
                                        ? _darkUserBubble
                                        : const Color(0xFFF0EFEC))
                                  : Colors.transparent,
                              borderRadius: user
                                  ? const BorderRadius.only(
                                      topLeft: Radius.circular(22),
                                      topRight: Radius.circular(22),
                                      bottomLeft: Radius.circular(22),
                                      bottomRight: Radius.circular(8),
                                    )
                                  : BorderRadius.circular(22),
                            ),
                            child: user
                                ? SelectableText(
                                    text,
                                    style: TextStyle(
                                      fontFamily: _bodyFontFamily(
                                        controller.settings,
                                      ),
                                      fontFamilyFallback: _bodyFontFallback(
                                        controller.settings,
                                      ),
                                      fontSize:
                                          13 * controller.workspaceFontScale,
                                      height: 1.5,
                                    ).copyWith(color: textColor),
                                  )
                                : Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: _workspacePartWidgets(
                                      message,
                                      streaming: streaming,
                                      textColor: textColor,
                                    ),
                                  ),
                          ),
                        );
                      },
                    ),
            ),
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 10, 18, 14),
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: surfaceColor,
                border: Border.all(
                  color: dark ? _darkLineStrong : _lightLineStrong,
                ),
                borderRadius: BorderRadius.circular(24),
                boxShadow: const <BoxShadow>[
                  BoxShadow(
                    color: Color(0x12000000),
                    blurRadius: 24,
                    offset: Offset(0, 8),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  TextField(
                    controller: workspaceComposer,
                    focusNode: workspaceFocus,
                    minLines: 1,
                    maxLines: 5,
                    onTapOutside: (_) =>
                        FocusManager.instance.primaryFocus?.unfocus(),
                    style: TextStyle(
                      fontSize: 16 * controller.workspaceFontScale,
                      height: 1.18,
                    ).copyWith(color: textColor),
                    decoration: InputDecoration(
                      hintText: '让 AI 帮你写文件...',
                      hintStyle: TextStyle(color: mutedColor),
                      filled: false,
                      border: const OutlineInputBorder(
                        borderSide: BorderSide.none,
                      ),
                      enabledBorder: const OutlineInputBorder(
                        borderSide: BorderSide.none,
                      ),
                      focusedBorder: const OutlineInputBorder(
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: <Widget>[
                      _LegacyWorkspacePill(
                        label: controller.workspaceMode.toUpperCase(),
                      ),
                      const Spacer(),
                      SizedBox.square(
                        dimension: 36,
                        child: FilledButton(
                          onPressed: controller.workspaceBusy
                              ? controller.stopWorkspaceGeneration
                              : () {
                                  final value = workspaceComposer.text;
                                  workspaceComposer.clear();
                                  FocusManager.instance.primaryFocus?.unfocus();
                                  controller.sendWorkspaceMessage(value);
                                },
                          style: FilledButton.styleFrom(
                            padding: EdgeInsets.zero,
                            shape: const CircleBorder(),
                            backgroundColor: controller.workspaceBusy
                                ? const Color(0xFFBD3E3E)
                                : sendBackground,
                            foregroundColor: sendForeground,
                          ),
                          child: _LegacyIcon(
                            controller.workspaceBusy
                                ? _LegacyIconKind.stop
                                : _LegacyIconKind.send,
                            size: 18,
                            color: sendForeground,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  List<Widget> _workspacePartWidgets(
    WorkspaceMessageRecord? message, {
    required bool streaming,
    required Color textColor,
  }) {
    final now = DateTime.now();
    final committedReasoning = controller.workspaceStreamingParts
        .where(
          (part) => const <String>{
            'thought',
            'thinking',
            'reasoning',
          }.contains(part.type),
        )
        .map((part) => part.content ?? '')
        .join();
    final committedText = controller.workspaceStreamingParts
        .where((part) => part.type == 'content')
        .map((part) => part.content ?? '')
        .join();
    final pendingReasoning = uncommittedStreamText(
      controller.workspaceStreamingReasoning,
      committedReasoning,
    );
    final pendingText = uncommittedStreamText(
      controller.workspaceStreamingText,
      committedText,
    );
    final parts = streaming
        ? <MessagePart>[
            for (final entry in controller.workspaceStreamingParts.indexed)
              MessagePart(
                id: 'workspace-stream-${entry.$1}',
                messageId: 'workspace-stream',
                sequence: entry.$1,
                type: entry.$2.type,
                content: entry.$2.content,
                metadataJson: canonicalJson(entry.$2.metadata),
                createdAt: now,
              ),
            if (controller.workspaceStreamingToolProgress case final progress?)
              MessagePart(
                id: 'workspace-stream-progress',
                messageId: 'workspace-stream',
                sequence: controller.workspaceStreamingParts.length + 1,
                type: progress.type,
                content: progress.content,
                metadataJson: canonicalJson(progress.metadata),
                createdAt: now,
              ),
            if (pendingReasoning.isNotEmpty)
              MessagePart(
                id: 'workspace-stream-thought',
                messageId: 'workspace-stream',
                sequence: controller.workspaceStreamingParts.length + 2,
                type: 'thought',
                content: pendingReasoning,
                createdAt: now,
              ),
            if (pendingText.isNotEmpty)
              MessagePart(
                id: 'workspace-stream-content',
                messageId: 'workspace-stream',
                sequence: controller.workspaceStreamingParts.length + 3,
                type: 'content',
                content: pendingText,
                createdAt: now,
              ),
          ]
        : <MessagePart>[
            ...(controller.workspaceMessagePartsByMessage[message!.id] ??
                const <MessagePart>[]),
          ];
    final durableParts = parts.where((part) {
      if (part.type == 'status') {
        final status = '${part.metadata['status'] ?? ''}';
        return !streaming &&
            status != 'sent' &&
            status != 'replying' &&
            !status.startsWith('tool_');
      }
      if (part.type != 'tool') return true;
      final status = '${part.metadata['status'] ?? ''}';
      return status != 'preparing' && status != 'running';
    }).toList();
    final hasContent = durableParts.any(
      (part) => part.type == 'content' && (part.content ?? '').isNotEmpty,
    );
    final effective = <MessagePart>[
      if (streaming)
        MessagePart(
          id: 'workspace-stream-replying-status',
          messageId: 'workspace-stream',
          sequence: -1,
          type: 'status',
          metadataJson: canonicalJson(<String, Object?>{'status': 'replying'}),
          createdAt: now,
        ),
      ...durableParts,
      if (!streaming && !hasContent && message!.content.isNotEmpty)
        MessagePart(
          id: '${message.id}-fallback',
          messageId: message.id,
          sequence: parts.length + 1,
          type: 'content',
          content: message.content,
          createdAt: message.createdAt,
        ),
      if (streaming)
        MessagePart(
          id: 'workspace-stream-status',
          messageId: 'workspace-stream',
          sequence: durableParts.length + 10,
          type: 'status',
          metadataJson: canonicalJson(<String, Object?>{
            'status': 'response_progress',
            'label': controller.workspaceStreamingToolProgress == null
                ? '小机子正在组织回复'
                : _toolProcessLabel(controller.workspaceStreamingToolProgress!),
          }),
          createdAt: now,
        ),
    ];
    return effective.map((part) {
      return switch (part.type) {
        'status' => _StatusCapsule(part: part),
        'tool' => _ToolCapsule(part: part),
        'thought' when (part.content ?? '').isNotEmpty => _ThoughtBlock(
          key: ValueKey(part.id),
          controller: controller,
          content: part.content!,
        ),
        'content' when (part.content ?? '').isNotEmpty => Padding(
          padding: const EdgeInsets.only(bottom: 5),
          child: _LegacyMarkdownContent(
            data: part.content!,
            streaming: streaming,
            controller: controller,
            styleSheet: _workspaceMarkdownStyle(context, textColor),
            extensionSet: _workspaceMarkdownExtensionSet,
          ),
        ),
        _ => const SizedBox.shrink(),
      };
    }).toList();
  }

  MarkdownStyleSheet _workspaceMarkdownStyle(
    BuildContext context,
    Color textColor,
  ) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final line = dark ? _darkLine : _lightLine;
    final muted = dark ? _darkMuted : _lightMuted;
    final soft = dark ? _darkSurface : _lightSurfaceSoft;
    final body = TextStyle(
      color: textColor,
      fontFamily: _bodyFontFamily(controller.settings),
      fontFamilyFallback: _bodyFontFallback(controller.settings),
      fontSize: 13 * controller.workspaceFontScale,
      height: 1.5,
    );
    return MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
      p: body,
      blockSpacing: 8.3542,
      listIndent: 16.25,
      listBullet: body,
      listBulletPadding: const EdgeInsets.only(right: 4),
      strong: const TextStyle(fontWeight: FontWeight.w800),
      em: const TextStyle(fontStyle: FontStyle.italic),
      h1: body.copyWith(fontSize: 19, fontWeight: FontWeight.w800),
      h2: body.copyWith(fontSize: 17, fontWeight: FontWeight.w800),
      h3: body.copyWith(fontSize: 15, fontWeight: FontWeight.w800),
      h4: body.copyWith(fontSize: 14, fontWeight: FontWeight.w800),
      h1Padding: const EdgeInsets.only(top: 12.64, bottom: 5.18),
      h2Padding: const EdgeInsets.only(top: 11.93, bottom: 4.90),
      h3Padding: const EdgeInsets.only(top: 11.23, bottom: 4.61),
      h4Padding: const EdgeInsets.only(top: 11.23, bottom: 4.61),
      blockquote: body.copyWith(color: muted),
      blockquotePadding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      blockquoteDecoration: BoxDecoration(
        color: soft,
        border: Border(left: BorderSide(color: line, width: 3)),
        borderRadius: BorderRadius.circular(3),
      ),
      tableHead: body.copyWith(fontWeight: FontWeight.w800),
      tableBody: body,
      tableBorder: TableBorder.all(color: line, width: 1),
      tableCellsPadding: const EdgeInsets.fromLTRB(10, 7, 10, 7),
      tableHeadCellsPadding: const EdgeInsets.fromLTRB(10, 7, 10, 7),
      tableHeadCellsDecoration: BoxDecoration(color: soft),
      code: body.copyWith(
        fontFamily: 'monospace',
        fontSize: 11.5,
        backgroundColor: soft,
      ),
      codeblockPadding: EdgeInsets.zero,
      codeblockDecoration: const BoxDecoration(color: Colors.transparent),
      horizontalRuleDecoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: line.withValues(alpha: .72), width: .666667),
        ),
      ),
    );
  }

  Future<void> _openWorkspaceSourcePage(
    BuildContext context,
    WorkspaceFileRecord file,
  ) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (pageContext) => Scaffold(
          body: SafeArea(
            child: AnimatedBuilder(
              animation: controller.workspaceActivity,
              builder: (context, _) => _workspaceSource(pageContext, file),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openWorkspaceFileVersionsPage(
    BuildContext context,
    WorkspaceFileRecord file,
  ) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) =>
            _WorkspaceFileVersionsPage(controller: controller, file: file),
      ),
    );
  }

  Widget _workspaceSource(BuildContext context, WorkspaceFileRecord file) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final text = dark ? _darkText : _lightText;
    final muted = dark ? _darkMuted : _lightMuted;
    final line = dark ? _darkLine : _lightLine;
    final live = controller
        .workspaceLiveFileEditsFor(file.workspaceId)
        .where((item) => item.name == file.name)
        .firstOrNull;
    final persisted = !file.id.startsWith('live:');
    final content =
        live?.content ?? controller.workspaceFileContents[file.id] ?? '';
    final runnable = const <String>{
      'html',
      'htm',
      'svg',
    }.contains(file.name.split('.').last.toLowerCase());
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 0),
      child: Column(
        children: <Widget>[
          SizedBox(
            height: 48,
            child: Row(
              children: <Widget>[
                IconButton(
                  tooltip: '返回文件列表',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 18),
                ),
                Expanded(
                  child: Text(
                    file.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: text,
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '复制源码',
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: content));
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(const SnackBar(content: Text('源码已复制')));
                  },
                  icon: const Icon(Icons.copy_rounded, size: 18),
                ),
                if (persisted)
                  IconButton(
                    tooltip: '文件版本',
                    onPressed: () =>
                        _openWorkspaceFileVersionsPage(context, file),
                    icon: const Icon(Icons.history_rounded, size: 19),
                  ),
                if (persisted)
                  IconButton(
                    tooltip: '导出文件',
                    onPressed: () => controller.shareWorkspaceFile(file),
                    icon: const Icon(Icons.ios_share_rounded, size: 19),
                  ),
                if (runnable)
                  IconButton(
                    tooltip: '运行',
                    onPressed: () => controller.platform.previewHtml(
                      content,
                      runtimeScope: 'workspace-${file.workspaceId}',
                      fallbackTitle: file.name,
                      refreshProvider: () => controller.workspacePreviewPayload(
                        file.workspaceId,
                        fallbackTitle: file.name,
                        fileId: file.id,
                      ),
                    ),
                    icon: const Icon(Icons.play_arrow_rounded, size: 21),
                  ),
              ],
            ),
          ),
          Divider(height: 1, color: line),
          if (live != null &&
              (live.status == 'preparing' || live.status == 'running'))
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
              child: Row(
                children: <Widget>[
                  const SizedBox.square(
                    dimension: 13,
                    child: CircularProgressIndicator(strokeWidth: 1.5),
                  ),
                  const SizedBox(width: 7),
                  Text(
                    live.status == 'preparing' ? '准备编辑文件' : '文件正在编辑',
                    style: TextStyle(color: muted, fontSize: 11),
                  ),
                ],
              ),
            ),
          Expanded(
            child: content.isEmpty
                ? Center(
                    child: Text(
                      '这个文件还没有写入任何内容',
                      style: TextStyle(color: muted, fontSize: 12),
                    ),
                  )
                : SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(10, 14, 10, 28),
                    child: SizedBox(
                      width: double.infinity,
                      child: SelectableText.rich(
                        _highlightWorkspaceSource(
                          content,
                          file.name,
                          dark: dark,
                        ),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _workspacePlan(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final muted = dark ? _darkMuted : _lightMuted;
    final steps = controller.workspacePlanItems;
    final completed = steps.where((item) => item.state == 'completed').length;
    final running = steps.where((item) => item.state == 'running').firstOrNull;
    final planSummary = steps.isEmpty
        ? '等待模型按当前需求拆解计划'
        : running != null
        ? '正在进行：${running.title}'
        : '已完成 $completed / ${steps.length} 项';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Text(
                    '计划',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    planSummary,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: muted,
                      fontSize: 11.5,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
            if (controller.workspaceBusy)
              const SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 1.8),
              ),
          ],
        ),
        const SizedBox(height: 12),
        Expanded(
          child: steps.isEmpty
              ? const _EmptyState(
                  icon: Icons.route_outlined,
                  legacyIcon: _LegacyIconKind.check,
                  title: '还没有计划',
                  message: '在“对话”中发起任务后，模型会把目标拆成计划步骤，并实时更新进行与完成状态。',
                )
              : ListView.separated(
                  padding: const EdgeInsets.only(bottom: 24),
                  itemCount: steps.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 6),
                  itemBuilder: (context, index) => _WorkspacePlanItemTile(
                    item: steps[index],
                    index: index,
                    dark: dark,
                  ),
                ),
        ),
      ],
    );
  }

  Widget _workspaceCheckpoints(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final text = dark ? _darkText : _lightText;
    final muted = dark ? _darkMuted : _lightMuted;
    return Column(
      children: <Widget>[
        Row(
          children: <Widget>[
            IconButton(
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 18),
              tooltip: '返回工作区设置',
            ),
            const Expanded(
              child: Text(
                '检查点',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
              ),
            ),
            TextButton.icon(
              onPressed: controller.workspaceBusy
                  ? null
                  : () => controller.createWorkspaceCheckpoint(),
              icon: const Icon(Icons.add_rounded, size: 17),
              label: const Text('保存'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child: controller.workspaceCommits.isEmpty
              ? const _EmptyState(
                  icon: Icons.history_rounded,
                  legacyIcon: _LegacyIconKind.clock,
                  title: '还没有检查点',
                  message: '手动保存或 Agent 完成任务后，版本会出现在这里。',
                )
              : ListView.separated(
                  padding: const EdgeInsets.only(bottom: 28),
                  itemCount: controller.workspaceCommits.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 7),
                  itemBuilder: (context, index) {
                    final commit = controller.workspaceCommits[index];
                    return Container(
                      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
                      decoration: BoxDecoration(
                        color: dark ? _darkSurface : _lightSurface,
                        border: Border.all(
                          color: dark ? _darkLine : _lightLine,
                        ),
                        borderRadius: BorderRadius.circular(11),
                      ),
                      child: Row(
                        children: <Widget>[
                          Container(
                            width: 38,
                            height: 38,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: _accent.withValues(alpha: .12),
                              borderRadius: BorderRadius.circular(9),
                            ),
                            child: Text(
                              '#${commit.sequence}',
                              style: const TextStyle(
                                color: _accent,
                                fontSize: 10.5,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Text(
                                  commit.message,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: text,
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  '${commit.fileCount} 个文件 · ${DateFormat('MM/dd HH:mm').format(commit.createdAt.toLocal())}',
                                  style: TextStyle(
                                    color: muted,
                                    fontSize: 10.5,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            onPressed: controller.workspaceBusy
                                ? null
                                : () => _confirmRestoreCheckpoint(
                                    context,
                                    commit,
                                  ),
                            tooltip: '恢复这个检查点',
                            icon: const Icon(Icons.restore_rounded, size: 19),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _workspaceSettings(BuildContext context) {
    final workspace = controller.activeWorkspace!;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final text = dark ? _darkText : _lightText;
    final muted = dark ? _darkMuted : _lightMuted;
    final selectedModel = controller.workspaceModelSlot;
    final effectiveProjectLabel = _workspaceProjectLabel(
      controller.effectiveWorkspaceProjectType,
    );
    final projectLabel = workspace.projectType == 'auto'
        ? '自动识别 · $effectiveProjectLabel'
        : effectiveProjectLabel;
    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 32),
      child: Column(
        children: <Widget>[
          _workspaceSettingsCard(
            context,
            title: '工作区',
            children: <Widget>[
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(workspace.name),
                subtitle: Text(
                  workspace.description.isEmpty
                      ? '未填写说明'
                      : workspace.description,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: const Icon(Icons.edit_outlined, size: 19),
                onTap: () => _editWorkspaceInfo(context),
              ),
              const Divider(height: 1),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('项目类型'),
                subtitle: Text(projectLabel),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => _chooseProjectType(context),
              ),
              Text(
                _workspaceCapability(controller.effectiveWorkspaceProjectType),
                style: TextStyle(color: muted, fontSize: 11.5, height: 1.45),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _workspaceSettingsCard(
            context,
            title: 'Agent',
            children: <Widget>[
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('模型'),
                subtitle: Text(
                  '${selectedModel?['label'] ?? controller.workspaceModel}',
                ),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: controller.modelSlots.isEmpty
                    ? null
                    : () => _chooseWorkspaceModel(context),
              ),
              const SizedBox(height: 5),
              Wrap(
                spacing: 7,
                runSpacing: 7,
                children: <Widget>[
                  for (final mode in const <(String, String)>[
                    ('chat', 'Chat'),
                    ('plan', 'Plan'),
                    ('agent', 'Agent'),
                  ])
                    ChoiceChip(
                      label: Text(mode.$2),
                      selected: controller.workspaceMode == mode.$1,
                      onSelected: (_) =>
                          controller.saveWorkspaceConfiguration(mode: mode.$1),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Text(switch (controller.workspaceMode) {
                'chat' => 'Chat 只讨论，不读取或修改文件。',
                'plan' => 'Plan 可以读取文件，但不能修改。',
                _ => 'Agent 可以读取、创建和编辑文件，并自动保存检查点。',
              }, style: TextStyle(color: muted, fontSize: 11.5, height: 1.4)),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('显示思维链'),
                value: workspace.settings['showThinking'] != false,
                onChanged: (value) =>
                    controller.saveWorkspaceConfiguration(showThinking: value),
              ),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('允许多个工作区同时运行'),
                subtitle: const Text('关闭后，已有工作区运行时不能启动另一个任务'),
                value: controller.allowMultipleWorkspaceRuns,
                onChanged: (value) => controller.saveWorkspaceConfiguration(
                  allowMultipleWorkspaceRuns: value,
                ),
              ),
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text('最大工具轮次', style: TextStyle(color: text)),
                  ),
                  Text(
                    '${controller.workspaceMaxRounds}',
                    style: TextStyle(color: muted),
                  ),
                ],
              ),
              Slider(
                value: controller.workspaceMaxRounds.toDouble(),
                min: 1,
                max: 20,
                divisions: 19,
                label: '${controller.workspaceMaxRounds}',
                onChanged: (value) => controller.saveWorkspaceConfiguration(
                  maxRounds: value.round(),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _workspaceSettingsCard(
            context,
            title: '界面',
            children: <Widget>[
              Row(
                children: <Widget>[
                  const Expanded(child: Text('工作区字号')),
                  Text(
                    '${(controller.workspaceFontScale * 100).round()}%',
                    style: TextStyle(color: muted),
                  ),
                ],
              ),
              Slider(
                value: controller.workspaceFontScale,
                min: .85,
                max: 1.25,
                divisions: 8,
                onChanged: (value) =>
                    controller.saveWorkspaceConfiguration(fontScale: value),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Material(
            color: dark ? _darkSurface : _lightSurface,
            shape: RoundedRectangleBorder(
              side: BorderSide(color: dark ? _darkLine : _lightLine),
              borderRadius: BorderRadius.circular(12),
            ),
            clipBehavior: Clip.antiAlias,
            child: ListTile(
              minTileHeight: 60,
              title: const Text(
                '检查点',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
              ),
              subtitle: Text(
                controller.workspaceCommits.isEmpty
                    ? '还没有检查点'
                    : '${controller.workspaceCommits.length} 个版本',
                style: TextStyle(color: muted, fontSize: 11.5),
              ),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => _openWorkspaceCheckpointsPage(context),
            ),
          ),
          const SizedBox(height: 10),
          _workspaceSettingsCard(
            context,
            title: '任务状态',
            children: <Widget>[
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('持久显示'),
                subtitle: const Text('无论是否有任务，都持续显示状态入口'),
                value: controller.workspaceTaskPersistent,
                onChanged: (value) => controller.saveWorkspaceConfiguration(
                  taskPersistent: value,
                ),
              ),
              const SizedBox(height: 3),
              Text('显示方式', style: TextStyle(color: muted, fontSize: 12)),
              const SizedBox(height: 7),
              Wrap(
                spacing: 7,
                children: <Widget>[
                  ChoiceChip(
                    label: const Text('顶部'),
                    selected: controller.workspaceTaskDisplayStyle == 'top',
                    onSelected: (_) => controller.saveWorkspaceConfiguration(
                      taskDisplayStyle: 'top',
                    ),
                  ),
                  ChoiceChip(
                    label: const Text('任务球'),
                    selected: controller.workspaceTaskDisplayStyle == 'ball',
                    onSelected: (_) => controller.saveWorkspaceConfiguration(
                      taskDisplayStyle: 'ball',
                    ),
                  ),
                ],
              ),
              if (controller.workspaceTaskSteps.isNotEmpty)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () => _showWorkspaceTaskDetails(context),
                    icon: const Icon(Icons.route_outlined, size: 17),
                    label: const Text('查看最近任务过程'),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          _workspaceSettingsCard(
            context,
            title: '管理',
            children: <Widget>[
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () async {
                    final workspace = controller.activeWorkspace;
                    if (workspace == null) return;
                    await controller.platform.clearPreviewCache(
                      runtimeScope: 'workspace-${workspace.id}',
                    );
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(const SnackBar(content: Text('运行预览缓存已清除')));
                  },
                  icon: const Icon(Icons.cleaning_services_outlined, size: 18),
                  label: const Text('清除运行缓存'),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () => _confirmArchiveWorkspace(context),
                  icon: const Icon(Icons.archive_outlined, size: 18),
                  label: const Text('归档工作区'),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () => _confirmDeleteWorkspace(context, controller),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _lightDanger,
                  ),
                  icon: const Icon(Icons.delete_outline_rounded, size: 18),
                  label: const Text('删除工作区'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _openWorkspaceCheckpointsPage(BuildContext context) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (pageContext) => Scaffold(
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 0),
              child: _workspaceCheckpoints(pageContext),
            ),
          ),
        ),
      ),
    );
  }

  Widget _workspaceSettingsCard(
    BuildContext context, {
    required String title,
    required List<Widget> children,
    Widget? trailing,
  }) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final expanded = expandedWorkspaceSettings.contains(title);
    return Material(
      color: dark ? _darkSurface : _lightSurface,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: dark ? _darkLine : _lightLine),
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: EdgeInsets.fromLTRB(14, 0, 14, expanded ? 14 : 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            InkWell(
              onTap: () => setState(() {
                if (!expandedWorkspaceSettings.add(title)) {
                  expandedWorkspaceSettings.remove(title);
                }
              }),
              child: SizedBox(
                height: 54,
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        title,
                        style: TextStyle(
                          color: dark ? _darkText : _lightText,
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    if (trailing != null && expanded) trailing,
                    Icon(
                      expanded
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      size: 20,
                      color: dark ? _darkMuted : _lightMuted,
                    ),
                  ],
                ),
              ),
            ),
            if (expanded) ...<Widget>[const SizedBox(height: 1), ...children],
          ],
        ),
      ),
    );
  }

  String _workspaceProjectLabel(String type) => switch (type) {
    'react' => 'React',
    'vue' => 'Vue',
    'svelte' => 'Svelte',
    'angular' => 'Angular',
    'node' => 'Node / npm',
    'flutter' => 'Flutter / Dart',
    'python' => 'Python',
    'java' => 'Java',
    'general' => '通用项目',
    _ => 'HTML / JavaScript',
  };

  Future<void> _showWorkspaceTaskDetails(BuildContext context) async {
    await _showWorkspaceTaskDetailsSheet(context, controller);
  }

  List<_WorkspaceTreeEntry> _workspaceTreeEntries(
    List<WorkspaceFileRecord> files,
  ) {
    final folders = <String>{};
    for (final file in files) {
      final parts = file.name.replaceAll('\\', '/').split('/');
      for (var index = 1; index < parts.length; index++) {
        folders.add(parts.take(index).join('/'));
      }
    }
    final entries =
        <_WorkspaceTreeEntry>[
          ...folders.map(
            (path) => _WorkspaceTreeEntry(
              path: path,
              label: path.split('/').last,
              depth: path.split('/').length - 1,
            ),
          ),
          ...files.map((file) {
            final path = file.name.replaceAll('\\', '/');
            return _WorkspaceTreeEntry(
              path: path,
              label: path.split('/').last,
              depth: path.split('/').length - 1,
              file: file,
            );
          }),
        ]..sort((left, right) {
          if (left.path == right.path) {
            return left.isFolder == right.isFolder
                ? 0
                : (left.isFolder ? -1 : 1);
          }
          return left.path.compareTo(right.path);
        });
    return entries
        .where((entry) {
          final parts = entry.path.split('/');
          for (var index = 1; index < parts.length; index++) {
            if (collapsedWorkspaceFolders.contains(
              parts.take(index).join('/'),
            )) {
              return false;
            }
          }
          return true;
        })
        .toList(growable: false);
  }

  IconData _workspaceFileIcon(String name) =>
      switch (name.split('.').last.toLowerCase()) {
        'html' || 'htm' => Icons.language_rounded,
        'css' => Icons.palette_outlined,
        'js' || 'mjs' || 'ts' || 'tsx' || 'jsx' => Icons.code_rounded,
        'py' => Icons.terminal_rounded,
        'md' => Icons.article_outlined,
        _ => Icons.insert_drive_file_outlined,
      };

  Future<void> _runWorkspace(BuildContext context) async {
    final workspace = controller.activeWorkspace!;
    final files = <String, String>{
      for (final file in controller.workspaceFiles)
        file.name: controller.workspaceFileContents[file.id] ?? '',
    };
    final inspection = WorkspaceProjectService.inspect(files);
    final document = WorkspaceProjectService.build(
      files,
      fallbackTitle: workspace.name,
    );
    if (document == null) {
      final message = inspection.diagnostics.isEmpty
          ? '当前项目没有可运行入口。'
          : inspection.diagnostics.join('\n');
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('暂时无法运行'),
          content: Text(message),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
      return;
    }
    await controller.platform.previewHtml(
      document.html,
      runtimeScope: 'workspace-${workspace.id}',
      fallbackTitle: document.title,
      refreshProvider: () => controller.workspacePreviewPayload(
        workspace.id,
        fallbackTitle: workspace.name,
      ),
    );
  }

  String _workspaceCapability(String type) => switch (type) {
    'react' =>
      'React / JSX / TSX 可在 Android 与 iOS 直接编译运行；首次运行需联网加载固定版本编译组件。React 核心依赖已支持，其他 npm 包需提交 dist/build 产物。',
    'vue' || 'svelte' || 'angular' || 'node' =>
      '可保存、编辑和版本化该项目；完整 npm/Vite/Node 构建链不能原样运行在 iOS，存在 dist/build/out 静态产物时可跨平台运行。',
    'flutter' =>
      '可保存、编辑和版本化 Flutter/Dart 项目；原生应用仍需桌面 Flutter SDK 与 macOS/Xcode 签名构建，手机端不伪装成本机构建。',
    'python' =>
      'Python 可在 Android 与 iOS 直接运行，支持工作区本地模块及兼容的 requirements.txt 依赖；首次运行需联网加载固定版本运行组件。',
    'java' =>
      '可保存、编辑和版本化 Java/Gradle 项目；手机端没有完整 JDK/Gradle/iOS 签名链，当前不伪装成本机构建。',
    'general' => '当前文件不足以识别项目类型；继续添加文件后会自动重新识别。',
    _ => 'HTML / CSS / JavaScript 可直接运行，并按工作区保留运行状态。',
  };

  Future<void> _editWorkspaceInfo(BuildContext context) async {
    final workspace = controller.activeWorkspace!;
    final name = TextEditingController(text: workspace.name);
    final description = TextEditingController(text: workspace.description);
    final save = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('工作区信息'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            TextField(
              controller: name,
              decoration: const InputDecoration(labelText: '名称'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: description,
              maxLines: 3,
              decoration: const InputDecoration(labelText: '说明'),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (save == true) {
      await controller.saveWorkspaceConfiguration(
        name: name.text,
        description: description.text,
      );
    }
    name.dispose();
    description.dispose();
  }

  Future<void> _chooseProjectType(BuildContext context) async {
    final value = await showModalBottomSheet<String>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (final item in const <(String, String)>[
              ('auto', '自动识别（推荐）'),
              ('web', 'HTML / JavaScript'),
              ('react', 'React'),
              ('vue', 'Vue'),
              ('svelte', 'Svelte'),
              ('angular', 'Angular'),
              ('node', 'Node / npm'),
              ('flutter', 'Flutter / Dart'),
              ('python', 'Python'),
              ('java', 'Java'),
            ])
              ListTile(
                title: Text(item.$2),
                trailing: controller.activeWorkspace!.projectType == item.$1
                    ? const Icon(Icons.check_rounded)
                    : null,
                onTap: () => Navigator.pop(sheetContext, item.$1),
              ),
          ],
        ),
      ),
    );
    if (value != null) {
      await controller.saveWorkspaceConfiguration(projectType: value);
    }
  }

  Future<void> _chooseWorkspaceModel(BuildContext context) async {
    final value = await showModalBottomSheet<String>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: controller.modelSlots
              .map(
                (slot) => ListTile(
                  title: Text('${slot['label'] ?? slot['apiName']}'),
                  subtitle: Text('${slot['apiName'] ?? ''}'),
                  trailing: controller.workspaceModelSlot?['id'] == slot['id']
                      ? const Icon(Icons.check_rounded)
                      : null,
                  onTap: () => Navigator.pop(sheetContext, '${slot['id']}'),
                ),
              )
              .toList(),
        ),
      ),
    );
    if (value != null) {
      await controller.saveWorkspaceConfiguration(modelSlotId: value);
    }
  }

  Future<void> _confirmArchiveWorkspace(BuildContext context) async {
    final workspace = controller.activeWorkspace!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        content: const Text('归档后，工作区会移到工作室页面底部的 Archive 列表，可随时恢复。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('归档'),
          ),
        ],
      ),
    );
    if (confirmed == true) await controller.archiveWorkspace(workspace);
  }

  Future<void> _confirmRestoreCheckpoint(
    BuildContext context,
    WorkspaceCommitRecord commit,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        content: Text(
          '恢复到 #${commit.sequence}“${commit.message}”？恢复前会自动保存当前状态。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('恢复'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await controller.restoreWorkspaceCheckpoint(commit);
    }
  }
}

class _WorkspacePlanItemTile extends StatelessWidget {
  const _WorkspacePlanItemTile({
    required this.item,
    required this.index,
    required this.dark,
  });

  final WorkspacePlanItem item;
  final int index;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    final running = item.state == 'running';
    final completed = item.state == 'completed';
    final failed = item.state == 'failed';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
      decoration: BoxDecoration(
        color: dark ? _darkSurface : _lightSurface,
        border: Border.all(color: dark ? _darkLine : _lightLine),
        borderRadius: BorderRadius.circular(11),
      ),
      child: Row(
        children: <Widget>[
          SizedBox.square(
            dimension: 22,
            child: running
                ? const Padding(
                    padding: EdgeInsets.all(3),
                    child: CircularProgressIndicator(strokeWidth: 1.8),
                  )
                : completed
                ? const Icon(
                    Icons.check_circle_outline_rounded,
                    color: _accent,
                    size: 21,
                  )
                : failed
                ? const Icon(
                    Icons.error_outline_rounded,
                    color: _lightDanger,
                    size: 21,
                  )
                : Center(
                    child: Text(
                      '${index + 1}',
                      style: TextStyle(
                        color: dark ? _darkMuted : _lightMuted,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              item.title,
              style: TextStyle(
                color: dark ? _darkText : _lightText,
                fontSize: 13,
                height: 1.35,
                fontWeight: running || completed
                    ? FontWeight.w700
                    : FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

TextSpan _highlightWorkspaceSource(
  String source,
  String fileName, {
  required bool dark,
}) {
  final base = TextStyle(
    color: dark ? const Color(0xFFD3D0CA) : const Color(0xFF2A2826),
    fontFamily: 'monospace',
    fontSize: 11.5,
    height: 1.5,
  );
  final keyword = dark ? const Color(0xFFFFA875) : const Color(0xFF9C4B28);
  final string = dark ? const Color(0xFFA8C990) : const Color(0xFF496D35);
  final comment = dark ? const Color(0xFF858079) : const Color(0xFF8C847C);
  final number = dark ? const Color(0xFF9BC6E8) : const Color(0xFF35698F);
  final spans = <TextSpan>[];
  final pattern = RegExp(
    r'''(<!--[\s\S]*?-->|/\*[\s\S]*?\*/|//[^\n]*|#[^\n]*$)|("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*')|\b(class|const|let|var|final|void|return|if|else|for|while|async|await|function|def|import|from|export|extends|new|true|false|null|None)\b|\b\d+(?:\.\d+)?\b''',
    multiLine: true,
  );
  var offset = 0;
  for (final match in pattern.allMatches(source)) {
    if (match.start > offset) {
      spans.add(TextSpan(text: source.substring(offset, match.start)));
    }
    final value = match.group(0)!;
    final color = match.group(1) != null
        ? comment
        : match.group(2) != null
        ? string
        : match.group(3) != null
        ? keyword
        : number;
    spans.add(
      TextSpan(
        text: value,
        style: TextStyle(color: color),
      ),
    );
    offset = match.end;
  }
  if (offset < source.length)
    spans.add(TextSpan(text: source.substring(offset)));
  return TextSpan(style: base, children: spans);
}

Future<void> _showWorkspaceTaskDetailsSheet(
  BuildContext context,
  AppController controller, {
  String? workspaceId,
}) async {
  final resolvedWorkspaceId = workspaceId ?? controller.activeWorkspace?.id;
  if (resolvedWorkspaceId == null) return;
  final dark = Theme.of(context).brightness == Brightness.dark;
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    backgroundColor: dark ? _darkSurface : _lightSurface,
    builder: (sheetContext) => AnimatedBuilder(
      animation: Listenable.merge(<Listenable>[
        controller,
        controller.workspaceActivity,
      ]),
      builder: (context, _) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheetContext).height * .72,
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 2, 18, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            '任务过程',
                            style: TextStyle(
                              color: dark ? _darkText : _lightText,
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            controller.workspaceTaskSummaryFor(
                              resolvedWorkspaceId,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: dark ? _darkMuted : _lightMuted,
                              fontSize: 11.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (controller.workspaceBusyFor(resolvedWorkspaceId))
                      const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 1.8),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                Flexible(
                  child:
                      controller
                          .workspaceTaskStepsFor(resolvedWorkspaceId)
                          .isEmpty
                      ? const Padding(
                          padding: EdgeInsets.symmetric(vertical: 24),
                          child: Text('尚无任务；状态入口会按当前设置保持显示。'),
                        )
                      : ListView.separated(
                          shrinkWrap: true,
                          itemCount: controller
                              .workspaceTaskStepsFor(resolvedWorkspaceId)
                              .length,
                          separatorBuilder: (_, _) => const SizedBox(height: 5),
                          itemBuilder: (context, index) {
                            final step = controller.workspaceTaskStepsFor(
                              resolvedWorkspaceId,
                            )[index];
                            final failed = step.state == 'failed';
                            final running = step.state == 'running';
                            return ListTile(
                              dense: true,
                              minTileHeight: 48,
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 8,
                              ),
                              leading: SizedBox.square(
                                dimension: 22,
                                child: running
                                    ? const Padding(
                                        padding: EdgeInsets.all(3),
                                        child: CircularProgressIndicator(
                                          strokeWidth: 1.7,
                                        ),
                                      )
                                    : Icon(
                                        failed
                                            ? Icons.error_outline_rounded
                                            : Icons
                                                  .check_circle_outline_rounded,
                                        size: 20,
                                        color: failed ? _lightDanger : _accent,
                                      ),
                              ),
                              title: Text(
                                step.label,
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              subtitle: step.detail.isEmpty
                                  ? null
                                  : Text(
                                      step.detail,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontSize: 11),
                                    ),
                              trailing: Text(
                                DateFormat('HH:mm:ss').format(step.updatedAt),
                                style: TextStyle(
                                  color: dark ? _darkMuted : _lightMuted,
                                  fontSize: 10,
                                ),
                              ),
                            );
                          },
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

class _WorkspaceTaskBallLayer extends StatefulWidget {
  const _WorkspaceTaskBallLayer({
    required this.controller,
    required this.child,
  });

  final AppController controller;
  final Widget child;

  @override
  State<_WorkspaceTaskBallLayer> createState() =>
      _WorkspaceTaskBallLayerState();
}

class _WorkspaceTaskBallLayerState extends State<_WorkspaceTaskBallLayer> {
  Offset? offset;

  @override
  void initState() {
    super.initState();
    widget.controller.workspaceActivity.addListener(_onActivity);
  }

  void _onActivity() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant _WorkspaceTaskBallLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;
    oldWidget.controller.workspaceActivity.removeListener(_onActivity);
    widget.controller.workspaceActivity.addListener(_onActivity);
  }

  @override
  void dispose() {
    widget.controller.workspaceActivity.removeListener(_onActivity);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final queue = widget.controller.workspaceTaskQueue;
      if (queue.isEmpty) return widget.child;
      final fallback = Offset(math.max(8.0, constraints.maxWidth - 56), 76);
      final ball = offset ?? fallback;
      final left = ball.dx
          .clamp(8.0, math.max(8.0, constraints.maxWidth - 50))
          .toDouble();
      final top = ball.dy
          .clamp(8.0, math.max(8.0, constraints.maxHeight - 50))
          .toDouble();
      return Stack(
        children: <Widget>[
          Positioned.fill(child: widget.child),
          Positioned(
            left: left,
            top: top,
            child: _WorkspaceTaskBall(
              busy: queue.any((item) => item.busy),
              hasTask: queue.any((item) => item.hasTask),
              onTap: () =>
                  _showWorkspaceTaskQueue(context, widget.controller, queue),
              onPanUpdate: (delta) => setState(() {
                offset = Offset(
                  (left + delta.dx)
                      .clamp(8.0, math.max(8.0, constraints.maxWidth - 50))
                      .toDouble(),
                  (top + delta.dy)
                      .clamp(8.0, math.max(8.0, constraints.maxHeight - 50))
                      .toDouble(),
                );
              }),
            ),
          ),
        ],
      );
    },
  );
}

Future<void> _showWorkspaceTaskQueue(
  BuildContext context,
  AppController controller,
  List<WorkspaceTaskQueueEntry> queue,
) async {
  Future<void> open(WorkspaceTaskQueueEntry entry) async {
    await controller.openWorkspace(entry.workspace);
    if (!context.mounted) return;
    await _showWorkspaceTaskDetailsSheet(
      context,
      controller,
      workspaceId: entry.workspace.id,
    );
  }

  if (queue.length == 1) {
    await open(queue.single);
    return;
  }
  final selected = await showModalBottomSheet<WorkspaceTaskQueueEntry>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Padding(
              padding: EdgeInsets.fromLTRB(8, 2, 8, 8),
              child: Text(
                '工作区任务队列',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
              ),
            ),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: queue.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final entry = queue[index];
                  return ListTile(
                    leading: SizedBox.square(
                      dimension: 22,
                      child: entry.busy
                          ? const CircularProgressIndicator(strokeWidth: 1.8)
                          : const Icon(
                              Icons.check_circle_outline_rounded,
                              size: 21,
                              color: _accent,
                            ),
                    ),
                    title: Text(
                      entry.workspace.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      entry.summary,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => Navigator.pop(sheetContext, entry),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    ),
  );
  if (selected != null && context.mounted) await open(selected);
}

class _WorkspaceMessageList extends StatefulWidget {
  const _WorkspaceMessageList({
    super.key,
    required this.activitySerial,
    required this.itemCount,
    required this.itemBuilder,
    required this.keyboardDismissBehavior,
    required this.padding,
  });

  final int activitySerial;
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final ScrollViewKeyboardDismissBehavior keyboardDismissBehavior;
  final EdgeInsetsGeometry padding;

  @override
  State<_WorkspaceMessageList> createState() => _WorkspaceMessageListState();
}

class _WorkspaceMessageListState extends State<_WorkspaceMessageList> {
  final ScrollController scrollController = ScrollController();
  bool userDragging = false;
  bool bottomScheduled = false;

  @override
  void initState() {
    super.initState();
    _scheduleBottom(force: true);
  }

  @override
  void didUpdateWidget(covariant _WorkspaceMessageList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.activitySerial == widget.activitySerial &&
        oldWidget.itemCount == widget.itemCount) {
      return;
    }
    _scheduleBottom(force: _isNearBottom());
  }

  bool _isNearBottom() {
    if (!scrollController.hasClients) return true;
    return scrollController.position.pixels <= 140;
  }

  void _scheduleBottom({required bool force}) {
    if (!force || userDragging || bottomScheduled) return;
    bottomScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      bottomScheduled = false;
      if (!mounted || !scrollController.hasClients || userDragging) return;
      scrollController.jumpTo(scrollController.position.minScrollExtent);
    });
  }

  @override
  void dispose() {
    scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is ScrollStartNotification &&
            notification.dragDetails != null) {
          userDragging = true;
        } else if (notification is ScrollEndNotification) {
          userDragging = false;
        }
        return false;
      },
      child: ListView.builder(
        key: const Key('workspace-message-list'),
        controller: scrollController,
        reverse: true,
        keyboardDismissBehavior: widget.keyboardDismissBehavior,
        padding: widget.padding,
        itemCount: widget.itemCount,
        itemBuilder: (context, index) =>
            widget.itemBuilder(context, widget.itemCount - 1 - index),
      ),
    ),
  );
}

class _WorkspaceFileVersionsPage extends StatefulWidget {
  const _WorkspaceFileVersionsPage({
    required this.controller,
    required this.file,
  });

  final AppController controller;
  final WorkspaceFileRecord file;

  @override
  State<_WorkspaceFileVersionsPage> createState() =>
      _WorkspaceFileVersionsPageState();
}

class _WorkspaceFileVersionsPageState
    extends State<_WorkspaceFileVersionsPage> {
  late Future<List<WorkspaceFileVersionRecord>> _versions;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    _versions = widget.controller.workspaceFileVersions(widget.file);
  }

  Future<void> _open(WorkspaceFileVersionRecord version) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => _WorkspaceFileVersionDetailPage(
          controller: widget.controller,
          version: version,
        ),
      ),
    );
    if (!mounted) return;
    setState(_reload);
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final text = dark ? _darkText : _lightText;
    final muted = dark ? _darkMuted : _lightMuted;
    final line = dark ? _darkLine : _lightLine;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: <Widget>[
            SizedBox(
              height: 52,
              child: Row(
                children: <Widget>[
                  IconButton(
                    tooltip: '返回',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(
                      Icons.arrow_back_ios_new_rounded,
                      size: 18,
                    ),
                  ),
                  Expanded(
                    child: Text(
                      '${widget.file.name} · 版本',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: text,
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  const SizedBox(width: 48),
                ],
              ),
            ),
            Divider(height: 1, color: line),
            Expanded(
              child: FutureBuilder<List<WorkspaceFileVersionRecord>>(
                future: _versions,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snapshot.hasError) {
                    return Center(child: Text('版本读取失败：${snapshot.error}'));
                  }
                  final values =
                      snapshot.data ?? const <WorkspaceFileVersionRecord>[];
                  if (values.isEmpty) {
                    return Center(
                      child: Text('还没有文件版本', style: TextStyle(color: muted)),
                    );
                  }
                  return ListView.separated(
                    padding: const EdgeInsets.fromLTRB(14, 14, 14, 30),
                    itemCount: values.length,
                    separatorBuilder: (_, _) => Divider(height: 1, color: line),
                    itemBuilder: (context, index) {
                      final version = values[index];
                      return ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 4,
                        ),
                        title: Text(
                          '版本 #${version.sequence}',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        subtitle: Text(
                          '${version.message}\n${_byteSizeLabel(version.byteSize)} · ${DateFormat('MM/dd HH:mm').format(version.createdAt.toLocal())}',
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: muted, height: 1.35),
                        ),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: () => _open(version),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WorkspaceFileVersionDetailPage extends StatefulWidget {
  const _WorkspaceFileVersionDetailPage({
    required this.controller,
    required this.version,
  });

  final AppController controller;
  final WorkspaceFileVersionRecord version;

  @override
  State<_WorkspaceFileVersionDetailPage> createState() =>
      _WorkspaceFileVersionDetailPageState();
}

class _WorkspaceFileVersionDetailPageState
    extends State<_WorkspaceFileVersionDetailPage> {
  late final Future<VerifiedWorkspaceFileVersion> _snapshot = widget.controller
      .readWorkspaceFileVersion(widget.version);

  Future<void> _restore() async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('恢复这个文件版本？'),
        content: const Text('当前文件会先保存为不可删除版本，然后再恢复所选内容。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('恢复'),
          ),
        ],
      ),
    );
    if (accepted != true || !mounted) return;
    await widget.controller.restoreWorkspaceFileVersion(widget.version);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final line = dark ? _darkLine : _lightLine;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: <Widget>[
            SizedBox(
              height: 52,
              child: Row(
                children: <Widget>[
                  IconButton(
                    tooltip: '返回',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(
                      Icons.arrow_back_ios_new_rounded,
                      size: 18,
                    ),
                  ),
                  Expanded(
                    child: Text(
                      '${widget.version.name} · #${widget.version.sequence}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                  IconButton(
                    tooltip: '恢复此版本',
                    onPressed: _restore,
                    icon: const Icon(Icons.restore_rounded),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: line),
            Expanded(
              child: FutureBuilder<VerifiedWorkspaceFileVersion>(
                future: _snapshot,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snapshot.hasError) {
                    return Center(child: Text('版本内容读取失败：${snapshot.error}'));
                  }
                  final content = snapshot.data!.content;
                  return SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(18, 16, 18, 32),
                    child: SizedBox(
                      width: double.infinity,
                      child: SelectableText(
                        content.isEmpty ? '这个版本没有写入任何内容' : content,
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WorkspaceTreeEntry {
  const _WorkspaceTreeEntry({
    required this.path,
    required this.label,
    required this.depth,
    this.file,
  });

  final String path;
  final String label;
  final int depth;
  final WorkspaceFileRecord? file;

  bool get isFolder => file == null;
}

class _WorkspaceTaskIndicator extends StatefulWidget {
  const _WorkspaceTaskIndicator({
    required this.label,
    required this.dark,
    required this.busy,
    required this.onTap,
  });

  final String label;
  final bool dark;
  final bool busy;
  final VoidCallback onTap;

  @override
  State<_WorkspaceTaskIndicator> createState() =>
      _WorkspaceTaskIndicatorState();
}

class _WorkspaceTaskIndicatorState extends State<_WorkspaceTaskIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );

  @override
  void initState() {
    super.initState();
    if (widget.busy) pulse.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant _WorkspaceTaskIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.busy == widget.busy) return;
    if (widget.busy) {
      pulse.repeat(reverse: true);
    } else {
      pulse
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final muted = widget.dark ? _darkMuted : _lightMuted;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: widget.dark ? _darkSurface : _lightSurfaceSoft,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: widget.dark ? _darkLine : _lightLine),
          ),
          child: Row(
            children: <Widget>[
              AnimatedBuilder(
                animation: pulse,
                builder: (context, child) => Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: widget.busy ? _accent : const Color(0xFF5B8E62),
                    boxShadow: widget.busy
                        ? <BoxShadow>[
                            BoxShadow(
                              color: _accent.withValues(
                                alpha: .12 + pulse.value * .2,
                              ),
                              blurRadius: 5 + pulse.value * 7,
                              spreadRadius: pulse.value * 2,
                            ),
                          ]
                        : const <BoxShadow>[],
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: muted,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (widget.busy)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 1.6),
                )
              else
                Icon(Icons.chevron_right_rounded, size: 18, color: muted),
            ],
          ),
        ),
      ),
    );
  }
}

class _WorkspaceTaskBall extends StatefulWidget {
  const _WorkspaceTaskBall({
    required this.busy,
    required this.hasTask,
    required this.onTap,
    required this.onPanUpdate,
  });

  final bool busy;
  final bool hasTask;
  final VoidCallback onTap;
  final ValueChanged<Offset> onPanUpdate;

  @override
  State<_WorkspaceTaskBall> createState() => _WorkspaceTaskBallState();
}

class _WorkspaceTaskBallState extends State<_WorkspaceTaskBall>
    with SingleTickerProviderStateMixin {
  late final AnimationController pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void initState() {
    super.initState();
    if (widget.busy) pulse.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant _WorkspaceTaskBall oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.busy == widget.busy) return;
    if (widget.busy) {
      pulse.repeat(reverse: true);
    } else {
      pulse
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: widget.onTap,
    onPanUpdate: (details) => widget.onPanUpdate(details.delta),
    child: AnimatedBuilder(
      animation: pulse,
      builder: (context, child) => Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Theme.of(context).colorScheme.surface,
          border: Border.all(color: _accent.withValues(alpha: .68)),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: _accent.withValues(
                alpha: widget.busy ? .12 + pulse.value * .15 : .1,
              ),
              blurRadius: widget.busy ? 10 + pulse.value * 7 : 9,
              spreadRadius: widget.busy ? pulse.value * 2 : 0,
            ),
          ],
        ),
        alignment: Alignment.center,
        child: widget.busy
            ? const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(
                widget.hasTask ? Icons.check_rounded : Icons.more_horiz_rounded,
                size: 20,
                color: widget.hasTask
                    ? const Color(0xFF5B8E62)
                    : Theme.of(context).colorScheme.onSurfaceVariant,
              ),
      ),
    ),
  );
}

class _VoicesPage extends StatefulWidget {
  const _VoicesPage({required this.controller});

  final AppController controller;

  @override
  State<_VoicesPage> createState() => _VoicesPageState();
}

class _VoicesPageState extends State<_VoicesPage> {
  final TextEditingController search = TextEditingController();
  bool favoritesOnly = false;

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final allItems = controller.voiceAssets;
    if (allItems.isEmpty) {
      return _EmptyState(
        icon: Icons.graphic_eq_rounded,
        title: '还没有保存的声音',
        message: '在任意回复下点击播放或选择声音，生成的语音会按编号保存在这里。',
      );
    }
    final query = search.text.trim().toLowerCase();
    final items = allItems
        .where((asset) {
          if (favoritesOnly && !asset.favorite) return false;
          if (query.isEmpty) return true;
          return asset.numberLabel.toLowerCase().contains(query) ||
              asset.libraryNumber.toString().contains(query) ||
              asset.sourceText.toLowerCase().contains(query);
        })
        .toList(growable: false);
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 32),
      children: <Widget>[
        Row(
          children: <Widget>[
            IconButton(
              onPressed: () => setState(() => favoritesOnly = !favoritesOnly),
              tooltip: favoritesOnly ? '显示全部声音' : '只看收藏',
              icon: Icon(
                favoritesOnly ? Icons.favorite : Icons.favorite_border,
                color: favoritesOnly ? _accent : _lightMuted,
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: TextField(
                controller: search,
                onChanged: (_) => setState(() {}),
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: '搜索编号或内容…',
                  prefixIcon: const Icon(Icons.search_rounded, size: 20),
                  suffixIcon: query.isEmpty
                      ? null
                      : IconButton(
                          onPressed: () {
                            search.clear();
                            setState(() {});
                          },
                          icon: const Icon(Icons.close_rounded, size: 18),
                          tooltip: '清空搜索',
                        ),
                  isDense: true,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (items.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 72),
            child: Center(
              child: Text(
                '没有找到对应的声音',
                style: TextStyle(color: _lightMuted, fontSize: 13),
              ),
            ),
          )
        else
          ...items.indexed.expand((entry) sync* {
            if (entry.$1 > 0) yield const SizedBox(height: 10);
            final asset = entry.$2;
            yield _VoiceLibraryRow(controller: controller, asset: asset);
          }),
      ],
    );
  }
}

class _VoiceLibraryRow extends StatelessWidget {
  const _VoiceLibraryRow({required this.controller, required this.asset});

  final AppController controller;
  final VoiceAsset asset;

  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).brightness == Brightness.dark
        ? _darkSurface
        : _lightSurface,
    shape: RoundedRectangleBorder(
      side: BorderSide(color: Theme.of(context).dividerColor),
      borderRadius: BorderRadius.circular(18),
    ),
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: () => _openVoiceDetail(context, controller, asset),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 8, 12),
        child: Row(
          children: <Widget>[
            Container(
              width: 54,
              height: 54,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: _accent.withValues(alpha: .11),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Text(
                asset.libraryNumber.toString().padLeft(4, '0'),
                style: const TextStyle(
                  color: _accent,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    asset.sourceText.trim().isEmpty
                        ? '未保存文本内容'
                        : asset.sourceText.trim(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    '${asset.model.isEmpty ? asset.provider : asset.model} · ${asset.roleName}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontSize: 12,
                      height: 1.15,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              onPressed: () => controller.voice
                  .setFavorite(asset, !asset.favorite)
                  .then((_) => controller.refreshVoices()),
              tooltip: asset.favorite ? '取消收藏' : '收藏',
              icon: Icon(
                asset.favorite ? Icons.favorite : Icons.favorite_border,
                color: asset.favorite ? _accent : _lightMuted,
                size: 21,
              ),
            ),
            Container(
              width: 44,
              height: 44,
              decoration: const BoxDecoration(
                color: _accent,
                shape: BoxShape.circle,
              ),
              child: IconButton(
                onPressed: () => controller.playVoice(asset),
                padding: EdgeInsets.zero,
                tooltip: controller.playingVoiceId == asset.id ? '停止' : '播放',
                icon: Icon(
                  controller.playingVoiceId == asset.id
                      ? Icons.stop_rounded
                      : Icons.play_arrow_rounded,
                  color: Colors.white,
                  size: 23,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

Future<void> _openVoiceDetail(
  BuildContext context,
  AppController controller,
  VoiceAsset asset,
) => showGeneralDialog<void>(
  context: context,
  barrierDismissible: false,
  transitionDuration: const Duration(milliseconds: 180),
  transitionBuilder: (context, animation, _, child) => SlideTransition(
    position: Tween<Offset>(
      begin: const Offset(1, 0),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
    child: child,
  ),
  pageBuilder: (dialogContext, _, _) => _VoiceDetailPage(
    controller: controller,
    asset: asset,
    onBack: () => Navigator.pop(dialogContext),
  ),
);

class _VoiceDetailPage extends StatefulWidget {
  const _VoiceDetailPage({
    required this.controller,
    required this.asset,
    required this.onBack,
  });

  final AppController controller;
  final VoiceAsset asset;
  final VoidCallback onBack;

  @override
  State<_VoiceDetailPage> createState() => _VoiceDetailPageState();
}

class _VoiceDetailPageState extends State<_VoiceDetailPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController pulse;

  @override
  void initState() {
    super.initState();
    pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );
  }

  @override
  void dispose() {
    pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final asset =
          widget.controller.voiceAssets
              .where((item) => item.id == widget.asset.id)
              .firstOrNull ??
          widget.asset;
      final playing = widget.controller.playingVoiceId == asset.id;
      if (playing && !pulse.isAnimating) pulse.repeat();
      if (!playing && pulse.isAnimating) pulse.stop();
      return Material(
        color: Theme.of(context).scaffoldBackgroundColor,
        child: SafeArea(
          child: Column(
            children: <Widget>[
              SizedBox(
                height: 58,
                child: Row(
                  children: <Widget>[
                    SizedBox(
                      width: 64,
                      child: IconButton(
                        onPressed: widget.onBack,
                        icon: const Icon(Icons.chevron_left_rounded, size: 25),
                        tooltip: '返回上级',
                      ),
                    ),
                    Expanded(
                      child: Text(
                        asset.numberLabel,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 64,
                      child: IconButton(
                        onPressed: () => widget.controller.voice
                            .setFavorite(asset, !asset.favorite)
                            .then((_) => widget.controller.refreshVoices()),
                        icon: Icon(
                          asset.favorite
                              ? Icons.favorite
                              : Icons.favorite_border,
                          size: 20,
                          color: asset.favorite ? _accent : _lightMuted,
                        ),
                        tooltip: '收藏',
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    SizedBox.square(
                      dimension: 250,
                      child: AnimatedBuilder(
                        animation: pulse,
                        builder: (context, _) => Stack(
                          alignment: Alignment.center,
                          children: <Widget>[
                            for (var index = 0; index < 3; index++)
                              _VoicePulseRing(
                                progress: playing
                                    ? (pulse.value + index / 3) % 1
                                    : 0,
                                visible: playing,
                              ),
                            GestureDetector(
                              onTap: () => widget.controller.playVoice(asset),
                              child: Container(
                                width: 132,
                                height: 132,
                                decoration: const BoxDecoration(
                                  shape: BoxShape.circle,
                                  gradient: RadialGradient(
                                    colors: <Color>[
                                      Color(0xFFFFE8DC),
                                      Color(0xFFE8A07B),
                                      Color(0xFFC96F47),
                                    ],
                                    stops: <double>[0, .52, 1],
                                  ),
                                  boxShadow: <BoxShadow>[
                                    BoxShadow(
                                      color: Color(0x42C96F47),
                                      blurRadius: 32,
                                      spreadRadius: 4,
                                    ),
                                  ],
                                ),
                                child: Icon(
                                  playing
                                      ? Icons.stop_rounded
                                      : Icons.play_arrow_rounded,
                                  size: 44,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 34),
                    Text(
                      asset.model.isEmpty ? asset.provider : asset.model,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 18),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 160),
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.symmetric(horizontal: 34),
                        child: Text(
                          asset.sourceText.trim().isEmpty
                              ? '未保存文本内容'
                              : asset.sourceText.trim(),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.onSurface,
                            fontSize: 14,
                            height: 1.55,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

class _VoicePulseRing extends StatelessWidget {
  const _VoicePulseRing({required this.progress, required this.visible});
  final double progress;
  final bool visible;

  @override
  Widget build(BuildContext context) => Transform.scale(
    scale: 1 + progress * .8,
    child: Container(
      width: 132,
      height: 132,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: _accent.withValues(
            alpha: visible ? ((1 - progress) * .28).clamp(0, 1) : 0,
          ),
          width: 2,
        ),
      ),
    ),
  );
}

class _MessageVoicesPage extends StatefulWidget {
  const _MessageVoicesPage({
    required this.controller,
    required this.message,
    required this.onBack,
  });

  final AppController controller;
  final ChatMessage message;
  final VoidCallback onBack;

  @override
  State<_MessageVoicesPage> createState() => _MessageVoicesPageState();
}

class _MessageVoicesPageState extends State<_MessageVoicesPage> {
  String selectedProfileId = '';
  int count = 1;
  bool generating = false;
  bool cancelRequested = false;
  int elapsedSeconds = 0;
  String localStatus = '';
  Timer? elapsedTimer;

  @override
  void initState() {
    super.initState();
    selectedProfileId = widget.controller.activeVoiceProfile?.id ?? '';
  }

  @override
  void dispose() {
    elapsedTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final voices = widget.controller.voicesForMessage(widget.message.id);
      final busy =
          generating ||
          widget.controller.voiceBusyMessageIds.contains(widget.message.id);
      final progress =
          widget.controller.voiceGenerationStatus[widget.message.id] ??
          localStatus;
      return Material(
        color: Theme.of(context).scaffoldBackgroundColor,
        child: SafeArea(
          child: Column(
            children: <Widget>[
              SizedBox(
                height: 58,
                child: Row(
                  children: <Widget>[
                    SizedBox(
                      width: 64,
                      child: IconButton(
                        onPressed: widget.onBack,
                        icon: const Icon(Icons.chevron_left_rounded, size: 25),
                        tooltip: '返回',
                      ),
                    ),
                    const Expanded(
                      child: Text(
                        '选择声音',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(width: 64),
                  ],
                ),
              ),
              Expanded(
                child: voices.isEmpty
                    ? const Center(
                        child: Text(
                          '这条消息还没有生成过声音',
                          style: TextStyle(color: _lightMuted, fontSize: 13),
                        ),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(18, 10, 18, 18),
                        itemCount: voices.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          final asset = voices[index];
                          return Material(
                            color:
                                Theme.of(context).brightness == Brightness.dark
                                ? _darkSurface
                                : _lightSurface,
                            shape: RoundedRectangleBorder(
                              side: BorderSide(
                                color: asset.bound
                                    ? _accent
                                    : Theme.of(context).dividerColor,
                              ),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: ListTile(
                              onTap: () => widget.controller.bindVoice(asset),
                              leading: IconButton(
                                onPressed: () =>
                                    widget.controller.playVoice(asset),
                                icon: Icon(
                                  widget.controller.playingVoiceId == asset.id
                                      ? Icons.stop_circle_outlined
                                      : Icons.play_arrow_rounded,
                                ),
                              ),
                              title: Text('声音 ${asset.numberLabel}'),
                              subtitle: Text(
                                asset.model.isEmpty
                                    ? asset.provider
                                    : asset.model,
                              ),
                              trailing: Icon(
                                asset.bound
                                    ? Icons.radio_button_checked
                                    : Icons.radio_button_off,
                                color: asset.bound ? _accent : _lightMuted,
                              ),
                            ),
                          );
                        },
                      ),
              ),
              Container(
                padding: const EdgeInsets.fromLTRB(18, 12, 18, 16),
                decoration: BoxDecoration(
                  color: Theme.of(context).scaffoldBackgroundColor,
                  border: Border(
                    top: BorderSide(color: Theme.of(context).dividerColor),
                  ),
                ),
                child: Column(
                  children: <Widget>[
                    if (widget.controller.voiceProfiles.isNotEmpty)
                      _LegacySelect(
                        value: selectedProfileId,
                        hint: '选择语音接口',
                        items: widget.controller.voiceProfiles
                            .map((profile) => (profile.id, profile.name))
                            .toList(),
                        onChanged: (value) =>
                            setState(() => selectedProfileId = value),
                      )
                    else
                      OutlinedButton.icon(
                        onPressed: () {
                          widget.onBack();
                          widget.controller.open(AppSection.settings);
                        },
                        icon: const Icon(Icons.settings_outlined, size: 18),
                        label: const Text('先去设置语音接口'),
                      ),
                    if (widget.controller.voiceProfiles.isNotEmpty) ...<Widget>[
                      if (progress.isNotEmpty) ...<Widget>[
                        Text(
                          busy ? '$progress  ${elapsedSeconds}s' : progress,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: busy ? _accent : _lightMuted,
                            fontSize: 12,
                            height: 1.35,
                          ),
                        ),
                        const SizedBox(height: 8),
                      ],
                      const SizedBox(height: 10),
                      Row(
                        children: <Widget>[
                          const Text('生成数量', style: TextStyle(fontSize: 12)),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Slider(
                              value: count.toDouble(),
                              min: 1,
                              max: 5,
                              divisions: 4,
                              label: '$count',
                              onChanged: busy
                                  ? null
                                  : (value) =>
                                        setState(() => count = value.round()),
                            ),
                          ),
                          SizedBox(
                            width: 24,
                            child: Text(
                              '$count',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                      SizedBox(
                        width: double.infinity,
                        height: 44,
                        child: FilledButton.icon(
                          onPressed: busy ? _stopGenerate : _generate,
                          icon: busy
                              ? const Icon(Icons.stop_rounded, size: 19)
                              : const Icon(Icons.graphic_eq_rounded, size: 19),
                          label: Text(
                            busy
                                ? '停止生成 ${elapsedSeconds}s'
                                : count == 1
                                ? '重新生成一条'
                                : '生成 $count 条',
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    },
  );

  Future<void> _generate() async {
    final profile = widget.controller.voiceProfiles
        .where((item) => item.id == selectedProfileId)
        .firstOrNull;
    if (profile == null) return;
    setState(() {
      generating = true;
      cancelRequested = false;
      elapsedSeconds = 0;
      localStatus = count == 1 ? '正在生成语音…' : '正在生成第 1/$count 条…';
    });
    elapsedTimer?.cancel();
    elapsedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => elapsedSeconds += 1);
    });
    try {
      VoiceAsset? last;
      for (var index = 0; index < count; index++) {
        if (cancelRequested) return;
        if (mounted && count > 1) {
          setState(() => localStatus = '正在生成第 ${index + 1}/$count 条…');
        }
        last = await widget.controller.generateVoice(
          widget.message,
          profile: profile,
          bind: count == 1,
        );
        if (last == null) {
          if (mounted) {
            setState(
              () => localStatus = cancelRequested ? '已停止生成语音' : '生成失败，请查看提示后重试',
            );
          }
          return;
        }
      }
      if (count > 1 && last != null) await widget.controller.bindVoice(last);
      if (mounted) setState(() => localStatus = '已生成并保存到 Ta的声音');
    } finally {
      elapsedTimer?.cancel();
      if (mounted) setState(() => generating = false);
    }
  }

  void _stopGenerate() {
    if (!generating) return;
    setState(() {
      cancelRequested = true;
      localStatus = '正在停止语音生成…';
    });
    widget.controller.stopVoiceGeneration(widget.message.id);
  }
}

class _ArchivedConversationsPanel extends StatelessWidget {
  const _ArchivedConversationsPanel({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final items = controller.archivedConversations;
    if (items.isEmpty) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(14, 8, 14, 16),
        child: _LegacyEmptyContent(label: '还没有已归档的对话'),
      );
    }
    return ListView.separated(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 14),
      itemCount: items.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final item = items[index];
        final time = DateFormat(
          'MM/dd HH:mm',
        ).format((item.archivedAt ?? item.updatedAt).toLocal());
        return Material(
          color: Theme.of(context).brightness == Brightness.dark
              ? _darkSurface
              : _lightSurface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(
              color: Theme.of(context).brightness == Brightness.dark
                  ? _darkLine
                  : _lightLine,
              width: 2 / 3,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => showGeneralDialog<void>(
              context: context,
              barrierDismissible: false,
              transitionDuration: Duration.zero,
              pageBuilder: (dialogContext, _, _) => _ArchivedConversationDetail(
                controller: controller,
                conversation: item,
                onBack: () => Navigator.pop(dialogContext),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(
                children: <Widget>[
                  const _LegacyDiaryState(label: '已归档'),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          item.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          time,
                          style: _legacyDiaryMetaStyle(
                            context,
                          ).copyWith(fontWeight: FontWeight.w400),
                        ),
                      ],
                    ),
                  ),
                  _LegacyIcon(
                    _LegacyIconKind.chevronRight,
                    size: 16,
                    color: Theme.of(context).brightness == Brightness.dark
                        ? _darkMuted
                        : _lightMuted,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ArchivedConversationDetail extends StatefulWidget {
  const _ArchivedConversationDetail({
    required this.controller,
    required this.conversation,
    required this.onBack,
  });

  final AppController controller;
  final Conversation conversation;
  final VoidCallback onBack;

  @override
  State<_ArchivedConversationDetail> createState() =>
      _ArchivedConversationDetailState();
}

class _ArchivedConversationDetailState
    extends State<_ArchivedConversationDetail> {
  late final Future<List<ChatMessage>> _messages = widget.controller
      .messagesForConversation(widget.conversation);

  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).scaffoldBackgroundColor,
    child: SafeArea(
      child: Column(
        children: <Widget>[
          _LegacyDetailHeader(
            title: widget.conversation.title,
            onBack: widget.onBack,
            backTooltip: '返回已归档数据',
            actions: <Widget>[
              SizedBox.square(
                dimension: 36,
                child: IconButton(
                  onPressed: () async {
                    await widget.controller.unarchiveConversation(
                      widget.conversation,
                    );
                    if (context.mounted) Navigator.pop(context);
                  },
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 36,
                    height: 36,
                  ),
                  icon: const Icon(Icons.unarchive_outlined, size: 18),
                  tooltip: '取消归档',
                ),
              ),
              _LegacyFileAction(
                icon: _LegacyIconKind.download,
                tooltip: '导出',
                onPressed: () =>
                    widget.controller.exportConversation(widget.conversation),
              ),
            ],
          ),
          Expanded(
            child: FutureBuilder<List<ChatMessage>>(
              future: _messages,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Center(
                    child: Text(
                      '无法读取归档对话',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  );
                }
                if (!snapshot.hasData) {
                  return const Center(
                    child: CircularProgressIndicator(strokeWidth: 2),
                  );
                }
                final messages = snapshot.data!;
                if (messages.isEmpty) {
                  return const Padding(
                    padding: EdgeInsets.all(16),
                    child: _LegacyEmptyContent(label: '这段对话没有消息'),
                  );
                }
                return ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                  itemCount: messages.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 14),
                  itemBuilder: (context, index) {
                    final message = messages[index];
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          message.role == 'user' ? '用户' : '小机子',
                          style: TextStyle(
                            color:
                                Theme.of(context).brightness == Brightness.dark
                                ? _darkMuted
                                : _lightMuted,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 5),
                        message.content.trim().isEmpty
                            ? const _LegacyEmptyContent(label: '这条消息没有正文')
                            : SelectableText(
                                message.content,
                                style: const TextStyle(
                                  fontSize: 13,
                                  height: 1.55,
                                ),
                              ),
                      ],
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    ),
  );
}

class _SettingsPage extends StatefulWidget {
  const _SettingsPage({required this.controller});
  final AppController controller;

  @override
  State<_SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<_SettingsPage> {
  AppController get controller => widget.controller;
  final Set<String> _expandedCards = <String>{};

  void _handleCardOpen(String title, bool open) => setState(() {
    if (open) {
      _expandedCards.add(title);
    } else {
      _expandedCards.remove(title);
    }
  });

  double? get _settingsThumbHeight {
    if (_expandedCards.length != 1) return null;
    return switch (_expandedCards.single) {
      'App' => 696,
      'API' => 576,
      'Voice' => 690,
      'Models' => 457,
      'Toolbox' => 306,
      'Diagnostics' => 430,
      'Preferences' => 591,
      _ => null,
    };
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Settings',
    child: Stack(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: ListView(
            padding: EdgeInsets.fromLTRB(
              4,
              8,
              _settingsThumbHeight == null ? 4 : 19,
              40,
            ),
            children: <Widget>[
              _SettingsAccountPill(controller: controller),
              const SizedBox(height: 14),
              _SettingsCard(
                title: 'App',
                icon: Icons.palette_outlined,
                first: true,
                onOpenChanged: (open) => _handleCardOpen('App', open),
                children: <Widget>[
                  _LegacyAppSettingsPanel(
                    controller: controller,
                    onRestore: () => _restoreAppearance(context),
                  ),
                ],
              ),
              _SettingsCard(
                title: 'API',
                icon: Icons.hub_outlined,
                onOpenChanged: (open) => _handleCardOpen('API', open),
                children: <Widget>[
                  _LegacyApiSettingsPanel(controller: controller),
                ],
              ),
              _SettingsCard(
                title: 'Voice',
                icon: Icons.graphic_eq_rounded,
                onOpenChanged: (open) => _handleCardOpen('Voice', open),
                children: <Widget>[
                  _LegacyVoiceSettingsPanel(controller: controller),
                ],
              ),
              _SettingsCard(
                title: 'Models',
                icon: Icons.tune_rounded,
                onOpenChanged: (open) => _handleCardOpen('Models', open),
                children: <Widget>[
                  _LegacyModelsSettingsPanel(
                    controller: controller,
                    onAdd: () => _modelSlotDialog(context),
                  ),
                ],
              ),
              _SettingsCard(
                title: 'Profile',
                icon: Icons.account_circle_outlined,
                onOpenChanged: (open) => _handleCardOpen('Profile', open),
                children: <Widget>[
                  _LegacyProfileSettingsPanel(controller: controller),
                ],
              ),
              _SettingsCard(
                title: 'Toolbox',
                icon: Icons.construction_outlined,
                onOpenChanged: (open) => _handleCardOpen('Toolbox', open),
                children: <Widget>[
                  _LegacyToolboxSettingsPanel(controller: controller),
                ],
              ),
              _SettingsCard(
                title: 'Diagnostics',
                icon: Icons.bug_report_outlined,
                onOpenChanged: (open) => _handleCardOpen('Diagnostics', open),
                children: <Widget>[
                  _DiagnosticsSettingsPanel(controller: controller),
                ],
              ),
              _SettingsCard(
                title: 'Preferences',
                icon: Icons.tune_rounded,
                onOpenChanged: (open) => _handleCardOpen('Preferences', open),
                children: <Widget>[
                  _LegacyPreferencesSettingsPanel(
                    controller: controller,
                    fontValue: _fontOptionValue(),
                  ),
                ],
              ),
              _SettingsCard(
                title: 'Archive',
                icon: Icons.archive_outlined,
                onOpenChanged: (open) => _handleCardOpen('Archive', open),
                children: <Widget>[
                  _ArchivedConversationsPanel(controller: controller),
                ],
              ),
              _SettingsCard(
                title: 'Local data',
                icon: Icons.shield_outlined,
                onOpenChanged: (open) => _handleCardOpen('Local data', open),
                children: <Widget>[
                  _LegacyLocalDataSettingsPanel(
                    onExport: () => _export(context),
                    onImport: () => _import(context),
                    onClear: () => _clearHistory(context),
                    onNewChat: () => controller.newConversation(),
                  ),
                ],
              ),
            ],
          ),
        ),
        if (kIsWeb && _settingsThumbHeight != null)
          _LegacySettingsScrollbar(height: _settingsThumbHeight!),
      ],
    ),
  );

  String _fontOptionValue() {
    final stored = '${controller.settings['fontFamily'] ?? 'claude'}';
    if (stored == '${controller.settings['customFontFamily'] ?? ''}' &&
        stored.isNotEmpty) {
      return 'custom';
    }
    return switch (stored) {
      'DMSans' => 'dm',
      'PlusJakartaSans' => 'jakarta',
      'Lora' => 'lora',
      'Newsreader' => 'newsreader',
      'SourceSerif4' => 'sourceSerif',
      'system' ||
      'claude' ||
      'dm' ||
      'jakarta' ||
      'lora' ||
      'newsreader' ||
      'sourceSerif' => stored,
      'custom' => 'custom',
      _ => 'system',
    };
  }

  Future<void> _clearHistory(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清空聊天历史？'),
        content: const Text('所有普通对话会从列表中移除。此操作不会删除 API、记忆、日记、文件或工作区。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await controller.clearConversationHistory();
    if (context.mounted) _snack(context, '聊天历史已清空');
  }

  // Kept as a fallback editor for future platform-specific entry points.
  // ignore: unused_element
  Future<void> _modelSlotDialog(
    BuildContext context, [
    Map<String, Object?>? value,
  ]) async {
    final label = TextEditingController(text: '${value?['label'] ?? ''}');
    var apiProfileId = '${value?['apiProfileId'] ?? ''}';
    var apiName = '${value?['apiName'] ?? ''}';
    var stream = value?['stream'] != false;
    final parameters = <String, num?>{
      'temperature': _slotNumber(value, 'temperature', .7),
      'topP': _slotNumber(value, 'topP', 1),
      'frequencyPenalty': _slotNumber(value, 'frequencyPenalty', 0),
      'presencePenalty': _slotNumber(value, 'presencePenalty', 0),
      'maxTokens': _slotNumber(value, 'maxTokens', 4096),
    };
    final contextTokens = TextEditingController(
      text: value?['contextTokens'] == null
          ? ''
          : '${((value!['contextTokens'] as num) / 1000).round()}',
    );
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => Dialog.fullscreen(
          child: Scaffold(
            appBar: AppBar(
              title: Text(value == null ? '添加模型' : '编辑模型'),
              leading: IconButton(
                onPressed: () => Navigator.pop(context, false),
                icon: const Icon(Icons.close_rounded),
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: apiName.isEmpty
                      ? null
                      : () => Navigator.pop(context, true),
                  child: const Text('保存'),
                ),
                const SizedBox(width: 8),
              ],
            ),
            body: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: ListView(
                  padding: const EdgeInsets.all(20),
                  children: <Widget>[
                    TextField(
                      controller: label,
                      decoration: const InputDecoration(labelText: '模型显示名'),
                    ),
                    const SizedBox(height: 12),
                    _LegacySelect(
                      value: apiProfileId,
                      hint: 'API 接口',
                      items: controller.profiles
                          .map((profile) => (profile.id, profile.name))
                          .toList(),
                      onChanged: (next) => setDialogState(() {
                        apiProfileId = next;
                        final profile = controller.profiles
                            .where((item) => item.id == apiProfileId)
                            .firstOrNull;
                        if (profile != null &&
                            !profile.models.contains(apiName)) {
                          apiName = '';
                        }
                      }),
                    ),
                    const SizedBox(height: 12),
                    _LegacySelect(
                      key: ValueKey('$apiProfileId::$apiName'),
                      value: apiName,
                      hint: '真实模型 ID',
                      items: controller.profiles
                          .where((profile) => profile.id == apiProfileId)
                          .expand((profile) => profile.models)
                          .map((model) => (model, model))
                          .toList(),
                      onChanged: (next) => setDialogState(() => apiName = next),
                    ),
                    const SizedBox(height: 8),
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('流式输出'),
                      value: stream,
                      onChanged: (next) => setDialogState(() => stream = next),
                    ),
                    ...<
                          ({
                            String key,
                            String label,
                            double min,
                            double max,
                            int divisions,
                            double fallback,
                          })
                        >[
                          (
                            key: 'temperature',
                            label: '温度',
                            min: 0,
                            max: 2,
                            divisions: 40,
                            fallback: .7,
                          ),
                          (
                            key: 'topP',
                            label: 'Top-P',
                            min: 0,
                            max: 1,
                            divisions: 20,
                            fallback: 1,
                          ),
                          (
                            key: 'frequencyPenalty',
                            label: '词频惩罚',
                            min: -2,
                            max: 2,
                            divisions: 80,
                            fallback: 0,
                          ),
                          (
                            key: 'presencePenalty',
                            label: '存在惩罚',
                            min: -2,
                            max: 2,
                            divisions: 80,
                            fallback: 0,
                          ),
                          (
                            key: 'maxTokens',
                            label: '回复令牌',
                            min: 256,
                            max: 16384,
                            divisions: 63,
                            fallback: 4096,
                          ),
                        ]
                        .map(
                          (parameter) => _ModelParameterSlider(
                            label: parameter.label,
                            value: parameters[parameter.key],
                            min: parameter.min,
                            max: parameter.max,
                            divisions: parameter.divisions,
                            integer: parameter.key == 'maxTokens',
                            onChanged: (next) => setDialogState(
                              () => parameters[parameter.key] = next,
                            ),
                            onToggleNone: () => setDialogState(() {
                              parameters[parameter.key] =
                                  parameters[parameter.key] == null
                                  ? parameter.fallback
                                  : null;
                            }),
                          ),
                        ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: contextTokens,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: '上下文预算（K）',
                        hintText: 'none',
                        helperText: '留空表示不自动裁剪；例如 128 表示 128K token',
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    if (saved == true) {
      final contextK = num.tryParse(contextTokens.text.trim());
      await controller.saveModelSlot(<String, Object?>{
        'id': '${value?['id'] ?? _uuid.v4()}',
        'label': label.text.trim().isEmpty ? apiName : label.text.trim(),
        'apiProfileId': apiProfileId,
        'apiName': apiName,
        'stream': stream,
        ...parameters,
        'contextTokens': contextK == null ? null : (contextK * 1000).round(),
      });
    }
    label.dispose();
    contextTokens.dispose();
  }

  num? _slotNumber(Map<String, Object?>? value, String key, num fallback) =>
      value == null ? fallback : value[key] as num?;

  // Kept as a fallback editor for future platform-specific entry points.
  // ignore: unused_element
  Future<void> _profileDialog(BuildContext context, [ApiProfile? value]) async {
    final name = TextEditingController(text: value?.name ?? '默认接口');
    final endpoint = TextEditingController(
      text: value?.endpoint ?? 'https://api.openai.com/v1',
    );
    final key = TextEditingController();
    final models = TextEditingController(text: value?.models.join('\n') ?? '');
    final headers = TextEditingController(
      text: value == null || value.customHeaders.isEmpty
          ? ''
          : const JsonEncoder.withIndent('  ').convert(value.customHeaders),
    );
    var fetching = false;
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(value == null ? '添加 API 接口' : '编辑 API 接口'),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(
              children: <Widget>[
                TextField(
                  controller: name,
                  decoration: const InputDecoration(labelText: '名称'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: endpoint,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    labelText: 'API 地址',
                    helperText: '支持 base URL 或 /chat/completions 完整地址',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: key,
                  obscureText: true,
                  decoration: InputDecoration(
                    labelText: value == null ? 'API Key' : 'API Key（留空表示不更改）',
                    helperText: '只保存在 Keychain / Android Keystore',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: models,
                  minLines: 3,
                  maxLines: 7,
                  decoration: const InputDecoration(labelText: '模型（每行一个）'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: headers,
                  minLines: 2,
                  maxLines: 6,
                  decoration: const InputDecoration(
                    labelText: '自定义请求头 JSON（可选）',
                    helperText: 'Authorization、Host、Content-Length 等敏感头会被拒绝',
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          if (value != null)
            TextButton.icon(
              onPressed: fetching
                  ? null
                  : () async {
                      fetching = true;
                      try {
                        final temporary = ApiProfile(
                          id: value.id,
                          name: name.text,
                          endpoint: endpoint.text,
                          models: value.models,
                          customHeaders: _parseHeaders(headers.text),
                          active: value.active,
                        );
                        final fetched = await controller.fetchModels(temporary);
                        models.text = fetched.join('\n');
                        if (context.mounted) {
                          _snack(context, '已获取 ${fetched.length} 个模型');
                        }
                      } on Object catch (error) {
                        if (context.mounted) _snack(context, '$error');
                      } finally {
                        fetching = false;
                      }
                    },
              icon: const Icon(Icons.download_outlined),
              label: const Text('获取模型'),
            ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('保存并启用'),
          ),
        ],
      ),
    );
    if (saved == true) {
      Map<String, String> customHeaders;
      try {
        customHeaders = _parseHeaders(headers.text);
      } on FormatException catch (error) {
        if (context.mounted) _snack(context, error.message);
        name.dispose();
        endpoint.dispose();
        key.dispose();
        models.dispose();
        headers.dispose();
        return;
      }
      await controller.settingsService.saveProfile(
        id: value?.id,
        name: name.text,
        endpoint: endpoint.text,
        apiKey: key.text,
        models: models.text
            .split(RegExp(r'[\r\n,]+'))
            .map((item) => item.trim())
            .where((item) => item.isNotEmpty)
            .toList(),
        customHeaders: customHeaders,
      );
      if (models.text.trim().isNotEmpty)
        await controller.saveSetting(
          'activeModelId',
          models.text.split(RegExp(r'[\r\n,]+')).first.trim(),
        );
      await controller.reload();
    }
    name.dispose();
    endpoint.dispose();
    key.dispose();
    models.dispose();
    headers.dispose();
  }

  Map<String, String> _parseHeaders(String source) {
    if (source.trim().isEmpty) return const <String, String>{};
    try {
      final decoded = jsonDecode(source);
      if (decoded is! Map) throw const FormatException();
      return decoded.map((key, value) => MapEntry('$key', '$value'));
    } on Object {
      throw const FormatException('自定义请求头必须是 JSON 对象');
    }
  }

  // Kept as a fallback editor for future platform-specific entry points.
  // ignore: unused_element
  Future<void> _textSetting(
    BuildContext context,
    String title,
    String key,
    String value, {
    int lines = 1,
  }) async {
    final input = TextEditingController(text: value);
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 560,
          child: TextField(
            controller: input,
            minLines: lines,
            maxLines: lines == 1 ? 2 : lines + 4,
            autofocus: true,
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (saved == true) await controller.saveSetting(key, input.text);
    input.dispose();
  }

  // Kept as a fallback editor for future platform-specific entry points.
  // ignore: unused_element
  Future<void> _numberSetting(
    BuildContext context,
    String title,
    String key,
    int? value, {
    int minimum = 4096,
    bool allowEmpty = true,
  }) async {
    final input = TextEditingController(text: value?.toString() ?? '');
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 440,
          child: TextField(
            controller: input,
            autofocus: true,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              helperText: '请输入整数；支持的最小值由当前设置项决定',
            ),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (saved == true) {
      final source = input.text.trim();
      final parsed = source.isEmpty && allowEmpty ? null : int.tryParse(source);
      if ((!allowEmpty && source.isEmpty) ||
          (source.isNotEmpty && (parsed == null || parsed < minimum))) {
        if (context.mounted) _snack(context, '请输入不小于 $minimum 的整数');
      } else {
        await controller.saveSetting(key, parsed);
      }
    }
    input.dispose();
  }

  Future<void> _restoreAppearance(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('恢复默认应用外观？'),
        content: const Text('应用名称、图标、开屏语和首页欢迎语会恢复默认；API、模型和聊天数据会保留。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('恢复'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    for (final entry in const <String, Object?>{
      'appName': 'ClaudeChat',
      'customIconPath': null,
      'splashPhrases': '欢迎回来\n很高兴见到你\n我在这里\n今天想聊些什么？',
      'splashRandom': true,
      'greeting': '',
    }.entries) {
      await controller.settingsService.set(entry.key, entry.value);
      controller.settings[entry.key] = entry.value;
    }
    await controller.reload();
  }

  Future<void> _export(BuildContext context) async {
    final password = TextEditingController();
    bool includeSecrets = false;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('导出完整备份'),
          content: SizedBox(
            width: 520,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                TextField(
                  controller: password,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: '备份密码（可留空）',
                    helperText: '建议设置至少 8 位密码；密码不会被保存',
                  ),
                ),
                CheckboxListTile(
                  value: includeSecrets,
                  onChanged: (value) =>
                      setState(() => includeSecrets = value ?? false),
                  title: const Text('包含 API 密钥'),
                  subtitle: const Text('开启后必须设置密码'),
                  contentPadding: EdgeInsets.zero,
                ),
                const Text(
                  '导出的 .claudechat 文件包含所有对话、记忆、日记版本、文件、工作区、语音缓存、绑定/收藏状态和删除记录。',
                  style: TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('导出'),
            ),
          ],
        ),
      ),
    );
    if (confirmed == true) {
      try {
        final path = await controller.exportBackup(
          password: password.text,
          includeSecrets: includeSecrets,
        );
        if (context.mounted) _snack(context, '备份已生成：$path');
      } on Object catch (error) {
        if (context.mounted) _snack(context, '$error');
      }
    }
    password.dispose();
  }

  Future<void> _import(BuildContext context) async {
    final password = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('合并导入'),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Text(
                '导入不会先清空本机数据。完全相同的记录会跳过；本机已删除但备份中仍存在的数据会恢复；同一对话或消息的内容有变化时会更新。其他并发修改会保留冲突记录。',
              ),
              const SizedBox(height: 8),
              const Text(
                '兼容旧版 JSON、旧网页未加密迁移包及加密 .claudechat 备份。旧版 JSON 本身未包含“Ta的文件”和工作区；完整迁移包会保留这些内容。未加密迁移包如包含 API Key，导入后请及时删除原文件。',
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: password,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: '备份密码（未加密或旧 JSON 可留空）',
                ),
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('选择文件'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      try {
        final report = await controller.pickAndImport(password: password.text);
        if (context.mounted && report != null)
          _snack(
            context,
            '导入完成：新增 ${report.added}，更新 ${report.updated}，跳过 ${report.skipped}，冲突留档 ${report.conflicts}',
          );
      } on Object catch (error) {
        if (context.mounted) _snack(context, '$error');
      }
    }
    password.dispose();
  }
}

class _ModelParameterSlider extends StatelessWidget {
  const _ModelParameterSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.integer,
    required this.onChanged,
    required this.onToggleNone,
  });

  final String label;
  final num? value;
  final double min;
  final double max;
  final int divisions;
  final bool integer;
  final ValueChanged<num> onChanged;
  final VoidCallback onToggleNone;

  @override
  Widget build(BuildContext context) {
    final enabled = value != null;
    final sliderValue = (value?.toDouble() ?? min).clamp(min, max);
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(child: Text('$label  ${enabled ? value : 'none'}')),
              TextButton(
                onPressed: onToggleNone,
                child: Text(enabled ? '设为 none' : '启用'),
              ),
            ],
          ),
          Slider(
            value: sliderValue,
            min: min,
            max: max,
            divisions: divisions,
            onChanged: enabled
                ? (next) => onChanged(
                    integer
                        ? next.round()
                        : double.parse(next.toStringAsFixed(2)),
                  )
                : null,
          ),
        ],
      ),
    );
  }
}

class _SettingsAccountPill extends StatelessWidget {
  const _SettingsAccountPill({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final name = '${controller.settings['profileName'] ?? '用户'}';
    final initial = name.trim().isEmpty ? '用' : name.trim().characters.first;
    return Container(
      constraints: const BoxConstraints(minHeight: 74),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).brightness == Brightness.dark
            ? _darkSurface86OnBackground
            : _lightSurface86OnBackground,
        border: Border.all(color: Theme.of(context).dividerColor, width: 1),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 44,
            child: Align(
              alignment: Alignment.centerLeft,
              child: CircleAvatar(
                radius: 18,
                backgroundColor: Theme.of(
                  context,
                ).colorScheme.surfaceContainerHighest,
                child: Text(
                  initial,
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w800,
                    height: 1,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    height: 1.3333333,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${controller.settings['profileNote'] ?? '本地账号'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 10.8,
                    fontWeight: FontWeight.w400,
                    height: 1.2962963,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LegacyAppSettingsPanel extends StatelessWidget {
  const _LegacyAppSettingsPanel({
    required this.controller,
    required this.onRestore,
  });

  final AppController controller;
  final VoidCallback onRestore;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(14, 0, 14, 0),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SizedBox(
          height: 96,
          child: Row(
            children: <Widget>[
              Container(
                width: 74,
                height: 74,
                alignment: Alignment.topLeft,
                decoration: BoxDecoration(
                  color: _lightSurfaceSoft,
                  border: Border.all(color: _lightLine, width: 0.6667),
                  borderRadius: BorderRadius.circular(18),
                  boxShadow: const <BoxShadow>[
                    BoxShadow(
                      color: Color(0x14000000),
                      offset: Offset(0, 6),
                      blurRadius: 16,
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(17.3333),
                  child: Image.asset(
                    'assets/icons/icon-512.png',
                    width: 74,
                    height: 74,
                    fit: BoxFit.cover,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    SizedBox(
                      height: 44,
                      width: double.infinity,
                      child: OutlinedButton(
                        onPressed: controller.installCustomIcon,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFF101010),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            _LegacyIcon(
                              _LegacyIconKind.upload,
                              size: 18,
                              color: Color(0xFF101010),
                            ),
                            SizedBox(width: 10),
                            Text(
                              '上传图标',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                height: 1,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 44,
                      width: double.infinity,
                      child: OutlinedButton(
                        onPressed: () => unawaited(
                          controller.saveSetting('customIconPath', ''),
                        ),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFF101010),
                        ),
                        child: Transform.translate(
                          offset: const Offset(-0.5, -1),
                          child: const Text(
                            '默认图标',
                            style: TextStyle(
                              fontSize: 12.6,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _LegacySettingsField(
          label: '账号名称',
          initialValue: '${controller.settings['profileName'] ?? ''}',
          onChanged: (value) =>
              unawaited(controller.saveSetting('profileName', value.trim())),
        ),
        const SizedBox(height: 12),
        _LegacySettingsField(
          label: '应用名称',
          initialValue: '${controller.settings['appName'] ?? ''}',
          onChanged: (value) =>
              unawaited(controller.saveSetting('appName', value)),
        ),
        const SizedBox(height: 12),
        _LegacySettingsField(
          label: '开屏语',
          initialValue: '${controller.settings['splashPhrases'] ?? ''}',
          minLines: 5,
          maxLines: 5,
          onChanged: (value) =>
              unawaited(controller.saveSetting('splashPhrases', value)),
        ),
        const SizedBox(height: 2.3333),
        SizedBox(
          height: 14,
          child: Transform.translate(
            offset: const Offset(0, 4.6667),
            child: const Text(
              '每行一句。开启随机后，每次打开会从这里抽一句。',
              style: TextStyle(fontSize: 9.9, height: 1.25, color: _lightMuted),
            ),
          ),
        ),
        const SizedBox(height: 3),
        Semantics(
          button: true,
          label: '随机开屏语',
          child: InkWell(
            onTap: () => unawaited(
              controller.saveSetting(
                'splashRandom',
                controller.settings['splashRandom'] != true,
              ),
            ),
            child: SizedBox(
              height: 48,
              child: Row(
                children: <Widget>[
                  const _LegacyIcon(
                    _LegacyIconKind.waveform,
                    size: 24,
                    color: Color(0xFF101010),
                  ),
                  const SizedBox(width: 15),
                  Expanded(
                    child: Transform.translate(
                      offset: const Offset(0, -3),
                      child: const Text(
                        '随机开屏语',
                        style: TextStyle(fontSize: 14.2),
                      ),
                    ),
                  ),
                  Transform.translate(
                    offset: const Offset(0, -0.3021),
                    child: _LegacySwitch(
                      value: controller.settings['splashRandom'] == true,
                      onChanged: (value) => unawaited(
                        controller.saveSetting('splashRandom', value),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        _LegacySettingsField(
          label: '欢迎语',
          initialValue: '${controller.settings['greeting'] ?? ''}',
          onChanged: (value) =>
              unawaited(controller.saveSetting('greeting', value)),
        ),
        const SizedBox(height: 5),
        SizedBox(
          height: 14,
          child: Transform.translate(
            offset: const Offset(0, 2),
            child: Text(
              '对话首页欢迎语。留空则根据时间段和账号名称自动切换（如"早上好，${_accountName(controller)}"）。',
              style: const TextStyle(
                fontSize: 9.9,
                height: 1.25,
                color: _lightMuted,
              ),
            ),
          ),
        ),
        const SizedBox(height: 12.4),
        SizedBox(
          height: 44,
          child: OutlinedButton(
            onPressed: onRestore,
            style: OutlinedButton.styleFrom(
              foregroundColor: _lightDanger,
              side: const BorderSide(color: _lightDangerLine),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                _LegacyIcon(
                  _LegacyIconKind.database,
                  size: 18,
                  color: _lightDanger,
                ),
                SizedBox(width: 11),
                Text(
                  '恢复默认设置',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    height: 1,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}

class _LegacyVoiceSettingsPanel extends StatefulWidget {
  const _LegacyVoiceSettingsPanel({required this.controller});
  final AppController controller;

  @override
  State<_LegacyVoiceSettingsPanel> createState() =>
      _LegacyVoiceSettingsPanelState();
}

class _LegacyVoiceSettingsPanelState extends State<_LegacyVoiceSettingsPanel> {
  late final TextEditingController name;
  late final TextEditingController endpoint;
  late final TextEditingController apiKey;
  late final TextEditingController model;
  late final TextEditingController voiceId;
  late final TextEditingController outputFormat;
  late final TextEditingController appId;
  late final TextEditingController cluster;
  late final TextEditingController headers;
  String selectedId = '__new';
  VoiceProvider provider = VoiceProvider.elevenLabs;
  bool saving = false;
  bool showApiKey = false;
  bool loadingApiKey = false;
  int _keyLoadGeneration = 0;
  late bool backgroundPlayback;

  AppController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    name = TextEditingController();
    endpoint = TextEditingController();
    apiKey = TextEditingController();
    model = TextEditingController();
    voiceId = TextEditingController();
    outputFormat = TextEditingController(text: 'mp3');
    appId = TextEditingController();
    cluster = TextEditingController(text: 'volcano_tts');
    headers = TextEditingController();
    backgroundPlayback = controller.settings['voiceBackgroundPlayback'] == true;
    _load(controller.activeVoiceProfile);
  }

  @override
  void dispose() {
    name.dispose();
    endpoint.dispose();
    apiKey.dispose();
    model.dispose();
    voiceId.dispose();
    outputFormat.dispose();
    appId.dispose();
    cluster.dispose();
    headers.dispose();
    super.dispose();
  }

  void _load(VoiceProfile? value) {
    selectedId = value?.id ?? '__new';
    provider = value?.provider ?? VoiceProvider.elevenLabs;
    name.text = value?.name ?? provider.label;
    endpoint.text = value?.endpoint ?? provider.defaultEndpoint;
    model.text = value?.model ?? provider.defaultModel;
    voiceId.text = value?.voiceId ?? '';
    outputFormat.text = value?.outputFormat ?? 'mp3';
    appId.text = '${value?.options['appId'] ?? ''}';
    cluster.text = '${value?.options['cluster'] ?? 'volcano_tts'}';
    headers.text = value == null || value.customHeaders.isEmpty
        ? ''
        : const JsonEncoder.withIndent(' ').convert(value.customHeaders);
    showApiKey = false;
    apiKey.clear();
    loadingApiKey = value != null;
    final generation = ++_keyLoadGeneration;
    if (value != null) {
      unawaited(_loadApiKey(value.id, generation));
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(14, 0, 14, 0),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Material(
          color: Colors.transparent,
          child: CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            controlAffinity: ListTileControlAffinity.leading,
            title: const Text(
              '允许后台播放',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
            ),
            subtitle: const Text(
              '锁屏或切换到其他 App 后继续播放当前语音',
              style: TextStyle(fontSize: 11.7),
            ),
            value: backgroundPlayback,
            onChanged: (value) {
              final enabled = value == true;
              setState(() => backgroundPlayback = enabled);
              unawaited(
                controller.saveSetting('voiceBackgroundPlayback', enabled),
              );
            },
          ),
        ),
        const SizedBox(height: 8),
        _LegacySettingsDropdown(
          label: '语音接口',
          value: selectedId,
          items: <(String, String)>[
            const ('__new', '新增语音接口'),
            ...controller.voiceProfiles.map((item) => (item.id, item.name)),
          ],
          onChanged: (value) => setState(() {
            final profile = controller.voiceProfiles
                .where((item) => item.id == value)
                .firstOrNull;
            _load(profile);
          }),
        ),
        const SizedBox(height: 12),
        _LegacySettingsDropdown(
          label: '服务商',
          value: provider.key,
          items: VoiceProvider.values
              .map((item) => (item.key, item.label))
              .toList(),
          onChanged: (value) => setState(() {
            provider = VoiceProviderInfo.fromKey(value);
            name.text = provider.label;
            endpoint.text = provider.defaultEndpoint;
            model.text = provider.defaultModel;
          }),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: name,
          decoration: const InputDecoration(labelText: '接口名称'),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: endpoint,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            labelText: 'API 地址',
            helperText: '地址可以编辑；ElevenLabs 可用 {voice_id} 占位符',
          ),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: apiKey,
          obscureText: !showApiKey,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            labelText: selectedId == '__new'
                ? 'API Key / Access Token'
                : 'API Key / Access Token',
            helperText: '仅保存在系统 Keychain / Keystore',
            suffixIcon: loadingApiKey
                ? const Padding(
                    padding: EdgeInsets.all(11),
                    child: CircularProgressIndicator(strokeWidth: 1.5),
                  )
                : showApiKey
                ? IconButton(
                    tooltip: '复制语音 API key',
                    onPressed: apiKey.text.isEmpty
                        ? null
                        : () async {
                            await Clipboard.setData(
                              ClipboardData(text: apiKey.text),
                            );
                            if (context.mounted) {
                              _snack(context, '语音 API key 已复制');
                            }
                          },
                    icon: const Icon(Icons.copy_outlined, size: 18),
                  )
                : null,
          ),
        ),
        SizedBox(
          height: 34,
          child: Row(
            children: <Widget>[
              Checkbox(
                value: showApiKey,
                onChanged: loadingApiKey
                    ? null
                    : (value) => setState(() => showApiKey = value == true),
              ),
              const Text('显示 key', style: TextStyle(fontSize: 11.7)),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: <Widget>[
            Expanded(
              child: TextField(
                controller: model,
                decoration: const InputDecoration(labelText: '模型名称'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: voiceId,
                decoration: const InputDecoration(labelText: '音色 / Voice ID'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        TextField(
          controller: outputFormat,
          decoration: const InputDecoration(
            labelText: '输出格式',
            hintText: 'mp3 / wav / mp3_44100_128',
          ),
        ),
        if (provider == VoiceProvider.volcengine) ...<Widget>[
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: appId,
                  decoration: const InputDecoration(labelText: 'App ID'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: cluster,
                  decoration: const InputDecoration(labelText: 'Cluster'),
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 10),
        TextField(
          controller: headers,
          minLines: 2,
          maxLines: 5,
          decoration: const InputDecoration(labelText: '自定义请求头 JSON（可选）'),
        ),
        const SizedBox(height: 12),
        Row(
          children: <Widget>[
            if (selectedId != '__new')
              TextButton(
                onPressed: saving ? null : _delete,
                style: TextButton.styleFrom(foregroundColor: _lightDanger),
                child: const Text('删除接口'),
              ),
            const Spacer(),
            FilledButton.icon(
              onPressed: saving ? null : _save,
              icon: saving
                  ? const SizedBox.square(
                      dimension: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.5,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.check_rounded, size: 18),
              label: const Text('保存并启用'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        const _LegacySettingsHint(
          'ElevenLabs、MiniMax、火山引擎与 Mossland 均使用各自官方请求格式；自定义项按 OpenAI 兼容格式发送，并支持自定义地址与请求头。',
        ),
      ],
    ),
  );

  Future<void> _save() async {
    Map<String, String> customHeaders;
    try {
      final value = headers.text.trim();
      if (value.isEmpty) {
        customHeaders = const <String, String>{};
      } else {
        final decoded = jsonDecode(value);
        if (decoded is! Map) throw const FormatException();
        customHeaders = decoded.map((key, value) => MapEntry('$key', '$value'));
      }
    } on Object {
      _snack(context, '自定义请求头必须是 JSON 对象');
      return;
    }
    setState(() => saving = true);
    try {
      final saved = await controller.voice.saveProfile(
        id: selectedId == '__new' ? null : selectedId,
        provider: provider,
        name: name.text,
        endpoint: endpoint.text,
        apiKey: apiKey.text,
        model: model.text,
        voiceId: voiceId.text,
        outputFormat: outputFormat.text,
        options: <String, Object?>{
          if (appId.text.trim().isNotEmpty) 'appId': appId.text.trim(),
          if (cluster.text.trim().isNotEmpty) 'cluster': cluster.text.trim(),
        },
        customHeaders: customHeaders,
      );
      await controller.refreshVoices();
      if (!mounted) return;
      setState(() => _load(saved));
      _snack(context, '语音接口已保存');
    } on Object catch (error) {
      if (mounted) _snack(context, '$error');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> _loadApiKey(String profileId, int generation) async {
    final value = await controller.voice.vault.readVoiceApiKey(profileId);
    if (!mounted ||
        generation != _keyLoadGeneration ||
        selectedId != profileId) {
      return;
    }
    setState(() {
      apiKey.text = value ?? '';
      loadingApiKey = false;
    });
  }

  Future<void> _delete() async {
    final profile = controller.voiceProfiles
        .where((item) => item.id == selectedId)
        .firstOrNull;
    if (profile == null) return;
    await controller.voice.deleteProfile(profile.id);
    await controller.refreshVoices();
    if (mounted) setState(() => _load(controller.activeVoiceProfile));
  }
}

class _LegacyApiSettingsPanel extends StatefulWidget {
  const _LegacyApiSettingsPanel({required this.controller});
  final AppController controller;

  @override
  State<_LegacyApiSettingsPanel> createState() =>
      _LegacyApiSettingsPanelState();
}

class _LegacyApiSettingsPanelState extends State<_LegacyApiSettingsPanel> {
  late final TextEditingController name;
  late final TextEditingController endpoint;
  late final TextEditingController apiKey;
  late final TextEditingController headers;
  String selectedId = '__default';
  bool showApiKey = false;
  bool loadingApiKey = false;
  int _keyLoadGeneration = 0;
  String status = '还没有获取模型列表';

  AppController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    name = TextEditingController();
    endpoint = TextEditingController();
    apiKey = TextEditingController();
    headers = TextEditingController();
    final profile = controller.activeProfile ?? controller.profiles.firstOrNull;
    _load(profile);
  }

  void _load(ApiProfile? profile) {
    selectedId = profile?.id ?? '__default';
    name.text = profile?.name ?? '默认接口';
    endpoint.text = profile?.endpoint ?? '';
    showApiKey = false;
    apiKey.clear();
    loadingApiKey = profile != null;
    final generation = ++_keyLoadGeneration;
    if (profile != null) {
      unawaited(_loadApiKey(profile.id, generation));
    }
    headers.text = profile == null || profile.customHeaders.isEmpty
        ? ''
        : const JsonEncoder.withIndent('  ').convert(profile.customHeaders);
    status = profile == null || profile.models.isEmpty
        ? '还没有获取模型列表'
        : '已获取 ${profile.models.length} 个模型';
  }

  @override
  void dispose() {
    name.dispose();
    endpoint.dispose();
    apiKey.dispose();
    headers.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(14, 0, 14, 0),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _label('已保存接口'),
        const SizedBox(height: 6),
        _LegacySelect(
          value: selectedId,
          items: <(String, String)>[
            if (controller.profiles.isEmpty) ('__default', '默认接口'),
            ...controller.profiles.map((profile) => (profile.id, profile.name)),
          ],
          onChanged: (value) {
            final profile = controller.profiles
                .where((item) => item.id == value)
                .firstOrNull;
            setState(() => _load(profile));
          },
        ),
        const SizedBox(height: 12),
        _controlledField('接口名称', name),
        const SizedBox(height: 12),
        _controlledField(
          'OpenAI-compatible endpoint',
          endpoint,
          hintText: 'https://api.example.com/v1',
        ),
        const SizedBox(height: 5),
        const Text(
          '填写到 /v1 即可；请求会自动补 /chat/completions 和 /models。',
          style: TextStyle(fontSize: 10.5, color: Color(0xFF77716B)),
        ),
        const SizedBox(height: 12),
        _controlledField(
          'API key',
          apiKey,
          hintText: loadingApiKey ? '正在读取…' : 'sk-...',
          obscure: !showApiKey,
          suffixIcon: loadingApiKey
              ? const Padding(
                  padding: EdgeInsets.all(11),
                  child: CircularProgressIndicator(strokeWidth: 1.5),
                )
              : showApiKey
              ? IconButton(
                  tooltip: '复制 API key',
                  onPressed: apiKey.text.isEmpty
                      ? null
                      : () async {
                          await Clipboard.setData(
                            ClipboardData(text: apiKey.text),
                          );
                          if (context.mounted) {
                            _snack(context, 'API key 已复制');
                          }
                        },
                  icon: const Icon(Icons.copy_outlined, size: 18),
                )
              : null,
        ),
        SizedBox(
          height: 34,
          child: Row(
            children: <Widget>[
              Checkbox(
                value: showApiKey,
                onChanged: loadingApiKey
                    ? null
                    : (value) => setState(() => showApiKey = value == true),
              ),
              const Text('显示 key', style: TextStyle(fontSize: 11.7)),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _controlledField(
          'Custom headers JSON',
          headers,
          hintText: '{"HTTP-Referer":"http://localhost"}',
          minLines: 3,
          maxLines: 3,
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 44,
          child: Row(
            children: <Widget>[
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => setState(() => _load(null)),
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: const Text('新接口'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _save,
                  icon: const Icon(Icons.storage_outlined, size: 18),
                  label: const Text('保存'),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 44,
          child: FilledButton.icon(
            onPressed: _fetch,
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF101010),
              foregroundColor: Colors.white,
            ),
            icon: const Icon(Icons.download_outlined, size: 18),
            label: const Text('获取模型'),
          ),
        ),
        Text(
          status,
          style: const TextStyle(fontSize: 10.5, color: Color(0xFF77716B)),
        ),
      ],
    ),
  );

  Widget _label(String value) => Text(
    value,
    style: const TextStyle(
      fontSize: 10.8,
      fontWeight: FontWeight.w600,
      color: _lightMuted,
    ),
  );

  Widget _controlledField(
    String label,
    TextEditingController field, {
    String? hintText,
    bool obscure = false,
    Widget? suffixIcon,
    int minLines = 1,
    int maxLines = 1,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      _label(label),
      const SizedBox(height: 7),
      SizedBox(
        height: maxLines == 1 ? 40 : 96,
        child: TextField(
          controller: field,
          obscureText: obscure,
          onChanged: suffixIcon == null ? null : (_) => setState(() {}),
          expands: maxLines > 1,
          minLines: maxLines > 1 ? null : minLines,
          maxLines: maxLines > 1 ? null : maxLines,
          textAlignVertical: TextAlignVertical.top,
          style: const TextStyle(fontSize: 12.6, height: 1.28),
          decoration: InputDecoration(
            hintText: hintText,
            suffixIcon: suffixIcon,
            constraints: BoxConstraints.tightFor(
              height: maxLines == 1 ? 40 : 96,
            ),
            contentPadding: EdgeInsets.symmetric(
              horizontal: 10,
              vertical: maxLines == 1 ? 8 : 12,
            ),
          ),
        ),
      ),
    ],
  );

  Map<String, String> _headers() {
    if (headers.text.trim().isEmpty) return <String, String>{};
    final decoded = jsonDecode(headers.text);
    if (decoded is! Map)
      throw const FormatException('Custom headers 必须是 JSON 对象');
    return decoded.map((key, value) => MapEntry('$key', '$value'));
  }

  Future<void> _loadApiKey(String profileId, int generation) async {
    final value = await controller.settingsService.vault.readApiKey(profileId);
    if (!mounted ||
        generation != _keyLoadGeneration ||
        selectedId != profileId) {
      return;
    }
    setState(() {
      apiKey.text = value ?? '';
      loadingApiKey = false;
    });
  }

  Future<void> _save() async {
    try {
      final old = controller.profiles
          .where((item) => item.id == selectedId)
          .firstOrNull;
      final saved = await controller.settingsService.saveProfile(
        id: old?.id,
        name: name.text,
        endpoint: endpoint.text,
        apiKey: apiKey.text,
        models: old?.models ?? const <String>[],
        customHeaders: _headers(),
      );
      await controller.reload();
      if (!mounted) return;
      final refreshed = controller.profiles
          .where((item) => item.id == saved.id)
          .firstOrNull;
      setState(() => _load(refreshed));
      _snack(context, '接口已保存');
    } on Object catch (error) {
      if (mounted) _snack(context, '$error');
    }
  }

  Future<void> _fetch() async {
    try {
      if (mounted) setState(() => status = '正在获取模型列表…');
      final old = controller.profiles
          .where((item) => item.id == selectedId)
          .firstOrNull;
      var saved = await controller.settingsService.saveProfile(
        id: old?.id,
        name: name.text,
        endpoint: endpoint.text,
        apiKey: apiKey.text,
        models: old?.models ?? const <String>[],
        customHeaders: _headers(),
      );
      final fetched = await controller.fetchModels(saved);
      final models = fetched
          .map((model) => model.trim())
          .where((model) => model.isNotEmpty)
          .toSet()
          .toList();
      saved = await controller.settingsService.saveProfile(
        id: saved.id,
        name: name.text,
        endpoint: endpoint.text,
        apiKey: '',
        models: models,
        customHeaders: _headers(),
      );
      await controller.reload();
      if (!mounted) return;
      final refreshed = controller.profiles
          .where((item) => item.id == saved.id)
          .firstOrNull;
      setState(() {
        _load(refreshed);
        status = '已获取 ${models.length} 个模型';
      });
    } on Object catch (error) {
      if (mounted) _snack(context, '$error');
    }
  }
}

class _LegacyProfileSettingsPanel extends StatefulWidget {
  const _LegacyProfileSettingsPanel({required this.controller});
  final AppController controller;

  @override
  State<_LegacyProfileSettingsPanel> createState() =>
      _LegacyProfileSettingsPanelState();
}

class _LegacyProfileSettingsPanelState
    extends State<_LegacyProfileSettingsPanel> {
  late final TextEditingController prompt;

  @override
  void initState() {
    super.initState();
    prompt = TextEditingController(
      text: '${widget.controller.settings['systemPrompt'] ?? ''}',
    );
  }

  @override
  void dispose() {
    prompt.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(14, 0, 14, 0),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _LegacySettingsField(
          label: 'Name',
          initialValue: '${widget.controller.settings['profileName'] ?? '用户'}',
          onChanged: (value) =>
              unawaited(widget.controller.saveSetting('profileName', value)),
        ),
        const SizedBox(height: 12),
        const Text(
          'Global prompt',
          style: TextStyle(fontSize: 12, color: _lightMuted),
        ),
        const SizedBox(height: 6),
        SizedBox(
          height: 96,
          child: TextField(
            controller: prompt,
            expands: true,
            minLines: null,
            maxLines: null,
            textAlignVertical: TextAlignVertical.top,
            style: const TextStyle(fontSize: 12.6, height: 1.28),
            decoration: InputDecoration(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 8,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: Color(0xFFE5E0DB)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: Color(0xFFE5E0DB)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: _accent, width: 1.3),
              ),
            ),
          ),
        ),
        const SizedBox(height: 15.6667),
        Row(
          mainAxisAlignment: MainAxisAlignment.start,
          children: <Widget>[
            SizedBox(
              width: 56.73,
              height: 26.67,
              child: OutlinedButton(
                onPressed: () => unawaited(
                  widget.controller.saveSetting('systemPrompt', prompt.text),
                ),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  textStyle: const TextStyle(fontSize: 11.7),
                ),
                child: const Text('保存'),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 56.73,
              height: 26.67,
              child: OutlinedButton(
                onPressed: () => setState(() => prompt.clear()),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  textStyle: const TextStyle(fontSize: 11.7),
                ),
                child: const Text('重置'),
              ),
            ),
          ],
        ),
      ],
    ),
  );
}

class _LegacyToolboxSettingsPanel extends StatelessWidget {
  const _LegacyToolboxSettingsPanel({required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final tools = ToolService.legacyChatDefinitions
        .where((tool) => tool.name != 'web_search' && tool.name != 'fetch_url')
        .toList();
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _LegacySettingsSwitchRow(
            legacyIcon: _LegacyIconKind.tool,
            label: '允许 AI 主动使用内部工具',
            value: controller.settings['toolboxEnabled'] != false,
            onChanged: (value) =>
                unawaited(controller.saveSetting('toolboxEnabled', value)),
          ),
          const _LegacySettingsHint(
            '开启后，请求会使用非流式工具循环。私密对话只开放时间工具，不会读写记忆或日记。',
            legacyLines: 1,
          ),
          _LegacySettingsSwitchRow(
            legacyIcon: _LegacyIconKind.globe,
            label: '允许 AI 搜索网络',
            value: controller.settings['webSearchEnabled'] == true,
            onChanged: (value) =>
                unawaited(controller.saveSetting('webSearchEnabled', value)),
          ),
          const _LegacySettingsHint(
            '开启后，AI 可以通过 web_search 工具搜索网络信息。输入框旁的 🌐 按钮与此同步。',
            legacyLines: 1,
          ),
          _LegacySettingsSwitchRow(
            legacyIcon: _LegacyIconKind.link,
            label: '允许 AI 抓取网页内容',
            value: controller.settings['fetchUrlEnabled'] == true,
            onChanged: (value) =>
                unawaited(controller.saveSetting('fetchUrlEnabled', value)),
          ),
          const _LegacySettingsHint(
            '开启后，AI 可以通过 fetch_url 工具读取你提供的链接内容。',
            legacyLines: 1,
          ),
          const SizedBox(height: 12),
          for (var index = 0; index < tools.length; index++) ...<Widget>[
            _LegacySettingsSwitchRow(
              legacyIcon: _toolLegacyIcon(tools[index].name),
              label: _toolLabel(tools[index].name),
              value: controller.toolEnabled(tools[index].name),
              onChanged: (value) => unawaited(
                controller.setToolEnabled(tools[index].name, value),
              ),
            ),
            _LegacySettingsHint(
              _legacyToolboxHint(tools[index].name).text,
              legacyLines: _legacyToolboxHint(tools[index].name).lines,
            ),
            if (index + 1 < tools.length) const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }

  _LegacyIconKind _toolLegacyIcon(String name) => switch (name) {
    'get_time' => _LegacyIconKind.clock,
    'search_memory' ||
    'search_diary_entries' ||
    'search_files' => _LegacyIconKind.search,
    'create_memory' || 'update_memory' => _LegacyIconKind.brain,
    'delete_memory' ||
    'request_delete_diary_entry' ||
    'delete_diary_entry' ||
    'delete_file' => _LegacyIconKind.trash,
    'create_diary_entry' || 'read_diary_entry' => _LegacyIconKind.book,
    'revise_diary_entry' ||
    'edit_file' ||
    'set_greeting' ||
    'set_splash_phrases' => _LegacyIconKind.edit,
    'read_file' || 'create_file' => _LegacyIconKind.file,
    _ => _LegacyIconKind.tool,
  };

  ({String text, int? lines}) _legacyToolboxHint(String name) {
    final text =
        '开启后，AI 可以通过 ${_legacyToolName(name)} 工具${_legacyToolDescription(name)}';
    return switch (name) {
      'get_time' => (
        text: '开启后，AI 可以通过 get_time 工具读取用户本机的当前日期、时间、时区和时间段，用于\n时间感知。',
        lines: 2,
      ),
      'search_memory' => (
        text:
            '开启后，AI 可以通过 search_memory 工具从本地记忆库搜索非私密记忆，返回匹配的记忆\n列表（含完整UUID、等级、标签、内容）。critical 记忆已默认注入，其它等级需要按需搜\n索。',
        lines: 3,
      ),
      'create_memory' => (
        text:
            '开启后，AI 可以通过 create_memory 工具把具有长期价值的信息写入本地记忆库。不要把\n普通寒暄或一次性信息写入记忆。创建成功后返回新记忆的完整UUID。',
        lines: 2,
      ),
      _ => (text: text, lines: null),
    };
  }
}

class _LegacyModelsSettingsPanel extends StatelessWidget {
  const _LegacyModelsSettingsPanel({
    required this.controller,
    required this.onAdd,
  });
  final AppController controller;
  final VoidCallback onAdd;

  double _modelsTextScale() {
    final explicit = (controller.settings['fontScale'] as num?)?.toDouble();
    final base = explicit != null && explicit != 1
        ? explicit.clamp(.8, 1.4)
        : switch ('${controller.settings['fontSize'] ?? 'compact'}') {
            'tiny' => .84,
            'regular' => 1.0,
            'large' => 1.08,
            _ => .9,
          };
    return (base * (19 / 18)).clamp(.8, 1.4);
  }

  @override
  Widget build(BuildContext context) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(_modelsTextScale())),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 0),
      child: Column(
        children: <Widget>[
          for (var i = 0; i < controller.modelSlots.length; i++) ...<Widget>[
            if (i > 0) const SizedBox(height: 14),
            _LegacyModelCard(
              key: ValueKey(controller.modelSlots[i]['id']),
              controller: controller,
              slot: controller.modelSlots[i],
            ),
          ],
          const SizedBox(height: 14),
          SizedBox(
            height: 38,
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: controller.modelSlots.length < 5 ? onAdd : null,
              icon: const Icon(Icons.add_rounded, size: 18),
              label: Text(
                controller.modelSlots.length < 5 ? '添加模型' : '已达到 5 个模型上限',
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _LegacyModelCard extends StatefulWidget {
  const _LegacyModelCard({
    required this.controller,
    required this.slot,
    super.key,
  });
  final AppController controller;
  final Map<String, Object?> slot;

  @override
  State<_LegacyModelCard> createState() => _LegacyModelCardState();
}

class _LegacyModelCardState extends State<_LegacyModelCard> {
  late Map<String, Object?> slot;
  late final TextEditingController labelController;
  late final TextEditingController contextController;

  @override
  void initState() {
    super.initState();
    slot = Map<String, Object?>.of(widget.slot);
    labelController = TextEditingController(text: '${slot['label'] ?? ''}');
    contextController = TextEditingController(
      text: slot['contextTokens'] == null
          ? ''
          : _formatContextBudgetK(slot['contextTokens'] as num),
    );
  }

  @override
  void dispose() {
    labelController.dispose();
    contextController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _LegacyModelCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (canonicalJson(oldWidget.slot) != canonicalJson(widget.slot)) {
      slot = Map<String, Object?>.of(widget.slot);
      final nextLabel = '${slot['label'] ?? ''}';
      if (labelController.text != nextLabel) {
        labelController.value = TextEditingValue(
          text: nextLabel,
          selection: TextSelection.collapsed(offset: nextLabel.length),
        );
      }
      final nextContext = slot['contextTokens'] == null
          ? ''
          : _formatContextBudgetK(slot['contextTokens'] as num);
      if (contextController.text != nextContext) {
        contextController.value = TextEditingValue(
          text: nextContext,
          selection: TextSelection.collapsed(offset: nextContext.length),
        );
      }
    }
  }

  Future<void> _save(String key, Object? value) async {
    setState(() => slot[key] = value);
    await widget.controller.saveModelSlot(slot);
  }

  @override
  Widget build(BuildContext context) {
    final encodedModel =
        '${slot['apiProfileId'] ?? ''}::${slot['apiName'] ?? ''}';
    final options = <(String, String)>[
      ('', '选择真实模型 ID'),
      for (final profile in widget.controller.profiles)
        for (final model in profile.models)
          ('${profile.id}::$model', '${profile.name} / $model'),
    ];
    final apiName = '${slot['apiName'] ?? ''}';
    if (apiName.isNotEmpty && !options.any((item) => item.$1 == encodedModel)) {
      options.insert(1, (encodedModel, apiName));
    }
    final hasModel = options.any((item) => item.$1 == encodedModel);
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: const Color(0xFFE5E0DB)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Container(
            height: 48.3333,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: const BoxDecoration(
              color: Color(0xFFF4F2EF),
              border: Border(bottom: BorderSide(color: Color(0xFFE5E0DB))),
            ),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    '${slot['label'] ?? ''}',
                    style: const TextStyle(
                      fontSize: 12.6,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (!const <String>{
                  'sonnet',
                  'opus',
                  'haiku',
                }.contains('${slot['id']}')) ...<Widget>[
                  IconButton(
                    onPressed: () =>
                        widget.controller.deleteModelSlot('${slot['id']}'),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: 28,
                      height: 28,
                    ),
                    tooltip: '删除模型',
                    icon: const Icon(
                      Icons.delete_outline,
                      size: 16,
                      color: _lightDanger,
                    ),
                  ),
                  const SizedBox(width: 4),
                ],
                SizedBox(
                  width: 60,
                  height: 28,
                  child: OutlinedButton(
                    onPressed: () => _save('stream', slot['stream'] == false),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      textStyle: const TextStyle(
                        fontSize: 9.9,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        const _LegacyIcon(_LegacyIconKind.waveform, size: 14),
                        const SizedBox(width: 5),
                        Text(slot['stream'] == false ? '非流式' : '流式'),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
            child: SizedBox(
              height: 22.6667,
              child: Row(
                children: <Widget>[
                  Expanded(
                    flex: 9,
                    child: DecoratedBox(
                      decoration: const BoxDecoration(
                        border: Border(
                          top: BorderSide(color: Color(0xFFDCDCDC), width: 2),
                          bottom: BorderSide(
                            color: Color(0xFFDCDCDC),
                            width: 2,
                          ),
                          left: BorderSide(color: Color(0xFF979797)),
                          right: BorderSide(color: Color(0xFF979797)),
                        ),
                      ),
                      child: TextFormField(
                        controller: labelController,
                        style: const TextStyle(fontSize: 12.6, height: 1),
                        decoration: const InputDecoration(
                          hintText: '模型显示名',
                          filled: false,
                          constraints: BoxConstraints.tightFor(height: 22.6667),
                          contentPadding: EdgeInsets.fromLTRB(2, 1, 2, 1),
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                        ),
                        onChanged: (value) => unawaited(_save('label', value)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 11,
                    child: _LegacySelect(
                      value: hasModel ? encodedModel : '',
                      hint: '选择真实模型 ID',
                      items: options,
                      height: 22.6667,
                      borderRadius: 0,
                      borderColor: const Color(0xFF767676),
                      borderWidth: .6667,
                      horizontalPadding: 2,
                      fontSize: 12.6,
                      compact: true,
                      onChanged: (value) {
                        final parts = value.split('::');
                        slot['apiProfileId'] = parts.first;
                        unawaited(_save('apiName', parts.skip(1).join('::')));
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 4),
          _LegacyModelSlider(
            label: '温度',
            value: slot['temperature'] as num?,
            min: 0,
            max: 2,
            divisions: 40,
            fallback: .8,
            onChanged: (value) => _save('temperature', value),
          ),
          _LegacyModelSlider(
            label: 'Top-P',
            value: slot['topP'] as num?,
            min: 0,
            max: 1,
            divisions: 20,
            fallback: 1,
            onChanged: (value) => _save('topP', value),
          ),
          _LegacyModelSlider(
            label: '词频惩罚',
            value: slot['frequencyPenalty'] as num?,
            min: -2,
            max: 2,
            divisions: 80,
            fallback: 0,
            onChanged: (value) => _save('frequencyPenalty', value),
          ),
          _LegacyModelSlider(
            label: '存在惩罚',
            value: slot['presencePenalty'] as num?,
            min: -2,
            max: 2,
            divisions: 80,
            fallback: 0,
            onChanged: (value) => _save('presencePenalty', value),
          ),
          _LegacyModelSlider(
            label: '回复令牌',
            value: slot['maxTokens'] as num?,
            min: 256,
            max: 16384,
            divisions: 63,
            fallback: 4096,
            integer: true,
            onChanged: (value) => _save('maxTokens', value),
          ),
          SizedBox(
            height: 34,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(
                children: <Widget>[
                  SizedBox(
                    width: 78,
                    child: Stack(
                      children: <Widget>[
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            '上下文预算(K)',
                            maxLines: 1,
                            overflow: TextOverflow.visible,
                            style: const TextStyle(
                              fontSize: 9.9,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF77716B),
                            ),
                          ),
                        ),
                        Align(
                          alignment: Alignment.centerRight,
                          child: Text(
                            slot['contextTokens'] == null
                                ? 'none'
                                : _formatContextBudgetK(
                                    slot['contextTokens'] as num,
                                  ),
                            style: const TextStyle(
                              fontSize: 10.8,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: SizedBox(
                      height: 22.6667,
                      child: DecoratedBox(
                        decoration: const BoxDecoration(
                          border: Border(
                            top: BorderSide(color: Color(0xFFDCDCDC), width: 2),
                            bottom: BorderSide(
                              color: Color(0xFFDCDCDC),
                              width: 2,
                            ),
                            left: BorderSide(color: Color(0xFF979797)),
                            right: BorderSide(color: Color(0xFF979797)),
                          ),
                        ),
                        child: TextFormField(
                          controller: contextController,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            hintText: 'none',
                            filled: false,
                            constraints: BoxConstraints.tightFor(
                              height: 22.6667,
                            ),
                            contentPadding: EdgeInsets.fromLTRB(2, 1, 2, 1),
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                          ),
                          onChanged: (value) => unawaited(
                            _save(
                              'contextTokens',
                              int.tryParse(value) == null
                                  ? null
                                  : int.parse(value) * 1000,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  SizedBox(
                    width: 38,
                    height: 20,
                    child: OutlinedButton(
                      onPressed: () => _save(
                        'contextTokens',
                        slot['contextTokens'] == null ? 128000 : null,
                      ),
                      style: OutlinedButton.styleFrom(
                        padding: EdgeInsets.zero,
                        backgroundColor: slot['contextTokens'] == null
                            ? const Color(0xFFD7D0CA)
                            : Colors.white,
                        foregroundColor: slot['contextTokens'] == null
                            ? Colors.white
                            : const Color(0xFF77716B),
                        textStyle: const TextStyle(
                          fontSize: 8.1,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      child: const Text('none'),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }
}

class _LegacyModelSlider extends StatelessWidget {
  const _LegacyModelSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.fallback,
    required this.onChanged,
    this.integer = false,
  });
  final String label;
  final num? value;
  final double min;
  final double max;
  final int divisions;
  final double fallback;
  final bool integer;
  final ValueChanged<num?> onChanged;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 34,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 78,
            child: Stack(
              children: <Widget>[
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.visible,
                    style: const TextStyle(
                      fontSize: 9.9,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF77716B),
                    ),
                  ),
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    value == null ? 'none' : _formatModelParameter(value!),
                    style: const TextStyle(
                      fontSize: 10.8,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: SizedBox(
              height: 24,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 5,
                  activeTrackColor: const Color(0xFFD7D0CA),
                  inactiveTrackColor: const Color(0xFFD7D0CA),
                  disabledActiveTrackColor: const Color(0xFFD7D0CA),
                  disabledInactiveTrackColor: const Color(0xFFD7D0CA),
                  thumbColor: _accent,
                  disabledThumbColor: const Color(0xFFC96F47),
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 8,
                    disabledThumbRadius: 8,
                  ),
                  tickMarkShape: SliderTickMarkShape.noTickMark,
                  overlayShape: SliderComponentShape.noOverlay,
                ),
                child: Slider(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  value: (value?.toDouble() ?? fallback).clamp(min, max),
                  min: min,
                  max: max,
                  divisions: divisions,
                  onChanged: value == null
                      ? null
                      : (next) => onChanged(integer ? next.round() : next),
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          SizedBox(
            width: 38,
            height: 20,
            child: OutlinedButton(
              onPressed: () => onChanged(value == null ? fallback : null),
              style: OutlinedButton.styleFrom(
                padding: EdgeInsets.zero,
                backgroundColor: value == null
                    ? const Color(0xFFD7D0CA)
                    : Colors.white,
                foregroundColor: value == null
                    ? Colors.white
                    : const Color(0xFF77716B),
                textStyle: const TextStyle(
                  fontSize: 8.1,
                  fontWeight: FontWeight.w700,
                ),
              ),
              child: const Text('none'),
            ),
          ),
        ],
      ),
    ),
  );
}

class _LegacyPreferencesSettingsPanel extends StatelessWidget {
  const _LegacyPreferencesSettingsPanel({
    required this.controller,
    required this.fontValue,
  });

  final AppController controller;
  final String fontValue;

  @override
  Widget build(BuildContext context) {
    final theme = '${controller.settings['themeMode'] ?? 'system'}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SizedBox(
            height: 44,
            child: Row(
              children: <Widget>[
                const SizedBox(
                  width: 22,
                  height: 22,
                  child: _LegacyIcon(_LegacyIconKind.moon, size: 22),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text('Appearance', style: TextStyle(fontSize: 13)),
                ),
                Text(
                  switch (theme) {
                    'light' => 'Light',
                    'dark' => 'Dark',
                    _ => 'System',
                  },
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF77716B),
                  ),
                ),
              ],
            ),
          ),
          Container(
            height: 44,
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: const Color(0xFFF4F2EF),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: <Widget>[
                for (var index = 0; index < 3; index++) ...<Widget>[
                  if (index > 0) const SizedBox(width: 4),
                  Expanded(
                    child: SizedBox(
                      height: 36,
                      child: TextButton(
                        onPressed: () => unawaited(
                          controller.saveSetting(
                            'themeMode',
                            const <String>['system', 'light', 'dark'][index],
                          ),
                        ),
                        style: TextButton.styleFrom(
                          padding: EdgeInsets.zero,
                          backgroundColor:
                              theme ==
                                  const <String>[
                                    'system',
                                    'light',
                                    'dark',
                                  ][index]
                              ? Colors.white
                              : Colors.transparent,
                          foregroundColor: _lightMuted,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          textStyle: const TextStyle(fontSize: 11.7),
                        ),
                        child: Text(
                          const <String>['System', 'Light', 'Dark'][index],
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
          _LegacySettingsDropdown(
            label: '字号',
            value: '${controller.settings['fontSize'] ?? 'compact'}',
            items: const <(String, String)>[
              ('tiny', '更小'),
              ('compact', '紧凑'),
              ('regular', '标准'),
              ('large', '偏大'),
            ],
            onChanged: (value) =>
                unawaited(controller.saveSetting('fontSize', value)),
          ),
          const SizedBox(height: 12),
          _LegacySettingsDropdown(
            label: '字体',
            value: fontValue,
            items: <(String, String)>[
              const ('system', '系统默认'),
              const ('claude', 'Claude 风格'),
              const ('dm', 'DM Sans'),
              const ('jakarta', 'Plus Jakarta Sans'),
              const ('lora', 'Lora'),
              const ('newsreader', 'Newsreader'),
              const ('sourceSerif', 'Source Serif 4'),
              (
                'custom',
                '${controller.settings['customFontName'] ?? ''}'.trim().isEmpty
                    ? '自定义字体'
                    : '${controller.settings['customFontName']}',
              ),
            ],
            onChanged: (value) {
              final stored = value == 'custom'
                  ? '${controller.settings['customFontFamily'] ?? ''}'
                            .trim()
                            .isEmpty
                        ? 'custom'
                        : '${controller.settings['customFontFamily']}'
                  : value;
              unawaited(controller.saveSetting('fontFamily', stored));
            },
          ),
          const SizedBox(height: 12),
          _LegacySettingsField(
            label: '代码块超过几行自动折叠',
            initialValue: '${controller.settings['codeFoldLines'] ?? 5}',
            onChanged: (value) => unawaited(
              controller.saveSetting('codeFoldLines', int.tryParse(value) ?? 0),
            ),
          ),
          const SizedBox(height: 5),
          const _LegacySettingsHint('默认 5 行。填 0 就不自动折叠；HTML 代码块会显示运行按钮。'),
          _LegacySettingsSwitchRow(
            legacyIcon: _LegacyIconKind.ghost,
            label: '显示小机子头像',
            value: controller.settings['showAssistantAvatar'] == true,
            onChanged: (value) =>
                unawaited(controller.saveSetting('showAssistantAvatar', value)),
          ),
          _LegacySettingsSwitchRow(
            legacyIcon: _LegacyIconKind.user,
            label: '显示用户头像',
            value: controller.settings['showUserAvatar'] == true,
            onChanged: (value) =>
                unawaited(controller.saveSetting('showUserAvatar', value)),
          ),
          Row(
            children: <Widget>[
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: controller.installCustomFont,
                  icon: const Icon(Icons.upload_outlined, size: 18),
                  label: const Text('上传 TTF'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: controller.resetCustomFont,
                  child: const Text('系统字体'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          _LegacySettingsValueRow(
            legacyIcon: _LegacyIconKind.globe,
            label: 'Speech language',
            value: '${controller.settings['language'] ?? 'zh-CN'}',
          ),
          const _LegacySettingsValueRow(
            legacyIcon: _LegacyIconKind.shield,
            label: 'Privacy',
            trailingChevron: true,
          ),
        ],
      ),
    );
  }
}

class _DiagnosticsSettingsPanel extends StatefulWidget {
  const _DiagnosticsSettingsPanel({required this.controller});

  final AppController controller;

  @override
  State<_DiagnosticsSettingsPanel> createState() =>
      _DiagnosticsSettingsPanelState();
}

class _DiagnosticsSettingsPanelState extends State<_DiagnosticsSettingsPanel> {
  AppController get controller => widget.controller;
  late Future<List<Map<String, Object?>>> _events;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _refresh() => _events = controller.diagnosticEntries(limit: 300);

  Future<void> _showLogs() async {
    final text = await controller.diagnosticText(limit: 300);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('最近的脱敏诊断日志'),
        content: SizedBox(
          width: 640,
          height: MediaQuery.sizeOf(dialogContext).height * .62,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Theme.of(dialogContext).colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(12),
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: SelectableText(
                text == '[]' ? '还没有诊断事件。请先复现一次问题。' : text,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
              ),
            ),
          ),
        ),
        actions: <Widget>[
          TextButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: text));
              if (dialogContext.mounted) {
                _snack(dialogContext, '日志已复制');
              }
            },
            icon: const Icon(Icons.copy_outlined, size: 18),
            label: const Text('复制'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('完成'),
          ),
        ],
      ),
    );
  }

  Future<void> _export() async {
    try {
      final path = await controller.shareDiagnostics();
      if (mounted) _snack(context, '诊断日志已生成：$path');
    } on Object catch (error) {
      if (mounted) _snack(context, '导出失败：$error');
    }
  }

  Future<void> _clear() async {
    await controller.clearDiagnostics();
    if (!mounted) return;
    setState(_refresh);
    _snack(context, '诊断日志已清空');
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(14, 0, 14, 0),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _LegacySettingsSwitchRow(
          legacyIcon: _LegacyIconKind.shield,
          label: '记录脱敏模型日志',
          value: controller.settings['diagnosticsEnabled'] != false,
          onChanged: (value) =>
              unawaited(controller.saveSetting('diagnosticsEnabled', value)),
        ),
        const _LegacySettingsHint(
          '记录请求轮次、上下文裁剪、流式事件、工具名和执行状态；不记录 API Key、完整聊天正文或完整工具参数。',
          legacyLines: 2,
        ),
        const SizedBox(height: 10),
        FutureBuilder<List<Map<String, Object?>>>(
          future: _events,
          builder: (context, snapshot) {
            final values = snapshot.data ?? const <Map<String, Object?>>[];
            final latest = values.firstOrNull;
            return Text(
              values.isEmpty
                  ? '尚无诊断事件'
                  : '最近载入 ${values.length} 条 · ${latest?['event'] ?? 'unknown'} · ${latest?['timestamp'] ?? ''}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11.5, color: _lightMuted),
            );
          },
        ),
        const SizedBox(height: 12),
        Row(
          children: <Widget>[
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _showLogs,
                icon: const Icon(Icons.receipt_long_outlined, size: 18),
                label: const Text('查看'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _export,
                icon: const Icon(Icons.ios_share_outlined, size: 18),
                label: const Text('导出'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: _clear,
          style: OutlinedButton.styleFrom(foregroundColor: _lightDanger),
          icon: const Icon(Icons.delete_outline, size: 18),
          label: const Text('清空日志'),
        ),
      ],
    ),
  );
}

class _LegacyLocalDataSettingsPanel extends StatelessWidget {
  const _LegacyLocalDataSettingsPanel({
    required this.onExport,
    required this.onImport,
    required this.onClear,
    required this.onNewChat,
  });

  final VoidCallback onExport;
  final VoidCallback onImport;
  final VoidCallback onClear;
  final VoidCallback onNewChat;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(14, 0, 14, 0),
    child: Column(
      children: <Widget>[
        const SizedBox(height: 12),
        Row(
          children: <Widget>[
            Expanded(
              child: SizedBox(
                height: 44,
                child: OutlinedButton.icon(
                  onPressed: onExport,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF101010),
                    side: const BorderSide(color: Color(0xFFE5E0DB)),
                    textStyle: const TextStyle(fontSize: 13),
                  ),
                  icon: const _LegacyIcon(_LegacyIconKind.download, size: 18),
                  label: const Text('导出'),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: SizedBox(
                height: 44,
                child: OutlinedButton.icon(
                  onPressed: onImport,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF101010),
                    side: const BorderSide(color: Color(0xFFE5E0DB)),
                    textStyle: const TextStyle(fontSize: 13),
                  ),
                  icon: const _LegacyIcon(_LegacyIconKind.upload, size: 18),
                  label: const Text('导入'),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: <Widget>[
            Expanded(
              child: SizedBox(
                height: 44,
                child: OutlinedButton.icon(
                  onPressed: onClear,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFFBD3E3E),
                    side: const BorderSide(color: _lightDangerLine),
                    textStyle: const TextStyle(fontSize: 13),
                  ),
                  icon: const _LegacyIcon(_LegacyIconKind.trash, size: 18),
                  label: const Text('清空历史'),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: SizedBox(
                height: 44,
                child: OutlinedButton.icon(
                  onPressed: onNewChat,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF101010),
                    side: const BorderSide(color: Color(0xFFE5E0DB)),
                    textStyle: const TextStyle(fontSize: 13),
                  ),
                  icon: const _LegacyIcon(_LegacyIconKind.plus, size: 18),
                  label: const Text('新对话'),
                ),
              ),
            ),
          ],
        ),
      ],
    ),
  );
}

class _LegacySettingsSwitchRow extends StatelessWidget {
  const _LegacySettingsSwitchRow({
    required this.label,
    required this.value,
    required this.onChanged,
    this.icon,
    this.legacyIcon,
  }) : assert(icon != null || legacyIcon != null);
  final IconData? icon;
  final _LegacyIconKind? legacyIcon;
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => Semantics(
    label: label,
    button: true,
    child: ExcludeSemantics(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onChanged(!value),
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: Theme.of(context).dividerColor),
            ),
          ),
          child: SizedBox(
            height: 48,
            child: Row(
              children: <Widget>[
                SizedBox(
                  width: 34,
                  child: Center(
                    child: legacyIcon != null
                        ? _LegacyIcon(legacyIcon!, size: 24)
                        : Icon(icon, size: 24),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(label, style: const TextStyle(fontSize: 12.6)),
                ),
                _LegacySwitch(value: value, onChanged: onChanged),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class _LegacySwitch extends StatelessWidget {
  const _LegacySwitch({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Semantics(
      toggled: value,
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onChanged(!value),
        child: SizedBox(
          width: 48,
          height: 28,
          child: Stack(
            children: <Widget>[
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: value
                        ? (dark ? const Color(0xFFDD8358) : _accent)
                        : (dark
                              ? const Color(0xFF4B4A45)
                              : const Color(0xFFD7D0CA)),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
              AnimatedPositioned(
                duration: const Duration(milliseconds: 180),
                curve: Curves.ease,
                top: 3,
                left: value ? 23 : 3,
                child: Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    color: dark ? const Color(0xFF2A2A28) : Colors.white,
                    shape: BoxShape.circle,
                    boxShadow: const <BoxShadow>[
                      BoxShadow(
                        color: Color(0x2E000000),
                        offset: Offset(0, 1),
                        blurRadius: 4,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LegacySettingsHint extends StatelessWidget {
  const _LegacySettingsHint(this.text, {this.legacyLines});
  final String text;
  final int? legacyLines;

  @override
  Widget build(BuildContext context) {
    final child = Text(
      text,
      strutStyle: const StrutStyle(
        fontSize: 9.9,
        height: 1.25,
        forceStrutHeight: true,
      ),
      style: const TextStyle(fontSize: 9.9, height: 1.25, color: _lightMuted),
    );
    return Semantics(
      label: text.replaceAll('\n', ''),
      excludeSemantics: true,
      child: legacyLines == null
          ? child
          : SizedBox(height: 12.375 * legacyLines!, child: child),
    );
  }
}

class _LegacySettingsDropdown extends StatelessWidget {
  const _LegacySettingsDropdown({
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
  });
  final String label;
  final String value;
  final List<(String, String)> items;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      SizedBox(
        height: 14,
        child: Transform.translate(
          offset: const Offset(-3, -2),
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              height: 1,
              fontWeight: FontWeight.w600,
              color: Color(0xFF77716B),
            ),
          ),
        ),
      ),
      const SizedBox(height: 6),
      _LegacySelect(value: value, items: items, onChanged: onChanged),
    ],
  );
}

class _LegacySelect extends StatelessWidget {
  const _LegacySelect({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    this.hint = '',
    this.height = 40,
    this.borderRadius = 10,
    this.borderColor = _lightLine,
    this.borderWidth = 1,
    this.horizontalPadding = 10,
    this.fontSize = 12.6,
    this.compact = false,
  });

  final String value;
  final List<(String, String)> items;
  final ValueChanged<String> onChanged;
  final String hint;
  final double height;
  final double borderRadius;
  final Color borderColor;
  final double borderWidth;
  final double horizontalPadding;
  final double fontSize;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final selected = items.where((item) => item.$1 == value).firstOrNull;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final surface = dark ? const Color(0xFF252523) : Colors.white;
    final textColor = dark ? const Color(0xFFE8E6E1) : const Color(0xFF101010);
    final muted = dark ? const Color(0xFF96948B) : _lightMuted;
    return MenuAnchor(
      alignmentOffset: Offset(0, compact ? 2 : 4),
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll<Color>(surface),
        elevation: const WidgetStatePropertyAll<double>(8),
        padding: const WidgetStatePropertyAll<EdgeInsets>(
          EdgeInsets.symmetric(vertical: 4),
        ),
        shape: WidgetStatePropertyAll<OutlinedBorder>(
          RoundedRectangleBorder(
            side: BorderSide(
              color: dark ? const Color(0xFF4B4A45) : _lightLine,
            ),
            borderRadius: BorderRadius.circular(compact ? 6 : 10),
          ),
        ),
      ),
      menuChildren: <Widget>[
        for (final item in items)
          MenuItemButton(
            onPressed: () => onChanged(item.$1),
            style: ButtonStyle(
              minimumSize: WidgetStatePropertyAll<Size>(
                Size(compact ? 190 : 260, compact ? 32 : 38),
              ),
              padding: WidgetStatePropertyAll<EdgeInsets>(
                EdgeInsets.symmetric(horizontal: compact ? 9 : 12),
              ),
              foregroundColor: WidgetStatePropertyAll<Color>(textColor),
              backgroundColor: item.$1 == value
                  ? WidgetStatePropertyAll<Color>(
                      dark ? const Color(0xFF343431) : _lightSurfaceSoft,
                    )
                  : null,
              textStyle: WidgetStatePropertyAll<TextStyle>(
                TextStyle(fontSize: compact ? 12 : 13, height: 1.2),
              ),
            ),
            child: SizedBox(
              width: compact ? 166 : 236,
              child: Text(
                item.$2,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
      ],
      builder: (context, menu, child) => Semantics(
        button: true,
        expanded: menu.isOpen,
        child: InkWell(
          onTap: items.isEmpty
              ? null
              : () => menu.isOpen ? menu.close() : menu.open(),
          borderRadius: BorderRadius.circular(borderRadius),
          child: Container(
            width: double.infinity,
            height: height,
            padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
            decoration: BoxDecoration(
              color: surface,
              border: Border.all(color: borderColor, width: borderWidth),
              borderRadius: BorderRadius.circular(borderRadius),
            ),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    selected?.$2 ?? hint,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: selected == null ? muted : textColor,
                      fontSize: fontSize,
                      height: 1,
                    ),
                  ),
                ),
                SizedBox(width: compact ? 2 : 6),
                Icon(
                  Icons.arrow_drop_down_rounded,
                  size: compact ? 14 : 18,
                  color: muted,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LegacySettingsValueRow extends StatelessWidget {
  const _LegacySettingsValueRow({
    required this.label,
    this.value,
    this.trailingChevron = false,
    this.icon,
    this.legacyIcon,
  }) : assert(icon != null || legacyIcon != null);
  final IconData? icon;
  final _LegacyIconKind? legacyIcon;
  final String label;
  final String? value;
  final bool trailingChevron;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 48,
    child: Row(
      children: <Widget>[
        if (legacyIcon != null)
          _LegacyIcon(legacyIcon!, size: 22)
        else
          Icon(icon, size: 22),
        const SizedBox(width: 12),
        Expanded(child: Text(label, style: const TextStyle(fontSize: 13))),
        if (value != null)
          Text(
            value!,
            style: const TextStyle(fontSize: 12, color: Color(0xFF77716B)),
          ),
        if (trailingChevron) const Icon(Icons.chevron_right_rounded, size: 20),
      ],
    ),
  );
}

class _LegacySettingsField extends StatelessWidget {
  const _LegacySettingsField({
    required this.label,
    required this.initialValue,
    required this.onChanged,
    this.minLines = 1,
    this.maxLines = 1,
  });

  final String label;
  final String initialValue;
  final ValueChanged<String> onChanged;
  final int minLines;
  final int maxLines;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      Text(
        label,
        style: const TextStyle(
          fontSize: 10.8,
          fontWeight: FontWeight.w600,
          color: Color(0xFF77716B),
        ),
      ),
      const SizedBox(height: 7),
      SizedBox(
        height: maxLines == 1 ? 40 : 96,
        child: Stack(
          children: <Widget>[
            Positioned.fill(
              child: TextFormField(
                initialValue: initialValue,
                onChanged: onChanged,
                minLines: minLines,
                maxLines: maxLines,
                textAlignVertical: TextAlignVertical.top,
                style: const TextStyle(fontSize: 12.6, height: 1.28),
                decoration: InputDecoration(
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: maxLines == 1 ? 15 : 12,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: Color(0xFFE5E0DB)),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: Color(0xFFE5E0DB)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: _accent, width: 1.3),
                  ),
                ),
              ),
            ),
            if (kIsWeb && maxLines > 1)
              const Positioned(
                top: 1,
                right: 1,
                bottom: 1,
                width: 12,
                child: _LegacyTextareaChrome(),
              ),
          ],
        ),
      ),
    ],
  );
}

class _LegacyTextareaChrome extends StatelessWidget {
  const _LegacyTextareaChrome();

  @override
  Widget build(BuildContext context) => Stack(
    children: <Widget>[
      Column(
        children: <Widget>[
          const SizedBox(
            width: 12,
            height: 12,
            child: _LegacyScrollbarArrow(up: true),
          ),
          const SizedBox(height: 8),
          Container(
            width: 10,
            height: 41,
            decoration: BoxDecoration(
              color: const Color(0xFF77716B),
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          const SizedBox(height: 3),
          const SizedBox(
            width: 12,
            height: 12,
            child: _LegacyScrollbarArrow(up: false),
          ),
          const Spacer(),
        ],
      ),
      const Positioned(
        right: 1,
        bottom: 1,
        width: 8,
        height: 8,
        child: _LegacyResizeGrip(),
      ),
    ],
  );
}

class _LegacyScrollbarArrow extends StatelessWidget {
  const _LegacyScrollbarArrow({required this.up});

  final bool up;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(painter: _LegacyScrollbarArrowPainter(up));
}

class _LegacyScrollbarArrowPainter extends CustomPainter {
  const _LegacyScrollbarArrowPainter(this.up);

  final bool up;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path();
    if (up) {
      path
        ..moveTo(size.width / 2, 3)
        ..lineTo(2.5, 8)
        ..lineTo(size.width - 2.5, 8);
    } else {
      path
        ..moveTo(2.5, 4)
        ..lineTo(size.width - 2.5, 4)
        ..lineTo(size.width / 2, 9);
    }
    path.close();
    canvas.drawPath(path, Paint()..color = const Color(0xFF77716B));
  }

  @override
  bool shouldRepaint(covariant _LegacyScrollbarArrowPainter oldDelegate) =>
      oldDelegate.up != up;
}

class _LegacyResizeGrip extends StatelessWidget {
  const _LegacyResizeGrip();

  @override
  Widget build(BuildContext context) =>
      CustomPaint(painter: const _LegacyResizeGripPainter());
}

class _LegacyResizeGripPainter extends CustomPainter {
  const _LegacyResizeGripPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFF77716B)
      ..strokeWidth = 1
      ..strokeCap = StrokeCap.square;
    canvas
      ..drawLine(const Offset(0, 7), const Offset(7, 0), paint)
      ..drawLine(const Offset(4, 7), const Offset(7, 4), paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _SettingsCard extends StatefulWidget {
  const _SettingsCard({
    required this.title,
    required this.icon,
    required this.children,
    this.first = false,
    this.onOpenChanged,
  });
  final String title;
  final IconData icon;
  final List<Widget> children;
  final bool first;
  final ValueChanged<bool>? onOpenChanged;

  @override
  State<_SettingsCard> createState() => _SettingsCardState();
}

class _SettingsCardState extends State<_SettingsCard> {
  bool open = false;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(bottom: open ? 12.6667 : 14),
    child: Card(
      color: Theme.of(context).brightness == Brightness.dark
          ? _darkSurface86OnBackground
          : _lightSurface86OnBackground,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: Theme.of(context).dividerColor, width: 1),
      ),
      child: Semantics(
        container: true,
        explicitChildNodes: true,
        child: Padding(
          padding: const EdgeInsets.all(1),
          child: Column(
            children: <Widget>[
              InkWell(
                borderRadius: BorderRadius.circular(16),
                overlayColor: const WidgetStatePropertyAll<Color>(
                  Colors.transparent,
                ),
                onTap: () {
                  setState(() => open = !open);
                  widget.onOpenChanged?.call(open);
                },
                child: SizedBox(
                  height: 48,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14.6667),
                    child: Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            widget.title,
                            style: const TextStyle(
                              fontSize: 12.6,
                              fontWeight: FontWeight.w700,
                              height: 1.05,
                            ),
                          ),
                        ),
                        AnimatedRotation(
                          turns: open ? .25 : 0,
                          duration: const Duration(milliseconds: 180),
                          child: _LegacyIcon(
                            _LegacyIconKind.chevronRight,
                            size: 18,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (open)
                Padding(
                  padding: const EdgeInsets.fromLTRB(0, 0, 0, 14.6667),
                  child: Column(children: _withDividers(widget.children)),
                ),
            ],
          ),
        ),
      ),
    ),
  );

  List<Widget> _withDividers(List<Widget> source) => <Widget>[
    for (var i = 0; i < source.length; i++) ...<Widget>[
      if (i > 0) const Divider(height: 1, indent: 18, endIndent: 18),
      source[i],
    ],
  ];
}

class _StandardPage extends StatelessWidget {
  const _StandardPage({
    required this.title,
    required this.subtitle,
    required this.child,
    this.rightPadding = 14,
    this.legacyScrollbar = false,
  });
  final String title;
  final String subtitle;
  final Widget child;
  final double rightPadding;
  final bool legacyScrollbar;

  @override
  Widget build(BuildContext context) => Semantics(
    label: title,
    hint: subtitle.isEmpty ? null : subtitle,
    child: Stack(
      children: <Widget>[
        Padding(
          padding: EdgeInsets.fromLTRB(14, 10, rightPadding, 18),
          child: child,
        ),
        if (legacyScrollbar && kIsWeb) const _LegacyBrowserScrollbar(),
      ],
    ),
  );
}

class _LegacyBrowserScrollbar extends StatelessWidget {
  const _LegacyBrowserScrollbar();

  @override
  Widget build(BuildContext context) => Positioned(
    top: 3,
    right: 3,
    bottom: 0,
    width: 9,
    child: Column(
      children: <Widget>[
        const SizedBox(height: 12, child: _LegacyScrollArrow(up: true)),
        const SizedBox(height: 3),
        Align(
          alignment: Alignment.centerLeft,
          child: Container(
            width: 8.75,
            height: 757,
            decoration: BoxDecoration(
              color: const Color(0xFF8A8A8A),
              borderRadius: BorderRadius.circular(5),
            ),
          ),
        ),
        const Spacer(),
        const SizedBox(height: 12, child: _LegacyScrollArrow(up: false)),
      ],
    ),
  );
}

class _LegacySettingsScrollbar extends StatelessWidget {
  const _LegacySettingsScrollbar({required this.height});
  final double height;

  @override
  Widget build(BuildContext context) => Positioned(
    top: 3,
    right: 3,
    bottom: 0,
    width: 9,
    child: Column(
      children: <Widget>[
        const SizedBox(height: 12, child: _LegacyScrollArrow(up: true)),
        const SizedBox(height: 3),
        Align(
          alignment: Alignment.centerLeft,
          child: Container(
            width: 8.75,
            height: height,
            decoration: BoxDecoration(
              color: const Color(0xFF8A8A8A),
              borderRadius: BorderRadius.circular(5),
            ),
          ),
        ),
        const Spacer(),
        const SizedBox(height: 12, child: _LegacyScrollArrow(up: false)),
      ],
    ),
  );
}

class _LegacyScrollArrow extends StatelessWidget {
  const _LegacyScrollArrow({required this.up});
  final bool up;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(painter: _LegacyScrollArrowPainter(up));
}

class _LegacyScrollArrowPainter extends CustomPainter {
  const _LegacyScrollArrowPainter(this.up);
  final bool up;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2 - 2);
    final path = Path();
    if (up) {
      path
        ..moveTo(center.dx, center.dy - 3)
        ..lineTo(center.dx - 5, center.dy + 4)
        ..lineTo(center.dx + 5, center.dy + 4);
    } else {
      path
        ..moveTo(center.dx, center.dy + 4)
        ..lineTo(center.dx - 5, center.dy - 3)
        ..lineTo(center.dx + 5, center.dy - 3);
    }
    path.close();
    canvas.drawPath(path, Paint()..color = const Color(0xFF8A8A8A));
  }

  @override
  bool shouldRepaint(covariant _LegacyScrollArrowPainter oldDelegate) =>
      oldDelegate.up != up;
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.message,
    this.legacyIcon,
    this.offsetY = 0,
    this.messageGap = 8,
  });
  final IconData icon;
  final String title;
  final String message;
  final _LegacyIconKind? legacyIcon;
  final double offsetY;
  final double messageGap;

  @override
  Widget build(BuildContext context) => Transform.translate(
    offset: Offset(0, offsetY),
    child: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (legacyIcon == null)
            Icon(icon, size: 34, color: _lightMuted)
          else
            _LegacyIcon(legacyIcon!, size: 34, color: _lightMuted),
          if (title.isNotEmpty) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              title,
              style: const TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
                height: 1.35,
                letterSpacing: 1,
              ),
            ),
            SizedBox(height: messageGap),
          ] else
            const SizedBox(height: 8),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              height: 1.33,
              letterSpacing: 1,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    ),
  );
}

String _sectionTitle(AppController controller) => switch (controller.section) {
  AppSection.chat =>
    controller.activeConversation?.title ??
        '${controller.settings['appName'] ?? 'ClaudeChat'}',
  AppSection.memories => 'Ta 的记忆',
  AppSection.diary => 'Ta 的心事',
  AppSection.files => 'Ta的文件',
  AppSection.voices => 'Ta的声音',
  AppSection.workspaces => 'Ta的工作室',
  AppSection.settings => 'Settings',
};

String _levelName(String level) => switch (level) {
  'critical' => '关键',
  'important' => '重要',
  'trivial' => '琐事',
  'archived' => '归档',
  _ => '日常',
};

String _formatContextBudgetK(num value) {
  final k = value >= 1024 ? value / 1000 : value.toDouble();
  final rounded = (k * 10).round() / 10;
  if (rounded == rounded.roundToDouble()) return rounded.round().toString();
  return rounded.toStringAsFixed(1);
}

String _formatModelParameter(num value) {
  if (value == value.roundToDouble()) return value.round().toString();
  return value
      .toStringAsFixed(2)
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');
}

String _fileSizeLabel(String content) {
  final length = content.length;
  if (length < 1000) return '$length 字符';
  return '${(length / 1000).toStringAsFixed(1)}K 字符';
}

String _cleanBoundaryText(String value) => value
    .replaceFirst(RegExp(r'^(?:[ \t]*\r?\n)+'), '')
    .replaceFirst(RegExp(r'(?:\r?\n[ \t]*)+$'), '');

String uncommittedStreamText(String full, String committed) {
  if (full.isEmpty) return '';
  if (committed.isEmpty) return full;
  if (full.startsWith(committed)) return full.substring(committed.length);
  if (committed.endsWith(full) || committed.contains(full)) return '';
  return full;
}

MarkdownStyleSheet _legacyContentMarkdownStyle(
  BuildContext context,
  AppController controller,
) {
  final theme = Theme.of(context);
  final dark = theme.brightness == Brightness.dark;
  final text = dark ? _darkText : _lightText;
  final muted = dark ? _darkMuted : _lightMuted;
  final line = dark ? _darkLine : _lightLine;
  final soft = dark ? _darkSurface : _lightSurfaceSoft;
  final body = TextStyle(
    fontFamily: _bodyFontFamily(controller.settings),
    fontFamilyFallback: _bodyFontFallback(controller.settings),
    fontSize: _legacyChatBodyFontSize,
    height: 1.52,
  );
  final heading = TextStyle(
    fontFamily: _bodyFontFamily(controller.settings),
    fontFamilyFallback: _bodyFontFallback(controller.settings),
    fontWeight: FontWeight.w800,
    height: 1.22,
  );
  return MarkdownStyleSheet.fromTheme(theme).copyWith(
    p: body.copyWith(color: text),
    blockSpacing: 8.3542,
    listIndent: 16.25,
    listBullet: body.copyWith(color: text),
    listBulletPadding: const EdgeInsets.only(right: 4),
    strong: const TextStyle(fontWeight: FontWeight.w800),
    em: const TextStyle(fontStyle: FontStyle.italic),
    h1: heading.copyWith(fontSize: 18, color: text),
    h2: heading.copyWith(fontSize: 17, color: text),
    h3: heading.copyWith(fontSize: 16, color: text),
    h4: heading.copyWith(fontSize: 16, color: text),
    h1Padding: const EdgeInsets.only(top: 12.64, bottom: 5.18),
    h2Padding: const EdgeInsets.only(top: 11.93, bottom: 4.90),
    h3Padding: const EdgeInsets.only(top: 11.23, bottom: 4.61),
    h4Padding: const EdgeInsets.only(top: 11.23, bottom: 4.61),
    code: TextStyle(
      color: text,
      fontFamily: 'monospace',
      fontSize: 13,
      backgroundColor: soft,
    ),
    codeblockPadding: EdgeInsets.zero,
    codeblockDecoration: const BoxDecoration(color: Colors.transparent),
    horizontalRuleDecoration: BoxDecoration(
      border: Border(
        top: BorderSide(color: line.withValues(alpha: .72), width: .666667),
      ),
    ),
    blockquote: body.copyWith(color: muted),
    blockquotePadding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
    blockquoteDecoration: BoxDecoration(
      color: soft,
      border: Border(left: BorderSide(color: line, width: 3)),
      borderRadius: BorderRadius.circular(3),
    ),
    tableHead: body.copyWith(color: text, fontWeight: FontWeight.w700),
    tableBody: body.copyWith(color: text),
    tableBorder: TableBorder.all(color: line, width: 1),
    tableCellsPadding: const EdgeInsets.fromLTRB(10, 7, 10, 7),
    tableHeadCellsPadding: const EdgeInsets.fromLTRB(10, 7, 10, 7),
    tableHeadCellsDecoration: BoxDecoration(color: soft),
  );
}

String _byteSizeLabel(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kib = bytes / 1024;
  if (kib < 1024) return '${kib.toStringAsFixed(1)} KB';
  final mib = kib / 1024;
  if (mib < 1024) return '${mib.toStringAsFixed(1)} MB';
  return '${(mib / 1024).toStringAsFixed(2)} GB';
}

bool _canPreview(String name, String type) {
  final normalizedType = type.toLowerCase();
  final normalizedName = name.toLowerCase();
  return const <String>{'html', 'htm', 'svg'}.contains(normalizedType) ||
      normalizedName.endsWith('.html') ||
      normalizedName.endsWith('.htm') ||
      normalizedName.endsWith('.svg');
}

String _usageNumber(int value) {
  if (value < 1000) return '$value';
  final formatted = value / 1000;
  return '${formatted.toStringAsFixed(formatted >= 100 ? 0 : 1)}K';
}

String _greetingText(AppController controller) {
  final custom = '${controller.settings['greeting'] ?? ''}'.trim();
  if (custom.isNotEmpty) return custom;
  final person = _accountName(controller);
  final hour = DateTime.now().hour;
  if (hour < 6) return '凌晨好，$person';
  if (hour < 11) return '早上好，$person';
  if (hour < 14) return '中午好，$person';
  if (hour < 18) return '下午好，$person';
  return '晚上好，$person';
}

String _accountName(AppController controller) {
  final name = '${controller.settings['profileName'] ?? ''}'.trim();
  return name.isEmpty ? '用户' : name;
}

String _toolLabel(String name) => switch (name) {
  'get_time' => '读取当前时间',
  'search_memory' => '搜索记忆',
  'create_memory' => '创建记忆',
  'update_memory' => '更新记忆',
  'delete_memory' => '删除记忆',
  'create_diary_entry' => '写 AI 日记',
  'revise_diary_entry' => '修订 AI 日记',
  'request_delete_diary_entry' || 'delete_diary_entry' => '删除 AI 日记',
  'search_diary_entries' => '搜索 AI 日记',
  'read_diary_entry' => '读取 AI 日记',
  'search_files' => '搜索文件',
  'read_file' => '读取文件',
  'create_file' => '创建文件',
  'edit_file' => '编辑文件',
  'delete_file' => '删除文件',
  'web_search' => '网络搜索',
  'fetch_url' => '抓取网页',
  'set_greeting' => '修改欢迎语',
  'set_splash_phrases' => '修改开屏语',
  'create_calendar_event' => '创建系统日历日程',
  'schedule_notification' => '创建本地通知',
  'create_system_reminder' => '创建系统提醒事项',
  'update_home_widget' => '更新桌面小组件',
  'create_workspace_file' => '创建工作区文件',
  'edit_workspace_file' => '编辑工作区文件',
  'list_workspace_files' => '检查工作区文件',
  'read_workspace_file' => '读取工作区文件',
  'list_workspace_file_versions' => '检查工作区文件版本',
  'read_workspace_file_version' => '读取工作区文件版本',
  'restore_workspace_file_version' => '恢复工作区文件版本',
  _ => name,
};

String _toolLifecycleNoun(String name) => switch (name) {
  'get_time' => '时间读取',
  'search_memory' => '记忆搜索',
  'create_memory' => '记忆创建',
  'update_memory' => '记忆更新',
  'delete_memory' => '记忆删除',
  'create_diary_entry' => '日记创建',
  'revise_diary_entry' => '日记修订',
  'request_delete_diary_entry' || 'delete_diary_entry' => '日记删除',
  'search_diary_entries' => '日记搜索',
  'read_diary_entry' => '日记读取',
  'search_files' => '文件搜索',
  'read_file' => '文件读取',
  'create_file' => '文件创建',
  'edit_file' => '文件编辑',
  'delete_file' => '文件删除',
  'web_search' => '网络搜索',
  'fetch_url' => '网页读取',
  'set_greeting' => '欢迎语修改',
  'set_splash_phrases' => '开屏语修改',
  'create_calendar_event' => '日历日程创建',
  'schedule_notification' => '本地通知创建',
  'create_system_reminder' => '提醒事项创建',
  'update_home_widget' => '桌面小组件更新',
  'create_workspace_file' => '工作区文件创建',
  'edit_workspace_file' => '工作区文件编辑',
  'list_workspace_files' => '工作区文件检查',
  'read_workspace_file' => '工作区文件读取',
  'list_workspace_file_versions' => '工作区文件版本检查',
  'read_workspace_file_version' => '工作区文件版本读取',
  'restore_workspace_file_version' => '工作区文件版本恢复',
  _ => _toolLabel(name),
};

String _toolProcessLabel(ChatCompletionPart part) {
  final name = '${part.metadata['name'] ?? 'tool'}';
  final preparing = '${part.metadata['status'] ?? ''}' == 'preparing';
  final arguments = part.metadata['arguments'];
  final fileName = arguments is Map
      ? '${arguments['name'] ?? arguments['fileName'] ?? ''}'.trim()
      : '';
  final suffix = fileName.isEmpty
      ? ''
      : '「${fileName.length <= 26 ? fileName : '${fileName.substring(0, 26)}…'}」';
  final verb = preparing ? '准备' : '正在';
  return switch (name) {
    'create_file' || 'create_workspace_file' => '小机子$verb创建文件$suffix',
    'edit_file' || 'edit_workspace_file' => '小机子$verb编辑文件$suffix',
    'read_file' || 'read_workspace_file' => '小机子$verb读取文件$suffix',
    'list_workspace_file_versions' => '小机子$verb检查文件版本$suffix',
    'read_workspace_file_version' => '小机子$verb读取文件版本$suffix',
    'restore_workspace_file_version' => '小机子$verb恢复文件版本$suffix',
    'delete_file' => '小机子$verb删除文件$suffix',
    'search_files' || 'list_workspace_files' => '小机子$verb检查文件',
    'search_memory' => '小机子$verb搜索记忆',
    'create_memory' => '小机子$verb创建记忆',
    'update_memory' => '小机子$verb更新记忆',
    'delete_memory' => '小机子$verb删除记忆',
    'create_diary_entry' => '小机子$verb写日记',
    'revise_diary_entry' => '小机子$verb修订日记',
    'search_diary_entries' => '小机子$verb搜索日记',
    'read_diary_entry' => '小机子$verb读取日记',
    'web_search' => '小机子$verb搜索网络',
    'fetch_url' => '小机子$verb读取网页',
    'get_time' => '小机子$verb读取当前时间',
    _ => '小机子$verb${_toolLifecycleNoun(name)}',
  };
}

String _legacyToolName(String name) => switch (name) {
  'delete_diary_entry' => 'request_delete_diary_entry',
  _ => name,
};

String _legacyToolDescription(String name) => switch (name) {
  'get_time' => '读取用户本机的当前日期、时间、时区和时间段，用于时间感知。',
  'search_memory' =>
    '从本地记忆库搜索非私密记忆，返回匹配的记忆列表（含完整UUID、等级、标签、内容）。critical 记忆已默认注入，其它等级需要按需搜索。',
  'create_memory' => '把具有长期价值的信息写入本地记忆库。不要把普通寒暄或一次性信息写入记忆。创建成功后返回新记忆的完整UUID。',
  'update_memory' =>
    '更新一条已有记忆。必须先通过 search_memory 获取记忆的UUID（形如 a1b2c3-... 的长字符串），不能使用数字序号。不要猜测ID，必须用搜索结果中返回的确切UUID。',
  'delete_memory' =>
    '请求删除一条本地记忆。必须先通过 search_memory 获取记忆的UUID，确认是正确的那条后再提交删除。必须提供删除原因。此操作需要用户审批。',
  'create_diary_entry' => '创建一篇 AI 自己的日记。用户不能编辑正文，但可以查看和导出。',
  'revise_diary_entry' => '修订一篇 AI 日记，旧版本会保留在历史记录里，不需要用户审批。',
  'request_delete_diary_entry' ||
  'delete_diary_entry' => '删除一篇 AI 日记。需要提供删除理由。',
  'search_diary_entries' => '搜索所有AI日记（包含已删除的日记），可按关键词、标签和状态筛选。已删除的日记内容会显示删除原因。',
  'read_diary_entry' => '读取一篇 AI 日记的当前内容和版本历史。已删除日记也可以读取历史。',
  'search_files' => '搜索Ta的文件区中的文件，可按文件名或内容关键词搜索。不包含已删除文件。',
  'read_file' =>
    '读取文件区中一个文件的完整内容。使用文件UUID（id），不是文件名。先通过 search_files 获取文件id，编辑前建议先 read_file 确认原文。',
  'create_file' => '创建文件保存到Ta的文件区。会自动记录版本历史；成功后返回文件UUID（id），后续读取、编辑或删除必须复用该id。',
  'edit_file' =>
    '编辑文件区中已存在的文件。使用 create_file 返回或 search_files 查到的文件UUID（id），不是版本ID。不要猜测ID；如果需要参考原文，先用 read_file 读取完整内容。',
  'delete_file' => '删除文件区中的一个文件（软删除，前端保留记录）。使用文件UUID（id），需要提供删除原因。',
  'set_greeting' => '修改对话首页欢迎语。当用户想让你更改欢迎问候时使用此工具。',
  'set_splash_phrases' => '修改开屏语列表。用户可能需要更新应用开屏时的问候语。',
  _ =>
    ToolService.definitions
            .where((tool) => tool.name == name)
            .map((tool) => tool.description)
            .firstOrNull ??
        '',
};

void _snack(BuildContext context, String message) => ScaffoldMessenger.of(
  context,
).showSnackBar(SnackBar(content: Text(message)));
